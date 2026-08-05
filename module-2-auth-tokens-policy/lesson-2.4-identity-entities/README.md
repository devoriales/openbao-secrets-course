# Lesson 2.4 — Identity, Entities and External Identity Providers

Artifacts for lesson 2.4 of [OpenBao Secrets Management: Production Operations on Kubernetes](https://devoriales.com/quiz/27/openbao-secrets-management-production-operations-on-kubernetes).

| File | What it is |
|---|---|
| `identity-demo.sh` | Shows the problem entities solve, then solves it, using two userpass mounts as stand-ins for two identity providers |

## Run it

```bash
export BAO_ADDR='https://127.0.0.1:8200' BAO_SKIP_VERIFY=1 BAO_TOKEN='<root>'
./identity-demo.sh
```

No external identity provider needed. Two `userpass` mounts stand in for "corporate SSO" and
"the contractor system", which is enough to show the behaviour.

## What it demonstrates

**Before.** The same person in two mounts, with no policy on either:

```
via userpass:     entity 00135ffb...
via contractors:  entity 950530ec...
```

Two entity IDs. Two unrelated principals as far as OpenBao is concerned.

**After.** One entity with an alias on each mount:

```
via userpass:     entity ce6c4e03...  identity_policies=['app-readonly']
via contractors:  entity ce6c4e03...  identity_policies=['app-readonly']
```

**Groups.** Adding the entity to an internal group adds the group's policy:

```
token policies    : ['app-readonly', 'default', 'platform-team']
identity policies : ['app-readonly', 'platform-team']
```

**External groups refuse direct members**, returning 400. Membership comes from the identity
provider, not from you, and OpenBao enforces that rather than letting two sources disagree.

## Two things worth remembering

**Aliases key on the mount accessor, not the mount path.** Accessors survive a mount being
renamed, which is what you want under a permanent identity mapping.

**`token_policies` and `identity_policies` are different fields.** The first comes from the auth
method, the second from the entity and its groups, and the effective set is the union. When a
grant will not go away, that distinction tells you where to look.

## Cleanup

```bash
bao auth disable userpass
bao auth disable contractors
bao delete identity/group/name/platform
bao policy delete app-readonly
bao policy delete platform-team
```
