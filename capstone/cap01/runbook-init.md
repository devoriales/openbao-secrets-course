# CAP01 runbook: initialising the cluster

Follow this in order. The order is the lesson: the unsealer has to be able to
answer before the production cluster is worth starting.

## 1. The unsealer, by hand

```bash
kubectl -n unsealer exec unsealer-openbao-0 -- \
  bao operator init -key-shares=3 -key-threshold=2 -format=json
```

Three shares, threshold two. This is the one Shamir ceremony left in the whole
estate, so decide now who holds these and write it down somewhere that is not
this cluster.

Unseal with two of them, then create the Transit key and a token for the
production cluster to use:

```bash
bao secrets enable transit
bao write -f transit/keys/autounseal
```

The policy for that token is two paths and nothing else:

```hcl
path "transit/encrypt/autounseal" { capabilities = ["update"] }
path "transit/decrypt/autounseal" { capabilities = ["update"] }
```

Note what is not in it: no `read` on the key, no `delete`, nothing under `sys/`.
The production cluster never needs to see the key material, only to send bytes
through it. Lesson 4.3 made that argument at the application level; it is the
same argument here.

Create the token with a period rather than a plain TTL, so the seal can renew it
indefinitely without it hitting a max TTL at three in the morning. Lesson 5.2
showed what that failure looks like from the inside.

Put it in a Secret in the production namespace, along with the unsealer's CA:

```bash
kubectl -n openbao create secret generic unsealer-token --from-literal=token=<token>
kubectl -n unsealer get secret unsealer-tls -o jsonpath='{.data.ca\.crt}' \
  | base64 -d > unsealer-ca.crt
kubectl -n openbao create secret generic unsealer-ca --from-file=ca.crt=unsealer-ca.crt
```

## 2. The production cluster, which initialises differently

Install the chart, wait for `openbao-0` to be `Running` (it will not be Ready:
it is sealed and uninitialised), then:

```bash
kubectl -n openbao exec openbao-0 -- \
  bao operator init -recovery-shares=5 -recovery-threshold=3 -format=json
```

**`-recovery-shares`, not `-key-shares`.** Read the output before you file it:

```json
{ "unseal_keys_b64": [], "recovery_keys_b64": [ "...", "...", ... ] }
```

There are no unseal keys. There cannot be: the root key is wrapped by the
Transit key on the unsealer, and nothing else can decrypt it. What you have
instead are recovery keys, which authorise privileged operations such as
`generate-root` on a **running** instance. They are not a way in. Lesson 3.1
said this; here is where it becomes your operational reality.

Store them like unseal keys anyway. They are the thing that lets you mint a new
root token after you lose the first one.

## 3. Watch the rest of the cluster build itself

`openbao-0` should reach Ready within seconds of `init`, because the seal
decrypts its root key without asking anyone. The StatefulSet is `OrderedReady`,
so `openbao-1` is only created once `openbao-0` is Ready, and `openbao-2` after
that. On a laptop the whole cluster is up inside a minute.

## 4. Verify before you move on

Do all four. CAP02 assumes every one of them passed.

```bash
# three pods, all Ready
kubectl -n openbao get pods -l app.kubernetes.io/name=openbao

# one leader, two followers, all voters
kubectl -n openbao exec openbao-0 -- bao operator raft list-peers

# per node: Sealed false, and exactly one 'active'
for p in 0 1 2; do kubectl -n openbao exec openbao-$p -- bao status | grep -E 'Sealed|HA Mode'; done

# TLS actually verifies against the CA, rather than merely answering
kubectl -n openbao exec openbao-0 -- sh -c \
  'BAO_ADDR=https://openbao.openbao.svc.cluster.local:8200 BAO_CACERT=/openbao/tls/ca.crt bao status'
```

The last one matters more than it looks. An OpenBao serving a certificate no
client can verify passes every check that uses `-tls-skip-verify` and fails the
first time a real client connects.

## 5. Prove the auto-unseal, because you will need to trust it

```bash
kubectl -n openbao delete pod openbao-2
```

It comes back Ready with no ceremony. That is the whole point of CAP01, and it
is also the thing CAP05 takes away from you on purpose.
