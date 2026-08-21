#!/usr/bin/env bash
#
# The same three operations the Go client performs, in the lowest common
# denominator any language can reach: HTTP and JSON.
#
#   export BAO_ADDR=https://127.0.0.1:8200
#   export BAO_CACERT=<path>/lesson-4.2-pki-certificates/root_ca.crt
#   export BAO_TOKEN=<your token>          # only to mint the AppRole credentials
#   ./curl-walkthrough.sh
#
# Read this before the Go program, not after. Everything the client library does
# is one of these requests with a struct wrapped around it, and when the library
# behaves in a way you did not expect, this is the layer you drop back down to.
set -euo pipefail
: "${BAO_ADDR:?set BAO_ADDR}"
: "${BAO_TOKEN:?set BAO_TOKEN}"
: "${BAO_CACERT:?set BAO_CACERT, the root_ca.crt written by lesson 4.2}"

CURL=(curl -s --cacert "$BAO_CACERT")

jq_or_cat() { command -v jq > /dev/null && jq "$@" || cat; }

echo "== 1. mint AppRole credentials (an operator task, not the app's) =="
ROLE_ID="$("${CURL[@]}" -H "X-Vault-Token: $BAO_TOKEN" \
  "$BAO_ADDR/v1/auth/approle/role/reporting/role-id" | jq_or_cat -r .data.role_id)"
SECRET_ID="$("${CURL[@]}" -H "X-Vault-Token: $BAO_TOKEN" -X POST \
  "$BAO_ADDR/v1/auth/approle/role/reporting/secret-id" | jq_or_cat -r .data.secret_id)"
echo "   RoleID   ${ROLE_ID:0:8}... (config, not a secret)"
echo "   SecretID ${SECRET_ID:0:8}... (a credential, delivered once)"

echo
echo "== 2. log in: the one request every client makes first =="
# Note the shape. The token is at .auth.client_token, the TTL at
# .auth.lease_duration, and .auth.renewable decides whether there is anything to
# renew at all. A client that reads .data here, out of habit from every other
# endpoint, gets null and reports a confusing error.
LOGIN="$("${CURL[@]}" -X POST \
  --data "{\"role_id\":\"$ROLE_ID\",\"secret_id\":\"$SECRET_ID\"}" \
  "$BAO_ADDR/v1/auth/approle/login")"
echo "$LOGIN" | jq_or_cat '{policies: .auth.token_policies, ttl: .auth.lease_duration, renewable: .auth.renewable}'
TOKEN="$(echo "$LOGIN" | jq_or_cat -r .auth.client_token)"

echo
echo "== 3. read the secret =="
# K/V v2 puts the value at .data.data, one level deeper than v1, for the same
# reason the read path carries a data/ segment. Lesson 1.4 has the full story.
"${CURL[@]}" -H "X-Vault-Token: $TOKEN" \
  "$BAO_ADDR/v1/secret/data/apps/reporting" | jq_or_cat '.data.data'

echo
echo "== 4. the two failures worth recognising on sight =="
echo "-- a path the policy does not grant --"
"${CURL[@]}" -H "X-Vault-Token: $TOKEN" -w " (HTTP %{http_code})\n" \
  "$BAO_ADDR/v1/secret/data/apps/billing"
echo "-- no token at all --"
"${CURL[@]}" -w " (HTTP %{http_code})\n" \
  "$BAO_ADDR/v1/secret/data/apps/reporting"

echo
echo "== 5. renewal, by hand =="
# This is what LifetimeWatcher automates. Note that renew-self extends by the
# role's token_ttl each time and can never take the token past token_max_ttl.
"${CURL[@]}" -H "X-Vault-Token: $TOKEN" -X POST \
  "$BAO_ADDR/v1/auth/token/renew-self" | jq_or_cat '{ttl: .auth.lease_duration, renewable: .auth.renewable}'

echo
echo "== 6. what expiry looks like =="
echo "   The role issues a 60 second token. Waiting 70 seconds without renewing."
sleep 70
"${CURL[@]}" -H "X-Vault-Token: $TOKEN" -w " (HTTP %{http_code})\n" \
  "$BAO_ADDR/v1/secret/data/apps/reporting"
echo
echo "   Same token, same path, same policy. The only thing that changed is time."
