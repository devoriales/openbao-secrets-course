# Lesson 2.1 — Token Lifecycle Internals

Artifacts for lesson 2.1 of [OpenBao Secrets Management: Production Operations on Kubernetes](https://devoriales.com/quiz/27/openbao-secrets-management-production-operations-on-kubernetes).

This lesson is command-driven rather than manifest-driven, so there is no YAML here. What
follows is the reference you will want open while working through it.

## Token types at a glance

| | Service | Batch | Periodic |
|---|---|---|---|
| Prefix | `s.` | `b.` | `s.` |
| Persisted to storage | yes | **no** | yes |
| Renewable | yes | **no** | yes, forever |
| Has an accessor | yes | **no** | yes |
| Can parent other tokens | yes | no | yes |
| Revocable | yes | **no** | yes |

A batch token created from a root token is refused outright:

```
Code: 400. Errors:
* batch tokens cannot be root tokens
```

Which follows: root never expires and batch cannot be revoked, so the combination would be a
credential nobody could take back.

## The max TTL failure, reproduced in under a minute

```bash
bao token create -policy=<some-policy> -ttl=30s -explicit-max-ttl=45s
bao token renew <token>     # 30s back
sleep 20
bao token renew <token>     # 24s back, not 30s
sleep 30
bao token renew <token>     # "token not found"
```

The middle call is the important one. **The renewal succeeded and returned less than it was
asked for.** Renewal code that checks only for errors sees a healthy renewal every time, right
up until the token is gone. The shrinking `token_duration` is the only warning, and it is the
field most renewal loops throw away.

## Useful commands

```bash
bao token lookup                          # inspect the current token (no -self flag exists)
bao token lookup <token>                  # inspect another token
bao token capabilities <token> <api-path> # what can this token do, exactly
bao token revoke <token>                  # revoke, cascading to children
bao token revoke -accessor <accessor>     # revoke without ever seeing the token
```

`bao token lookup -self` is not valid in OpenBao 2.6.2; bare `bao token lookup` does it.

## Cleanup

```bash
bao token revoke -accessor <accessor>
bao policy delete <policy-name>
```
