#!/usr/bin/env bash
#
# Sealable namespaces: a tenant holding its own key material, and the two
# operations that are constantly confused with each other, seal and lock.
#
#   export BAO_ADDR=https://127.0.0.1:8200
#   export BAO_CACERT=<path>/lesson-4.2-pki-certificates/root_ca.crt
#   export BAO_TOKEN=<your token>
#   ./sealable-namespace-drill.sh
#
# Run ./create-namespaces.sh first. This drill checks that tenant-a stays up
# while tenant-b is sealed, so it needs tenant-a to exist.
#
# Requires OpenBao 2.6.0 or later. Sealable namespaces shipped in 2.6.0 and are
# Shamir only: the drill proves that by asking for an auto-unseal namespace and
# showing you the refusal.
set -euo pipefail
: "${BAO_ADDR:?set BAO_ADDR}"
: "${BAO_TOKEN:?set BAO_TOKEN}"
: "${BAO_CACERT:?set BAO_CACERT, the root_ca.crt written by lesson 4.2}"

KEYFILE="${KEYFILE:-tenant-b-unseal-keys.txt}"

# ---------------------------------------------------------------------------
# 1. Create a namespace with its own Shamir seal.
#
# The shares are printed once, at creation, and never again. They belong to the
# tenant, not to you. In a real handover they go to the tenant's key holders
# down separate channels before the tenant ever logs in.
#
# This writes them to a file so the rest of the drill can run unattended. Do not
# do that anywhere real, and delete the file when you are finished.
# ---------------------------------------------------------------------------
echo "== 1. create tenant-b with its own seal =="
bao namespace create -key-shares=3 -key-threshold=2 tenant-b | tee "$KEYFILE"

K1="$(awk '/Unseal Key 1:/ {print $4}' "$KEYFILE")"
K2="$(awk '/Unseal Key 2:/ {print $4}' "$KEYFILE")"
[ -n "$K1" ] && [ -n "$K2" ] || { echo "could not read the unseal keys from $KEYFILE" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 2. It is born sealed.
#
# This is the step people skip. Creating the namespace does not leave it usable.
# Its key material exists but is not in memory, so every request into it fails
# with 503 until somebody supplies the shares, including the request that would
# enable its first secrets engine.
# ---------------------------------------------------------------------------
echo
echo "== 2. a brand new sealable namespace is already sealed =="
bao secrets enable -namespace=tenant-b -path=secret kv-v2 2>&1 | tail -3 || true
bao namespace seal-status tenant-b

# ---------------------------------------------------------------------------
# 3. Unseal it, one share at a time.
#
# Same ceremony as the cluster seal in lesson 3.1, one scope down. Unlike the
# cluster seal, this is done once per cluster rather than once per node: the
# namespace seal status is synchronised across the nodes.
# ---------------------------------------------------------------------------
echo
echo "== 3. unseal, share by share =="
bao namespace unseal tenant-b "$K1" | sed -n '/Unseal Progress/p'
bao namespace unseal tenant-b "$K2" | sed -n '/Sealed/p'

bao secrets enable -namespace=tenant-b -path=secret kv-v2
bao kv put -namespace=tenant-b secret/app/db password=tenant-b-secret > /dev/null
echo "   tenant-b is open for business"

# ---------------------------------------------------------------------------
# 4. Seal it again, and check the blast radius.
#
# The point of the whole feature: tenant-b goes dark, and nothing else does.
# The cluster itself is untouched, and tenant-a never notices.
# ---------------------------------------------------------------------------
echo
echo "== 4. seal tenant-b, then look at everybody else =="
bao namespace seal tenant-b

echo "-- tenant-b --"
bao kv get -namespace=tenant-b secret/app/db 2>&1 | tail -3 || true

echo "-- tenant-a, during the same outage --"
echo "   $(bao kv get -field=password -namespace=tenant-a secret/app/db)"

echo "-- the cluster itself --"
bao status | sed -n '/^Sealed/p'

# ---------------------------------------------------------------------------
# 5. Seal is not lock.
#
# Lock is an administrative gate on the API. The data stays decryptable by the
# cluster, and an operator with sudo can lift it without the tenant's key, which
# the CLI will tell you in as many words.
#
# Seal removes the namespace's key material from memory. There is no sudo path
# back in. That difference is the entire reason to hand a tenant shares.
# ---------------------------------------------------------------------------
echo
echo "== 5. lock, for comparison =="
bao namespace lock tenant-a | head -2
bao kv get -namespace=tenant-a secret/app/db 2>&1 | tail -2 || true

echo
echo "-- and an operator lifts it without holding any tenant key --"
bao namespace unlock tenant-a
echo "   $(bao kv get -field=password -namespace=tenant-a secret/app/db)"

# ---------------------------------------------------------------------------
# 6. The documented limitation, demonstrated rather than asserted.
#
# Auto-unseal is what every other seal lesson in this course has been steering
# you towards, and it is exactly what a namespace seal cannot use yet. A tenant
# seal means a human with shares, every time the namespace is sealed.
# ---------------------------------------------------------------------------
echo
echo "== 6. auto-unseal for a namespace, refused =="
cat > /tmp/namespace-seal.hcl <<'HCL'
seal "transit" {
  address    = "https://127.0.0.1:8200"
  token      = "placeholder"
  key_name   = "namespace-unseal"
  mount_path = "transit/"
}
HCL
bao namespace create -seal=/tmp/namespace-seal.hcl tenant-c 2>&1 | tail -3 || true
rm -f /tmp/namespace-seal.hcl

echo
echo "Unseal tenant-b again with two shares from $KEYFILE when you want it back,"
echo "then delete that file."
