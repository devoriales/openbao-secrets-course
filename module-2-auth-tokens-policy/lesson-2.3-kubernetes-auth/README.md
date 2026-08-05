# Lesson 2.3 — Native Kubernetes Authentication

Artifacts for lesson 2.3 of [OpenBao Secrets Management: Production Operations on Kubernetes](https://devoriales.com/quiz/27/openbao-secrets-management-production-operations-on-kubernetes).

| File | What it is |
|---|---|
| `setup-k8s-auth.sh` | Configures the auth method end to end, then proves it works and proves it refuses the wrong identity |
| `probe-pods.yaml` | Two pods identical except for their ServiceAccount |

## Run it

```bash
kubectl -n openbao port-forward svc/openbao 8200:8200 &
export BAO_ADDR='https://127.0.0.1:8200' BAO_SKIP_VERIFY=1 BAO_TOKEN='<root>'
./setup-k8s-auth.sh
```

Expected tail:

```
==> probe (app-sa): should succeed
   policies: ['app-readonly', 'default'] | ttl: 1200 s
==> probe-wrong (wrong-sa): should be refused
   errors: ['service account name not authorized']
==> and the working pod reads the secret with the token it was issued
   read: {'password': 'from-k8s-auth', 'username': 'dbadmin'}
```

## Three things worth knowing

**OpenBao does not validate the JWT.** It calls the Kubernetes TokenReview API and trusts the
answer. The trust chain is: your pod trusts Kubernetes, OpenBao trusts Kubernetes, so OpenBao
can trust your pod.

**The Helm chart already granted the RBAC.** `openbao-server-binding` binds the `openbao`
ServiceAccount to `system:auth-delegator`, which is exactly the TokenReview permission. Much
material has you create this by hand; with this chart it is already there.

Remove it and watch what happens:

```bash
kubectl delete clusterrolebinding openbao-server-binding
# same pod, same JWT:
{"errors":["permission denied"]}
```

A healthy OpenBao, a valid token, a correct role, and `permission denied`. The denied permission
is OpenBao's, not the pod's.

**`token_reviewer_jwt` is only for OpenBao running outside the cluster.** In-cluster, OpenBao
uses its own ServiceAccount token, so `token_reviewer_jwt_set` reads `false` and that is
correct. Outside the cluster you must supply one, and it becomes a long-lived credential you
have to rotate.

## Cleanup

```bash
kubectl delete -f probe-pods.yaml
kubectl delete namespace production
bao auth disable kubernetes
bao policy delete app-readonly
```
