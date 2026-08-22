# CAP05: the seal outage drill

Not a skeleton. Run this as written, with all three services from CAP03 running,
and time every step. The times are the deliverable.

**Before you start:** have the unsealer's Shamir shares to hand, and know which
of your colleagues holds the others. If that sentence made you check something,
the drill has already done part of its job.

## Predict first

Write these down, one line each. Do not skip this: the difference between what
you expect and what happens is the entire exercise.

1. When the seal backend disappears, what happens to the three running OpenBao
   nodes?
2. What happens to the three microservices?
3. What happens when one production node is restarted during the outage?
4. Can the recovery keys from CAP01 help you?
5. What is the shortest path back?

## Step 1: take the seal backend away

```bash
kubectl -n unsealer scale statefulset unsealer-openbao --replicas=0
kubectl -n unsealer wait --for=delete pod/unsealer-openbao-0 --timeout=120s
date -u +"unsealer gone at %H:%M:%SZ"
```

Then, immediately, test the estate rather than assuming:

```bash
bao status | grep -E 'Sealed|HA Mode'
bao read -field=username database/creds/payments-ro
kubectl -n payments logs -l app=svc-a-sidecar -c app --tail=1
```

Write down what you see. Most people are surprised.

## Step 2: restart one production node

```bash
kubectl -n openbao delete pod openbao-2
sleep 40
kubectl -n openbao get pods -l app.kubernetes.io/name=openbao
kubectl -n openbao logs openbao-2 --tail=3
```

Record the pod's status and the exact error. Then check what the rest of the
cluster thinks:

```bash
bao operator raft list-peers
bao read -field=username database/creds/payments-ro
```

## Step 3: try the recovery keys

You have five of them from CAP01 and a threshold of three. Try to use them on the
node that will not start.

```bash
kubectl -n openbao exec openbao-2 -- bao operator unseal <recovery key>
```

Write down what happens, exactly. Not what you expected to happen.

## Step 4: recover

The fix is not on the production cluster.

```bash
date -u +"recovery started %H:%M:%SZ"
kubectl -n unsealer scale statefulset unsealer-openbao --replicas=1
# wait for the pod, then unseal it with the threshold of Shamir shares
date -u +"unsealer open at %H:%M:%SZ"

# now do nothing to the production cluster and watch
kubectl -n openbao get pods -l app.kubernetes.io/name=openbao -w
date -u +"cluster whole again at %H:%M:%SZ"
```

## Step 5: the numbers

Fill these in from your own clock, not from the lesson:

| | Your time |
|---|---|
| Seal backend gone at | |
| Failed node first restarted at | |
| Recovery started at | |
| Unsealer unsealed at | |
| Production node Ready again at | |
| **Cluster unavailable for** | |
| **That node unavailable for** | |

The last two rows are usually different, and understanding why is the point of
the whole capstone.

## Step 6: the questions

**Was your secrets estate ever down?** Be precise about what "down" means here:
requests served, credentials issued, nodes able to start.

**What is the actual dependency you have accepted by choosing auto-unseal?**
Write it as a sentence about restarts, not about availability in general.

**What would have happened if all three nodes had restarted at once?**
You do not need to run it to answer, but you should be able to say exactly what
you would have seen and exactly what you would have done.

**What would have happened if the unsealer's storage were gone, rather than the
pod?** This is the question CAP01 asked you to answer in one sentence. Compare
your answer then with your answer now.

**Where in your monitoring would this outage have appeared first?**
Lesson 5.5 has the metric names. Note that the metrics endpoint on the surviving
nodes kept answering throughout.
