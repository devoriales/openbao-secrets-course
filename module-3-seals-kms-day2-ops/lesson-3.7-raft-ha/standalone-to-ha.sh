#!/usr/bin/env bash
#
# Turns the single standalone OpenBao from Module 1 into a three node Raft
# cluster, keeping the data, the unseal keys and the root token.
#
# The shape of it:
#   1. uninstall the release, keep the PersistentVolumeClaim
#   2. run `bao operator migrate` as a Job: file -> raft, offline, on the same volume
#   3. install the HA release, which reuses data-openbao-0 for node 0
#   4. unseal each node with the ORIGINAL keys; nodes 1 and 2 join by retry_join
#
# What this uses: the same openbao/openbao 0.28.6 chart and the stock
# quay.io/openbao/openbao:2.6.1 image. Raft is built into the binary, so
# unlike lessons 3.3 and 3.4 there is no custom image and no plugin.
#
# THIS IS AN OUTAGE. The instance is down from step 1 until step 4 finishes.
# There is no way to migrate storage backends without one, because the whole
# point of `operator migrate` is that nothing is writing while it copies.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${NS:-openbao-mig}"
KEYS_FILE="${KEYS_FILE:-/tmp/mig-keys.txt}"   # one unseal key per line, quorum's worth

need() { command -v "$1" >/dev/null || { echo "need $1" >&2; exit 1; }; }
need kubectl; need helm; need bao

[ -s "$KEYS_FILE" ] || { echo "no unseal keys at $KEYS_FILE" >&2; exit 1; }
K1="$(sed -n 1p "$KEYS_FILE")"; K2="$(sed -n 2p "$KEYS_FILE")"

unseal_pod() {  # $1 = pod
  kubectl -n "$NS" exec "$1" -- sh -c "BAO_ADDR=http://127.0.0.1:8200 bao operator unseal $K1" >/dev/null 2>&1 || true
  kubectl -n "$NS" exec "$1" -- sh -c "BAO_ADDR=http://127.0.0.1:8200 bao operator unseal $K2" >/dev/null 2>&1 || true
}
wait_running() {  # $1 = pod
  for _ in $(seq 60); do
    [ "$(kubectl -n "$NS" get pod "$1" -o jsonpath='{.status.phase}' 2>/dev/null || true)" = "Running" ] && return 0
    sleep 5
  done
  echo "$1 never reached Running" >&2; return 1
}

echo "==> 1. Uninstall the standalone release, keep the volume"
helm uninstall openbao -n "$NS" >/dev/null 2>&1 || true
sleep 6
kubectl -n "$NS" get pvc data-openbao-0 --no-headers | sed 's/^/   /'

echo "==> 2. Migrate file to raft, offline"
kubectl -n "$NS" delete job storage-migrate >/dev/null 2>&1 || true
kubectl -n "$NS" apply -f "$HERE/migrate-job.yaml" >/dev/null
for _ in $(seq 60); do
  [ "$(kubectl -n "$NS" get job storage-migrate -o jsonpath='{.status.succeeded}' 2>/dev/null)" = "1" ] && break
  if [ -n "$(kubectl -n "$NS" get job storage-migrate -o jsonpath='{.status.failed}' 2>/dev/null)" ]; then
    kubectl -n "$NS" logs job/storage-migrate | tail -20; echo "migration failed" >&2; exit 1
  fi
  sleep 5
done
kubectl -n "$NS" logs job/storage-migrate 2>/dev/null | tail -1 | sed 's/^/   /'

echo "==> 3. Install the HA release over the same claim"
helm install openbao openbao/openbao -n "$NS" --version 0.28.6 \
  --values "$HERE/values-ha-raft.yaml" >/dev/null
wait_running openbao-0

echo "==> 4. Unseal node 0 with the original keys"
# The barrier came across with the data, so these are the same keys and the
# same root token. Storage changed; nothing about the seal did.
unseal_pod openbao-0
kubectl -n "$NS" exec openbao-0 -- sh -c 'BAO_ADDR=http://127.0.0.1:8200 bao status' \
  | grep -E 'Storage Type|Sealed|HA Mode' | sed 's/^/   /'

# Nodes 1 and 2 only get created once node 0 is Ready, because the StatefulSet
# is OrderedReady and readiness means unsealed. Then each has to be unsealed
# before it can finish joining.
for p in openbao-1 openbao-2; do
  echo "==> waiting for $p"
  wait_running "$p"
  unseal_pod "$p"
  kubectl -n "$NS" exec "$p" -- sh -c 'BAO_ADDR=http://127.0.0.1:8200 bao status' 2>/dev/null \
    | grep -E 'Sealed|HA Mode' | sed 's/^/   /' || true
done

echo
echo "==> The cluster"
kubectl -n "$NS" exec openbao-0 -- sh -c 'BAO_ADDR=http://127.0.0.1:8200 bao operator raft list-peers' 2>/dev/null | sed 's/^/   /'

cat <<'NOTE'

   Three nodes, one leader, two followers. Failure tolerance is 1: check it
   with `bao operator raft autopilot state`, which prints the number rather
   than making you work it out.

   Unsealing three nodes by hand after every restart is the argument for the
   auto-unseal mechanisms in lessons 3.2 to 3.4.
NOTE
