# Lesson 3.6 — Key Rotation, Disambiguated

Artifacts for lesson 3.6 of [OpenBao Secrets Management: Production Operations on Kubernetes](https://devoriales.com/quiz/27/openbao-secrets-management-production-operations-on-kubernetes).

Three different operations get called "key rotation". Two of them are one letter apart in
the CLI and do completely unrelated things.

```bash
export BAO_ADDR=http://127.0.0.1:8200
export BAO_TOKEN=<root or equivalent>
./rotation-runbook.sh quorum.txt              # Shamir instance
./rotation-runbook.sh quorum.txt recovery     # auto-unsealed instance
```

`quorum.txt` is one key per line, enough of them to meet the threshold. No new
infrastructure is needed: any unsealed OpenBao works, including the one from lesson 1.3.

## The three operations

| Command | Changes | Does NOT change | When you want it |
|---|---|---|---|
| `bao operator rotate-keys` | The unseal or recovery **shares** and threshold | The barrier encryption key. Nothing is re-encrypted | A key holder leaves, a share is exposed, you need a different quorum |
| `bao operator rotate` | The **barrier encryption key**, adding a new term to the keyring | Your unseal or recovery keys | A compliance control says "rotate the encryption key" |
| Rotating the KMS key | The key that wraps the root key, at the provider | Barrier key term, recovery shares | KMS-level compliance, suspected KMS key compromise |

`bao operator key-status` is how you tell the first two apart after the fact.

## `bao operator rekey` does not work in 2.6.2

The CLI still ships the subcommand, and it tells you itself:

```
$ bao operator rekey -h
  WARNING: this method is deprecated, please use:
    $ bao operator rotate-keys
```

It is worse than deprecated. The server endpoint is gone:

```
$ bao operator rekey -init -key-shares=3 -key-threshold=2
URL: PUT http://127.0.0.1:8200/v1/sys/rekey/init
Code: 405. Errors:

* unsupported operation
```

`-status` returns the same 405. Any runbook still calling `rekey` is broken, and it will
fail at the worst moment, which is the middle of an incident where somebody's key needs
revoking. Grep your runbooks.

## The naming is the trap

```
bao operator rotate         ->  the encryption key
bao operator rotate-keys    ->  the key SHARES
```

Those names are nearly identical and their effects are unrelated. Running `rotate-keys`
when an auditor asked for encryption key rotation produces five impressive-looking new
keys, a satisfying sense of completion, and **no key rotation at all**:

```
=== 1. rotate-keys: new unseal shares ===
Key 1: tcduhGBhlcHTqY5pXkw...
...
=== Did that rotate the encryption key? (it did not) ===
Key Term            1
```

`Key Term` is the number that answers the question. It moves only for `bao operator rotate`:

```
=== 2. rotate: new barrier encryption key ===
Success! Rotated key
Key Term            2
Encryption Count    0
```

`Encryption Count` resets to zero with each new term, so a term with a low count is a
recently rotated one.

## Old data stays readable

`rotate` installs a new key in the keyring and leaves the old terms in place. Data written
under term 1 is still readable under term 2, because the keyring still holds the term 1
key to decrypt it. Nothing is re-encrypted in bulk, which is why this is instant and
online even on a large instance.

The corollary is worth stating: rotating the barrier key does **not** re-encrypt existing
data with the new key. If your control requires that old ciphertext stop existing, this
operation does not achieve it on its own.

## `-target=recovery`, and what happens if you forget it

On an auto-unsealed instance the shares you care about are the recovery keys, and you must
say so:

```bash
bao operator rotate-keys -init -target=recovery -key-shares=5 -key-threshold=3
```

Leave the flag off and it does not fail. It starts a different operation, against the
stored unseal key, silently ignoring the share count you asked for:

```
New Shares               1
New Threshold            1
```

and then sits there, pending, indefinitely:

```
$ bao operator rotate-keys -status
Started                  true
Progress                 0/3
New Shares               1
```

Cancel it with `bao operator rotate-keys -cancel`. On a Shamir instance the flag is
rejected honestly instead: `400, recovery keys not supported`.

## A bad key is not rejected until the threshold

Submitting a stale or wrong key looks fine:

```
$ bao operator generate-root -nonce=... <old recovery key>
Progress    1/2
```

The failure only arrives when the quorum completes and verification runs:

```
Code: 500. Errors:
* root generation aborted: unable to authenticate: recovery key verification failed:
  recovery key does not match submitted values
```

So during a key ceremony, "it accepted my key" means nothing until the last holder submits.
Plan for the possibility that you find out at the end.

## Cleanup

Nothing to tear down. Every operation here runs against an existing instance.
