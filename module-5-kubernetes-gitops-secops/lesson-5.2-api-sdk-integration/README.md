# Lesson 5.2 — Direct API & SDK Integration

Artifacts for lesson 5.2 of [OpenBao Secrets Management: Production Operations on Kubernetes](https://devoriales.com/quiz/27/openbao-secrets-management-production-operations-on-kubernetes).

The lesson itself lives on devoriales.com. This folder holds only what that lesson asks you
to apply.

Validated on 2026-08-21 against OpenBao **v2.6.1**, chart **openbao-0.28.6**, the OpenBao Go
client **github.com/openbao/openbao/api/v2 v2.6.0**, and **Go 1.26.1**. See
[`VERSIONS.md`](../../VERSIONS.md) for the full pinned toolchain.

## Contents

| File | What it is |
|---|---|
| `curl-walkthrough.sh` | Login, read, the two failure shapes, manual renewal, and expiry, in plain HTTP |
| `main.go` | The same thing in Go, with `LifetimeWatcher` renewing in the background |
| `go.mod`, `go.sum` | Pinned at `api/v2 v2.6.0`, OpenBao's only first party client library |

## Setup

Everything here needs the lesson 4.2 end state: OpenBao serving a certificate it issued
itself, and `root_ca.crt` on disk as the trust anchor.

```bash
kubectl -n openbao port-forward svc/openbao 8200:8200 &
export BAO_ADDR=https://127.0.0.1:8200
export BAO_CACERT="/path/to/lesson-4.2-pki-certificates/root_ca.crt"
export BAO_TOKEN=<your token>
```

Then the operator side, once: a secret to read, an AppRole to read it with, and a policy that
grants exactly that one path.

```bash
bao secrets enable -path=secret kv-v2
bao kv put secret/apps/reporting \
  db_url="postgres://reporting@postgres:5432/reports" api_key="not-a-real-key"

bao auth enable approle
bao policy write reporting-read - <<'HCL'
path "secret/data/apps/reporting" {
  capabilities = ["read"]
}
HCL

# A deliberately short TTL. Renewal is invisible at eight hours and obvious at sixty seconds.
bao write auth/approle/role/reporting \
  token_policies=reporting-read \
  token_ttl=60s token_max_ttl=10m \
  secret_id_ttl=20m secret_id_num_uses=10
```

## Apply

```bash
# HTTP first. Read this before the Go program.
./curl-walkthrough.sh

# Then the client, with renewal.
export ROLE_ID=$(bao read -field=role_id auth/approle/role/reporting/role-id)
export SECRET_ID=$(bao write -f -field=secret_id auth/approle/role/reporting/secret-id)
go run . -addr "$BAO_ADDR" -ca "$BAO_CACERT" -every 25s -for 3m

# And the same program with renewal switched off, which exits when the token dies.
go run . -addr "$BAO_ADDR" -ca "$BAO_CACERT" -every 25s -no-renew
```

## What the artifacts prove

**The login response is not shaped like every other response.** The token is at
`.auth.client_token`, the TTL at `.auth.lease_duration`, and `.auth.renewable` decides whether
renewal is even possible. Clients that reach for `.data` out of habit get `null` and report a
confusing error.

**Both authentication failures are 403, not 401.** A token whose policy does not cover the path:

```
{"errors":["1 error occurred:\n\t* permission denied\n\n"]}
```

and no token at all:

```
{"errors":["permission denied"]}
```

Same status code, nearly the same body. If your client distinguishes "not allowed" from "not
authenticated" by status code, it will get this wrong.

**`LifetimeWatcher` renews well before expiry, not at it.** With a 60 second TTL it renews at
roughly the two thirds mark, and it reports each renewal on `RenewCh`.

**Renewal is not immortality.** `token_max_ttl` is a ceiling that renewal cannot cross. When the
watcher gives up it closes `DoneCh`, and an application that only logs that channel keeps running
with a credential that no longer works. Re-authenticate there.

**An unrenewed token fails mid-run, not at startup.** The program reads successfully, twice,
then the same read against the same path with the same policy returns `permission denied`. The
only thing that changed is time, which is exactly what makes this hard to recognise in
production logs.

## Cleanup

```bash
bao delete auth/approle/role/reporting
bao auth disable approle
bao policy delete reporting-read
bao kv metadata delete secret/apps/reporting
```
