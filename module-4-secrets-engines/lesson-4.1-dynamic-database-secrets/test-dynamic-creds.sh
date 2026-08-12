#!/usr/bin/env bash
#
# Prove a dynamic credential is real: it works, it is scoped, and it stops
# working when the lease ends.
#
#   export BAO_ADDR=https://127.0.0.1:8200
#   export BAO_SKIP_VERIFY=1
#   export BAO_TOKEN=<your token>
#   ./test-dynamic-creds.sh
#
# psql runs inside the cluster, in the psql-client pod, not on your laptop. That
# is deliberate. The engine reaches PostgreSQL over the in-cluster DNS name, and
# testing over a port-forward to 127.0.0.1 exercises a different network path
# than the one that matters. It also means you need no local psql.
set -euo pipefail
: "${BAO_ADDR:?set BAO_ADDR}"
: "${BAO_TOKEN:?set BAO_TOKEN}"

NS_DB="${NS_DB:-databases}"
DB_HOST="${DB_HOST:-postgres.databases.svc.cluster.local}"
ROLE="${ROLE:-payments-readonly}"

pg() {
  kubectl -n "$NS_DB" exec -i psql-client -- \
    env PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -U "$DB_USER" -d appdb "$@"
}

echo "== 1. request a credential =="
CREDS="$(bao read -format=json "database/creds/${ROLE}")"
DB_USER="$(printf '%s' "$CREDS" | python3 -c 'import json,sys;print(json.load(sys.stdin)["data"]["username"])')"
DB_PASS="$(printf '%s' "$CREDS" | python3 -c 'import json,sys;print(json.load(sys.stdin)["data"]["password"])')"
LEASE="$(printf '%s' "$CREDS" | python3 -c 'import json,sys;print(json.load(sys.stdin)["lease_id"])')"

# The username is v-<display_name>-<role>-<random>-<epoch>, and BOTH the display
# name and the role name are truncated to eight characters. payments-readonly and
# payments-readwrite therefore both appear as "v-...-payments-..." in PostgreSQL's
# logs. The username tells you which auth method issued the credential. It does
# not tell you which role, so do not build alerting that assumes it does.
echo "username: $DB_USER"
echo "lease:    $LEASE"

echo
echo "== 2. it works, and it is who it says it is =="
pg -c "SELECT current_user, current_database();"
pg -c "SELECT account_ref, amount_cents, currency FROM payments ORDER BY id;"

echo
echo "== 3. it is scoped: INSERT must be refused on a readonly role =="
if pg -c "INSERT INTO payments (account_ref, amount_cents, currency) VALUES ('acct_0000000', 1, 'SEK');" 2>&1; then
  echo "UNEXPECTED: the readonly role could write. Check creation_statements." >&2
  exit 1
fi

echo
echo "== 4. revoke, and wait for PostgreSQL to agree =="
# `bao lease revoke` is asynchronous. The request carries "sync": false and the
# CLI answers "All revocation operations queued successfully!" the moment the job
# is accepted, NOT when PostgreSQL has actually dropped the role. Never treat
# that message as proof a credential is dead. Confirm against the database.
bao lease revoke "$LEASE"

for i in $(seq 1 30); do
  GONE="$(kubectl -n "$NS_DB" exec postgres-0 -- \
    psql -U openbao_admin -d appdb -tAc \
    "SELECT count(*) FROM pg_roles WHERE rolname='${DB_USER}';" 2>/dev/null | tr -d ' ')"
  [ "$GONE" = "0" ] && { echo "role dropped after ~${i}s"; break; }
  sleep 1
done

if [ "${GONE:-1}" != "0" ]; then
  echo "STILL PRESENT after 30s. Your revocation_statements are failing." >&2
  echo "Check the OpenBao server log for SQLSTATE 2BP01." >&2
  exit 1
fi

echo
echo "== 5. the credential is now refused =="
# PostgreSQL will not tell you whether a role exists, so a dropped role and a
# wrong password produce the same message. Expect
#   FATAL:  password authentication failed for user "v-..."
# and NOT "role does not exist".
pg -c "SELECT 1;" 2>&1 || true

echo
echo "Done."
