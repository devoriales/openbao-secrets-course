# Lesson 3.4 — Cloud KMS Auto-Unseal

Artifacts for lesson 3.4 of [OpenBao Secrets Management: Production Operations on Kubernetes](https://devoriales.com/quiz/27/openbao-secrets-management-production-operations-on-kubernetes).

A complete AWS KMS auto-unseal lab that costs nothing, plus an honest account of
the one thing it cannot test.

```bash
./setup-awskms-unseal.sh
```

Needs docker, k3d, kubectl and helm, plus the lesson 1.2 cluster.

## What is in here

| File | What it is |
|---|---|
| `Dockerfile` | Stock OpenBao image plus the `kms-aws` plugin binary |
| `ministack.yaml` | The AWS KMS emulator, with state persistence |
| `values-awskms.yaml` | Helm values carrying the `plugin "kms"` and `seal "awskms"` stanzas |
| `setup-awskms-unseal.sh` | Builds, imports, creates the key, installs, initialises |
| `iam-policy.json` | The minimal IAM policy, for when you point this at real AWS |

## Every component, and why it is here

**`openbao/openbao:2.6.1`** is the default distribution, Alpine based. Lesson 3.3
needed the `openbao-ubi` glibc build; this one does not, for the reason below.

**`openbao-plugin-kms-aws`, release `kms-aws-v0.1.0`**, from
[openbao/openbao-plugins](https://github.com/openbao/openbao-plugins), implements
`seal "awskms"`. It reaches KMS over HTTPS with the AWS SDK for Go, so it needs no
C libraries, is built `CGO_ENABLED=0`, and is a statically linked 18 MB binary that
runs unmodified on musl.

You can tell which plugins need cgo without downloading anything: `kms-aws`
publishes linux builds for amd64, arm64, arm 6, ppc64le, riscv64 and s390x, while
`kms-pkcs11` publishes amd64 and arm64 only. That spread is the signature of a
pure-Go build.

**`nahuelnucera/ministack:1.4.11`**, from
[ministackorg/ministack](https://github.com/ministackorg/ministack) (MIT), is a
local AWS API emulator. It answers the KMS wire protocol on port 4566, which is all
that is required, because OpenBao's seal is an ordinary AWS SDK client and does not
care what is on the other end.

LocalStack used to fill this role. Its current images require a paid auth token and
exit without one, so it is not usable here.

**`amazon/aws-cli:2.36.16`** creates the KMS key and its alias. This is the real AWS
CLI, not a mock: the same binary you would run against AWS, pointed at a different
`--endpoint-url`.

## What this lab proves, and what it cannot

It proves the mechanism end to end: the seal stanza, the plugin registration and
checksum pinning, key id versus alias, initialisation with recovery shares,
auto-unseal on restart, and every failure mode that involves the KMS endpoint.

**It cannot test IAM.** MiniStack accepts any credentials at all. Boot OpenBao with
`AKIACOMPLETELYBOGUS` and a secret key of `not-even-close-to-a-real-secret` and it
unseals in eleven seconds. That is not a defect in the emulator, it is the nature of
one, and it matters because IAM is the most common cause of real cloud-KMS unseal
failures. `iam-policy.json` is correct per the documentation and is the part you must
verify against real AWS yourself.

## Going to real AWS

Delete one line. The `endpoint` field exists only to point the SDK at MiniStack:

```hcl
seal "awskms" {
  region     = "us-east-1"
  kms_key_id = "alias/openbao-unseal"
  endpoint   = "http://ministack..."   # <- delete this
}
```

Then stop injecting `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` from a Secret and
use IRSA instead, so the pod receives short-lived credentials from STS:

```yaml
server:
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT_ID:role/openbao-unseal
```

The role's trust policy federates to the cluster's OIDC provider and its permission
policy is `iam-policy.json`. Static keys in a Secret work and are what the lab uses,
because there is no STS to federate with locally.

Cost, if you do this: one KMS key is about **$1/month**, plus per-request charges
that round to nothing at unseal frequency.

## Failure modes, and where each one lands

| What broke | Symptom | Recoverable |
|---|---|---|
| KMS unreachable, instance already running | Nothing at all | n/a, no impact until restart |
| KMS unreachable, on restart | `Error configuring seal "awskms": ... connection refused`, CrashLoopBackOff | Yes, self-heals when KMS returns |
| Alias deleted or repointed | `NotFoundException: Key alias/openbao-unseal not found` | **Yes**, recreate the alias against the same key |
| The KMS key itself deleted | Same `NotFoundException` | **No.** Nothing can unwrap the root key |
| IAM drift, `kms:Decrypt` revoked | Access denied at next restart | Yes, restore the permission |

The third and fourth rows produce the *same error* and have opposite outcomes. An
alias is a pointer; losing it loses nothing. Read carefully what is actually missing
before you reach for a snapshot.

Recovery keys do not help with any row in that table. They authorise privileged
operations against a running instance and are not a decryption path for the root key.

## MiniStack persistence is not optional here

`ministack.yaml` sets `PERSIST_STATE=1`, `STATE_DIR` and a PVC. The default is
in-memory, and without persistence the KMS key disappears whenever the pod restarts,
which permanently bricks the OpenBao instance whose root key it wrapped.

It also collapses the two failure modes the lesson is trying to separate: without
persistence, "the KMS endpoint went away for a minute" and "somebody deleted the KMS
key" become the same event.

## Cleanup

```bash
helm uninstall openbao -n openbao-kms && kubectl delete namespace openbao-kms
```

That removes the KMS key along with everything else, which is fine here and is worth
thinking about for a moment anywhere else.
