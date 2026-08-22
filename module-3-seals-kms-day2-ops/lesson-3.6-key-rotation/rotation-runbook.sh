#!/usr/bin/env bash
#
# The three operations people call "key rotation", run one after another
# against the same instance so you can watch which one changes what.
#
# Nothing here needs new infrastructure: any unsealed OpenBao will do. Point
# BAO_ADDR and BAO_TOKEN at one and pass the keys it was initialised with.
#
# Commands used, all from OpenBao 2.6.2:
#   bao operator key-status    current barrier key term, install time, use count
#   bao operator rotate-keys   new unseal or recovery SHARES  (this replaced rekey)
#   bao operator rotate        new BARRIER ENCRYPTION KEY
#
# `bao operator rekey` is NOT used, because it no longer works. The CLI still
# ships the subcommand and it still prints a deprecation notice pointing here,
# but the server endpoint is gone in 2.6.2:
#   PUT /v1/sys/rekey/init  ->  405, "unsupported operation"
#
# Usage:
#   export BAO_ADDR=http://127.0.0.1:8200
#   export BAO_TOKEN=<a root or suitably privileged token>
#   ./rotation-runbook.sh keys-file        # one key per line, a quorum's worth
#   ./rotation-runbook.sh keys-file recovery   # for an auto-unsealed instance
set -euo pipefail

KEYS_FILE="${1:?usage: rotation-runbook.sh <keys-file> [recovery]}"
MODE="${2:-unseal}"
TARGET_FLAG=""
[ "$MODE" = "recovery" ] && TARGET_FLAG="-target=recovery"

: "${BAO_ADDR:?set BAO_ADDR}"
: "${BAO_TOKEN:?set BAO_TOKEN}"

banner() { printf '\n=== %s ===\n' "$1"; }

banner "Before anything: the barrier key"
# Key Term is the number that answers "have we rotated the encryption key?".
# Encryption Count is how many values have been encrypted under the current
# term, and it resets to zero every time the term increments.
bao operator key-status

banner "1. rotate-keys: new $MODE shares"
# This changes who can unseal (or who can authorise privileged operations on
# an auto-unsealed instance). It does NOT re-encrypt anything.
#
# On an auto-unsealed instance you MUST pass -target=recovery. Without it the
# command does not fail: it starts a different operation against the stored
# unseal key, ignores your -key-shares and -key-threshold, and sits pending.
NONCE="$(bao operator rotate-keys -init $TARGET_FLAG -key-shares=5 -key-threshold=3 -format=json \
         | grep -o '"nonce": "[^"]*"' | sed 's/.*: "//;s/"//')"
echo "operation nonce: $NONCE"

# Supply a quorum of the CURRENT keys. Note that an invalid key is not
# rejected on submission; you find out at the threshold, when verification runs.
n=0
while read -r key; do
  [ -z "$key" ] && continue
  n=$((n + 1))
  bao operator rotate-keys $TARGET_FLAG -nonce="$NONCE" "$key" > /tmp/rotate-keys-out.txt 2>&1 || {
    echo "submission $n failed:"; cat /tmp/rotate-keys-out.txt; exit 1; }
  grep -E '^Progress' /tmp/rotate-keys-out.txt || true
done < "$KEYS_FILE"

echo "new keys:"
grep -E '^Key [0-9]+:' /tmp/rotate-keys-out.txt || echo "  (threshold not reached, no new keys issued)"
echo
echo "STORE THESE NOW. The previous set stopped working the moment this completed."

banner "Did that rotate the encryption key? (it did not)"
bao operator key-status

banner "2. rotate: new barrier encryption key"
# This is the one that satisfies "rotate the encryption key" in a compliance
# control. It installs a new key in the keyring. Old keys stay in the ring so
# existing data remains readable, which is why this is online and instant even
# on a large instance: nothing is re-encrypted in bulk.
bao operator rotate

banner "Now the term has moved"
bao operator key-status

cat <<'NOTE'

3. Rotating an external KMS key is the third operation and it does not happen
   here, because it does not happen in OpenBao at all. You rotate the key in
   AWS, GCP or Azure, or repoint the alias at a new key as lesson 3.4 showed.
   OpenBao keeps using whatever the configured key id resolves to. It changes
   neither your recovery shares nor the barrier key term.

   Three operations, three different objects:
     rotate-keys  ->  who holds the keys
     rotate       ->  the barrier encryption key   (this is the one auditors mean)
     KMS rotation ->  the key that wraps the root key, managed by the provider
NOTE
