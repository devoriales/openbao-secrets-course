#!/usr/bin/env python3
"""Transit engine client: encrypt, decrypt, rotate, rewrap.

    export BAO_ADDR=https://127.0.0.1:8200
    export BAO_CACERT=/path/to/root_ca.crt    # from lesson 4.2
    export BAO_TOKEN=<your token>
    ./sample-client.py

Depends only on requests (2.32.x, Apache-2.0), the same HTTP library the rest of
the course uses for direct API work. Nothing here needs an OpenBao SDK: Transit
is six HTTP endpoints and a base64 call.

TLS: this script verifies. It passes BAO_CACERT to requests as the trust anchor,
which is the certificate lesson 4.2 made OpenBao issue for itself. Plenty of
Transit examples online carry verify=False, and that is a habit worth not
forming, because an unverified TLS connection to a service whose entire job is
holding your keys is a man in the middle away from handing plaintext to someone
else.
"""
import base64
import os
import sys

import requests

ADDR = os.environ.get("BAO_ADDR", "https://127.0.0.1:8200")
TOKEN = os.environ.get("BAO_TOKEN")
CACERT = os.environ.get("BAO_CACERT")
KEY = os.environ.get("KEY", "customer-data")

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


def encrypt(plaintext: str) -> str:
    """Plaintext in, ciphertext out. The key never leaves OpenBao.

    The base64 is not decoration. Transit takes bytes, JSON carries text, and
    base64 is the bridge. Skip it and you get one of two outcomes: a 400 saying
    `illegal base64 data at input byte N`, or, if your plaintext happens to be
    valid base64 on its own, silent corruption. "password" is valid base64. It
    decodes to six bytes of nothing, and those six bytes are what gets encrypted.
    """
    b64 = base64.b64encode(plaintext.encode()).decode()
    return _post(f"transit/encrypt/{KEY}", {"plaintext": b64})["ciphertext"]


def decrypt(ciphertext: str) -> str:
    b64 = _post(f"transit/decrypt/{KEY}", {"ciphertext": ciphertext})["plaintext"]
    return base64.b64decode(b64).decode()


def rotate() -> int:
    """Create a new key version. Existing ciphertext keeps decrypting."""
    _post(f"transit/keys/{KEY}/rotate")
    resp = session.get(f"{ADDR}/v1/transit/keys/{KEY}")
    resp.raise_for_status()
    return resp.json()["data"]["latest_version"]


def rewrap(ciphertext: str) -> str:
    """Upgrade one ciphertext to the current key version.

    OpenBao decrypts and re-encrypts internally. No plaintext is returned, and a
    token that holds only transit/rewrap cannot produce plaintext at all.
    """
    return _post(f"transit/rewrap/{KEY}", {"ciphertext": ciphertext})["ciphertext"]


def rewrap_batch(ciphertexts, references=None):
    """Rewrap many ciphertexts in one request.

    One HTTP round trip per database row does not survive contact with a real
    table. batch_input takes a list and returns batch_results in the same order.

    THE TRAP THIS FUNCTION EXISTS TO HANDLE: a batch containing failures still
    returns HTTP 200. The per-item errors live inside batch_results, so
    raise_for_status() sees a clean response and a migration reports success
    while silently skipping rows. Verified against 2.6.1: one bad entry among
    two returned 200 with {"error": "invalid ciphertext: version is too new"}
    sitting in the second slot.

    `reference` is echoed back on each result untouched. It is how you map a
    result to the row it came from without trusting list ordering.
    """
    items = []
    for i, ct in enumerate(ciphertexts):
        item = {"ciphertext": ct}
        if references is not None:
            item["reference"] = references[i]
        items.append(item)

    results = _post(f"transit/rewrap/{KEY}", {"batch_input": items})["batch_results"]

    ok, failed = [], []
    for item, result in zip(items, results):
        if "error" in result:
            failed.append((item.get("reference"), result["error"]))
        else:
            ok.append((item.get("reference"), result["ciphertext"]))
    return ok, failed


def migrate(rows):
    """Re-encrypt a table's worth of ciphertext after a rotation.

    `rows` is a list of (row_id, ciphertext). Returns the rows to write back.

    TODO(you): decide what this does when rewrap_batch reports failures.

    The choice is real and the options are not equivalent:

      - Abort the whole run on the first failed batch. Nothing is written back,
        the table stays internally consistent, and an operator has to look at it
        before anything moves. Safest, and it means one poisoned row stops a
        migration that was 99% fine.

      - Write back the successes, collect the failures, carry on. The migration
        finishes, and you are left with a table in two states plus a list to
        work through. Needs the caller to actually read the returned failures,
        which is the assumption that got us here in the first place.

      - Retry failures individually, then apply one of the above. Distinguishes
        a transient fault from a genuinely bad ciphertext, at the cost of a
        second pass and more code to get wrong.

    Whatever you pick, the failures must leave this function in a form a caller
    cannot ignore by accident. Returning them in a tuple that gets unpacked and
    dropped is how silent data loss happens.
    """
    raise NotImplementedError("see the TODO above")


if __name__ == "__main__":
    secret = "SSN: 123-45-6789"
    print(f"plaintext            {secret}")

    ct = encrypt(secret)
    print(f"ciphertext           {ct}")

    # Same input, encrypted again. aes256-gcm96 uses a fresh nonce per call, so
    # this differs from the line above. Ciphertext is therefore useless as a
    # lookup key, and identical values in two rows are not detectable.
    print(f"encrypted again      {encrypt(secret)}")

    back = decrypt(ct)
    print(f"decrypted            {back}")
    assert back == secret, "round trip failed"

    version = rotate()
    print(f"rotated, version     {version}")
    print(f"new writes use       {encrypt(secret)[:16]}...")
    print(f"old ciphertext still decrypts: {decrypt(ct) == secret}")

    upgraded = rewrap(ct)
    print(f"rewrapped            {upgraded}")
    assert decrypt(upgraded) == secret, "rewrap changed the plaintext"

    # A batch with one deliberately broken entry, to show where the error lands.
    ok, failed = rewrap_batch([ct, "vault:v9:bogus"], references=["row-1", "row-2"])
    print(f"batch ok             {[r for r, _ in ok]}")
    print(f"batch failed         {failed}")
    assert failed, "expected the bogus ciphertext to fail inside a 200 response"

    print("\nall assertions passed")
