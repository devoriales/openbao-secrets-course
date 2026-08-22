# Lesson 4.1 — Dynamic Database Secrets

Artifacts for lesson 4.1 of [OpenBao Secrets Management: Production Operations on Kubernetes](https://devoriales.com/quiz/27/openbao-secrets-management-production-operations-on-kubernetes).

The lesson itself lives on devoriales.com. This folder holds only what that lesson asks you
to apply.

Validated on 2026-08-12 against OpenBao **v2.6.2**, chart **openbao-0.29.2** and PostgreSQL
**18.4** (`postgres:18.4-trixie`). See [`VERSIONS.md`](../../VERSIONS.md) for the full pinned
toolchain.

## Contents

| File | What it is |
|---|---|
| `postgres.yaml` | PostgreSQL 18.4 StatefulSet, service, seed schema and the deliberately committed bootstrap password |
| `configure-database-engine.sh` | Enables the engine, writes the connection config, both roles and the application policy |
| `test-dynamic-creds.sh` | Requests a credential, proves it works, proves it is scoped, revokes it, proves it is dead |
| `rotate-root-procedure.sh` | Rotates the engine's own PostgreSQL password, with a confirmation prompt |
| `lease-expiry-drill.sh` | Reproduces what an application sees when its lease ends mid-transaction |

No Helm chart is used for PostgreSQL. `VERSIONS.md` pins the official `postgres:18.4-trixie`
image, and a plain StatefulSet is the whole requirement, so a third-party chart would only add
a dependency this course would have to keep alive.

## Setup

You need the Module 1 cluster and a standalone OpenBao with TLS, as built in lesson 1.3.
Nothing here needs the HA Raft cluster from 3.7: the database engine, roles and leases behave
identically on one node.

```bash
kubectl apply -f postgres.yaml
kubectl -n databases rollout status statefulset/postgres

# an in-cluster psql, so you need no local client and you test the same network
# path the engine itself uses
kubectl -n databases run psql-client --image=postgres:18.4-trixie \
  --restart=Never --command -- sleep infinity
kubectl -n databases wait --for=condition=Ready pod/psql-client

kubectl -n openbao port-forward svc/openbao 8200:8200 &
export BAO_ADDR=https://127.0.0.1:8200
export BAO_SKIP_VERIFY=1     # the bootstrap certificate is self-signed until lesson 4.2
export BAO_TOKEN=<your token>

./configure-database-engine.sh
```

## Apply

```bash
./test-dynamic-creds.sh      # the happy path, end to end
./lease-expiry-drill.sh      # the failure the knowledge check is built on
./rotate-root-procedure.sh   # do this one last, see the warning below
```

Run `rotate-root-procedure.sh` last. After it, the password in `postgres.yaml` is dead, so
`configure-database-engine.sh` can no longer authenticate and re-running it will fail. That is
correct behaviour, not a bug in the script. To start over, reset the password by the break-glass
route below and then re-run the configure script.

## Things worth knowing before you copy any of this

**`bao lease revoke` is asynchronous and its success message is not proof.** The request carries
`"sync": false` and the CLI prints `All revocation operations queued successfully!` when the job
is accepted, not when PostgreSQL has acted on it. If the revocation SQL fails, that message is
still what you get, the lease stays in the lease list, and the credential keeps working while
OpenBao retries on a backoff. Always confirm against the database, which is what step 4 of
`test-dynamic-creds.sh` does.

**`DROP ROLE` alone cannot revoke these credentials.** PostgreSQL refuses to drop a role that
holds granted privileges (`SQLSTATE 2BP01`), and every role created here is granted something.
`DROP OWNED BY` first, then `DROP ROLE`.

**Revocation statements are read from the role at revocation time.** They are not frozen into
the lease when it is issued. So if you discover your revocation SQL is broken, correct the role
and the backlog of stuck revocations drains on its next retry, with no manual cleanup.

**Generated usernames truncate to eight characters in two places.** The format is
`v-<display_name>-<role_name>-<random>-<epoch>`, and both the display name and the role name are
cut to eight. `payments-readonly` and `payments-readwrite` both render as `payments`, so a
PostgreSQL log line tells you which auth method issued a credential and never which role. Do not
build alerting that assumes otherwise.

**A dropped role does not disconnect anyone.** Existing sessions stay open; only the privileges
go. The symptom is `permission denied` on a table the connection read a moment earlier, which
looks like someone edited your grants.

### The known gap in `revocation_statements`

`DROP OWNED BY` has no `IF EXISTS`. If somebody removes one of these roles in PostgreSQL by
hand, the later revocation fails with `role "v-..." does not exist (SQLSTATE 42704)` and that
lease is stuck exactly the way a `2BP01` failure is. The escape hatch is:

```bash
bao lease revoke -force <lease_id>
```

which discards OpenBao's record without running any SQL, and warns you that it is leaving
OpenBao out of sync with the engine.

The shipped script keeps the simple two-statement form because the contrast with the broken
`DROP ROLE`-only version is the thing worth learning. If you want a form that tolerates an
absent role, this one is verified to work:

```
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '{{name}}') THEN
    EXECUTE format('DROP OWNED BY %I', '{{name}}');
    EXECUTE format('DROP ROLE %I', '{{name}}');
  END IF;
END $$;
```

The better answer is not to clean up dynamic roles by hand.

### Break-glass after `rotate-root`

If OpenBao loses the rotated password, no route through OpenBao gets it back. Recover through
the database:

```bash
kubectl -n databases exec -it postgres-0 -- \
  psql -U openbao_admin -d appdb -c \
  "ALTER ROLE openbao_admin WITH PASSWORD 'initial_password_will_be_rotated';"
```

That works here because the local socket connection is trusted and `openbao_admin` is a
superuser. On a managed database it is the provider's console instead. Confirm you have such a
route *before* you rotate.

## Cleanup

```bash
kubectl -n databases delete pod psql-client
kubectl delete -f postgres.yaml
```

`postgres.yaml` declares the namespace, so deleting it takes the PVC with it. If you instead
remove only the StatefulSet, the PVC survives on purpose, because a StatefulSet's
`volumeClaimTemplates` are never garbage collected with it. Delete it by hand in that case:

```bash
kubectl -n databases delete pvc data-postgres-0
```

Leave the database engine mounted if you are going straight on to lesson 4.2. Otherwise
`bao secrets disable database` removes it, and note that it will refuse while any lease still
has failing revocation SQL.
