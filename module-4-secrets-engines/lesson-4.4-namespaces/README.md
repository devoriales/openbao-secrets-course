# Lesson 4.4 — Multi-Tenancy with Namespaces

Artifacts for lesson 4.4 of [OpenBao Secrets Management: Production Operations on Kubernetes](https://devoriales.com/quiz/27/openbao-secrets-management-production-operations-on-kubernetes).

The lesson itself lives on devoriales.com. This folder holds only what that lesson asks you
to apply.

Validated on 2026-08-21 against OpenBao **v2.6.1**, chart **openbao-0.28.6**, on k3d
**v5.9.0** with Kubernetes **v1.36.2+k3s1**. See [`VERSIONS.md`](../../VERSIONS.md) for the
full pinned toolchain. Sealable namespaces need **2.6.0 or later**; everything else here
works from 2.3 on.

## Contents

| File | What it is |
|---|---|
| `create-namespaces.sh` | The tenant hierarchy, a K/V v2 engine per namespace, a scoped policy and token |
| `tenant-policy.hcl` | A tenant's own policy, with no namespace name anywhere in it |
| `sealable-namespace-drill.sh` | A namespace with its own Shamir seal: born sealed, unsealed, sealed again, and lock for contrast |

## Setup

Everything here needs the lesson 4.2 end state: OpenBao serving a certificate it issued
itself, and `root_ca.crt` on disk as the trust anchor.

```bash
kubectl -n openbao port-forward svc/openbao 8200:8200 &
export BAO_ADDR=https://127.0.0.1:8200
export BAO_CACERT="/path/to/lesson-4.2-pki-certificates/root_ca.crt"
export BAO_TOKEN=<your token>

./create-namespaces.sh
./sealable-namespace-drill.sh
```

`BAO_SKIP_VERIFY` does not appear in this folder and should not appear in your shell.

## What the scripts prove

**A namespace is addressed by a header, and the header still says Vault.** `-namespace=` on
the CLI and `X-Vault-Namespace:` on the API are the same routing decision. `X-Bao-Namespace`
is not a header OpenBao knows: it is ignored, the request lands in the root namespace, and
you get the 404 below. The path prefix form, `/v1/tenant-a/secret/data/app/db`, works too.

**Forgetting the namespace looks like a missing mount, not like a missing namespace.**

```
{"errors":["no handler for route \"secret/data/app/db\". route entry not found."]}
```

The error names the path. Nothing in it mentions namespaces, so the instinct is to go and
look at the mount, which is present and healthy one namespace over. Through the `kv` CLI the
same mistake surfaces differently again, as a 403 from the preflight capability check rather
than a 404.

**A sealable namespace is created sealed.** Creating it does not leave it usable. The first
`bao secrets enable` into it fails with `503 namespace is sealed` until somebody supplies the
shares. Plan the handover before the tenant needs the namespace, not after.

**Namespace seals are Shamir only, verified rather than assumed:**

```
* namespaces currently only support shamir seals
```

A sealed tenant therefore needs a human with key shares to come back. That is a genuine
operational cost and it is the reason not to hand out tenant seals by default.

**Seal and lock are different tools.** `bao namespace lock` gates the API and hands you an
unlock key, and an operator with `sudo` lifts it without that key:

```
Namespace unlocked using sudo capabilities
```

`bao namespace seal` removes the namespace's key material from memory. There is no sudo path
back in. Lock is for an administrator suspending a tenant; seal is for a tenant revoking
their own data, including from the platform team.

**Deletion has its own rules.** A parent with children is refused, a child is deleted from
its parent with `-namespace=`, not by writing a slash path, and a sealed namespace needs
`delete-sealed`. All three are scheduled rather than immediate:

```
Success! Namespace deletion scheduled: tenant-a/
```

## Cleanup

```bash
bao namespace delete -namespace=tenant-a production
bao namespace delete tenant-a
bao namespace delete-sealed tenant-b
rm -f tenant-b-unseal-keys.txt
```
