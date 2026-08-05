#!/usr/bin/env bash
#
# Configures Kubernetes authentication end to end, then proves it works and proves
# the binding actually refuses the wrong identity.
#
# Usage (against the lesson 1.3 deployment, unsealed):
#   export BAO_ADDR='https://127.0.0.1:8200' BAO_SKIP_VERIFY=1 BAO_TOKEN=<root>
#   ./setup-k8s-auth.sh
set -euo pipefail
: "${BAO_ADDR:?}"; : "${BAO_TOKEN:?}"
ROOT="$BAO_TOKEN"

echo "==> A secret for the workload to read"
bao secrets enable -path=secret -version=2 kv 2>/dev/null || true
bao kv put secret/production/db username=dbadmin password=from-k8s-auth >/dev/null

echo "==> Policy"
cat > /tmp/app-readonly.hcl <<'HCL'
path "secret/data/production/*" {
  capabilities = ["read"]
}
HCL
bao policy write app-readonly /tmp/app-readonly.hcl >/dev/null

echo "==> Enable the auth method"
bao auth enable kubernetes 2>/dev/null || true

# Configured from INSIDE the pod. Two reasons that matters:
#   - KUBERNETES_PORT_443_TCP_ADDR and the CA bundle are already there
#   - no token_reviewer_jwt is needed, because OpenBao uses its own ServiceAccount
#     token to call TokenReview. The Helm chart already binds that SA to
#     system:auth-delegator, so there is no RBAC to create.
echo "==> Configure (in-cluster style, no token_reviewer_jwt)"
kubectl -n openbao exec openbao-0 -- sh -c "
  export BAO_TOKEN='$ROOT'
  bao write auth/kubernetes/config \
    kubernetes_host=\"https://\$KUBERNETES_PORT_443_TCP_ADDR:443\" \
    kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt" >/dev/null

echo "==> Role: only app-sa in namespace production"
bao write auth/kubernetes/role/app \
  bound_service_account_names=app-sa \
  bound_service_account_namespaces=production \
  policies=app-readonly ttl=20m >/dev/null

echo "==> Two ServiceAccounts and two pods, one of each"
kubectl create namespace production 2>/dev/null || true
kubectl -n production create serviceaccount app-sa 2>/dev/null || true
kubectl -n production create serviceaccount wrong-sa 2>/dev/null || true
kubectl apply -f "$(dirname "${BASH_SOURCE[0]}")/probe-pods.yaml" >/dev/null
kubectl -n production wait --for=condition=Ready pod/probe pod/probe-wrong --timeout=180s >/dev/null

login() { # $1 = pod name
  kubectl -n production exec "$1" -- sh -c '
    JWT=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
    curl -sk -X POST -d "{\"role\":\"app\",\"jwt\":\"$JWT\"}" \
      https://openbao.openbao.svc.cluster.local:8200/v1/auth/kubernetes/login'
}

echo
echo "==> probe (app-sa): should succeed"
login probe | python3 -c 'import sys,json;d=json.load(sys.stdin);a=d.get("auth");print("   policies:",a["policies"],"| ttl:",a["lease_duration"],"s") if a else print("   errors:",d.get("errors"))'

echo "==> probe-wrong (wrong-sa): should be refused"
login probe-wrong | python3 -c 'import sys,json;d=json.load(sys.stdin);print("   errors:",d.get("errors"))'

echo
echo "==> and the working pod reads the secret with the token it was issued"
kubectl -n production exec probe -- sh -c '
  JWT=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  T=$(curl -sk -X POST -d "{\"role\":\"app\",\"jwt\":\"$JWT\"}" \
    https://openbao.openbao.svc.cluster.local:8200/v1/auth/kubernetes/login \
    | sed -n "s/.*\"client_token\":\"\([^\"]*\)\".*/\1/p")
  curl -sk -H "X-Vault-Token: $T" \
    https://openbao.openbao.svc.cluster.local:8200/v1/secret/data/production/db' \
  | python3 -c 'import sys,json;print("   read:",json.load(sys.stdin)["data"]["data"])'
