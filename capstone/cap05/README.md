# CAP05 — The seal outage drill

The last stage, and the only one that breaks something on purpose.

Everything you built in CAP01 through CAP04 is running: three OpenBao nodes on
Raft, auto-unsealed by a separate OpenBao instance, issuing dynamic PostgreSQL
credentials over TLS to three microservices that consume them three different
ways, with two audit devices recording it.

Now take the seal backend away and find out what you actually built.

## Files here

| File | What it is |
|---|---|
| `recovery-runbook.md` | Write this **before** the drill, then correct it afterwards |
| `seal-outage-drill.md` | The drill itself. Not a skeleton: run it as written |
| `requirements.md` | Acceptance criteria |
| `observations-template.md` | Where the answers go, filled in while it is fresh |

## Order

1. Write the runbook first, from what you think you know.
2. Write down your five predictions.
3. Run the drill, timing every step.
4. Fill in the observations while you still remember what surprised you.
5. Correct the runbook from what actually happened, and note what changed.

## Why this is the final stage

CAP01 asked you to choose auto-unseal and to answer, in one sentence, what
happens if the unsealer is gone. This is where that sentence is graded.

The failure is not hypothetical: a transit seal is a network dependency in the
startup path of your most important service, and there is a specific window in
which it costs you nothing and a specific window in which it costs you the
cluster. Being able to draw the line between them, with times from your own
clock, is the skill this whole course exists to teach.

Do not skip the prediction step. Anybody can read the outcome afterwards and
find it obvious.
