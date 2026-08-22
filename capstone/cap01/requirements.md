# CAP01 acceptance criteria

Check these yourself before moving to CAP02. Every one is a command whose output
you can read, not a judgement call.

| # | Criterion | How you check it |
|---|---|---|
| 1 | An unsealer instance runs in its own namespace, Shamir sealed, unsealed by hand | `kubectl -n unsealer get pods` shows `1/1`, and `bao status` on it reports `Seal Type shamir` |
| 2 | The unsealer holds a Transit key used for nothing else | `bao list transit/keys` on the unsealer shows your key |
| 3 | The production cluster's seal token can encrypt and decrypt with that key, and do nothing else | Read the policy back, and try `bao read transit/keys/<name>` with that token: it must be refused |
| 4 | Three production pods, all Ready | `kubectl -n openbao get pods -l app.kubernetes.io/name=openbao` shows three `1/1` |
| 5 | Every production node is unsealed, and exactly one is active | `bao status` per pod: `Sealed false`, one `HA Mode active`, two `standby` |
| 6 | Raft has three voters | `bao operator raft list-peers` shows one leader, two followers, `Voter true` for all three |
| 7 | Storage is Raft, seal is Transit, recovery seal is Shamir | `bao status` shows `Storage Type raft`, `Seal Type transit`, `Recovery Seal Type shamir` |
| 8 | Initialisation produced recovery keys and no unseal keys | The `init` output has an empty `unseal_keys_b64` and five entries in `recovery_keys_b64` |
| 9 | TLS verifies, rather than merely answering | `BAO_CACERT=<ca> bao status` against the service DNS name succeeds, and the same call without `BAO_CACERT` fails with `x509: certificate signed by unknown authority` |
| 10 | A restarted node returns without a human | `kubectl -n openbao delete pod openbao-2`, then watch it reach Ready with no unseal ceremony |
| 11 | You can produce the cold-start failure deliberately, and recover from it | Scale the unsealer to zero, delete a production pod, read the `Error configuring seal` line in its log, then bring the unsealer back and watch the pod recover on its own |

Criterion 11 is the one worth doing twice. CAP05 is that failure with the clock
running and an audience.

## What you should be able to answer at the end of this stage

- Why does the production cluster have no unseal keys, and what do the recovery
  keys actually authorise?
- Which certificate does a Raft peer verify when it joins, and which names must
  be in it?
- Which trust anchor does the seal stanza use, and why is it not the same file
  the listener uses?
- If everything in the cluster restarts at once, in what order does it come back,
  and what does the noise in between look like?
