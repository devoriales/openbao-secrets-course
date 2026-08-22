# Lesson 2.5 — AppRole

Artifacts for lesson 2.5 of [OpenBao Secrets Management: Production Operations on Kubernetes](https://devoriales.com/quiz/27/openbao-secrets-management-production-operations-on-kubernetes).

| File | What it is |
|---|---|
| `approle-demo.sh` | The two-part credential, single-use SecretIDs, revocation by accessor, CIDR binding, and response wrapping |

```bash
export BAO_ADDR='https://127.0.0.1:8200' BAO_SKIP_VERIFY=1 BAO_TOKEN='<root>'
./approle-demo.sh
```

## The shape of it

**RoleID is not a secret.** Commit it. **SecretID is.** Neither authenticates alone:

```
role_id only:    * missing secret_id
secret_id only:  * missing role_id
```

**Make the SecretID barely worth stealing** with `secret_id_num_uses=1` and a short
`secret_id_ttl`. Reuse then fails with `invalid role or secret ID`, and if a thief beats your
workload to it, your workload's login failure is the alarm.

**SecretIDs have accessors**, so an operator can revoke one they have never seen. That is what
makes it safe to log which SecretID went to which runner.

**CIDR binding** is defence in depth. Note the real error carries `%!w(<nil>)`, an upstream Go
formatting bug in OpenBao 2.6.2. Cosmetic, and not something you caused.

**Response wrapping** is the important one:

```
unwrap once:  got a secret_id: True
unwrap again: * wrapping token is not valid or does not exist
```

Whoever delivers the wrapping token never sees the SecretID, and a wrapping token is single use.
If your workload's unwrap fails, someone unwrapped it first and you know immediately. Response
wrapping does not solve the secret zero problem; it makes theft **detectable**.

## A shell note worth stealing

The script runs with `set -euo pipefail` and most of its commands are *meant* to fail. Under
`pipefail`, a failing command in a pipeline aborts the run even when a later stage succeeds, so
the expected failures are wrapped in an `expect_fail` helper that guards the command itself
rather than the formatting pipeline. Guarding the wrong end of the pipe looks like it works and
silently ends the script at the first example.

## Cleanup

```bash
bao auth disable approle
bao policy delete app-readonly
```
