# CAP02 — Database and PKI integration

Two halves, both built in Module 4, now running against the CAP01 cluster.

**The database half:** PostgreSQL with dynamic credentials, and `rotate-root`
executed so that the password committed in the manifest stops being a credential
at all.

**The PKI half:** OpenBao issuing PostgreSQL's server certificate through
cert-manager, so the database that hands out short lived credentials is itself
reached over a certificate your own CA signed.

## Files here

| File | What it is |
|---|---|
| `database-config.sh.skeleton` | The engine, the connection, the role, and `rotate-root` |
| `pki-and-issuer.yaml.skeleton` | ServiceAccount, RBAC, Issuer and Certificate, with the `caBundle` trap marked |
| `postgres-tls.patch.yaml.skeleton` | The patch that makes PostgreSQL actually serve the certificate |
| `requirements.md` | Twelve acceptance criteria, three of which have a false-pass trap |

PostgreSQL itself comes from lesson 4.1's `postgres.yaml`, unchanged. Apply it as
it is: the plaintext bootstrap password in that manifest is the thing this stage
destroys.

## Order

1. PostgreSQL, from lesson 4.1's manifest.
2. The database engine, connection and role, then a credential you actually log
   in with **from a client pod**, not from inside the database.
3. `rotate-root`, then verify both halves: the old password is refused, and new
   credentials still work.
4. The PKI role and the Kubernetes auth role for cert-manager in this namespace.
5. The Issuer, and read its status before moving on. If it is not `True`, the
   message tells you which of the two CAs you got wrong.
6. The Certificate, then the patch that makes PostgreSQL serve it.
7. A client connection with `sslmode=verify-full` against the OpenBao root.

## The three false passes

This stage is arranged so that the obvious check passes when the thing is
broken. That is not a trick; it is what these failures look like in production.

**Verifying a rotation from inside the database pod.** The stock `pg_hba.conf`
grants `trust` on loopback, so `kubectl exec postgres-0 -- psql` succeeds with
any password, including a deliberately wrong one. Check from another pod, over
the service name.

**Assuming an issued certificate is a used certificate.** `kubectl get
certificate` reporting `True` means cert-manager wrote a Secret. PostgreSQL will
happily keep serving plaintext until you tell it otherwise, and every client that
did not ask for TLS will keep working.

**Assuming `sslmode=require` proves anything.** It encrypts and verifies nothing.
Only `verify-full` with a trust anchor tells you that the server is the one your
CA signed, which is the entire reason the PKI half of this stage exists.

## What to carry into CAP03

You now have a database whose credentials are short lived and whose identity is
verifiable. CAP03 puts three microservices in front of it, each one obtaining
those credentials a different way, and asks you to justify each choice. Two of
the three will hold the credential somewhere you can read with `kubectl`.
