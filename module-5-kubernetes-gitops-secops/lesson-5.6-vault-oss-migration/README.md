# Lesson 5.6 — Migrating from Vault OSS to OpenBao

Artifacts for lesson 5.6 of [OpenBao Secrets Management: Production Operations on Kubernetes](https://devoriales.com/quiz/27/openbao-secrets-management-production-operations-on-kubernetes).

The lesson itself lives on devoriales.com. This folder holds only what that lesson asks you
to apply.

Validated on 2026-08-22: **HashiCorp Vault 1.14.0** (chart `hashicorp/vault` **0.25.0**) migrated
to **OpenBao v2.6.2** (chart **openbao-0.29.2**), both standalone on the file storage backend with
a Shamir seal, on k3d. See [`VERSIONS.md`](../../VERSIONS.md) for the full pinned toolchain.

## Contents

| File | What it is |
|---|---|
| `vault-values.yaml` | The Vault 1.14 side of the lab, deliberately minimal |
| `migrate.sh` | The runbook: `backup`, `cutover`, `verify`, `rollback` |

## Setup

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm install vault hashicorp/vault --version 0.25.0 \
  -n vault --create-namespace -f vault-values.yaml

kubectl -n vault exec vault-0 -- vault operator init -key-shares=5 -key-threshold=3
# unseal with three shares, then put some data in it worth migrating
```

Install OpenBao from lesson 1.3 as usual, and **do not initialise it**. It is going to adopt
Vault's storage, barrier and all, so anything it wrote for itself would be in the way.

## Apply

Run the steps in order and read each one's output before the next.

```bash
export VAULT_TOKEN=<vault root token>
./migrate.sh backup     # seal Vault, take the archive, prove it opens
./migrate.sh cutover    # stop Vault, load the archive into OpenBao, start it
# unseal OpenBao with VAULT's three shares
./migrate.sh verify     # the checklist, on the other side
```

If anything looks wrong:

```bash
./migrate.sh rollback   # OpenBao down, Vault back up on its own untouched volume
```

## What the artifacts prove

**The barrier is the same barrier.** OpenBao 2.6.2 started on Vault 1.14's data directory and
reported `Initialized true`, `Sealed true`, `Total Shares 5`, `Threshold 3` without being told
anything. Vault's three unseal shares opened it. Vault's root token then worked unchanged.

**Everything came across.** After the cutover: the `secret/` kv-v2 mount, the `approle/` auth
method with its `reporting` role and `[reporting-read]` policy, the `reporting-read` policy
itself, and the secret value `written-under-vault-1.14`. Even the cluster name came across, so
`bao status` reports `Cluster Name vault-cluster-...` on an OpenBao instance.

**Including things OpenBao does not use.** `bao policy list` shows `control-group`, a policy that
exists because Vault put it there. Migration copies your estate, warts included; it is not a
filter.

**A wrong unseal share does not announce itself.** With one byte of one share corrupted, the first
two shares reported normal progress and the ceremony only failed at the threshold:

```
Unseal Progress    1/3
Unseal Progress    2/3
Code: 400. Errors:
* unable to retrieve stored keys: invalid key: failed to decrypt keys from storage: cipher: message authentication failed
```

Hold the ceremony where every key holder is reachable, because you find out at the end.

**Rollback does not need the archive.** The cutover scales Vault to zero rather than deleting it,
so its PVC is untouched. Rolling back is scaling OpenBao down, Vault up, and unsealing: verified,
with `written-under-vault-1.14` still readable afterwards. The archive is the second line of
defence, for the case where somebody deletes the PVC anyway.

**Two kubectl details that cost time.** Piping an archive into a pod with `kubectl run -i` races
the container's startup and returns `error: timed out waiting for the condition` while the copy
silently never happens; `migrate.sh` uses a sleeping helper pod plus `kubectl cp` instead. And
`kubectl wait` on a pod that does not exist yet errors rather than waiting, so the rollback polls.

## Cleanup

```bash
helm uninstall vault -n vault
kubectl delete namespace vault
rm -f vault-data-*.tgz    # these contain a full copy of your Vault storage
```
