#!/usr/bin/env bash
#
# Build a two tenant hierarchy inside one OpenBao cluster.
#
#   kubectl -n openbao port-forward svc/openbao 8200:8200 &
#   export BAO_ADDR=https://127.0.0.1:8200
#   export BAO_CACERT=<path>/lesson-4.2-pki-certificates/root_ca.crt
#   export BAO_TOKEN=<your token>
#   ./create-namespaces.sh
#
# What you get:
#
#   root                     the namespace every earlier lesson worked in
#   +- tenant-a/             a tenant, with its own secret/ engine and policies
#      +- production/        a child of that tenant, isolated from its parent
#
# BAO_SKIP_VERIFY is not used here and is not used anywhere from lesson 4.2 on.
set -euo pipefail
: "${BAO_ADDR:?set BAO_ADDR}"
: "${BAO_TOKEN:?set BAO_TOKEN}"
: "${BAO_CACERT:?set BAO_CACERT, the root_ca.crt written by lesson 4.2}"

# ---------------------------------------------------------------------------
# 1. The hierarchy.
#
# `bao namespace create` is relative to the namespace you are already in, which
# is the root namespace unless BAO_NAMESPACE or -namespace says otherwise. So
# the child is created by pointing at the parent, not by writing a slash path.
#
# The command does not print "Success!". It prints the namespace record: its
# id, its path, and whether it is locked or tainted. The id is the short string
# that turns up again on the end of every token issued in this namespace.
# ---------------------------------------------------------------------------
echo "== 1. create the tenant hierarchy =="
bao namespace create tenant-a
bao namespace create -namespace=tenant-a production

echo
echo "-- list is one level deep, scan is recursive --"
bao namespace list
bao namespace scan

# ---------------------------------------------------------------------------
# 2. A secrets engine per namespace.
#
# Both of these mount at secret/. They are different mounts with different
# storage, different data and different policy paths, and neither can see the
# other. That is the whole point: a tenant gets the paths it expects rather
# than a prefix it has to remember to type.
# ---------------------------------------------------------------------------
echo
echo "== 2. a K/V v2 engine inside each namespace =="
bao secrets enable -namespace=tenant-a          -path=secret kv-v2
bao secrets enable -namespace=tenant-a/production -path=secret kv-v2

bao kv put -namespace=tenant-a           secret/app/db password=tenant-a-dev  > /dev/null
bao kv put -namespace=tenant-a/production secret/app/db password=tenant-a-prod > /dev/null

echo
echo "-- the same path in two namespaces, two different secrets --"
echo "   tenant-a            $(bao kv get -field=password -namespace=tenant-a secret/app/db)"
echo "   tenant-a/production  $(bao kv get -field=password -namespace=tenant-a/production secret/app/db)"

# ---------------------------------------------------------------------------
# 3. Policy and a token, both inside the namespace.
#
# The policy is written INTO tenant-a, and its paths are relative to tenant-a.
# There is no "tenant-a/secret/data/app/*" anywhere in the file. A tenant admin
# writing policy for their own namespace writes the paths they actually use,
# and cannot accidentally grant themselves anything outside it, because a path
# outside it is not addressable from in here at all.
# ---------------------------------------------------------------------------
echo
echo "== 3. policy and token, scoped to tenant-a =="
bao policy write -namespace=tenant-a app-read tenant-policy.hcl

TOKEN="$(bao token create -namespace=tenant-a -policy=app-read -ttl=30m -field=token)"

echo
echo "-- the token carries the namespace id as a suffix --"
echo "   ${TOKEN}"
echo
echo "   That suffix is how the server knows which namespace issued it. Copy the"
echo "   whole string, suffix included, or nothing will authenticate."

echo
echo "-- it reads its own namespace --"
echo "   $(BAO_TOKEN="$TOKEN" bao kv get -field=password -namespace=tenant-a secret/app/db)"

echo
echo "-- and it is refused in the child namespace, one level down --"
BAO_TOKEN="$TOKEN" bao kv get -namespace=tenant-a/production secret/app/db 2>&1 | tail -3 || true

echo
echo "Done. Next: ./sealable-namespace-drill.sh"
