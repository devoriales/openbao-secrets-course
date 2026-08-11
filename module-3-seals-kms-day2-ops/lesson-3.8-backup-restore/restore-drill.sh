#!/usr/bin/env bash
#
# The drill: destroy the cluster completely, rebuild it from a snapshot in
# Garage, and prove the data came back.
#
# A backup that has never been restored is a hypothesis. This script is how you
# turn it into a fact, and it is written to be run on a schedule against a
# throwaway cluster, not once before an audit.
#
# THE THING THIS DRILL EXISTS TO TEACH: a snapshot is not sufficient. The
# restored instance is sealed with the ORIGINAL barrier, so it needs the
# ORIGINAL unseal keys and the ORIGINAL root token. The `operator init` this
# script runs on the rebuilt cluster is a throwaway whose keys are dead the
# moment the restore lands. Store your key material as carefully as your
# snapshots or you are storing something you can never open.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${NS:-openbao}"
BACKUP_NS="${BACKUP_NS:-openbao-backup}"
BUCKET="${BUCKET:-openbao-snapshots}"
HA_VALUES="${HA_VALUES:-$HERE/../lesson-3.7-raft-ha/values-ha-raft.yaml}"
# One unseal key per line, quorum's worth, from the ORIGINAL cluster.
# No apostrophe in this message. Inside ${VAR:?...} bash parses a single quote
# as the start of a quoted string, and the script fails to parse 50 lines later
# with an error pointing at the wrong place entirely.
KEYS_FILE="${KEYS_FILE:?set KEYS_FILE to the unseal keys of the ORIGINAL cluster}"

need() { command -v "$1" >/dev/null || { echo "need $1" >&2; exit 1; }; }
need kubectl; need helm; need bao; need aws

K1="$(sed -n 1p "$KEYS_FILE")"; K2="$(sed -n 2p "$KEYS_FILE")"
[ -n "$K1" ] && [ -n "$K2" ] || { echo "need two unseal keys in $KEYS_FILE" >&2; exit 1; }

