#!/usr/bin/env bash
#
# Reproduce what an application actually sees when its lease ends while it is
# holding an open connection. This is the drill behind the lesson's knowledge
# check, and the symptom is not the one most people expect.
#
#   export BAO_ADDR=https://127.0.0.1:8200
#   export BAO_SKIP_VERIFY=1
#   export BAO_TOKEN=<your token>
#   ./lease-expiry-drill.sh
#
# Instead of waiting an hour for the TTL, the script revokes the lease at a
# controlled moment mid-transaction. Revocation and expiry run the same
# revocation_statements, so the observable behaviour is identical.
#
# WHAT YOU ARE ABOUT TO SEE, AND WHY IT IS CONFUSING
#
# Dropping a PostgreSQL role does NOT disconnect the sessions authenticated as
# that role. The connection stays open. Authentication already happened and is
# not re-checked. What disappears is the role's privileges, so the next
# statement fails with:
#
#     ERROR:  permission denied for table payments
#
# on a table the same connection read successfully seconds earlier. That aborts
# the transaction, COMMIT returns ROLLBACK, and the connection remains open and
# permanently useless until the application reconnects.
#
# In production this reads like somebody revoked a GRANT, not like a credential
# expired, and teams lose real time chasing the wrong thing. There is no
# "role does not exist" anywhere in it. That message only appears at CONNECT
# time, and even then PostgreSQL disguises it as a password failure.
set -euo pipefail
: "${BAO_ADDR:?set BAO_ADDR}"
: "${BAO_TOKEN:?set BAO_TOKEN}"

NS_DB="${NS_DB:-databases}"
DB_HOST="${DB_HOST:-postgres.databases.svc.cluster.local}"

CREDS="$(bao read -format=json database/creds/payments-readonly)"
DB_USER="$(printf '%s' "$CREDS" | python3 -c 'import json,sys;print(json.load(sys.stdin)["data"]["username"])')"
DB_PASS="$(printf '%s' "$CREDS" | python3 -c 'import json,sys;print(json.load(sys.stdin)["data"]["password"])')"
LEASE="$(printf '%s' "$CREDS" | python3 -c 'import json,sys;print(json.load(sys.stdin)["lease_id"])')"
echo "username: $DB_USER"

TXN_OUT="$(mktemp)"
trap 'rm -f "$TXN_OUT"' EXIT

kubectl -n "$NS_DB" exec -i psql-client -- \
  env PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -U "$DB_USER" -d appdb >"$TXN_OUT" 2>&1 <<'SQL' &
SELECT now() AS transaction_started;
BEGIN;
SELECT count(*) AS rows_read_ok FROM payments;
SELECT pg_sleep(35);
SELECT count(*) AS rows_read_after_revocation FROM payments;
COMMIT;
SQL
PSQL_PID=$!

sleep 12
echo "revoking at $(date -u +%Y-%m-%dT%H:%M:%SZ), mid-transaction"
bao lease revoke "$LEASE"

wait "$PSQL_PID" || true
echo
echo "==================== what the application saw ===================="
cat "$TXN_OUT"
echo "=================================================================="
echo
echo "The connection never dropped. The privileges did."
