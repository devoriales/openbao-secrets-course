#!/usr/bin/env bash
#
# Walks one OpenBao instance through three seals without losing a byte:
#
#   Shamir  ->  Transit  ->  PKCS#11
#
# A canary secret is written under Shamir at the start and read back after each
# migration, because "it unsealed" is not the same claim as "the data is still
# there".
#
# What this uses, and why:
#   openbao-pkcs11:lab            built by lesson 3.3. Carries bao, SoftHSM and
#                                 openbao-plugin-kms-pkcs11. Used from step 1
#                                 so the image never changes mid-migration.
#   lesson 3.2's unsealer         a small OpenBao holding one Transit key.
#                                 Installed here by reusing that lesson's values.
#   openbao/openbao 0.29.2 chart  same chart as every other lesson.
#
# Usage: ./migrate.sh [step]      step = 1, 2, 3, or "all" (default)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
L32="$HERE/../lesson-3.2-transit-auto-unseal"
L33="$HERE/../lesson-3.3-pkcs11-softhsm2"

NS=openbao-migrate
NS_UNSEALER=openbao-unsealer
CLUSTER="${K3D_CLUSTER:-openbao-dev}"
IMAGE=openbao-pkcs11:lab
PIN=1234
STEP="${1:-all}"

pf() {  # port-forward to the POD, not the service: an un-Ready pod has no endpoints
  # Started in a subshell and killed by PID rather than pkill, so bash job
  # control does not print "Terminated: 15" over the lesson's output.
  if [ -n "${PF_PID:-}" ]; then kill "$PF_PID" 2>/dev/null || true; wait "$PF_PID" 2>/dev/null || true; fi
  sleep 1
  kubectl -n "$NS" port-forward pod/openbao-0 8200:8200 >/tmp/pf-migrate.log 2>&1 &
  PF_PID=$!
  for _ in $(seq 30); do
    curl -s --max-time 2 -o /dev/null http://127.0.0.1:8200/v1/sys/seal-status && return 0
    sleep 1
  done
  echo "port-forward never came up" >&2; return 1
}

wait_running() {
  for _ in $(seq 60); do
    [ "$(kubectl -n "$NS" get pod/openbao-0 -o jsonpath='{.status.phase}' 2>/dev/null || true)" = "Running" ] && return 0
    sleep 3
  done
  echo "pod never reached Running" >&2; return 1
}

keys() { grep -o '"[A-Za-z0-9+/=]\{40,\}"' /tmp/migrate-init.json | tr -d '"' | sed -n "${1}p"; }

# ---------------------------------------------------------------- step 1
if [ "$STEP" = "1" ] || [ "$STEP" = "all" ]; then
echo "==> STEP 1  Shamir"
docker build -q -t "$IMAGE" "$L33" >/dev/null
k3d image import "$IMAGE" -c "$CLUSTER" >/dev/null 2>&1
helm repo add openbao https://openbao.github.io/openbao-helm >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1 || true
kubectl create namespace "$NS" >/dev/null 2>&1 || true
kubectl -n "$NS" delete secret softhsm-pin >/dev/null 2>&1 || true
kubectl -n "$NS" create secret generic softhsm-pin --from-literal=pin="$PIN" >/dev/null
helm install openbao openbao/openbao -n "$NS" --version 0.29.2 \
  --values "$HERE/values-step1-shamir.yaml" >/dev/null
wait_running; pf
export BAO_ADDR=http://127.0.0.1:8200