# Unsealing a follower the instant it reports Running does not work. It has to
# finish retry_join and pull the seal config from the leader first, and until it
# does an unseal submission is accepted and does nothing. Poll the pod's own
# seal status instead of trusting the pod phase.
unseal_when_ready() {  # $1 = pod
  local p="$1"
  for _ in $(seq 60); do
    [ "$(kubectl -n "$NS" get pod "$p" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ] && break
    sleep 5
  done
  for _ in $(seq 30); do
    kubectl -n "$NS" exec "$p" -c openbao -- sh -c \
      'BAO_ADDR=http://127.0.0.1:8200 bao status' >/dev/null 2>&1 && break
    sleep 3
  done
  for _ in $(seq 10); do
    kubectl -n "$NS" exec "$p" -c openbao -- sh -c \
      "BAO_ADDR=http://127.0.0.1:8200 bao operator unseal $K1" >/dev/null 2>&1 || true
    kubectl -n "$NS" exec "$p" -c openbao -- sh -c \
      "BAO_ADDR=http://127.0.0.1:8200 bao operator unseal $K2" >/dev/null 2>&1 || true
    if kubectl -n "$NS" exec "$p" -c openbao -- sh -c \
        'BAO_ADDR=http://127.0.0.1:8200 bao status' 2>/dev/null | grep -q '^Sealed *false'; then
      echo "   $p unsealed"; return 0
    fi
    sleep 5
  done
  echo "$p did not unseal" >&2; return 1
}

echo "==> 1. Fetch the most recent snapshot from Garage"
kubectl -n "$BACKUP_NS" port-forward svc/garage 3900:3900 >/tmp/pf-garage.log 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
for _ in $(seq 30); do curl -s --max-time 2 -o /dev/null http://127.0.0.1:3900/ && break; sleep 1; done

export AWS_ACCESS_KEY_ID="$(kubectl -n "$BACKUP_NS" get secret garage-creds -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)"
export AWS_SECRET_ACCESS_KEY="$(kubectl -n "$BACKUP_NS" get secret garage-creds -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)"
export AWS_DEFAULT_REGION=garage

SNAP="$(aws --endpoint-url http://127.0.0.1:3900 s3 ls "s3://$BUCKET/" | sort | awk '{print $4}' | tail -1)"
[ -n "$SNAP" ] || { echo "no snapshots in s3://$BUCKET" >&2; exit 1; }
aws --endpoint-url http://127.0.0.1:3900 s3 cp "s3://$BUCKET/$SNAP" /tmp/drill.snap >/dev/null
echo "   $SNAP ($(wc -c < /tmp/drill.snap) bytes)"

# Never restore a file you have not confirmed is a snapshot. A snapshot is a
# gzipped tar; anything else here means the backup job wrote an error body.
[ "$(od -An -tx1 -N2 /tmp/drill.snap | tr -d ' \n')" = "1f8b" ] \
  || { echo "that is not a snapshot" >&2; exit 1; }

echo "==> 2. Destroy the cluster. Volumes and all."
helm uninstall openbao -n "$NS" >/dev/null 2>&1 || true
sleep 8
kubectl -n "$NS" delete pvc --all >/dev/null 2>&1 || true

echo "==> 3. Rebuild it empty"
helm install openbao openbao/openbao -n "$NS" --version 0.28.6 --values "$HA_VALUES" >/dev/null
for _ in $(seq 60); do
  [ "$(kubectl -n "$NS" get pod openbao-0 -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ] && break
  sleep 5
done

# These keys are discarded. A brand new instance has to be initialised before it
# will accept anything at all, including a restore, but the restore replaces the
# barrier and with it every key generated here.
kubectl -n "$NS" exec openbao-0 -c openbao -- sh -c \
  'BAO_ADDR=http://127.0.0.1:8200 bao operator init -key-shares=1 -key-threshold=1 -format=json' \
  > /tmp/throwaway-init.json 2>/dev/null
TK="$(python3 -c "import json;print(json.load(open('/tmp/throwaway-init.json'))['unseal_keys_b64'][0])")"
TROOT="$(python3 -c "import json;print(json.load(open('/tmp/throwaway-init.json'))['root_token'])")"
kubectl -n "$NS" exec openbao-0 -c openbao -- sh -c \
  "BAO_ADDR=http://127.0.0.1:8200 bao operator unseal $TK" >/dev/null

# Forward to the POD, not to svc/openbao-active. The active service selects on a
# label that service_registration only applies once the node is unsealed AND
# active, so while the instance is sealed that service has no endpoints at all
# and `kubectl port-forward` to it exits immediately. Every later command then
# fails with connection refused, which reads like a broken restore.
kubectl -n "$NS" port-forward pod/openbao-0 8210:8200 >/tmp/pf-active.log 2>&1 &
PF2=$!
trap 'kill $PF $PF2 2>/dev/null || true' EXIT
TUNNEL=""
for _ in $(seq 30); do
  curl -s --max-time 2 -o /dev/null http://127.0.0.1:8210/v1/sys/seal-status && { TUNNEL=up; break; }
  sleep 1
done
[ "$TUNNEL" = up ] || { echo "port-forward to openbao-0 never came up" >&2; exit 1; }
export BAO_ADDR=http://127.0.0.1:8210 BAO_TOKEN="$TROOT"

echo "==> 4. Restore"
# Unforced first, on purpose, so the drill shows you the refusal every time.
# The snapshot was sealed by a different barrier than this instance's, so the
# sealed checksum file cannot be verified and OpenBao declines.
if bao operator raft snapshot restore /tmp/drill.snap 2>&1 | grep -q 'could not verify hash file'; then
  echo "   refused as expected, retrying with -force"
fi
# `restore` prints "Error properly closing policy file: ... file already closed"
# on success in 2.6.1 and exits 0. So stderr is not the signal here: the EXIT
# CODE is. Do not add `|| true` to this line. An earlier draft of this script
# did, and a genuinely failed restore sailed straight through to the unseal
# step, which then failed for a completely unrelated-looking reason.
if ! bao operator raft snapshot restore -force /tmp/drill.snap; then
  echo "restore failed, see the error above" >&2
  exit 1
fi
sleep 6

# The running process read its seal configuration into memory at startup and a
# restore does not make it re-read. Storage now says 3 shares threshold 2 while
# the process still believes the throwaway 1-of-1 it was initialised with, and
# the mismatch produces two different and equally misleading errors:
#
#   original keys  -> invalid key: failed to setup unseal key:
#                     crypto/aes: invalid key size 33
#   throwaway key  -> unable to retrieve stored keys: failed to decrypt keys
#                     from storage: cipher: message authentication failed
#
# Neither says "restart me". Restart the pod and the restored seal config loads.
echo "==> 5. Restart so the restored seal config is read"
kubectl -n "$NS" delete pod openbao-0 >/dev/null
for _ in $(seq 60); do
  [ "$(kubectl -n "$NS" get pod openbao-0 -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ] && break
  sleep 5
done
sleep 6

echo "==> 6. Unseal with the ORIGINAL keys"
# The throwaway keys from step 3 will not work now, and that is the point.
unseal_when_ready openbao-0
for p in openbao-1 openbao-2; do unseal_when_ready "$p"; done

echo "==> 7. Prove it"
# The step 5 restart killed the tunnel from step 3. Through a dead port-forward
# `bao status` reports EOF rather than connection refused, because kubectl
# accepts the local connection before it knows the far end is gone (lesson 3.2).
# `wait` inside the same subshell suppresses bash's "Terminated" job-control
# notice, which otherwise prints in the middle of the drill output.
{ kill $PF2 && wait $PF2; } 2>/dev/null || true
kubectl -n "$NS" port-forward pod/openbao-0 8210:8200 >/tmp/pf-active.log 2>&1 &
PF2=$!
trap 'kill $PF $PF2 2>/dev/null || true' EXIT
for _ in $(seq 30); do
  curl -s --max-time 2 -o /dev/null http://127.0.0.1:8210/v1/sys/seal-status && break
  sleep 1
done
# The throwaway root token died with the barrier, so everything from here needs
# the ORIGINAL root token. Set ORIGINAL_ROOT to see the autopilot state.
export BAO_TOKEN="${ORIGINAL_ROOT:-$TROOT}"
bao status | grep -E 'Sealed|Cluster ID|HA Mode' | sed 's/^/   /'
echo
echo "   Wait for Failure Tolerance to reach 1 before calling this done."
echo "   Autopilot promotes the last node only after it has been stable, so a"
echo "   freshly restored cluster reports 0 for about a minute with all three"
echo "   nodes healthy."
if ! bao operator raft autopilot state 2>/dev/null | grep -E 'Healthy|Failure Tolerance' | sed 's/^/   /'; then
  echo "   (set ORIGINAL_ROOT to the original root token to read autopilot state)"
fi
