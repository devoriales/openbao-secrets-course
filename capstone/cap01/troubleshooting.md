# CAP01 troubleshooting

Four failures, in the order people hit them. Each one is a real symptom from
building this stage, not a hypothetical.

## The pod never becomes Ready, and the logs look fine

Check `global.tlsDisable`. With a TLS listener it must be `false`, or the chart
derives an http scheme for its probes and they fail against an https port
forever. The server is healthy and answering; the probe is speaking the wrong
protocol. Lesson 1.3.

## A joining node logs `x509: certificate signed by unknown authority`

The joiner is verifying the leader's certificate and has no trust anchor. In
`retry_join`, `leader_api_addr` is not enough once the listener is TLS: the
stanza also needs `leader_ca_cert_file` pointing at the CA inside the pod.

The confusing part is where the message appears. The leader is fine, its
certificate is fine, and the error is on the node doing the joining.

## `raft list-peers` shows one node, and each node claims to be healthy

Almost always the certificate's SAN list. Raft peers dial each other by pod name
on the headless service, not through the service, so a certificate covering only
`openbao.openbao.svc.cluster.local` fails that handshake. Every
`openbao-N.openbao-internal` name has to be in `dnsNames`.

Check what the certificate actually covers before you change anything else:

```bash
kubectl -n openbao get secret openbao-tls -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -text | grep -A2 'Subject Alternative Name'
```

## The cluster will not start after a restart, and the pod is in Error

This is the cold start, and it is the most important failure in CAP01 because
CAP05 is built on it. Symptom, with the unsealer down:

```
Error configuring seal "transit": Put "https://unsealer-openbao.unsealer.svc.cluster.local:8200/v1/transit/encrypt/autounseal": dial tcp 10.43.244.40:8200: connect: connection refused
```

`kubectl get pod` shows `Error`, then `CrashLoopBackOff`. There is no sealed
instance to talk to, because seal configuration happens during startup, before
the listener is up. `bao status` against it returns connection refused, and your
recovery keys are useless: they authorise operations on a running instance, and
there is no running instance.

The fix is not on the production cluster at all:

1. Bring the unsealer back and unseal it with its Shamir shares.
2. Do nothing to the production pods. They are already restarting on their own
   backoff and will come up the moment the seal answers.

Measured in this lab: unsealer back at 23:39:00, `openbao-2` Ready again at
23:39:06, with three restarts on the clock and no human touching it.

**The ordering consequence for a full cold start:** unsealer first, always. If
your platform starts everything at once, the production cluster will crashloop
until the unsealer is unsealed, which is noisy but harmless. What is not
harmless is concluding from the noise that the production cluster is broken and
starting to reinitialise it.
