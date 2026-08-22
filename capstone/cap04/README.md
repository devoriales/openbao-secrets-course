# CAP04 — Hardening and auditing

Three things, and the third is the one that matters.

1. Turn on audit devices, which on 2.6.2 means configuration and a rolling
   restart rather than an API call.
2. Tighten each service to one path, and check the tightening by trying to cross
   the lines.
3. Revoke a live credential while all three services are running, and write down
   what each one did.

## Files here

| File | What it is |
|---|---|
| `audit-config.hcl.skeleton` | The two audit stanzas, and why the command in most tutorials fails |
| `policies/*.hcl.skeleton` | One policy per service, with the question each one turns on |
| `revocation-drill.sh` | The drill. Not a skeleton: run it as written |
| `observations-template.md` | Where you write what you saw, immediately afterwards |

## Order

1. Add the audit stanzas to the production values and roll the cluster: standbys
   first, then `bao operator step-down` and roll the leader last. Every node
   comes back unsealed on its own, which is CAP01 paying for itself in an
   ordinary operation rather than in an incident.
2. Confirm both devices are listed, and that the file is growing.
3. Write the three policies. Derive service C's second path from the audit log
   rather than from documentation: run it, let it renew, look at what its token
   touched.
4. Predict what the revocation will do to each service. Write the predictions
   down before you run the drill; the template has a column for them.
5. Run `revocation-drill.sh`.
6. Fill in `observations-template.md` while it is fresh.

## Why the drill is the assessment

Revocation is the only mechanism in this course that tests every earlier claim at
once. It tells you whether your credentials really are short lived, whether your
services really do notice, and whether your audit log really can tell you who
read what.

Two of the three services will keep using a dead credential for a while. One of
them will not know why. The interesting question is not which, it is how long,
and what would have to be true for that gap to be acceptable in your estate.

## What CAP05 does with this

CAP05 takes the seal backend away while all of this is running. The audit device
you just enabled is how you will reconstruct what happened, and the free space on
the volume it writes to is one of the things that can turn a seal outage into a
second, unrelated outage.
