# Lesson 4.2 — PKI Engine and Automated Certificate Management

Artifacts for lesson 4.2 of [OpenBao Secrets Management: Production Operations on Kubernetes](https://devoriales.com/quiz/27/openbao-secrets-management-production-operations-on-kubernetes).

The lesson itself lives on devoriales.com. This folder holds only what that lesson asks you
to apply.

Validated on 2026-08-12 against OpenBao **v2.6.2**, chart **openbao-0.29.2** and cert-manager
**v1.21.1**. See [`VERSIONS.md`](../../VERSIONS.md) for the full pinned toolchain.

This is where lesson 1.3's bootstrap ends. OpenBao's listener has been serving a cert-manager
self signed certificate since Module 1, because OpenBao could not secure its own first boot. By
the end of this folder it serves a certificate it issued itself, the chain validates, and
`BAO_SKIP_VERIFY` is retired for the rest of the course.

## Contents

| File | What it is |
|---|---|
| `configure-pki.sh` | Root CA, intermediate CA, issuer naming, roles, the cert-manager policy and Kubernetes auth role |
| `cert-manager-rbac.yaml` | The ServiceAccount cert-manager authenticates as, and the RBAC that lets it mint a token for it |
| `openbao-listener-cert.yaml` | The `Certificate` that replaces the bootstrap one |
| `close-the-loop.sh` | The migration, in the order that actually works |

## Setup

```bash
kubectl -n openbao port-forward svc/openbao 8200:8200 &
export BAO_ADDR=https://127.0.0.1:8200
export BAO_SKIP_VERIFY=1        # for the last time
export BAO_TOKEN=<your token>

./configure-pki.sh                        # writes root_ca.crt into $PWD
kubectl apply -f cert-manager-rbac.yaml
./close-the-loop.sh
```

`close-the-loop.sh` expects `root_ca.crt` and `openbao-listener-cert.yaml` in the working
directory. Run all three from this folder.

## Apply

Afterwards, and permanently:

```bash
export BAO_CACERT="$PWD/root_ca.crt"
unset BAO_SKIP_VERIFY
bao status
```

Issue a certificate for any workload:

```bash
bao write pki_int/issue/kubernetes-services \
  common_name="payments.production.svc.cluster.local" ttl=168h
```

## Things worth knowing before you copy any of this

**`issuer_name` does not survive `set-signed`.** Passing it to
`pki_int/intermediate/generate/internal` names nothing that lasts, because `set-signed` imports
fresh issuers with empty names. A role written against the missing name is accepted and stored,
then fails at issuance with an HTTP **500**:

```
* could not fetch the CA certificate (was one set?): unable to find PKI issuer for
  reference: intermediate-2026
```

Name the issuer after importing it. `configure-pki.sh` does.

**`set-signed` imports two issuers, not one.** `format=pem_bundle` carries the root along with
the intermediate, so the root ends up inside the intermediate mount without its private key. The
real intermediate is the default issuer, and the one whose `ca_chain` has two certificates.

**cert-manager needs `sign`, never `issue`.** cert-manager generates its own private key and
sends a CSR. `issue/` ignores the CSR and generates its own key pair, so the certificate comes
back correctly signed and permanently useless. The CertificateRequest reports success:

```
Issued | Certificate fetched from issuer successfully
```

and the diagnosis is one level down, on the Certificate:

```
Warning  InvalidCertificate  Issuer returned a certificate with a public key that does not
match the CSR. This usually indicates a misconfigured issuer.
```

The policy in `configure-pki.sh` grants `pki_int/sign/*` and deliberately not `issue`, because
an automation account has no business receiving private keys.

**cert-manager backs off for an hour after a failed issuance.** Fixing the Issuer is not
observable until you delete and recreate the `Certificate`. Deleting only the
`CertificateRequest` does not retrigger it, which makes a correct fix look like a failed one.

**`serviceAccountRef` names an account in the Issuer's namespace.** For the namespaced Issuer
here, that is `openbao`, not `cert-manager`. cert-manager also needs Kubernetes permission to
create a token for it, which is what `cert-manager-rbac.yaml` grants and what nothing in the
cert-manager docs puts next to the Issuer example.

**Exceeding a role's `max_ttl` does not fail. It truncates, silently.**

```
asked 720h  -> notAfter Sep 11 11:02:49 2026 GMT
asked 5000h -> notAfter Sep 11 11:02:50 2026 GMT
```

Same certificate lifetime, no error and no warning field. Anything that computes its own renewal
schedule must read `notAfter` off the certificate it received rather than trusting the TTL it
asked for. Exceeding the *CA's* remaining validity does fail, and says exactly why:

```
* cannot satisfy request, as TTL would result in notAfter of 2033-06-16T10:42:29Z that is
  beyond the expiration of the CA certificate at 2031-08-11T10:41:17Z
```

The loud failure is the safe one.

### The caBundle has two states, and getting stuck in the first one is a time bomb

cert-manager must reach OpenBao over TLS before OpenBao can issue it anything, and at that moment
the listener is still serving the bootstrap certificate. So `caBundle` starts as the **bootstrap
CA** and becomes the **OpenBao root** only after the swap.

If you forget the second step, nothing appears wrong. The Issuer stays `Ready` and renewals keep
succeeding, because cert-manager reuses a cached client. The failure lands the next time
cert-manager restarts, on an upgrade or a node drain:

```
Error initializing issuer: ... tls: failed to verify certificate:
x509: certificate signed by unknown authority
```

and every certificate in the cluster stops renewing, at a moment with no connection to the change
that caused it. Step 6 of `close-the-loop.sh` is that step.

### Reloading without a restart

A restart picks up the new certificate and also leaves a Shamir sealed instance behind, turning a
routine rotation into a key ceremony. `SIGHUP` avoids it. Two things get in the way:

- The mounted Secret is not updated instantly. Measured around **40 to 50 seconds** for kubelet to
  project it into the pod. Reloading before that does nothing and looks like a reload that failed.
- **`kill -HUP 1` does nothing.** PID 1 is the chart's shell wrapper; the `bao server` process is
  a child. Signal that one. The log confirms it with `==> OpenBao reload triggered`, and
  `bao status` still reads `Sealed false`.

## Cleanup

```bash
kubectl -n openbao delete certificate openbao-tls-from-pki
kubectl -n openbao delete issuer openbao-pki
kubectl delete -f cert-manager-rbac.yaml
bao secrets disable pki_int
bao secrets disable pki
```

Deleting the `Certificate` leaves the `openbao-tls` Secret in place, so the listener keeps
serving its last certificate until it expires. To return to the bootstrap state, re-apply
lesson 1.3's `bootstrap-tls.yaml` and SIGHUP the process again.