bao operator init -key-shares=3 -key-threshold=2 -format=json > /tmp/migrate-init.json
bao operator unseal "$(keys 1)" >/dev/null
bao operator unseal "$(keys 2)" >/dev/null
BAO_TOKEN="$(grep -o '"root_token": "[^"]*"' /tmp/migrate-init.json | sed 's/.*: "//;s/"//')"
export BAO_TOKEN
bao secrets enable -path=kv kv-v2 >/dev/null 2>&1 || true
bao kv put kv/canary note="written under shamir" >/dev/null
echo "   canary written. seal is:"
bao status | grep -E 'Seal Type|Sealed|Total Shares' | sed 's/^/   /'
fi

# ---------------------------------------------------------------- step 2
if [ "$STEP" = "2" ] || [ "$STEP" = "all" ]; then
echo
echo "==> STEP 2  Shamir to Transit"
# The unsealer from lesson 3.2, installed exactly as that lesson installs it.
if ! helm status unsealer -n "$NS_UNSEALER" >/dev/null 2>&1; then
  kubectl create namespace "$NS_UNSEALER" >/dev/null 2>&1 || true
  helm install unsealer openbao/openbao -n "$NS_UNSEALER" --version 0.29.2 \
    --values "$L32/values-unsealer.yaml" >/dev/null
  for _ in $(seq 60); do
    [ "$(kubectl -n "$NS_UNSEALER" get pod/unsealer-openbao-0 -o jsonpath='{.status.phase}' 2>/dev/null || true)" = "Running" ] && break
    sleep 3
  done
  kubectl -n "$NS_UNSEALER" port-forward svc/unsealer-openbao 8300:8200 >/tmp/pf-unsealer.log 2>&1 &
  for _ in $(seq 30); do curl -s --max-time 2 -o /dev/null http://127.0.0.1:8300/v1/sys/seal-status && break; sleep 1; done
  BAO_ADDR=http://127.0.0.1:8300 bao operator init -key-shares=1 -key-threshold=1 -format=json > /tmp/unsealer-init.json
  UK="$(grep -o '"[A-Za-z0-9+/=]\{40,\}"' /tmp/unsealer-init.json | tr -d '"' | sed -n 1p)"
  BAO_ADDR=http://127.0.0.1:8300 bao operator unseal "$UK" >/dev/null
  UROOT="$(grep -o '"root_token": "[^"]*"' /tmp/unsealer-init.json | sed 's/.*: "//;s/"//')"
  BAO_ADDR=http://127.0.0.1:8300 BAO_TOKEN="$UROOT" bao secrets enable transit >/dev/null 2>&1 || true
  BAO_ADDR=http://127.0.0.1:8300 BAO_TOKEN="$UROOT" bao write -f transit/keys/autounseal >/dev/null
  cat > /tmp/autounseal.hcl <<'HCL'
path "transit/encrypt/autounseal" { capabilities = ["update"] }
path "transit/decrypt/autounseal" { capabilities = ["update"] }
HCL
  BAO_ADDR=http://127.0.0.1:8300 BAO_TOKEN="$UROOT" bao policy write autounseal /tmp/autounseal.hcl >/dev/null
  UT="$(BAO_ADDR=http://127.0.0.1:8300 BAO_TOKEN="$UROOT" bao token create -policy=autounseal -period=24h -field=token)"
  kubectl -n "$NS" delete secret unsealer-token >/dev/null 2>&1 || true
  kubectl -n "$NS" create secret generic unsealer-token --from-literal=token="$UT" >/dev/null
  echo "   unsealer up, transit key created, scoped token stored"
fi

helm upgrade openbao openbao/openbao -n "$NS" --version 0.29.2 \
  --values "$HERE/values-step2-transit.yaml" >/dev/null
kubectl -n "$NS" delete pod openbao-0 >/dev/null 2>&1 || true
sleep 5; wait_running; pf
export BAO_ADDR=http://127.0.0.1:8200

echo "   it does NOT unseal on its own:"
kubectl -n "$NS" logs openbao-0 | grep -i "seal migration mode" | sed 's/^/   /' || true

# The keys supplied here are the SHAMIR keys. They become recovery keys.
bao operator unseal -migrate "$(keys 1)" >/dev/null
bao operator unseal -migrate "$(keys 2)" >/dev/null
bao status | grep -E 'Seal Type|Recovery Seal Type|Sealed|Total Recovery Shares' | sed 's/^/   /'
BAO_TOKEN="$(grep -o '"root_token": "[^"]*"' /tmp/migrate-init.json | sed 's/.*: "//;s/"//')"
export BAO_TOKEN
echo "   canary: $(bao kv get -field=note kv/canary)"
fi

# ---------------------------------------------------------------- step 3
if [ "$STEP" = "3" ] || [ "$STEP" = "all" ]; then
echo
echo "==> STEP 3  Transit to PKCS#11"
# The key must exist before the incoming seal is asked to use it. Lesson 3.3
# covers what happens if it does not: the instance is destroyed, not merely
# broken. The token itself was created by the image entrypoint at pod start.
if ! kubectl -n "$NS" exec openbao-0 -- pkcs11-tool --module /usr/lib/softhsm/libsofthsm2.so \
      --token-label openbao --login --pin "$PIN" --list-objects 2>/dev/null | grep -q "bao-unseal"; then
  kubectl -n "$NS" exec openbao-0 -- pkcs11-tool --module /usr/lib/softhsm/libsofthsm2.so \
    --token-label openbao --login --pin "$PIN" --keygen --key-type AES:32 \
    --label bao-unseal --id 01 >/dev/null
  echo "   AES-256 key generated inside the token"
fi

PLUGIN_BINARY="$(docker run --rm --entrypoint sh "$IMAGE" -c 'ls /openbao/plugins | grep ^openbao-plugin-kms-pkcs11')"
PLUGIN_SHA256="$(docker run --rm --entrypoint sh "$IMAGE" -c 'cut -d" " -f1 /openbao/plugins/.sha256')"
RENDERED="$(mktemp)"; trap 'rm -f "$RENDERED"' EXIT
sed -e "s|PLUGIN_BINARY|${PLUGIN_BINARY}|" -e "s|PLUGIN_SHA256|${PLUGIN_SHA256}|" \
    "$HERE/values-step3-pkcs11.yaml" > "$RENDERED"

helm upgrade openbao openbao/openbao -n "$NS" --version 0.29.2 --values "$RENDERED" >/dev/null
kubectl -n "$NS" delete pod openbao-0 >/dev/null 2>&1 || true
sleep 5; wait_running; pf
export BAO_ADDR=http://127.0.0.1:8200

echo "   both seals are named in the banner:"
kubectl -n "$NS" logs openbao-0 | grep -E 'Auto Seal|Old Auto Seal|seal migration mode' | sed 's/^/   /' || true

# This time the keys are RECOVERY keys. They happen to be the same strings,
# because the Shamir keys were converted into recovery keys in step 2.
bao operator unseal -migrate "$(keys 1)" >/dev/null
bao operator unseal -migrate "$(keys 2)" >/dev/null
bao status | grep -E 'Seal Type|Recovery Seal Type|Sealed' | sed 's/^/   /'
BAO_TOKEN="$(grep -o '"root_token": "[^"]*"' /tmp/migrate-init.json | sed 's/.*: "//;s/"//')"
export BAO_TOKEN
echo "   canary after two migrations: $(bao kv get -field=note kv/canary)"

cat <<'NOTE'

   Once the instance is up on the new seal, the outgoing stanza can be deleted
   from the config. Until then it is the only thing that can decrypt the
   current root key. Delete it too early and there is no way back.
NOTE
fi
