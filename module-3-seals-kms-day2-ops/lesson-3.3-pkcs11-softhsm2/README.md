# Lesson 3.3 — PKCS#11 Auto-Unseal with SoftHSM

Artifacts for lesson 3.3 of [OpenBao Secrets Management: Production Operations on Kubernetes](https://devoriales.com/quiz/27/openbao-secrets-management-production-operations-on-kubernetes).

| File | What it is |
|---|---|
| `Dockerfile` | Builds one image holding OpenBao, SoftHSM and the KMS plugin |
| `softhsm2.conf` | SoftHSM config, and the one line that decides whether your barrier survives a reschedule |
| `hsm-entrypoint.sh` | Provisions the token at container start, the way a real HSM partition already exists |
| `values-pkcs11.yaml` | Helm values with the `plugin "kms"` and `seal "pkcs11"` stanzas |
| `setup-pkcs11-unseal.sh` | Builds, imports, installs, generates the key, initialises |

```bash
./setup-pkcs11-unseal.sh
```

Needs docker, k3d, kubectl and helm, plus the lesson 1.2 cluster.

## Why everything is in one container

PKCS#11 is a C library API, not a network protocol. There is no HSM service to
connect to: OpenBao `dlopen()`s the `.so` and calls into it in-process. So the
OpenBao binary, `libsofthsm2.so` and the plugin all have to live in the same
container. Any design that puts "the HSM" in a separate pod is describing
something PKCS#11 does not do.

## Why it is not the standard OpenBao image

Two independent reasons, and each one alone is fatal.

The stock `openbao/openbao` image has PKCS#11 compiled out:

```
Error configuring seal "pkcs11": this build of OpenBao has PKCS#11 disabled
```

And the published plugin binary is dynamically linked against glibc, while the
stock image is Alpine and therefore musl. `openbao/openbao-ubi` is the glibc
build, which is why the Dockerfile copies `bao` from there onto a Debian base.

## Built-in seal versus plugin

The `seal "pkcs11"` stanza is identical either way. That is what the release
notes mean by drop-in compatible. What differs is where the implementation
comes from:

|  | `openbao/openbao-hsm` | default image + plugin |
|---|---|---|
| `bao version` | `v2.6.2+hsm ... (cgo)` | `v2.6.2` |
| Startup banner | `builtin: true`, `Cgo: enabled` | `builtin: false`, `Cgo: disabled` |
| On startup | prints a discontinuation warning | clean |
| After v2.7.0 | gone | supported |

The HSM distribution still works today and warns on every start that it is
discontinued. This lab uses the plugin because that is the path that survives
the next minor release.

## The ordering rule, which is the whole lesson

**Generate the key before `bao operator init`.** OpenBao never creates PKCS#11
key material, unlike a Transit or cloud KMS seal where the backend mints a key
on demand.

Getting this wrong does not produce a clean error. The server starts normally,
the API answers, and `init` fails halfway through:

```
Code: 400. Errors:

* failed to store keys: failed to encrypt keys for storage: rpc error: code = Unknown desc = no key found
```

By then the barrier has already been written to storage. The instance now
reports `Initialized: true`, holds no recovery keys and no root token, and
cannot be repaired:

```
$ bao operator init -recovery-shares=3 -recovery-threshold=2
* Vault is already initialized

$ # generate the key and restart, in the hope it picks it up
[WARN] failed to unseal core: error="stored unseal keys are supported, but none were found: is the server initialized?"
```

The only way out is to delete the storage and start over. On a fresh instance
that costs you nothing, which is exactly why it is worth doing here on purpose
rather than discovering it on something that holds secrets.

## Three misconfigurations, three very different symptoms

The useful thing is not the error text, it is *when* each one lands.

| Wrong | When it fails | What you see |
|---|---|---|
| `sha256sum` | Startup, immediately | `start plugin client: checksums did not match` |
| `token_label` | Startup, immediately | `failed to find token with label: openbaoo` |
| `key_label` | Never, until `init` | Nothing at all, then a bricked instance |

The first two fail closed and tell you exactly what is wrong. A wrong
`key_label` is indistinguishable at startup from a correct one, because the
seal resolves the token at configure time and the key only when it first needs
to encrypt.

## Persistence

`directories.tokendir` in `softhsm2.conf` points into `/openbao/data`, which is
the chart's PersistentVolumeClaim. The Debian default is
`/var/lib/softhsm/tokens`, which in Kubernetes is container-local scratch: the
token would be created on first boot, work perfectly, and disappear on the
first reschedule, taking the barrier with it.

The token directory is the thing to back up. Recovery keys do not rebuild it.

## The pod is Running and not Ready for a while, on purpose

The chart's readiness probe is `bao status`, which exits non-zero until the
instance is initialised, and it cannot be initialised until you have generated
the key. So the pod stays un-Ready through that whole step, the Service has no
endpoints, and `port-forward` to the service hangs. Forward to the pod:

```bash
kubectl -n openbao-pkcs11 port-forward pod/openbao-0 8200:8200
```

## Cleanup

```bash
helm uninstall openbao -n openbao-pkcs11 && kubectl delete namespace openbao-pkcs11
```

The PVC holds the token, which holds the only copy of the key that can open the
barrier. Deleting the namespace destroys it, which is what you want here and is
worth thinking about anywhere else.
