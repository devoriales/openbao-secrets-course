# Lesson 4.3 — Encryption as a Service (Transit Engine)

Artifacts for lesson 4.3 of [OpenBao Secrets Management: Production Operations on Kubernetes](https://devoriales.com/quiz/27/openbao-secrets-management-production-operations-on-kubernetes).

The lesson itself lives on devoriales.com. This folder holds only what that lesson asks you
to apply.

Validated on 2026-08-13 against OpenBao **v2.6.2**, chart **openbao-0.29.2**, Python
**3.13**, `requests` **2.32.4** and `cryptography` **49.0.0**. See
[`VERSIONS.md`](../../VERSIONS.md) for the full pinned toolchain.

This is the same engine that unsealed OpenBao in lesson 3.2, approached from the other side.
There it wrapped one root key for another OpenBao instance. Here it wraps application data,
using the identical encrypt and decrypt API.

## Contents

| File | What it is |
|---|---|
| `configure-transit.sh` | Enables the engine and creates the `customer-data` key |
| `encrypt-only-policy.hcl` | For an app that writes ciphertext and never reads it |
| `decrypt-policy.hcl` | For the few things that genuinely need plaintext back |
| `rewrap-only-policy.hcl` | For the migration job, which needs neither plaintext nor decrypt |
| `sample-client.py` | Encrypt, decrypt, rotate, rewrap, and batch rewrap over the HTTP API |
| `envelope-demo.py` | The datakey path, for payloads Transit will not carry |
| `erasure-drill.sh` | Cryptographic erasure, including the step that only looks like it |

## Setup

Everything here needs the lesson 4.2 end state: OpenBao serving a certificate it issued
itself, and `root_ca.crt` on disk as the trust anchor.

```bash
kubectl -n openbao port-forward svc/openbao 8200:8200 &
export BAO_ADDR=https://127.0.0.1:8200
export BAO_CACERT="/path/to/lesson-4.2-pki-certificates/root_ca.crt"
export BAO_TOKEN=<your token>

./configure-transit.sh
```

`BAO_SKIP_VERIFY` does not appear in this folder and should not appear in your shell.
A client that skips verification against the service holding its keys is one bad DNS answer
away from posting plaintext to somebody else.

## Apply

```bash
# encrypt something
bao write transit/encrypt/customer-data \
  plaintext=$(printf '%s' "SSN: 123-45-6789" | base64)

# the full client
./sample-client.py

# envelope encryption, 50 MiB through a 32 MiB ceiling
./envelope-demo.py

# erasure, honestly
./erasure-drill.sh
```

Least privilege, applied:

```bash
bao policy write transit-encrypt-only encrypt-only-policy.hcl
bao policy write transit-rewrap-only  rewrap-only-policy.hcl
bao policy write transit-decrypt      decrypt-policy.hcl
```

## Things worth knowing before you copy any of this

**The ciphertext prefix is `vault:v1:`, on OpenBao.** Not `bao:`. Token prefixes did change
when OpenBao forked, from Vault's `hvs.` to `s.` and `b.`, so it is reasonable to expect this
one to have changed too. It did not, and it is stored in your database on every row, which
makes it the wrong thing to go changing. Do not write a parser that rejects it.

**Encrypting the same plaintext twice gives two different ciphertexts.** `aes256-gcm96`
generates a fresh nonce per operation. This is what you want: an attacker holding your
database cannot tell which rows share a value. It also means ciphertext cannot be used as a
lookup key, and `WHERE encrypted_email = ?` will never match. Searching on an encrypted
column is a different problem than this engine solves.

**Plaintext must be base64, and forgetting is not always an error.** Send a raw string and
you usually get:

```
Code: 400. Errors:
* illegal base64 data at input byte 3
```

But send the raw string `password`, which happens to be valid base64, and it is accepted.
OpenBao decodes it to six bytes of binary and encrypts those. Nothing warns you, and the
round trip even looks correct as long as the reader also forgets to decode. The corruption
surfaces the day one side of your codebase is fixed.

**A batch request with failures inside it still returns HTTP 200.** The errors are per item,
in `batch_results`:

```json
{"batch_results": [
  {"ciphertext": "vault:v2:...", "key_version": 2, "reference": ""},
  {"error": "invalid ciphertext: version is too new", "reference": ""}
]}
```

`resp.raise_for_status()` is happy with that. A rewrap migration written the obvious way
reports a clean run and silently skips every row it could not process. `rewrap_batch()` in
`sample-client.py` returns successes and failures separately for this reason, and the
`reference` field is echoed back untouched so results can be matched to rows without
trusting list order.

**`min_decryption_version` is not cryptographic erasure.** This is the big one, and
`erasure-drill.sh` demonstrates it rather than asserting it. Setting
`min_decryption_version=2` removes version 1 from the key metadata and makes v1 ciphertext
fail to decrypt:

```
* ciphertext or signature version is disallowed by policy (too old)
```

which reads like destruction and is not. Set it back to 1 and the data returns. It is a
policy floor, reversible by anyone holding `update` on the key's config path, and the key
material never moved.

**`deletion_allowed` has nothing to do with this.** It gates deleting the key as a whole
(`error deleting policy customer-data: deletion is not allowed for this key`) and is not a
prerequisite for any version-level operation. Material that presents it as the safety catch
before erasure is describing a guardrail that is not there.

**The real erasure is `trim`, behind three gates.** In order, each refusing until the
previous is satisfied:

```bash
bao write transit/keys/customer-data/config min_encryption_version=2
bao write transit/keys/customer-data/config min_decryption_version=2
bao write transit/keys/customer-data/trim   min_available_version=2
```

Out of order you get `minimum available version cannot be set when minimum encryption
version is not set`, then `minimum available version cannot be greater than minimum
decryption version`. Afterwards the walk-back is refused permanently, with OpenBao's own
typo intact:

```
* min decryption version should not be less then min available version
```

Only now is "nobody can decrypt this, including us" a true statement.

**Erasure is per key version, so the blast radius is chosen when you create the key.**
Everything encrypted under a version dies together. If you need to erase one customer, one
tenant or one retention class independently, that has to be a separate key, decided up
front. Retrofitting the split means decrypting and re-encrypting everything, which is the
one operation the whole design exists to avoid.

**There is a 32 MiB ceiling and it takes your port forward with it.** The listener's
`max_request_size` defaults to 32 MiB. Measured: a 32,156,332 byte body succeeded, a
34,952,536 byte one returned `413 http: request body too large`. On a port-forwarded lab
the 413 also kills the tunnel:

```
error: lost connection to pod
```

after which everything says `connection refused` and looks like a crash. The pod is fine;
verified 1/1 Running, zero restarts, still unsealed. Restart the port forward. For anything
approaching that size use `envelope-demo.py`, which sends 89 bytes instead of 50 MiB.

**`rewrap` is a real privilege boundary, not a convenience.** A token holding only
`transit/rewrap/customer-data` re-encrypts everything and is refused on `transit/decrypt`
with `permission denied`. The job that touches every row of a customer table is exactly the
one that should not be able to read it.

## Cleanup

```bash
for k in customer-data erasure-drill; do
  bao write transit/keys/$k/config deletion_allowed=true
  bao delete transit/keys/$k
done
bao secrets disable transit
```
