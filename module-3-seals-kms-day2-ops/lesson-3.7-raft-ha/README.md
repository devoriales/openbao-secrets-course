# Lesson 3.7 — Standalone to HA: Raft Consensus & Cluster Operations

Artifacts for lesson 3.7 of [OpenBao Secrets Management: Production Operations on Kubernetes](https://devoriales.com/quiz/27/openbao-secrets-management-production-operations-on-kubernetes).

Takes the single file-backed instance from Module 1 and turns it into a three node Raft
cluster, keeping the data, the unseal keys and the root token.

```bash
# with the standalone release running in $NS and its unseal keys on disk
NS=openbao-mig KEYS_FILE=/tmp/mig-keys.txt ./standalone-to-ha.sh
```

| File | What it is |
|---|---|
| `values-ha-raft.yaml` | Three node HA release on `storage "raft"` |
| `migrate-job.yaml` | Offline `bao operator migrate` from file to raft, plus its config |
| `standalone-to-ha.sh` | The whole procedure, in order, with the waits that matter |

## What it uses

Nothing new. The same `openbao/openbao` 0.28.6 chart and the stock
`quay.io/openbao/openbao:2.6.1` image as every other lesson. **Raft is built into the
OpenBao binary**, so unlike PKCS#11 in 3.3 or AWS KMS in 3.4 there is no plugin to
register, no checksum to pin and no custom image to build. `storage "raft"` needs exactly
what `storage "file"` needed.

Seal stays Shamir throughout, on purpose: the migration changes one thing, the storage
backend. The cost is unsealing three nodes by hand, which is the argument for lessons 3.2
to 3.4.

## The migration is an outage

`bao operator migrate` works directly on encrypted data. It needs no running server and
never unseals anything, which is exactly why the release must be **uninstalled** while it
runs: nothing may be writing to the source. There is no zero-downtime path between storage
backends.

The PersistentVolumeClaim survives `helm uninstall`. That is the whole trick here:
`data-openbao-0` still holds the file data afterwards, the Job migrates it in place into a
subdirectory, and the new HA release reuses the same claim for node 0. Nodes 1 and 2 get
fresh volumes and pull the data over the network by joining.

## Two things that will bite

**Raft will not create its parent directory.** The path is `/openbao/data/raft`, and on
nodes 1 and 2 that directory does not exist on a fresh volume:

```
error initializing storage of type raft: failed to create fsm:
  failed to open bolt file: open /openbao/data/raft/vault.db: no such file or directory
```

`values-ha-raft.yaml` carries a one line init container that does `mkdir -p`. Without it,
node 0 works (the Job made the directory) and the others crashloop, which reads like a
Raft problem and is not.

**The StatefulSet is `OrderedReady`, and readiness means unsealed.** Pod 1 is not created
until pod 0 is Ready, and pod 0 is not Ready until you initialise and unseal it. So the
cluster comes up one node at a time and each one needs unsealing before the next appears.
This is not a hang. Check with `kubectl get pods` and unseal whatever is sitting at `0/1`.

## Quorum, and why two voters is the worst number

Quorum is `(N/2)+1` **voters**. You do not have to work it out:

```
$ bao operator raft autopilot state
Healthy:                         true
Failure Tolerance:               1
Leader:                          openbao-0
```

| Voters | Quorum | Survives |
|---|---|---|
| 1 | 1 | 0 failures |
| 2 | 2 | **0 failures** |
| 3 | 2 | 1 failure |
| 5 | 3 | 2 failures |

Two voters tolerate exactly as many failures as one, on twice the hardware and twice the
failure surface. The OpenBao documentation recommends **five** nodes; three is the usual
practical minimum and what this lab runs.

Demoting a voter proves the arithmetic live:

```
$ bao operator raft demote openbao-2
$ bao operator raft autopilot state
Failure Tolerance:               0
Voters:
   openbao-0
   openbao-1
Non Voters:
   openbao-2
```

Three running, healthy nodes and a failure tolerance of zero. `bao operator raft promote`
puts it back.

## Losing quorum

Take two of three down and the survivor cannot elect itself. Its own log does the
arithmetic for you:

```
[INFO] storage.raft: pre-vote campaign failed, waiting for election timeout:
  term=4 tally=1 refused=2 votesNeeded=2
```

Clients get a 500 that names the situation precisely:

```
{"errors":["local node not active but active cluster node not found"]}
```

There is no partial service. A cluster without quorum does not serve reads either, because
there is no leader to forward to. Restore the nodes, unseal them, and it recovers on its
own.

## Standbys are not read replicas

A standby forwards your request to the leader and returns the answer. It does not serve
reads from its local copy.

OpenBao has **no cross-cluster replication and no performance standbys**. This is not an
omission in this README, it is the product:

```
$ bao -h | grep -i replicat        # no such command
$ curl -s $BAO_ADDR/v1/sys/replication/status
{"errors":["unsupported path"]}    # 404
```

If you need multi-region, you are designing it yourself out of separate clusters, not
enabling a feature.

## Upgrades

The chart sets `updateStrategy: OnDelete`, so a `helm upgrade` changes the StatefulSet and
touches no running pod. You roll it yourself:

1. delete a **standby** pod, wait for it to come back and unseal it
2. repeat for the other standby
3. `bao operator step-down` on the leader to move leadership to an already-upgraded node
4. delete the old leader last

Quorum holds throughout because only one node is ever down. Never delete two at once on a
three node cluster.

## Cleanup

```bash
helm uninstall openbao -n openbao-mig
kubectl delete namespace openbao-mig
```
