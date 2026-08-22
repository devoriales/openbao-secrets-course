# CAP03 — Workload security

Three microservices in front of the CAP02 database, one per consumption pattern
from lesson 5.1. The manifests are the easy part. The deliverable is the
justification.

| Service | Reads | Mechanism |
|---|---|---|
| A | dynamic PostgreSQL credentials | Agent sidecar injection |
| B | a third party API key | External Secrets Operator |
| C | dynamic PostgreSQL credentials | AppRole and the Go client, managing its own lease |

Two of the three read database credentials, deliberately. Comparing A with C is
the point: same secret, same OpenBao, same policy shape, and a completely
different answer to "what happens when it expires".

## Do this first

Fill in `justification-template.md` **before** you write any manifests. Every
question in it has an answer you can work out from Module 5 without deploying
anything, and answering them afterwards turns the exercise into copying.

## Files here

| File | What it is |
|---|---|
| `justification-template.md` | The deliverable. Three services, one comparison table, one closing question |
| `microservice-a/deployment.yaml.skeleton` | Sidecar annotations, with the two-trust-anchor trap marked |
| `microservice-b/external-secret.yaml.skeleton` | Store and ExternalSecret, and why this service and not A's credential |
| `microservice-c/main.go.skeleton` | The structure of a client that renews two different lifetimes |
| `requirements.md` | Twelve criteria, the first of which is the justification itself |

## The traps, marked in place

**Two trust anchors in one pod.** Microservice A's sidecar verifies OpenBao's
listener certificate. Microservice A's application verifies PostgreSQL's, which
was issued by OpenBao's PKI in CAP02 and is signed by a different CA. Mount one
and the sidecar works while the application fails with
`SSL error: certificate verify failed`, which looks like a database problem and
is not.

**Two lifetimes in one service.** Microservice C holds a token and a lease. They
renew separately and end separately. A service that renews only the token has a
healthy OpenBao session and a dead database credential, and its logs will show
the renewals succeeding right up until every query fails.

**One identity for all of B.** ESO authenticates as its own ServiceAccount, not
as your application. Every secret it reads, for every namespace, appears in the
audit log under that one identity. CAP04 is where you notice.

## What CAP04 does to this

It revokes a lease while all three services are running, and asks you to prove
which ones stopped working and how fast. One of them will not notice for a while,
and finding out which is the exercise.
