# Lesson 2.2 — Policies and Granular Access Control

Artifacts for lesson 2.2 of [OpenBao Secrets Management: Production Operations on Kubernetes](https://devoriales.com/quiz/27/openbao-secrets-management-production-operations-on-kubernetes).

| File | What it is |
|---|---|
| `wildcard-demo.sh` | Settles `*` versus `+` by experiment: creates secrets at four depths, writes three policies, and prints exactly what each token can read |

## Run it

```bash
kubectl -n openbao port-forward svc/openbao 8200:8200 &
export BAO_ADDR='https://127.0.0.1:8200'
export BAO_SKIP_VERIFY=1
export BAO_TOKEN='<root token>'
./wildcard-demo.sh
```

## What it demonstrates

```
path "secret/data/production/*"     glob, crosses slashes
  ALLOW  production/db
  ALLOW  production/app/db          <- nested, and still allowed
  DENY   staging/db

path "secret/data/+/db"             exactly one segment
  ALLOW  production/db
  ALLOW  staging/db
  DENY   staging/ci/db              <- nested, and correctly denied

path "secret/data/*/db"             accepted on write, matches NOTHING
  DENY   production/db
  DENY   staging/db
```

Three rules worth memorising:

- **`*` is greedy.** It crosses `/`, so `production/*` grants the whole subtree, not one level.
- **`*` only works at the end of a path.** In the middle it is a literal asterisk. The policy
  writes without error, reads back verbatim, and grants nothing.
- **`+` matches exactly one segment** and is legal anywhere, which is what you want mid-path.

The silent-failure case is the expensive one. There is no error at write time and no warning
at read time; the only symptom is a 403 on a path you are certain you allowed.

## Paths are API paths

A policy for `secret/production/db` grants nothing. The endpoint is
`secret/data/production/db`. K/V v2 needs `data/` and `metadata/` rules separately, and
`list` lives on `metadata/`.

## Debugging a 403

```bash
bao token capabilities <token> secret/data/production/db
```

Ask that first. It answers against the stored policy rather than the one you think you wrote,
and it takes the API path, so it catches the missing `data/` at the same time.
