#!/usr/bin/env bash
#
# Rotate the credential OpenBao itself uses to log in to PostgreSQL.
#
#   export BAO_ADDR=https://127.0.0.1:8200
#   export BAO_SKIP_VERIFY=1
#   export BAO_TOKEN=<your token>
#   ./rotate-root-procedure.sh
#
# WHAT THIS DOES THAT YOU CANNOT UNDO
#
# OpenBao generates a new password for openbao_admin, runs ALTER ROLE against
# PostgreSQL to set it, and stores it behind the barrier. It does not print it,
# and there is no endpoint that returns it. `bao read database/config/appdb`
# comes back with a connection_details map containing connection_url and
# username and NO password field at all.
#
# So after this runs, the openbao_admin password is known to exactly one party,
# and that party is not a person. The value in postgres.yaml, in your shell
# history and in every clone of this repository becomes worthless, which is the
# entire point: a static credential that leaked six months ago stops mattering.
#
# The fear people have about it is legitimate and worth stating plainly. If
# OpenBao's storage is lost, nobody can log in to PostgreSQL as openbao_admin
# again. The recovery path is not through OpenBao: it is superuser access to the
# database itself, ALTER ROLE openbao_admin WITH PASSWORD, and reconfiguring the
# engine. On this lab that is `kubectl -n databases exec -it postgres-0 -- psql`.
# On a managed database it is the provider's console. Confirm you have that path
# BEFORE you rotate, not after.
#
# Note also what rotate-root does NOT do: it does not touch any dynamic
# credential already issued. Existing leases keep working until they expire.
set -euo pipefail
: "${BAO_ADDR:?set BAO_ADDR}"
: "${BAO_TOKEN:?set BAO_TOKEN}"

CONFIG="${CONFIG:-appdb}"

cat <<EOF
About to rotate the root credential for database/config/${CONFIG}.

After this, the password for openbao_admin is known only to OpenBao.
Anything you have written down stops working, including the value committed
in postgres.yaml.

Before continuing, confirm you have superuser access to PostgreSQL by some
route that does not involve OpenBao.
EOF

read -r -p "Continue? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
  echo "Aborted. Nothing changed."
  exit 1
fi

bao write -f "database/rotate-root/${CONFIG}"

echo
echo "Rotated. Two checks worth running now:"
echo
echo "  # the old password must be refused:"
echo "  kubectl -n databases exec psql-client -- env PGPASSWORD=initial_password_will_be_rotated \\"
echo "    psql -h postgres.databases.svc.cluster.local -U openbao_admin -d appdb -c 'SELECT 1;'"
echo
echo "  # and the engine must still be able to issue credentials:"
echo "  bao read database/creds/payments-readonly"
