#!/usr/bin/env bash
#
# Builds the Transit auto-unseal topology: a small OpenBao whose only job is to
# hold one encryption key, and a second OpenBao that asks it to unwrap a root key
# at startup instead of asking a human.
#
# Zero cost, no cloud KMS, and it demonstrates exactly the mechanism a cloud KMS
# seal uses.
#
# Usage: ./setup-transit-unseal.sh   (needs kubectl, helm 3.x, the lesson 1.2 cluster)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

jq_() { python3 -c "import sys,json;print(json.load(sys.stdin)$1)"; }

# Opens a port-forward and does not return until it actually carries traffic.
#
# Note what this does NOT do: wait for the pod to be Ready. The chart's readiness
# probe is `bao status`, which exits non-zero while an instance is sealed or
# uninitialized. A fresh OpenBao is therefore never Ready until after the init and
# unseal steps below, which means `helm install --wait` cannot be used to gate
# these installs at all. It either burns its whole timeout or, on some Helm
# versions, returns before the pod exists and the port-forward dies with
# "unable to forward port because pod is not running".
#
# So: wait for Running, then poll the tunnel until it answers.
#
# $2 is the chart's fullname, which is NOT always "<release>-openbao". Helm's
# fullname template drops the prefix when the release name already contains the
# chart name, so release "unsealer" gives unsealer-openbao while release
# "openbao" gives plain openbao. Confirm yours with `kubectl get svc` rather than
# assuming either form.
open_tunnel() {
  local ns="$1" name="$2" lport="$3" logf="$4" phase=""

  # Polled rather than `kubectl wait`, because wait errors out with "pods
  # <name> not found" if it beats the StatefulSet controller to creating the
  # pod, which on a fresh namespace it usually does.
  for _ in $(seq 60); do
    phase="$(kubectl -n "$ns" get "pod/${name}-0" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [ "$phase" = "Running" ] && break
    sleep 3
  done
  [ "$phase" = "Running" ] || { echo "pod ${name}-0 never reached Running (phase: ${phase:-absent})" >&2; return 1; }

  kubectl -n "$ns" port-forward "svc/${name}" "${lport}:8200" >"$logf" 2>&1 &
  for _ in $(seq 30); do
    if curl -s --max-time 2 -o /dev/null "http://127.0.0.1:${lport}/v1/sys/seal-status"; then
      return 0
    fi
    sleep 1
  done
  echo "port-forward to ${name} never came up, see $logf" >&2
  return 1
}

echo "==> 1. The unsealer: a plain Shamir instance holding one Transit key"
helm repo add openbao https://openbao.github.io/openbao-helm >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1 || true
kubectl create namespace openbao-unsealer >/dev/null 2>&1 || true
helm install unsealer openbao/openbao -n openbao-unsealer --version 0.29.2 \
  --values "$HERE/values-unsealer.yaml" >/dev/null

# The service here is unsealer-openbao, not unsealer. Port-forwarding to the
# release name alone exits silently and every later command fails with
# connection refused.
open_tunnel openbao-unsealer unsealer-openbao 8300 /tmp/pf-unsealer.log

export BAO_ADDR='http://127.0.0.1:8300'
bao operator init -key-shares=1 -key-threshold=1 -format=json > /tmp/unsealer-init.json
bao operator unseal "$(jq_ "['unseal_keys_b64'][0]" < /tmp/unsealer-init.json)" >/dev/null
export BAO_TOKEN="$(jq_ "['root_token']" < /tmp/unsealer-init.json)"
echo "   unsealer up and unsealed"

echo "==> 2. Transit engine, one key, and a least-privilege policy"
bao secrets enable transit >/dev/null 2>&1 || true
bao write -f transit/keys/autounseal >/dev/null

# Encrypt and decrypt on ONE key. Nothing else. This token is going to sit in the
# production instance's environment, so it should be able to do exactly one job.
cat > /tmp/autounseal.hcl <<'HCL'
path "transit/encrypt/autounseal" { capabilities = ["update"] }
path "transit/decrypt/autounseal" { capabilities = ["update"] }
HCL
bao policy write autounseal /tmp/autounseal.hcl >/dev/null

# Periodic, so it renews forever rather than dying at a max TTL and taking your
# ability to restart with it. Lesson 2.1 covers why that distinction matters.
UT=$(bao token create -policy=autounseal -period=24h -format=json | jq_ "['auth']['client_token']")
echo "   transit key and periodic token ready"

echo "==> 3. The production instance, auto-unsealed"
kubectl create namespace openbao >/dev/null 2>&1 || true
kubectl -n openbao delete secret unsealer-token >/dev/null 2>&1 || true
kubectl -n openbao create secret generic unsealer-token --from-literal=token="$UT" >/dev/null
helm install openbao openbao/openbao -n openbao --version 0.29.2 \
  --values "$HERE/values-autounseal.yaml" >/dev/null

open_tunnel openbao openbao 8200 /tmp/pf-main.log

export BAO_ADDR='http://127.0.0.1:8200'
echo
echo "--- before init, note the seal type ---"
bao status 2>/dev/null | grep -E 'Seal Type|Recovery Seal Type|Initialized|Sealed' | sed 's/^/   /' || true

echo
echo "--- init with RECOVERY shares, not key shares ---"
bao operator init -recovery-shares=3 -recovery-threshold=2 -format=json > /tmp/main-init.json
python3 - <<'PY'
import json
d = json.load(open('/tmp/main-init.json'))
print('   recovery keys returned:', len(d.get('recovery_keys_b64') or []))
print('   unseal  keys returned:', len(d.get('unseal_keys_b64') or []), ' <- there are none, and never will be')
PY

sleep 5
echo
echo "--- and it unsealed itself ---"
bao status | grep -E 'Seal Type|Sealed|Total Recovery Shares' | sed 's/^/   /'

cat <<'NOTE'

   Nobody typed a key. That is the point.

   Save /tmp/main-init.json somewhere real: the recovery keys authorise generating a
   new root token against a RUNNING instance. They are not an unseal path, and if the
   unsealer is unreachable the production instance will not start at all.
NOTE
