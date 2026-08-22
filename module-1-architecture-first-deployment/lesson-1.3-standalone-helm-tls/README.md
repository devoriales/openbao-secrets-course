# Lesson 1.3 — Deploying Standalone OpenBao via Helm, with TLS from Day One

Artifacts for lesson 1.3 of [OpenBao Secrets Management: Production Operations on Kubernetes](https://devoriales.com/quiz/27/openbao-secrets-management-production-operations-on-kubernetes).

## Contents

| File | What it is |
|---|---|
| `bootstrap-tls.yaml` | cert-manager self-signed ClusterIssuer plus the OpenBao serving Certificate |
| `values-standalone.yaml` | Helm values: standalone mode, TLS listener, file storage, correct probes |

## Prerequisites

The lesson 1.2 cluster, running:

```bash
kubectl get nodes            # three nodes Ready on v1.36.2+k3s1
```

## 1. cert-manager

OpenBao becomes this cluster's certificate authority in Module 4, but it cannot issue the
certificate that protects its own first boot. Something has to go first, and that is
cert-manager with a self-signed issuer. It is scaffolding, and it gets replaced.

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.21.1 \
  --set crds.enabled=true \
  --wait
```

Note `crds.enabled=true`. A lot of older material says `installCRDs=true`; that spelling is
deprecated.

## 2. The bootstrap certificate

```bash
kubectl create namespace openbao
kubectl apply -f bootstrap-tls.yaml
kubectl wait --for=condition=Ready certificate/openbao-tls -n openbao --timeout=90s
```

This produces a `kubernetes.io/tls` Secret holding `tls.crt`, `tls.key` and `ca.crt`.

## 3. Deploy OpenBao

```bash
helm repo add openbao https://openbao.github.io/openbao-helm
helm repo update
helm install openbao openbao/openbao \
  --namespace openbao \
  --version 0.29.2 \
  --values values-standalone.yaml \
  --wait
```

Expect the pod to sit at `0/1 Running`. That is correct: it is uninitialized and sealed, and
the readiness probe reports exactly that.

## 4. Initialize and unseal

```bash
kubectl -n openbao port-forward svc/openbao 8200:8200 &
export BAO_ADDR='https://127.0.0.1:8200'
export BAO_SKIP_VERIFY=1        # self-signed bootstrap CA

bao operator init -key-shares=5 -key-threshold=3
```

**Save the five unseal keys and the root token before you do anything else.** With a Shamir
seal there is no recovery path. Lose three of the five keys and the data is cryptographically
gone; there is no support line that can help.

```bash
bao operator unseal        # paste key 1  -> Unseal Progress 1/3
bao operator unseal        # paste key 2  -> Unseal Progress 2/3
bao operator unseal        # paste key 3  -> Sealed false
```

The pod flips to `1/1 Running` shortly after the third key.

## Three things in `values-standalone.yaml` that are easy to get wrong

**Paths are `/openbao/`, not `/vault/`.** The chart descends from vault-helm and much of the
material online still says `/vault/data` and `/vault/tls`. Mount your certificate at
`/vault/tls` here and the process never reads it. Confusingly, the Agent injector annotations
you meet in Module 5 really do use the `vault.hashicorp.com/` prefix, because the chart ships
the upstream `vault-k8s` injector unchanged. Filesystem paths changed; annotation prefixes
did not.

**`global.tlsDisable: false` is mandatory, and it defaults to `true`.** Setting `tls_cert_file`
in the listener config is only half the job. The chart derives the scheme for the probes, the
injector and the CSI provider from this one global value. Leave it at its default with a TLS
listener and Kubernetes probes an https port with plaintext http, the probes fail forever, and
the pod never goes Ready while the server itself is perfectly healthy.

**Do not give the readiness probe a multi-parameter HTTP path.** With `path` unset the chart
uses an exec probe, `bao status -tls-skip-verify`, whose exit code is the seal status. That is
the right semantic and it sidesteps TLS. If you replace it with
`/v1/sys/health?standbyok=true&sealedcode=204&uninitcode=204`, Kubernetes escapes the
ampersands when building the probe URL, OpenBao parses the whole tail as the value of
`standbyok`, and answers **400** forever, while `curl` of that identical URL from your laptop
returns 204. One query parameter is fine. Two or more is not.

Liveness is left disabled, which is the chart default. No HTTP health check can distinguish
"wedged" from "healthy but sealed", because sealed answers 503 and uninitialized answers 501
and both are legitimate states. Enable it naively and Kubernetes restarts the pod every few
seconds during the exact window in which you are trying to initialize and unseal it, re-sealing
the instance each time.

## Verifying TLS is real

```bash
# should fail: the listener does not speak plaintext
BAO_ADDR='http://127.0.0.1:8200' bao status

# what is actually presented on the wire
echo | openssl s_client -connect 127.0.0.1:8200 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
```

Subject and issuer are identical, which is what self-signed means and why `BAO_SKIP_VERIFY=1`
is needed at this stage. That flag disappears once OpenBao issues its own certificates.

## Cleanup

```bash
helm uninstall openbao -n openbao
kubectl delete namespace openbao
helm uninstall cert-manager -n cert-manager
```

Deleting the namespace removes the PVC, and with it the barrier. That is the intended
behaviour: see the storage note in lesson 1.2.
