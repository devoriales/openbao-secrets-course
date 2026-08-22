#!/usr/bin/env bash
#
# The OpenBao side of Agent injection, plus the two pieces of Kubernetes the
# injected agent needs before it can authenticate.
#
#   kubectl -n openbao port-forward svc/openbao 8200:8200 &
#   export BAO_ADDR=https://127.0.0.1:8200
#   export BAO_CACERT=<path>/lesson-4.2-pki-certificates/root_ca.crt
#   export BAO_TOKEN=<your token>
#   ./configure-injection.sh
#
# Nothing here installs the injector. The chart from lesson 1.3 already did:
# `openbao-agent-injector` runs docker.io/hashicorp/vault-k8s:1.7.2, the upstream
# Vault injector, and it injects quay.io/openbao/openbao:2.6.2 as the agent.
set -euo pipefail
: "${BAO_ADDR:?set BAO_ADDR}"
: "${BAO_TOKEN:?set BAO_TOKEN}"
: "${BAO_CACERT:?set BAO_CACERT, the root_ca.crt written by lesson 4.2}"

NS="${NS:-apps}"

echo "== 1. the secret the application will read =="
bao secrets enable -path=secret kv-v2 2> /dev/null || echo "   kv-v2 already enabled at secret/"
bao kv put secret/apps/reporting \
  db_url="postgres://reporting@postgres:5432/reports" \
  api_key="not-a-real-key" > /dev/null
echo "   secret/apps/reporting written"

echo
echo "== 2. a policy that grants exactly that one path =="
bao policy write reporting-read - <<'HCL'
path "secret/data/apps/reporting" {
  capabilities = ["read"]
}
HCL

echo
echo "== 3. a Kubernetes auth role bound to one ServiceAccount in one namespace =="
# Both bindings matter. Binding only the ServiceAccount name would let a
# ServiceAccount called "reporting" in any namespace assume this role, and
# ServiceAccount names are not scarce.
bao auth enable kubernetes 2> /dev/null || echo "   kubernetes auth already enabled"
bao write auth/kubernetes/role/reporting \
  bound_service_account_names=reporting \
  bound_service_account_namespaces="$NS" \
  policies=reporting-read \
  ttl=20m

echo
echo "== 4. the namespace, the ServiceAccount, and the CA the agent has to trust =="
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NS" create serviceaccount reporting --dry-run=client -o yaml | kubectl apply -f -

# The agent talks to OpenBao over TLS that OpenBao issued itself in lesson 4.2,
# so it needs the root as a trust anchor. This copies it out of the listener's
# own Secret rather than asking you to find the file again.
kubectl -n openbao get secret openbao-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/openbao-ca.crt
kubectl -n "$NS" create secret generic openbao-ca \
  --from-file=ca.crt=/tmp/openbao-ca.crt \
  --dry-run=client -o yaml | kubectl apply -f -
rm -f /tmp/openbao-ca.crt
echo "   secret/openbao-ca created in namespace $NS"

echo
echo "Next: kubectl apply -f reporting-app.yaml"
