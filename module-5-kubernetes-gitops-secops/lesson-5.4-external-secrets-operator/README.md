# Lesson 5.4 — GitOps with External Secrets Operator

Artifacts for lesson 5.4 of [OpenBao Secrets Management: Production Operations on Kubernetes](https://devoriales.com/quiz/27/openbao-secrets-management-production-operations-on-kubernetes).

The lesson itself lives on devoriales.com. This folder holds only what that lesson asks you
to apply.

Validated on 2026-08-22 against OpenBao **v2.6.1**, chart **openbao-0.28.6**, and the External
Secrets Operator **2.8.0** (`ghcr.io/external-secrets/external-secrets:v2.8.0`). See
[`VERSIONS.md`](../../VERSIONS.md) for the full pinned toolchain.

## Contents

| File | What it is |
|---|---|
| `configure-eso-auth.sh` | The KV value, the policy that defines what may be copied, the Kubernetes auth role bound to ESO's ServiceAccount, and the CA bundle |
| `cluster-secret-store.yaml` | The store, with the provider trap documented in place |
| `external-secret.yaml` | What an application team commits: a path, not a value |
| `consumer-app.yaml` | A workload that consumes the same Secret twice, as env and as a volume, so rotation behaviour is visible in one log line |

## Setup

Install ESO, then run the OpenBao side. Everything here needs the lesson 4.2 end state.

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  --version 2.8.0 -n external-secrets --create-namespace --wait

kubectl -n openbao port-forward svc/openbao 8200:8200 &
export BAO_ADDR=https://127.0.0.1:8200
export BAO_CACERT="/path/to/lesson-4.2-pki-certificates/root_ca.crt"
export BAO_TOKEN=<your token>

./configure-eso-auth.sh
kubectl apply -f cluster-secret-store.yaml -f external-secret.yaml -f consumer-app.yaml
```

## Apply

```bash
kubectl get clustersecretstore openbao
kubectl -n apps get externalsecret reporting

# The copy, and the one command that is the whole trade-off.
kubectl -n apps get secret reporting-config -o jsonpath='{.data.API_KEY}' | base64 -d

# Rotate, then watch env and file diverge.
bao kv put secret/apps/reporting \
  db_url="postgres://reporting@postgres:5432/reports" api_key="rotated-$(date +%H%M%S)"
kubectl -n apps logs -l app=reporting-consumer -f
```

## What the artifacts prove

**The `openBao` provider cannot use Kubernetes auth in ESO 2.8.0.** Its auth options are
`appRole`, `tokenSecretRef` and `userPass`; the older `vault` provider adds `kubernetes`. A store
using `openBao` with Kubernetes auth is rejected at admission with
`strict decoding error: unknown field "spec.provider.openBao.auth.kubernetes"`. The `vault`
provider works against OpenBao because OpenBao kept the Vault API. Re-check on every ESO upgrade.

**One identity reads for the whole cluster.** ESO authenticates as its own ServiceAccount, so
`eso-read` is not an application policy: it is the list of paths you are willing to have copied
into Kubernetes Secrets.

**The copy is base64, in etcd, and readable by the namespace.**
`kubectl get secret ... | base64 -d` returns the value. That is the cost lesson 5.1 named, made
concrete.

**Three clocks, measured.** Value changed in OpenBao at 22:15:17; ESO rewrote the Secret at
22:15:35, on its next `refreshInterval` tick rather than on the change; the pod's mounted file
caught up at 22:16:39 on the kubelet's own sync; the environment variable never changed at all.
Mount a Secret that rotates, or plan for a rollout.

**A denied path fails visibly but leaves nothing behind.** The ExternalSecret reports
`SecretSyncedError` with `could not get secret data from provider`, and the target Secret is not
created, so a consumer sits in `ContainerCreating` blaming a missing Secret rather than the
ExternalSecret that failed.

## Cleanup

```bash
kubectl delete -f consumer-app.yaml -f external-secret.yaml -f cluster-secret-store.yaml
kubectl delete namespace apps
helm uninstall external-secrets -n external-secrets
bao delete auth/kubernetes/role/eso
bao policy delete eso-read
```
