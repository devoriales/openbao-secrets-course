#!/usr/bin/env bash
#
# Shows the problem entities solve, then solves it.
#
# Creates the same person in two separate auth mounts, proves they arrive as two
# unrelated principals, then merges them into one entity and shows a single policy
# following the person rather than the login method.
#
# Usage (against the lesson 1.3 deployment, unsealed):
#   export BAO_ADDR='https://127.0.0.1:8200' BAO_SKIP_VERIFY=1 BAO_TOKEN=<root>
#   ./identity-demo.sh
set -euo pipefail
: "${BAO_ADDR:?}"; : "${BAO_TOKEN:?}"
ROOT="$BAO_TOKEN"

jqf() { python3 -c "import sys,json;print(json.load(sys.stdin)$1)"; }

echo "==> Two auth mounts, standing in for two identity providers"
bao auth enable userpass                >/dev/null 2>&1 || true
bao auth enable -path=contractors userpass >/dev/null 2>&1 || true

echo "==> A secret and a policy"
bao secrets enable -path=secret -version=2 kv >/dev/null 2>&1 || true
bao kv put secret/production/db username=dbadmin password=identity-demo >/dev/null
printf 'path "secret/data/production/*" { capabilities = ["read"] }\n' > /tmp/app-readonly.hcl
bao policy write app-readonly /tmp/app-readonly.hcl >/dev/null

echo "==> The same human in both mounts, with NO policy attached to either"
bao write auth/userpass/users/alice    password=corp-pw       >/dev/null
bao write auth/contractors/users/alice password=contractor-pw >/dev/null

echo
echo "--- Before: two logins, two principals ---"
for m in userpass contractors; do
  pw=$([ "$m" = userpass ] && echo corp-pw || echo contractor-pw)
  bao write -format=json "auth/$m/login/alice" password="$pw" \
    | jqf "['auth']" >/dev/null
  eid=$(bao write -format=json "auth/$m/login/alice" password="$pw" | jqf "['auth']['entity_id']")
  echo "   via ${m}: entity ${eid:0:8}..."
done
echo "   Two different entity ids. Same person, two unrelated principals."

echo
echo "==> Delete the auto-created entities and build one canonical entity"
for id in $(bao list -format=json identity/entity/id | python3 -c 'import sys,json;print(" ".join(json.load(sys.stdin)))'); do
  bao delete "identity/entity/id/$id" >/dev/null
done
EID=$(bao write -field=id identity/entity name=alice policies=app-readonly)
UP=$(bao auth list -format=json | jqf "['userpass/']['accessor']")
CT=$(bao auth list -format=json | jqf "['contractors/']['accessor']")
bao write identity/entity-alias name=alice canonical_id="$EID" mount_accessor="$UP" >/dev/null
bao write identity/entity-alias name=alice canonical_id="$EID" mount_accessor="$CT" >/dev/null
echo "   entity ${EID:0:8}... with an alias on each mount"

echo
echo "--- After: two logins, one principal ---"
for m in userpass contractors; do
  pw=$([ "$m" = userpass ] && echo corp-pw || echo contractor-pw)
  bao write -format=json "auth/$m/login/alice" password="$pw" | python3 -c "
import sys,json;a=json.load(sys.stdin)['auth']
print(f'   via $m: entity {a[\"entity_id\"][:8]}...  identity_policies={a.get(\"identity_policies\")}')"
done

echo
echo "==> An internal group, to grant by team rather than by person"
printf 'path \"secret/data/staging/*\" { capabilities = [\"read\",\"create\",\"update\"] }\n' > /tmp/platform-team.hcl
bao policy write platform-team /tmp/platform-team.hcl >/dev/null
bao write identity/group name=platform type=internal \
  policies=platform-team member_entity_ids="$EID" >/dev/null
bao write -format=json auth/userpass/login/alice password=corp-pw | python3 -c "
import sys,json;a=json.load(sys.stdin)['auth']
print('   token policies   :',a['policies'])
print('   identity policies:',a.get('identity_policies'))"

echo
echo "==> External groups refuse direct membership, by design"
if bao write identity/group name=oidc-admins type=external \
     policies=platform-team member_entity_ids="$EID" >/dev/null 2>&1; then
  echo "   UNEXPECTED: external group accepted a direct member"
else
  echo "   refused, as it should be. Membership comes from the identity provider."
fi
