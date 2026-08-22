# CAP05 recovery runbook

Write this yourself, before the drill, as if you were handing it to somebody who
has never seen this estate. Then run the drill and correct it from what actually
happened.

A runbook that has not survived contact with the failure it describes is a
document, not a runbook.

## What a real one has to contain

Fill in each section. The prompts are questions, not instructions.

### 1. How you know this is the failure you think it is

What does an operator see, on the pod, in the logs, and in the metrics? Which of
those signals distinguishes this failure from a sealed instance waiting for key
holders, and from a node that has lost quorum?

Include the exact string to search for.

### 2. What is still working

Before anybody starts fixing, what is the current blast radius? Which requests
still succeed, which workloads are unaffected, and which are failing for reasons
that have nothing to do with the seal?

Getting this wrong is how a seal outage becomes an unnecessary restart of
something healthy.

### 3. Who has to be reachable

Names, or role names, and how many of them. Where the shares are held. What
happens if one holder is unreachable, and at what number of unreachable holders
this runbook stops working.

If your answer is "the shares are in a password manager", say who can open it and
whether that system depends on the estate you are currently recovering.

### 4. The order

Numbered, with the reason for the order. There is exactly one correct first step
and it is not on the production cluster.

### 5. What you do NOT do

List the tempting wrong moves. At minimum:

- do not re-initialise anything
- do not delete PersistentVolumeClaims
- do not attempt to unseal the production nodes with recovery keys
- do not "fix" the crashlooping pods

For each, one line on what it would cost.

### 6. How you know it is over

The specific commands, and what their output looks like when the estate is whole.
Include the Raft peer list and one end-to-end check through an application, not
just `bao status`.

### 7. What you changed afterwards

Filled in after the drill. If nothing, say why.

## After the drill

Compare the runbook you wrote before with what you actually did. The differences
are worth more than the runbook: they are the assumptions you did not know you
were making.
