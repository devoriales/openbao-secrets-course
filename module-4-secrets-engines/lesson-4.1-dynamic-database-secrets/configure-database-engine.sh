#!/usr/bin/env bash
#
# Configure the database secrets engine against the PostgreSQL 18.4 instance
# deployed by postgres.yaml.
#
# Run it with a port-forward open and BAO_ADDR / BAO_TOKEN set:
#
#   kubectl -n openbao port-forward svc/openbao 8200:8200 &
#   export BAO_ADDR=https://127.0.0.1:8200
#   export BAO_SKIP_VERIFY=1        # bootstrap cert is self-signed until lesson 4.2
#   export BAO_TOKEN=<your token>
#   ./configure-database-engine.sh
#
# THE ONE LINE THAT MATTERS IS revocation_statements. Read the block above it
# before you copy this file into anything real.
set -euo pipefail
: "${BAO_ADDR:?set BAO_ADDR, e.g. https://127.0.0.1:8200}"
: "${BAO_TOKEN:?set BAO_TOKEN}"

DB_HOST="${DB_HOST:-postgres.databases.svc.cluster.local}"

bao secrets enable database 2>/dev/null || echo "database/ already enabled, continuing"

# The connection configuration.
#
# {{username}} and {{password}} are placeholders OpenBao substitutes at connect
# time from the credential it holds for this config. Writing them literally is
# the point: after rotate-root the stored password changes and this URL does not,
# because the URL never contained the password in the first place.
#
# allowed_roles is a whitelist, not documentation. A role not named here cannot
# use this connection even if the role definition points at it.
bao write database/config/appdb \
  plugin_name=postgresql-database-plugin \
  allowed_roles="payments-readonly,payments-readwrite" \
  connection_url="postgresql://{{username}}:{{password}}@${DB_HOST}:5432/appdb?sslmode=disable" \
  username="openbao_admin" \
  password="initial_password_will_be_rotated"

# ---------------------------------------------------------------------------
# WHY revocation_statements IS "DROP OWNED BY" AND NOT JUST "DROP ROLE"
#
# Almost every tutorial, and the first draft of this course, used:
#
#     revocation_statements="DROP ROLE IF EXISTS \"{{name}}\";"
#
# That does not work, and the way it fails is worse than an outright error.
# PostgreSQL refuses to drop a role that still holds granted privileges:
#
#     ERROR: role "v-root-payments-..." cannot be dropped because some objects
#     depend on it (SQLSTATE 2BP01)
#
# and the creation_statements below grant SELECT to every role they create, so
# EVERY revocation hits it. What you see at the CLI is:
#
#     $ bao lease revoke database/creds/payments-readonly/<id>
#     All revocation operations queued successfully!
#
# Success. Meanwhile the lease stays in the lease list, the PostgreSQL role is
# still there, and the credential you just "revoked" still logs in and still
# reads your data. OpenBao retries on an exponential backoff and fails the same
# way every time; the error appears only in the OpenBao server log.
#
# Revoking a leaked credential during an incident and being told it worked, when
# it did not, is the most expensive failure in this lesson.
#
# DROP OWNED BY revokes the privileges granted to the role and drops the objects
# it owns, which leaves nothing for DROP ROLE to trip over. It needs the
# configured account to be a superuser or a member of the target role.
#
# If you have already issued credentials with a broken revocation statement, you
# do not have to clean up by hand: OpenBao reads these statements from the ROLE
# at revocation time, not from a copy frozen into the lease. Correct the role and
# the stuck revocations drain on their next retry.
#
# ONE KNOWN GAP, LEFT IN DELIBERATELY. DROP OWNED BY has no IF EXISTS clause, so
# if somebody drops one of these roles in PostgreSQL by hand, OpenBao's later
# revocation fails with
#
#     ERROR: role "v-..." does not exist (SQLSTATE 42704)
#
# and that lease is stuck for good, exactly the way the 2BP01 case above is. The
# way out is `bao lease revoke -force <lease_id>`, which drops OpenBao's record
# without running any SQL and warns you that it is doing so. A guarded PL/pgSQL
# variant that tolerates the absence is in the README; it is kept out of here
# because it buries the one line this lesson is actually about. The real fix is
# not to clean up dynamic roles by hand.
# ---------------------------------------------------------------------------

bao write database/roles/payments-readonly \
  db_name=appdb \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
  revocation_statements="DROP OWNED BY \"{{name}}\"; DROP ROLE IF EXISTS \"{{name}}\";" \
  default_ttl="1h" \
  max_ttl="24h"

bao write database/roles/payments-readwrite \
  db_name=appdb \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
  revocation_statements="DROP OWNED BY \"{{name}}\"; DROP ROLE IF EXISTS \"{{name}}\";" \
  default_ttl="1h" \
  max_ttl="24h"

# A policy scoped to reading one role's credentials, which is what an application
# should hold. Note it does NOT include sys/leases/revoke: an application that can
# revoke its own lease can also revoke someone else's if the path is broadened.
bao policy write payments-app - <<'HCL'
path "database/creds/payments-readonly" {
  capabilities = ["read"]
}

# Renewal, so a long-lived process can hold one credential instead of requesting
# a new one per connection. Lease accumulation is the failure mode this prevents.
path "sys/leases/renew" {
  capabilities = ["update"]
}
HCL

echo
echo "Configured. Request a credential with:"
echo "  bao read database/creds/payments-readonly"
