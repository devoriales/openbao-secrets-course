#!/usr/bin/env bash
#
# Cryptographic erasure, demonstrated honestly.
#
#   export BAO_ADDR=https://127.0.0.1:8200
#   export BAO_CACERT=/path/to/root_ca.crt
#   export BAO_TOKEN=<your token>
#   ./erasure-drill.sh
#
# This script runs on its own key, erasure-drill, and does not touch
# customer-data. It ends by destroying key material on purpose, which is the
# point, and there is no way to undo the last step.
#
# WHAT THIS EXISTS TO CORRECT
#
# Most material on the Transit engine, including material that is otherwise
# accurate, tells you that setting min_decryption_version deletes the older key
# versions and makes their ciphertext permanently unrecoverable. It does not.
# It is a policy setting, it is reversible by anyone who can write to the key's
# config path, and the key material stays exactly where it was. Part 2 below
# reverses it and reads the data back.
#
# The step that actually destroys key material is trim, and it is gated behind
# two other settings so that you cannot reach it by accident.
set -euo pipefail
: "${BAO_ADDR:?set BAO_ADDR}"
: "${BAO_TOKEN:?set BAO_TOKEN}"
# Note the wording: no apostrophe. Inside ${VAR:?message} bash still processes
# quoting, so an apostrophe in the message opens a single quoted string and the
# script dies at parse time with an EOF error pointing at a line far below.
: "${BAO_CACERT:?set BAO_CACERT to the root_ca.crt from lesson 4.2}"

KEY="erasure-drill"
SECRET="SSN: 123-45-6789"

hr() { printf '\n== %s ==\n' "$1"; }

# Several steps below are supposed to fail. Under `set -o pipefail` a failing
# command on the left of a pipe kills the script, so the expected failures run
# through this instead of being piped directly.
expect_fail() {
  local out
  if out="$("$@" 2>&1)"; then
    echo "   UNEXPECTED SUCCESS: $*" >&2
    return 1
  fi
  printf '%s\n' "$out" | sed -n 's/^\*/   */p'
}

hr "0. a key, one secret encrypted under version 1, then a rotation"
bao secrets enable transit 2>/dev/null || true
# Reset, so the drill can be run more than once. Deleting a Transit key needs
# deletion_allowed first, and that flag is about the key as a whole; it has
# nothing to do with the version level controls this script is about.
if bao read "transit/keys/${KEY}" >/dev/null 2>&1; then
  bao write "transit/keys/${KEY}/config" deletion_allowed=true >/dev/null
  bao delete "transit/keys/${KEY}" >/dev/null
fi
bao write -f "transit/keys/${KEY}" > /dev/null
V1="$(bao write -field=ciphertext "transit/encrypt/${KEY}" \
      plaintext="$(printf '%s' "$SECRET" | base64)")"
echo "   v1 ciphertext: ${V1}"
bao write -f "transit/keys/${KEY}/rotate" > /dev/null
echo "   rotated. latest_version is now $(bao read -field=latest_version "transit/keys/${KEY}")"

hr "1. the step everyone calls erasure"
bao write "transit/keys/${KEY}/config" min_decryption_version=2 > /dev/null
echo "   keys map is now: $(bao read -field=keys "transit/keys/${KEY}")"
echo "   version 1 has disappeared from the metadata. Decrypting v1 ciphertext:"
expect_fail bao write "transit/decrypt/${KEY}" ciphertext="$V1"
echo
echo "   That looks final. An auditor reading this transcript would accept it."

hr "2. it is not final"
# Nothing was deleted. min_decryption_version is a floor on which versions the
# engine is willing to use, and floors can be lowered again. The only thing
# standing between the "erased" data and its plaintext is a single write to a
# config path, by anyone holding update on it.
bao write "transit/keys/${KEY}/config" min_decryption_version=1 > /dev/null
echo "   keys map is back: $(bao read -field=keys "transit/keys/${KEY}")"
printf '   decrypted: '
bao write -field=plaintext "transit/decrypt/${KEY}" ciphertext="$V1" | base64 -d
echo
echo
echo "   The data was never gone. It was hidden behind a setting."

hr "3. the ladder that does destroy it"
# Three gates, in this order, each refusing until the one before it is satisfied.
# The ordering is not bureaucracy: it makes you state, separately, that you have
# stopped writing under the old version, then that you have stopped reading it,
# and only then that you want the material gone. By the time trim is legal, any
# application still depending on version 1 has already been failing loudly.

echo "-- trim before anything else:"
expect_fail bao write "transit/keys/${KEY}/trim" min_available_version=2

echo "-- gate 1: stop encrypting under old versions"
bao write "transit/keys/${KEY}/config" min_encryption_version=2 > /dev/null
echo "   min_encryption_version=2"

echo "-- trim again, with only gate 1 satisfied:"
expect_fail bao write "transit/keys/${KEY}/trim" min_available_version=2

echo "-- gate 2: stop decrypting old versions"
bao write "transit/keys/${KEY}/config" min_decryption_version=2 > /dev/null
echo "   min_decryption_version=2"

echo "-- gate 3: destroy the archived material"
bao write "transit/keys/${KEY}/trim" min_available_version=2 > /dev/null
echo "   min_available_version=$(bao read -field=min_available_version "transit/keys/${KEY}")"

hr "4. now try to walk it back"
expect_fail bao write "transit/keys/${KEY}/config" min_decryption_version=1
echo
echo "   Refused, and it stays refused. min_available_version is a floor under"
echo "   the floor. The version 1 key material is gone from storage, so there is"
echo "   nothing for a lowered min_decryption_version to reach."
echo "   decrypting the v1 ciphertext:"
expect_fail bao write "transit/decrypt/${KEY}" ciphertext="$V1"

hr "5. what you can now tell an auditor"
cat <<'TEXT'
   Only after step 3 is the claim "this data cannot be decrypted by anyone,
   including us" true, and it is true for every row ever encrypted under
   version 1 at once, wherever those rows live. That is the property worth
   having: erasure by key destruction does not require finding the data.

   It is also why the blast radius has to be designed in advance. Everything
   encrypted under a key version dies together. A key per tenant, or per
   retention class, is a decision made when the key is created and effectively
   impossible to retrofit, because retrofitting means decrypting and
   re-encrypting everything under the new split.
TEXT

echo
echo "Cleanup: bao write transit/keys/${KEY}/config deletion_allowed=true && bao delete transit/keys/${KEY}"
