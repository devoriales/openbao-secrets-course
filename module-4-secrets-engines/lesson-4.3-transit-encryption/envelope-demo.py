#!/usr/bin/env python3
"""Envelope encryption: encrypt data Transit is too small to carry.

    export BAO_ADDR=https://127.0.0.1:8200
    export BAO_CACERT=/path/to/root_ca.crt
    export BAO_TOKEN=<your token>
    ./envelope-demo.py

WHY THIS EXISTS

transit/encrypt sends your whole payload to OpenBao and sends the whole
ciphertext back. That is fine for a national insurance number and wrong for a
file. There is a hard ceiling: the listener's max_request_size defaults to
32 MiB, and past it the request is refused before Transit sees it.

    Code: 413. Errors:
    * http: request body too large

Measured on 2.6.2: a 32,156,332 byte body succeeded, a 34,952,536 byte one did
not. The payload below is 50 MiB, so the direct path cannot carry it at all.

A WARNING ABOUT THAT 413, IF YOU ARE ON A PORT FORWARD

Sending it costs you the tunnel. OpenBao answers 413 correctly, and then
kubectl port-forward dies:

    error: lost connection to pod

Every command after that reports `connection refused` and it reads exactly like
OpenBao crashed. It did not: the pod stayed 1/1 Running with zero restarts and
still unsealed, verified. Restart the port forward and carry on. Because this
wrecks the lab you are following along in, the oversized request is off by
default here. Set SHOW_413=1 if you want to watch it happen.

Envelope encryption inverts the flow. Instead of sending data to the key, you
fetch a key to the data:

    1. transit/datakey/plaintext returns a fresh AES-256 key, twice: once in
       plaintext, once wrapped by the Transit key.
    2. Encrypt the payload locally with the plaintext key.
    3. Store the wrapped key next to the ciphertext, and throw the plaintext
       key away.
    4. To read: send the wrapped key back to transit/decrypt, get the data key,
       decrypt locally.

Only the wrapped key crosses the wire. Here that is 89 bytes standing in for
52,428,800.

Dependencies, both already pinned by the course: requests 2.32.x (Apache-2.0)
for the HTTP calls, and cryptography 49.0.0 (Apache-2.0 or BSD-3-Clause) for
local AES-GCM. cryptography binds to OpenSSL rather than implementing the cipher
in Python, which is the only reason encrypting 50 MiB in a demo script finishes
while you are still looking at it.

THE PART THAT IS NOW YOUR PROBLEM

The direct path has no key handling in it at all, which is its whole appeal.
This one hands you a plaintext AES key in process memory, and everything that
was OpenBao's job becomes yours: not logging it, not swapping it to disk, not
leaving it in a heap dump, and dropping it as soon as the encrypt is done. The
`del` below is a gesture at that and not a guarantee, because Python will not
promise you the bytes are gone. Envelope encryption buys throughput and pays for
it in responsibility.
"""
import base64
import hashlib
import os
import sys

import requests
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

ADDR = os.environ.get("BAO_ADDR", "https://127.0.0.1:8200")
TOKEN = os.environ.get("BAO_TOKEN")
CACERT = os.environ.get("BAO_CACERT")
KEY = os.environ.get("KEY", "customer-data")
SIZE = 50 * 1024 * 1024

if not TOKEN:
    sys.exit("set BAO_TOKEN")
if not CACERT:
    sys.exit("set BAO_CACERT to the root_ca.crt from lesson 4.2")

session = requests.Session()
session.headers["X-Vault-Token"] = TOKEN
session.verify = CACERT


def _post(path, payload=None):
    resp = session.post(f"{ADDR}/v1/{path}", json=payload or {})
    resp.raise_for_status()
    return resp.json()["data"]


def seal(payload: bytes):
    """Encrypt locally under a fresh data key. Returns what you would store."""
    # datakey/plaintext returns both forms. There is also datakey/wrapped, which
    # returns only the ciphertext and is for the case where something else will
    # do the encrypting: you can hand out a wrapped key without ever holding the
    # plaintext one yourself.
    datakey = _post(f"transit/datakey/plaintext/{KEY}")
    key = base64.b64decode(datakey["plaintext"])
    wrapped = datakey["ciphertext"]

    nonce = os.urandom(12)
    ciphertext = AESGCM(key).encrypt(nonce, payload, None)
    del key  # see the docstring: a gesture, not a guarantee

    return {"wrapped_key": wrapped, "nonce": nonce, "ciphertext": ciphertext}


def unseal(record) -> bytes:
    """Unwrap the data key, then decrypt locally."""
    key = base64.b64decode(
        _post(f"transit/decrypt/{KEY}", {"ciphertext": record["wrapped_key"]})["plaintext"]
    )
    return AESGCM(key).decrypt(record["nonce"], record["ciphertext"], None)


if __name__ == "__main__":
    payload = os.urandom(SIZE)
    digest = hashlib.sha256(payload).hexdigest()
    print(f"payload              {len(payload):,} bytes, sha256 {digest[:32]}")

    # What the direct path does with this, for contrast. Off by default: the
    # 413 takes a kubectl port-forward down with it. See the docstring.
    if os.environ.get("SHOW_413"):
        oversized = session.post(
            f"{ADDR}/v1/transit/encrypt/{KEY}",
            json={"plaintext": base64.b64encode(payload).decode()},
        )
        print(f"transit/encrypt      HTTP {oversized.status_code} {oversized.text.strip()[:60]}")
        print("                     (if you are port forwarding, the tunnel is now dead)")
    else:
        print("transit/encrypt      skipped, would be HTTP 413. SHOW_413=1 to try it")

    record = seal(payload)
    print(f"wrapped key          {record['wrapped_key'][:48]}...")
    print(f"sent to OpenBao      {len(record['wrapped_key'])} bytes, not {len(payload):,}")
    print(f"stored ciphertext    {len(record['ciphertext']):,} bytes")

    recovered = unseal(record)
    print(f"recovered            sha256 {hashlib.sha256(recovered).hexdigest()[:32]}")
    assert recovered == payload, "envelope round trip failed"

    print("\nround trip matched")
