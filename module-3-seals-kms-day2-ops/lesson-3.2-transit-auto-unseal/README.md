# Lesson 3.2 — Transit Auto-Unseal

Artifacts for lesson 3.2 of [OpenBao Secrets Management: Production Operations on Kubernetes](https://devoriales.com/quiz/27/openbao-secrets-management-production-operations-on-kubernetes).
Lesson 3.1 also refers to this topology when comparing seal types.

| File | What it is |
|---|---|
| `values-unsealer.yaml` | The unsealer: a plain Shamir instance whose only job is to hold one Transit key |
| `values-autounseal.yaml` | The production instance, with the `seal "transit"` stanza |
| `setup-transit-unseal.sh` | Builds both, wires them together, and shows the result |

```bash
./setup-transit-unseal.sh
```

## What auto-unseal looks like

```
Seal Type                transit
Recovery Seal Type       shamir
Sealed                   false
Total Recovery Shares    3
```

Note it says **Recovery** Shares. Initialisation uses `-recovery-shares` and
`-recovery-threshold`, and the response comes back with `recovery_keys_b64` populated and
`unseal_keys_b64` **empty**. There are no unseal keys on this instance and there never will be.

Nobody types anything. That is the point.

## Recovery keys are not an unseal path

The most important thing in this lesson is what happens when the unsealer is gone. Scale it to
zero and restart the production instance:

```
NAME        READY   STATUS   RESTARTS
openbao-0   0/1     Error    2
```

```
Error configuring seal "transit": Put "http://unsealer.../v1/transit/encrypt/autounseal":
  dial tcp: connect: connection refused
```

The process exits **while configuring the seal**. It never reaches a sealed-but-listening state,
so there is no API to present a recovery key to. `bao status` gets connection refused.

Recovery keys authorise privileged operations against a **running** instance, mainly generating
a new root token. They cannot decrypt the root key, because the seal backend encrypted it.

The only fix is restoring the unsealer, after which the instance comes back with no human
action at all.

## Two things the script gets right that are easy to get wrong

**The service is `unsealer-openbao`, not `unsealer`.** The chart names services
`<release>-openbao`. Port-forwarding to the wrong name exits silently and every later command
fails with connection refused.

**The unsealer token is periodic.** A token with a max TTL eventually dies, and when it does the
production instance loses the ability to restart. Lesson 2.1 covers why renewal cannot push past
a max TTL; this is the place that bites hardest.

## Cleanup

```bash
helm uninstall openbao -n openbao && kubectl delete namespace openbao
helm uninstall unsealer -n openbao-unsealer && kubectl delete namespace openbao-unsealer
```
