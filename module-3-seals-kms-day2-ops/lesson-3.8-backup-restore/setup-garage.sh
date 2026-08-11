#!/usr/bin/env bash
#
# Brings up Garage v2.3.0 and prepares it to receive OpenBao snapshots:
# a storage layout, an S3 access key and a bucket the key may write to.
#
# Garage will not serve S3 at all until a layout is applied. A fresh node
# reports "NO ROLE ASSIGNED" and every bucket call fails, which looks like a
# broken deployment and is actually an unfinished one.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${NS:-openbao-backup}"
BUCKET="${BUCKET:-openbao-snapshots}"

g() { kubectl -n "$NS" exec garage-0 -- /garage "$@"; }

echo "==> 1. Deploy Garage"
kubectl create namespace "$NS" >/dev/null 2>&1 || true
kubectl apply -f "$HERE/garage.yaml" >/dev/null
for _ in $(seq 60); do
  [ "$(kubectl -n "$NS" get pod garage-0 -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ] && break
  sleep 5
done
# Running is not serving. Poll the CLI until the daemon answers its own RPC.
for _ in $(seq 30); do g status >/dev/null 2>&1 && break; sleep 2; done

echo "==> 2. Assign a storage layout"
NODE_ID="$(g status 2>/dev/null | awk '/NO ROLE ASSIGNED|garage-0/ {print $1; exit}')"
if [ -n "$NODE_ID" ] && g status 2>/dev/null | grep -q 'NO ROLE ASSIGNED'; then
  g layout assign -z dc1 -c 1G "$NODE_ID" >/dev/null
  # Layout changes are staged and then applied at an explicit version. The
  # version number is always one higher than the current one, and `apply`
  # refuses rather than guessing.
  g layout apply --version 1 >/dev/null
  echo "   layout applied to $NODE_ID"
else
  echo "   layout already assigned"
fi

echo "==> 3. Bucket and access key"
g bucket create "$BUCKET" >/dev/null 2>&1 || true
KEYOUT="$(g key create "$BUCKET-key" 2>/dev/null || g key info "$BUCKET-key" --show-secret 2>/dev/null)"
KEY_ID="$(printf '%s' "$KEYOUT" | awk '/Key ID:/ {print $3}')"
KEY_SECRET="$(printf '%s' "$KEYOUT" | awk '/Secret key:/ {print $3}')"
g bucket allow --read --write "$BUCKET" --key "$BUCKET-key" >/dev/null

[ -n "$KEY_ID" ] && [ -n "$KEY_SECRET" ] || { echo "could not read the access key" >&2; exit 1; }

echo "==> 4. Store the credentials for the snapshot job"
kubectl -n "$NS" delete secret garage-creds >/dev/null 2>&1 || true
kubectl -n "$NS" create secret generic garage-creds \
  --from-literal=AWS_ACCESS_KEY_ID="$KEY_ID" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$KEY_SECRET" >/dev/null

echo
echo "   bucket:     $BUCKET"
echo "   access key: $KEY_ID"
echo "   endpoint:   http://garage.$NS.svc.cluster.local:3900"
echo
echo "   Credentials are in the garage-creds Secret in $NS."
