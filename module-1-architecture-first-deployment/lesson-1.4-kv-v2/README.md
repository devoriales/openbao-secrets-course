# Lesson 1.4 — Storage Engines & K/V v2 Deep Dive

Artifacts for lesson 1.4 of [OpenBao Secrets Management: Production Operations on Kubernetes](https://devoriales.com/quiz/27/openbao-secrets-management-production-operations-on-kubernetes).

## Contents

| File | What it is |
|---|---|
| `api-examples.sh` | Every K/V v2 operation over the REST API, so you can see the real paths |

## Prerequisites

The lesson 1.3 deployment: OpenBao running, initialized and unsealed.

```bash
kubectl -n openbao port-forward svc/openbao 8200:8200 &
export BAO_ADDR='https://127.0.0.1:8200'
export BAO_SKIP_VERIFY=1
export BAO_TOKEN='<your root token>'
```

## There is no `secret/` mount until you make one

A freshly initialized OpenBao has three mounts, and none of them is a K/V store:

```
Path          Type         Description
----          ----         -----------
cubbyhole/    cubbyhole    per-token private secret storage
identity/     identity     identity store
sys/          system       system endpoints used for control, policy and debugging
```

Plenty of material assumes `secret/` already exists, because Vault's `-dev` mode creates one.
Yours does not. Enable it explicitly:

```bash
bao secrets enable -path=secret -version=2 kv
```

## The path mismatch that catches everyone

The CLI hides two path segments that the API requires. Same secret, three different paths:

| What you are doing | CLI | API |
|---|---|---|
| Read/write data | `secret/production/db` | `secret/data/production/db` |
| Version history | `secret/production/db` | `secret/metadata/production/db` |
| Soft delete | `secret/production/db` | `secret/delete/production/db` |
| Undelete | `secret/production/db` | `secret/undelete/production/db` |
| Destroy | `secret/production/db` | `secret/destroy/production/db` |

The CLI tells you which one it used. `bao kv put secret/production/db` prints
`====== Secret Path ======` followed by `secret/data/production/db`. Read that line; it is
the answer to most "why does my curl 404" questions.

Run `./api-examples.sh` to watch each operation hit its real URL.

## The response nests twice

A K/V v2 read returns your keys under `.data.data`, and the version info under
`.data.metadata`:

```json
{
  "data": {
    "data":     { "password": "cas-write", "username": "dbadmin" },
    "metadata": { "version": 4, "destroyed": false, "deletion_time": "" }
  }
}
```

Reaching for `.data` and getting metadata instead of your secret is a rite of passage. In
`jq` terms you want `.data.data.password`, not `.data.password`.

## Four operations, and only one of them is reversible

| Operation | Reversible | What survives |
|---|---|---|
| `bao kv delete` | **yes**, via `undelete` | Everything. `deletion_time` is set, the data is hidden |
| `bao kv undelete` | n/a | Clears `deletion_time`, data readable again |
| `bao kv destroy` | **no** | Version metadata stays with `destroyed: true`; the data is gone |
| `bao kv metadata delete` | **no** | Nothing. The secret and every version of it disappear |

The distinction that matters operationally: `delete` is a tombstone you can lift, `destroy`
removes the ciphertext for one version, and `metadata delete` removes the whole secret and
its entire history. Only `delete` has an undo.

Three states can coexist on one secret, which the version history makes obvious:

```
versions: {1: destroyed, 2: destroyed, 3: live, 4: deleted, 5: live}
```

## Check-and-set

`cas_required` turns blind writes into errors, which is how you stop two processes silently
overwriting each other:

```bash
bao kv metadata put -cas-required=true secret/production/db

bao kv put secret/production/db password=x
#   * check-and-set parameter required for this call

bao kv put -cas=1 secret/production/db password=x
#   * check-and-set parameter did not match the current version

bao kv put -cas=3 secret/production/db password=x     # succeeds if 3 really is current
```

You are asserting "I read version 3 and I am writing on that basis". If somebody else wrote
version 4 in between, your write is rejected rather than silently clobbering theirs.

## The token header kept the Vault name

```bash
curl -H "X-Vault-Token: $BAO_TOKEN" ...   # 200
curl -H "X-Bao-Token: $BAO_TOKEN"   ...   # 403
```

`X-Bao-Token` is not a header OpenBao 2.6.1 accepts. This is the same pattern as the Agent
injector annotations keeping their `vault.hashicorp.com/` prefix: the wire protocol stayed
compatible even where the filesystem paths did not.

## Cleanup

```bash
bao kv metadata delete secret/production/db      # removes the secret and all versions
bao secrets disable secret/                      # removes the mount entirely
```
