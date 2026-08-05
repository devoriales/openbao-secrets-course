#!/usr/bin/env bash
#
# AppRole end to end: the two-part credential, single-use SecretIDs, revocation by
# accessor, CIDR binding, and response wrapping.
#
# Usage (against the lesson 1.3 deployment, unsealed):
#   export BAO_ADDR='https://127.0.0.1:8200' BAO_SKIP_VERIFY=1 BAO_TOKEN=<root>
#   ./approle-demo.sh
set -euo pipefail
: "${BAO_ADDR:?}"; : "${BAO_TOKEN:?}"

# Runs a command that is MEANT to fail and prints the interesting lines of its error.
#
# The script runs with `set -euo pipefail`, so a failing command inside a pipeline
# would abort the whole run even though the failure is the thing being demonstrated.
# Guarding the command itself, rather than the pipeline that formats it, is what
# keeps `pipefail` from ending the lesson at the first example.
expect_fail() {
  { "$@" 2>&1 || true; } | { grep -E 'Code:|^[[:space:]]*\*' || true; } | head -3 | sed 's/^/     /'
}

echo "==> Secret, policy, auth method"
bao secrets enable -path=secret -version=2 kv >/dev/null 2>&1 || true
bao kv put secret/production/db username=dbadmin password=approle-demo >/dev/null
printf 'path "secret/data/production/*" { capabilities = ["read"] }\n' > /tmp/app-readonly.hcl
bao policy write app-readonly /tmp/app-readonly.hcl >/dev/null
bao auth enable approle >/dev/null 2>&1 || true

echo "==> A role whose SecretIDs are single-use and short-lived"
bao write auth/approle/role/ci-runner \
  token_policies=app-readonly \
  token_ttl=20m token_max_ttl=1h \
  secret_id_ttl=10m secret_id_num_uses=1 >/dev/null

RID=$(bao read -field=role_id auth/approle/role/ci-runner/role-id)
SID=$(bao write -f -field=secret_id auth/approle/role/ci-runner/secret-id)
echo "   role_id ${RID:0:8}...  is NOT a secret"
echo "   secret_id issued, good for one login within 10 minutes"

echo
echo "--- Neither half alone authenticates ---"
echo "   role_id only:"
expect_fail bao write auth/approle/login role_id="$RID"
echo "   secret_id only:"
expect_fail bao write auth/approle/login secret_id="$SID"

echo
echo "--- Both halves ---"
bao write -format=json auth/approle/login role_id="$RID" secret_id="$SID" | python3 -c "
import sys,json;a=json.load(sys.stdin)['auth']
print('   policies:',a['policies'],'| token ttl:',a['lease_duration'],'s')"

echo
echo "--- The same SecretID a second time (num_uses was 1) ---"
expect_fail bao write auth/approle/login role_id="$RID" secret_id="$SID"

echo
echo "==> Revoking a SecretID you do not hold, by accessor"
OUT=$(bao write -f -format=json auth/approle/role/ci-runner/secret-id)
SID2=$(echo "$OUT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["secret_id"])')
ACC=$(echo "$OUT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["secret_id_accessor"])')
bao write auth/approle/role/ci-runner/secret-id-accessor/destroy secret_id_accessor="$ACC" >/dev/null
echo "   destroyed accessor ${ACC:0:8}..., now try to use its SecretID:"
expect_fail bao write auth/approle/login role_id="$RID" secret_id="$SID2"

echo
echo "==> CIDR binding: a SecretID that only works from one network"
bao write auth/approle/role/cidr-locked \
  token_policies=app-readonly token_ttl=10m \
  secret_id_bound_cidrs="10.99.0.0/24" >/dev/null
RID2=$(bao read -field=role_id auth/approle/role/cidr-locked/role-id)
SID3=$(bao write -f -field=secret_id auth/approle/role/cidr-locked/secret-id)
echo "   logging in from outside 10.99.0.0/24:"
expect_fail bao write auth/approle/login role_id="$RID2" secret_id="$SID3"

echo
echo "==> Response wrapping: hand over a SecretID without ever seeing it"
WT=$(bao write -f -wrap-ttl=120s -format=json auth/approle/role/ci-runner/secret-id \
      | python3 -c 'import sys,json;print(json.load(sys.stdin)["wrap_info"]["token"])')
echo "   wrapping token issued. Whoever delivers this never sees the SecretID."
bao unwrap -format=json "$WT" | python3 -c "
import sys,json;print('   unwrapped once, got a secret_id:',bool(json.load(sys.stdin)['data'].get('secret_id')))"
echo "   unwrapping the same token again:"
expect_fail bao unwrap "$WT"
echo
echo "   That second failure is the point. A wrapping token is single use, so if it"
echo "   has already been unwrapped when your workload tries, someone else got there"
echo "   first and you know it immediately."
