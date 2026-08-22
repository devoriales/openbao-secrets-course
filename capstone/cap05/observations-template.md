# CAP05 observations

Fill in the predictions column **before** you run anything. Date both columns.

## Predictions and results

| Question | What you predicted | What happened |
|---|---|---|
| Running nodes when the seal backend disappears | | |
| The three microservices | | |
| A production node restarted during the outage | | |
| The recovery keys from CAP01 | | |
| The shortest path back | | |

## The timeline

| Event | Time (UTC) |
|---|---|
| Seal backend scaled to zero | |
| First check of the running cluster | |
| Credential issued during the outage (paste the username) | |
| Production node deleted | |
| Node's first failure logged | |
| Recovery started | |
| Unsealer unsealed | |
| Production node Ready again | |

**Cluster unavailable for:** ________

**That node unavailable for:** ________

Explain the difference in one sentence.

## The exact error

Paste the line from the failed node's log:

```

```

Which operation was it performing, and at what point in startup?

## The Raft view during the outage

Paste `bao operator raft list-peers` from a surviving node:

```

```

The missing node still appears. Say why, and say what would have been different
if you had removed it from the cluster instead of restarting it.

## The recovery keys

What happened when you tried one on the node that would not start?

What would have happened if you had tried one on a node that was running?

These are two different answers with two different reasons. Write both.

## The dependency, in one sentence

Auto-unseal makes the seal backend a dependency of ______________, and not of
______________.

## What you would change

Two or three sentences, and be specific. Some candidates, none of which are
automatically right:

- where the unsealer runs, relative to the cluster it unseals
- whether the unsealer's own Shamir shares are reachable during an outage of the
  estate they protect
- what your PodDisruptionBudget and node drain policy do to a cluster whose
  restarts depend on a remote service
- what you would alert on, and at what threshold, given that the surviving nodes
  looked completely healthy throughout

## Back to CAP01

CAP01 asked you to write one sentence about what happens if the unsealer is gone.
Paste that sentence here, and then say what you would write now.

```

```
