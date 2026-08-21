#!/usr/bin/env bash
#
# The OpenBao side of External Secrets Operator, plus the CA bundle ESO needs to
# trust the listener.
#
#   kubectl -n openbao port-forward svc/openbao 8200:8200 &
#   export BAO_ADDR=https://127.0.0.1:8200
#   export BAO_CACERT=<path>/lesson-4.2-pki-certificates/root_ca.crt
#   export BAO_TOKEN=<your token>
#   ./configure-eso-auth.sh
#
# Install ESO first:
#
#   helm repo add external-secrets https://charts.external-secrets.io
#   helm install external-secrets external-secrets/external-secrets \
#     --version 2.8.0 -n external-secrets --create-namespace --wait
set -euo pipefail
: "${BAO_ADDR:?set BAO_ADDR}"
: "${BAO_TOKEN:?set BAO_TOKEN}"
: "${BAO_CACERT:?set BAO_CACERT, the root_ca.crt written by lesson 4.2}"

ESO_NS="${ESO_NS:-external-secrets}"
APP_NS="${APP_NS:-apps}"

echo "== 1. the secret ESO will copy =="
bao secrets enable -path=secret kv-v2 2> /dev/null || echo "   kv-v2 already enabled at secret/"
bao kv put secret/apps/reporting \
  db_url="postgres://reporting@postgres:5432/reports" \
  api_key="not-a-real-key" > /dev/null
echo "   secret/apps/reporting written"

echo
echo "== 2. a policy for ESO =="
# ESO reads on behalf of every ExternalSecret in the cluster, so this token is
# not a per-application credential. Keep the grant as narrow as the set of paths
# you are willing to have copied into Kubernetes Secrets, which is the real
# boundary this policy defines.
bao policy write eso-read - <<'HCL'
path "secret/data/apps/*" {
  capabilities = ["read"]
}
path "secret/metadata/apps/*" {
  capabilities = ["read", "list"]
}
HCL

echo
echo "== 3. a Kubernetes auth role bound to ESO's own ServiceAccount =="
bao auth enable kubernetes 2> /dev/null || echo "   kubernetes auth already enabled"
bao write auth/kubernetes/role/eso \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces="$ESO_NS" \
  policies=eso-read \
  ttl=20m

echo
echo "== 4. the CA bundle, where ESO can reach it =="
# The ClusterSecretStore is cluster scoped, so its caProvider reference has to
# name a namespace explicitly. ESO's own namespace is the sensible home for it.
kubectl -n openbao get secret openbao-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/openbao-ca.crt
kubectl -n "$ESO_NS" create secret generic openbao-ca \
  --from-file=ca.crt=/tmp/openbao-ca.crt --dry-run=client -o yaml | kubectl apply -f -
rm -f /tmp/openbao-ca.crt

kubectl create namespace "$APP_NS" --dry-run=client -o yaml | kubectl apply -f -

echo
echo "Next: kubectl apply -f cluster-secret-store.yaml -f external-secret.yaml"
