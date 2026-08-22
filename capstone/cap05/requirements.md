# CAP05 acceptance criteria

| # | Criterion | How you check it |
|---|---|---|
| 1 | The whole estate was live when you started | Three OpenBao pods Ready, three services running, credentials being issued |
| 2 | You wrote the runbook before breaking anything | `recovery-runbook.md` is filled in, and you can say which parts you later had to correct |
| 3 | You predicted all five questions before running the drill | The predictions column of `observations-template.md` is filled in first |
| 4 | The seal backend was fully gone, not just degraded | The unsealer pod is deleted, and the Service has no endpoints |
| 5 | You tested the running cluster rather than assuming | `bao status` and at least one real credential issued *after* the seal backend went away |
| 6 | You restarted a production node during the outage | One pod deleted, and you have its exact error line |
| 7 | You can name the operation that failed | Not "it could not start": the specific thing OpenBao was trying to do with the seal, from the log |
| 8 | You know what the surviving cluster thought of the missing node | `bao operator raft list-peers` output during the outage, and an explanation of it |
| 9 | You tried the recovery keys and can say why they did not help | Both the outcome and the reason. There are two different reasons, depending on the node you tried |
| 10 | The first recovery step was not on the production cluster | Your times show the unsealer restored before anything else changed |
| 11 | The production node recovered with no manual action | You did nothing to it between the unsealer opening and the pod going Ready |
| 12 | You have two different durations | How long the *cluster* was unavailable, and how long that *node* was unavailable. They are not the same number |
| 13 | You can state the dependency in one sentence | About restarts specifically, not about availability in general |
| 14 | You can say what an all-nodes-at-once restart would have done | Without having run it |
| 15 | `observations-template.md` is complete | Including the last section, which is the point of the whole capstone |

## The sentence this stage exists to produce

Write it out and keep it. It goes something like: auto-unseal means the seal
backend is a dependency of every OpenBao **start**, not of every OpenBao
**request**, and the size of that distinction is the difference between an
incident and a footnote.

Your version should be in your own words, with your own numbers, and it should be
specific enough that somebody who has not done this drill would change something
in their design after reading it.
