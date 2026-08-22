# CAP04 observations

Fill this in immediately after the drill, from what you saw rather than from
what you expected. The gap between the two columns is the deliverable.

## The revocation

Time of revocation:

| Service | You predicted | What actually happened | How long until it noticed |
|---|---|---|---|
| A, Agent sidecar | | | |
| B, ESO | | | |
| C, direct SDK | | | |

## The questions the drill answers

**Which service stopped being able to use the database first?**
> Careful: "stopped working" and "found out" are two different events, and they
> did not happen in the same order for all three.

**Which service knew why?**
> One of them saw a message about a lease. The others saw a database error, or
> nothing at all.

**How did service C learn, and could it tell revocation apart from the lease
simply reaching its maximum TTL?**
> Look at what the watcher reported, not just that it reported something.

**What would each service have to do to recover without being restarted?**

## The audit log

**Which identity did each read appear under?**

| Service | Identity in the audit log |
|---|---|
| A | |
| B | |
| C | |

**One of these makes an incident harder to investigate. Which, and why?**

**If somebody asked you "which workload read this secret at 03:14", could you
answer for all three services?**

## Least privilege

**Try one cross-service read**: take a token for service A and read service B's
path.

Command:

Result:

**Does your policy set survive this question:** if one of the three services were
compromised tonight, what would the attacker be able to read, and for how long?

## What you would change

Two or three sentences. If the answer is "nothing", say why the drill did not
change your mind.
