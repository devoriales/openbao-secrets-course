#!/usr/bin/env bash
#
# Every K/V v2 operation from lesson 1.4, over the REST API rather than the CLI.
#
# The point of this script is the paths. The CLI hides the /data/ and /metadata/
# segments; the API does not, and every integration you write later talks to the
# API. Run it and watch which URL each operation actually uses.
#
# Usage:
#   kubectl -n openbao port-forward svc/openbao 8200:8200 &
#   export BAO_ADDR='https://127.0.0.1:8200'
#   export BAO_TOKEN='<your token>'
#   ./api-examples.sh
#
set -euo pipefail

: "${BAO_ADDR:?set BAO_ADDR, e.g. https://127.0.0.1:8200}"
: "${BAO_TOKEN:?set BAO_TOKEN}"

MOUNT="secret"
SECRET="production/db"

# -k because the bootstrap certificate is self-signed. This disappears once
# OpenBao issues its own certificates in Module 4.
CURL=(curl -sk -H "X-Vault-Token: ${BAO_TOKEN}")

# The header really is X-Vault-Token, not X-Bao-Token. OpenBao kept the Vault
# header name for compatibility; X-Bao-Token returns 403.

hr() { printf '\n\033[0;34m== %s\033[0m\n' "$*"; }
show() { python3 -m json.tool 2>/dev/null || cat; }

# Make the script re-runnable. The CAS section below turns cas_required on, so a
# second run would hit the blind-write step with CAS already required, get a 400,
# and carry on regardless: curl exits 0 on an HTTP error and 'set -e' never sees
# it. The demo would then quietly be doing something different from what it says.
hr "RESET  clear cas_required so this run starts from a known state"
"${CURL[@]}" -X POST \
  -H 'Content-Type: application/json' \
  -d '{"cas_required":false}' \
  "${BAO_ADDR}/v1/${MOUNT}/metadata/${SECRET}" -w '  HTTP %{http_code}\n' || true

hr "WRITE a new version   PUT ${MOUNT}/data/${SECRET}"
"${CURL[@]}" -X PUT \
  -H 'Content-Type: application/json' \
  -d '{"data":{"username":"dbadmin","password":"from-the-api"}}' \
  "${BAO_ADDR}/v1/${MOUNT}/data/${SECRET}" | show

hr "READ current          GET ${MOUNT}/data/${SECRET}"
# Note the response nests twice: .data.data holds your keys, .data.metadata holds
# the version info. Reaching for .data and finding metadata is a rite of passage.
"${CURL[@]}" "${BAO_ADDR}/v1/${MOUNT}/data/${SECRET}" | show

hr "READ a specific version  GET ${MOUNT}/data/${SECRET}?version=1"
"${CURL[@]}" "${BAO_ADDR}/v1/${MOUNT}/data/${SECRET}?version=1" | show

hr "VERSION HISTORY       GET ${MOUNT}/metadata/${SECRET}"
"${CURL[@]}" "${BAO_ADDR}/v1/${MOUNT}/metadata/${SECRET}" | show

hr "SOFT DELETE v1        POST ${MOUNT}/delete/${SECRET}"
# Reversible. Sets deletion_time and hides the data; the version still exists.
"${CURL[@]}" -X POST \
  -H 'Content-Type: application/json' \
  -d '{"versions":[1]}' \
  "${BAO_ADDR}/v1/${MOUNT}/delete/${SECRET}" -w '  HTTP %{http_code}\n'

hr "UNDELETE v1           POST ${MOUNT}/undelete/${SECRET}"
"${CURL[@]}" -X POST \
  -H 'Content-Type: application/json' \
  -d '{"versions":[1]}' \
  "${BAO_ADDR}/v1/${MOUNT}/undelete/${SECRET}" -w '  HTTP %{http_code}\n'

hr "DESTROY v1            POST ${MOUNT}/destroy/${SECRET}"
# Irreversible. The ciphertext is gone; the version's metadata entry remains with
# destroyed=true so the history still shows that something was there.
"${CURL[@]}" -X POST \
  -H 'Content-Type: application/json' \
  -d '{"versions":[1]}' \
  "${BAO_ADDR}/v1/${MOUNT}/destroy/${SECRET}" -w '  HTTP %{http_code}\n'

hr "CHECK-AND-SET: require it"
"${CURL[@]}" -X POST \
  -H 'Content-Type: application/json' \
  -d '{"cas_required":true}' \
  "${BAO_ADDR}/v1/${MOUNT}/metadata/${SECRET}" -w '  HTTP %{http_code}\n'

hr "CAS: a blind write is now refused (expect 400)"
"${CURL[@]}" -X PUT \
  -H 'Content-Type: application/json' \
  -d '{"data":{"password":"blind"}}' \
  "${BAO_ADDR}/v1/${MOUNT}/data/${SECRET}" | show

hr "CAS: supply the version you believe is current"
CURRENT=$("${CURL[@]}" "${BAO_ADDR}/v1/${MOUNT}/metadata/${SECRET}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["current_version"])')
echo "  current_version is ${CURRENT}"
"${CURL[@]}" -X PUT \
  -H 'Content-Type: application/json' \
  -d "{\"options\":{\"cas\":${CURRENT}},\"data\":{\"username\":\"dbadmin\",\"password\":\"cas-write\"}}" \
  "${BAO_ADDR}/v1/${MOUNT}/data/${SECRET}" | show

cat <<'EOF'

DELETE the metadata to remove the secret and EVERY version of it:

  curl -sk -X DELETE -H "X-Vault-Token: $BAO_TOKEN" \
    "$BAO_ADDR/v1/secret/metadata/production/db"

That one is not in this script on purpose. It is the only K/V v2 operation with no
undo at all, and it should be something you type deliberately rather than something
a script runs past you.
EOF
