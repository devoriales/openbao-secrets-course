# Lesson 5.3 — OpenBao Agent Sidecar Injection

Artifacts for lesson 5.3 of [OpenBao Secrets Management: Production Operations on Kubernetes](https://devoriales.com/quiz/27/openbao-secrets-management-production-operations-on-kubernetes).

The lesson itself lives on devoriales.com. This folder holds only what that lesson asks you
to apply.

Validated on 2026-08-22 against OpenBao **v2.6.1**, chart **openbao-0.28.6**, the injector
**hashicorp/vault-k8s 1.7.2** that the chart ships, and the agent image the injector uses,
**quay.io/openbao/openbao:2.6.1**. See [`VERSIONS.md`](../../VERSIONS.md) for the full pinned
toolchain.

## Contents

| File | What it is |
|---|---|
| `configure-injection.sh` | The secret, the policy, the Kubernetes auth role, and the namespace, ServiceAccount and CA the agent needs |
| `reporting-app.yaml` | A Deployment that gets its secret from annotations alone, with every annotation explained |

## Setup

Everything here needs the lesson 4.2 end state: OpenBao serving a certificate it issued
itself, and `root_ca.crt` on disk as the trust anchor.

```bash
kubectl -n openbao port-forward svc/openbao 8200:8200 &
export BAO_ADDR=https://127.0.0.1:8200
export BAO_CACERT="/path/to/lesson-4.2-pki-certificates/root_ca.crt"
export BAO_TOKEN=<your token>

./configure-injection.sh
kubectl apply -f reporting-app.yaml
```

Nothing here installs the injector. The chart from lesson 1.3 already did.

## Apply

```bash
POD=$(kubectl -n apps get pod -l app=reporting -o jsonpath='{.items[0].metadata.name}')

# Two containers you did not write, plus yours.
kubectl -n apps get pod $POD \
  -o jsonpath='init: {.spec.initContainers[*].name}{"\n"}main: {.spec.containers[*].name}{"\n"}'

# The rendered template, in your application's filesystem.
kubectl -n apps exec $POD -c reporting -- cat /vault/secrets/db-config

# On tmpfs, not on a disk.
kubectl -n apps exec $POD -c reporting -- df -h /vault/secrets

# The config the injector generated, decoded.
kubectl -n apps get pod $POD -o json \
  | python3 -c "import json,sys,base64; c=[x for x in json.load(sys.stdin)['spec']['containers'] if x['name']=='vault-agent'][0]; print(json.dumps(json.loads(base64.b64decode([e for e in c['env'] if e['name']=='VAULT_CONFIG'][0]['value'])), indent=2))"
```

## What the artifacts prove

**The injector is Vault's, the agent is OpenBao's.** `docker.io/hashicorp/vault-k8s:1.7.2` does
the pod surgery and injects `quay.io/openbao/openbao:2.6.1`. That is why the annotation prefix is
`vault.hashicorp.com/` and not `bao.hashicorp.com/`.

**The wrong prefix fails silently.** A pod annotated `bao.hashicorp.com/agent-inject: "true"`
starts `1/1 Running`, healthy, with no injection, no warning and no event. The only signal is the
container count.

**Limits without requests produce no pod at all.** The injector defaults to requesting 250m CPU;
setting only `agent-limits-cpu: 100m` makes the API server reject the pod, and the error lands on
the ReplicaSet where `kubectl get pods` will not show it:

```
spec.containers[1].resources.requests: Invalid value: "250m":
must be less than or equal to cpu limit of 100m
```

**Rendered secrets live on tmpfs.** `df -h /vault/secrets` reports `tmpfs`, because the injector
builds the shared volume as an `emptyDir` with `medium: Memory`. Nothing is written to a disk and
nothing becomes an API object.

**Rotation updates the file, not your process.** After a `bao kv put`, the agent logged
`(runner) rendered "(dynamic)" => "/vault/secrets/db-config"` eight seconds later and the file
contained the new value, with no restart. An application that cached the value at startup still
holds the old one.

**Configuration failures are loud.** A wrong role name leaves the pod at `Init:0/1` with
`400 invalid role name` in the init container's log; a path outside the policy leaves it at
`Init:0/1` with `403 permission denied`. In both cases the application never starts, which is the
init container doing its job.

## Cleanup

```bash
kubectl delete -f reporting-app.yaml
kubectl delete namespace apps
bao delete auth/kubernetes/role/reporting
bao policy delete reporting-read
bao kv metadata delete secret/apps/reporting
```
