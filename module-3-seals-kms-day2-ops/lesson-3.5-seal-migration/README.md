# Lesson 3.5 — Seal Migration

Artifacts for lesson 3.5 of [OpenBao Secrets Management: Production Operations on Kubernetes](https://devoriales.com/quiz/27/openbao-secrets-management-production-operations-on-kubernetes).

One instance walked through three seals without losing a byte:

```
Shamir  ->  Transit  ->  PKCS#11
```

```bash
./migrate.sh          # all three steps
./migrate.sh 2        # just step 2, if you are re-running
```

Needs docker, k3d, kubectl and helm, plus the lesson 1.2 cluster.

| File | What it is |
|---|---|
| `values-step1-shamir.yaml` | Starting point. No seal stanza at all |
| `values-step2-transit.yaml` | Adds `seal "transit"`. One stanza is the whole diff |
| `values-step3-pkcs11.yaml` | Adds `seal "pkcs11"`, marks `seal "transit"` disabled |
| `migrate.sh` | Runs the three steps and checks a canary secret after each |

## What it uses

**`openbao-pkcs11:lab`**, the image built by [lesson 3.3](../lesson-3.3-pkcs11-softhsm2).
It carries the `bao` binary, `libsofthsm2.so` from Debian's `softhsm2` 2.6.1-3, and the
`openbao-plugin-kms-pkcs11` binary from release `kms-pkcs11-v0.1.0`.

It is used from **step 1**, before anything needs PKCS#11. Changing the image in the
middle of a seal migration means discovering a missing library at the worst possible
moment, so the chain runs on one image throughout.

**The Transit unsealer from [lesson 3.2](../lesson-3.2-transit-auto-unseal)**, installed
from that lesson's `values-unsealer.yaml`. A small Shamir-sealed OpenBao whose only job is
to hold one `transit/keys/autounseal` key.

**A canary secret.** `migrate.sh` writes `kv/canary` under Shamir and reads it back after
every migration. "It unsealed" and "the data is still there" are different claims.

## The three things that bite

**1. Keep the outgoing seal stanza.** It is the only thing that can still decrypt the
current root key. Delete it instead of disabling it and there is nothing left to open the
barrier. Remove it only after the instance is up on the new seal.

**2. Mark it `disabled = "true"`.** Two live seals is a config error, and a good one,
because it fails before the process starts:

```
error loading configuration from /openbao/config/bao.hcl:
  seals: two seals provided but neither is disabled
```

**3. Pass `-migrate`.** Nothing migrates on a restart. The instance comes up sealed and
says so:

```
[WARN]  core: entering seal migration mode; Vault will not automatically unseal even if
using an autoseal: from_barrier_type=shamir to_barrier_type=transit
```

Unseal without the flag and you get:

```
Code: 500. Errors:
* migrate option not provided and seal migration is pending
```

## Which keys to supply

| Leaving | Supply | They become |
|---|---|---|
| Shamir | the unseal keys | recovery keys of the new seal |
| An auto seal | the recovery keys | recovery keys of the next seal, or unseal keys if going to Shamir |

In this lab the strings never change: the Shamir keys created in step 1 become the
recovery keys in step 2, and are what you present again in step 3.

## Reading the banner

During a migration the startup banner names both seals:

```
   Auto Seal: pkcs11 (builtin: false, key_label: "bao-unseal", ...)
   Old Auto Seal: transit (address: "http://unsealer-openbao...", builtin: true, ...)
```

`Auto Seal` is the incoming one, `Old Auto Seal` is the one marked disabled. If the second
line is missing when you expected a migration, the config is not what you think it is.

## Same-type migration

The OpenBao documentation states that AWSKMS to AWSKMS migration is not supported. On
**2.6.1 that is not what happens**: an `awskms` seal migrated to a second `awskms` seal
with a different key, entered migration mode normally, accepted the migrate unseal, and
afterwards opened with only the new key present in the config.

That was verified against a local KMS emulator rather than real AWS, so treat it as
"the documented limitation did not reproduce" rather than a guarantee. Do not plan a
production same-type migration on the strength of a lab result.

## Cleanup

```bash
helm uninstall openbao -n openbao-migrate && kubectl delete namespace openbao-migrate
helm uninstall unsealer -n openbao-unsealer && kubectl delete namespace openbao-unsealer
```
