# Lesson 3.8 — Backup, Restore and Break-Glass

Artifacts for lesson 3.8 of [OpenBao Secrets Management: Production Operations on Kubernetes](https://devoriales.com/quiz/27/openbao-secrets-management-production-operations-on-kubernetes).

Snapshots to S3, a restore drill that actually destroys the cluster, and the break-glass
procedure that stopped working the way everyone documents it.

```bash
./setup-garage.sh                                   # S3 target and credentials
kubectl apply -f snapshot-cronjob.yaml              # scheduled snapshots
KEYS_FILE=quorum.txt ORIGINAL_ROOT=s.… ./restore-drill.sh
BAO_ADDR=… ./break-glass-runbook.sh authed quorum.txt
```

Needs docker, k3d, kubectl, helm, `bao` and the `aws` CLI, plus a three node Raft cluster
from [lesson 3.7](../lesson-3.7-raft-ha).

| File | What it is |
|---|---|
| `garage.yaml` | Garage v2.3.0, the S3 target |
| `setup-garage.sh` | Deploys it, applies a layout, creates the bucket and key |
| `snapshot-cronjob.yaml` | Scheduled snapshots, authenticated with Kubernetes auth |
| `restore-drill.sh` | Destroys the cluster and rebuilds it from a snapshot |
| `break-glass-runbook.sh` | Root token recovery, both the authenticated and legacy paths |

## What it uses

**Garage v2.3.0**, image `dxflrs/garage:v2.3.0`, from
[Deuxfleurs](https://git.deuxfleurs.fr/Deuxfleurs/garage), **AGPL-3.0**. It is the S3
target. The licence is worth knowing rather than discovering: running it yourself as a backup
target, which is what this lesson does, is unremarkable, but the network copyleft clause
applies to anyone offering a modified Garage as a service. Garage is 25.8 MB, which matters on
a laptop already running three OpenBao nodes. Any S3 compatible target works: the lesson is the
snapshot and the restore, not the bucket.

**`amazon/aws-cli:2.36.16`** in the snapshot job, the same pin as lesson 3.4. It is the
real AWS CLI pointed at a different `--endpoint-url`, not a mock.

**`quay.io/openbao/openbao:2.6.2`** and chart `openbao/openbao` 0.29.2, unchanged from
lesson 3.7. Raft snapshots are built into the binary; there is no plugin and no custom
image for any of this.

## OpenBao has no scheduled snapshots

`bao operator raft snapshot` has two subcommands, `save` and `restore`. There is no
built-in scheduler: `sys/storage/raft/snapshot-auto/config` returns **404 unsupported
path**, because automated snapshots are a Vault Enterprise feature. The schedule, the
retention policy and the upload are yours to write, which is what `snapshot-cronjob.yaml`
is.

The job authenticates with Kubernetes auth (lesson 2.3) for a 20 minute token carrying one
capability:

```hcl
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}
```

A backup job holding a root token is a backup job that can also destroy what it backs up.

Two details in that job are load-bearing. It reads from `openbao-active`, because the plain
`openbao` service load balances across standbys. And it validates the file before uploading:
`curl` without `--fail` writes the error body to the output path and exits 0, which fills a
bucket with valid-looking snapshots that are JSON error documents. The check is on the gzip
magic bytes rather than `gzip -t`, because the aws-cli image has no gzip.

## What is actually inside a snapshot

A snapshot is a gzipped tar of four files:

```
meta.json           plaintext Raft metadata: index, term, node ids and addresses
state.bin           the bolt database
SHA256SUMS          plaintext hashes of the two above
SHA256SUMS.sealed   the same hashes, encrypted with the instance's seal
```

Values are encrypted; structure is not. Searching `state.bin` for the secrets written
before the snapshot finds nothing, but these are all in the clear:

| In the clear | Encrypted |
|---|---|
| policy names, e.g. `sys/policy/restore-check` | every secret value |
| userpass usernames, e.g. `auth/<uuid>/user/drill` | KV secret paths |
| mount layout and token accessors | |
| the seal config, including type and share counts | |

KV v2 salts its storage paths, which is why secret names do not appear; the auth and policy
stores do not. So a leaked snapshot is not a plaintext dump of your secrets, but it does
disclose your mount layout, your policy names, your usernames and your seal parameters.
Treat it as confidential.

## A restore is not an import. It is a transplant.

This is the part that surprises people, and the reason the drill exists.

Restoring a snapshot into an instance that did not produce it is **refused**:

```
Code: 400. Errors:
* could not verify hash file, possibly the snapshot is using a different set of unseal
  keys; use the snapshot-force API to bypass this check
```

That is `SHA256SUMS.sealed`: the target cannot decrypt it, so it cannot verify it. Force it
and the restore succeeds, and what you have afterwards is **not your instance with imported
data**. It is the source instance. Same barrier, same keyring, same root token, same cluster
ID. The target's own unseal keys are dead from that moment.

Executed, on a cluster destroyed down to its PersistentVolumeClaims and rebuilt empty:

| Attempt | Result |
|---|---|
| Unforced restore | 400, refused |
| `-force` restore | Succeeds, instance seals itself |
| Unseal with the rebuilt cluster's own brand new keys | Fails |
| Unseal with the **original** keys | Opens, cluster ID reverts to the original |

**A snapshot is not a backup on its own.** The `operator init` you run on a DR cluster is a
throwaway whose keys die the moment the restore lands. A team that stores snapshots
diligently and does not store the unseal keys and root token with equal care can restore
their data and will never be able to open it.

## The restore does not reload the seal configuration

Worth its own section, because both symptoms point away from the cause.

If the DR cluster was initialised with a different share and threshold count than the
source, `bao status` keeps reporting the **old** one after the restore. The process read its
seal config into memory at startup and a restore does not make it re-read. Storage and
memory now disagree, and the error you get depends on which key you try:

```
original keys  -> invalid key: failed to setup unseal key: crypto/aes: invalid key size 33
throwaway key  -> unable to retrieve stored keys: failed to decrypt keys from storage:
                  cipher: message authentication failed
```

The first is a 3-of-2 Shamir share, 33 bytes with its trailing index byte, offered to an
instance that believes it is 1-of-1 and expects a raw 32 byte key. The second is the barrier
genuinely having been replaced. Neither says "restart me".

`kubectl delete pod openbao-0`, and the restored seal config loads. Note that this stays
hidden if the DR cluster happens to be initialised with the same share counts as the source,
so the drill passes on a lucky configuration and fails on an unlucky one.

## Break-glass changed, and the usual runbook no longer works

Every generate-root runbook you will find starts with `bao operator generate-root -init`
and no credentials. On 2.6.2:

```
$ bao operator generate-root -init
URL: PUT http://127.0.0.1:8200/v1/sys/generate-root-token/attempt
Code: 403. Errors:
* permission denied
```

Two changes cause it. As of v2.6.0 the CLI calls the **authenticated**
`/sys/generate-root-token` endpoints, and every step needs a token, including
`-generate-otp` and `-decode`, which look local but call the status endpoint to learn the
OTP length. And the legacy unauthenticated `/sys/generate-root` endpoints are **disabled by
default**: the listener parameter `disable_unauthed_generate_root_endpoints` has defaulted
to true since v2.5.3, because unauthenticated callers could cancel an in-flight root
generation, a denial of service against the exact ceremony you run in an emergency.

**So a default 2.6.2 instance has no no-token recovery path.** If you want one, you set it
before the incident:

```hcl
listener "tcp" {
  disable_unauthed_generate_root_endpoints = false
}
```

`break-glass-runbook.sh` implements both. The `unauthed` half is raw API calls, because the
CLI will not use those endpoints even when they are enabled. The legacy attempt response
hands you the OTP, which the authenticated flow does not, and decoding is a local XOR
against it.

Whichever path you take, it is not finished when you have the token. `generate-root` **adds**
a root token; it does not revoke any existing one. Verified: after the ceremony the original
root token was still valid and two root accessors existed. If you ran this because a token
leaked, that token still works right now.

## Failure tolerance is 0 immediately after a restore

With all three pods Running, Ready and unsealed, autopilot still reported:

```
Healthy:             true
Failure Tolerance:   0
```

`list-peers` showed the third node as `Voter false`. Autopilot promotes a new node only once
it has been stable for a period, so a freshly restored cluster is briefly a two voter cluster
and tolerates zero failures. Measured: about 60 seconds. Do not call a DR exercise finished
on pod readiness; wait for the number.

## Cleanup

```bash
helm uninstall openbao -n openbao
kubectl delete namespace openbao openbao-backup
```

And delete the unseal keys and root token you saved for the drill. They open a cluster that
no longer exists, right up until someone restores its snapshot.
