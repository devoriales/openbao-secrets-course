#!/usr/bin/env bash
#
# Break glass: mint a new root token from a quorum of key holders.
#
# READ THIS BEFORE THE INCIDENT, NOT DURING IT.
#
# On OpenBao 2.6.x the classic no-token procedure does not work out of the box.
# Two changes landed:
#
#   1. `bao operator generate-root` now calls the AUTHENTICATED
#      /sys/generate-root-token endpoints. Every step needs a valid token,
#      including -generate-otp and -decode, which look local but call the status
#      endpoint to learn the OTP length.
#
#   2. The legacy unauthenticated /sys/generate-root endpoints are DISABLED by
#      default. The listener parameter disable_unauthed_generate_root_endpoints
#      has defaulted to true since v2.5.3, because unauthenticated callers could
#      cancel an in-flight root generation, which is a denial of service against
#      the exact ceremony you run in an emergency.
#
# So on a default build, "I have lost every token" is NOT recoverable through
# generate-root. The listener parameter has to be set BEFORE you need it. That
# is a real decision with a real trade-off, and this script supports both.
#
#   ./break-glass-runbook.sh authed   quorum.txt   # needs BAO_TOKEN
#   ./break-glass-runbook.sh unauthed quorum.txt   # needs the listener param set
#
# quorum.txt is one unseal key (or recovery key, on an auto seal) per line,
# enough of them to meet the threshold.
set -euo pipefail
MODE="${1:?usage: $0 authed|unauthed <quorum-file>}"
QUORUM="${2:?usage: $0 authed|unauthed <quorum-file>}"
: "${BAO_ADDR:?set BAO_ADDR}"

[ -s "$QUORUM" ] || { echo "no keys in $QUORUM" >&2; exit 1; }

case "$MODE" in
authed)
  : "${BAO_TOKEN:?authed mode needs a token; that is the whole problem with it}"

  # A ceremony that was started and not finished blocks every later attempt with
  #   Code: 400. * root generation already in progress for this namespace
  # An abandoned run, a lost OTP, or someone else mid-ceremony all look the
  # same. Cancelling is safe: it destroys the in-flight nonce, not any token.
  # Check with someone before you do this in anger, in case the ceremony you are
  # about to discard is a colleague's.
  echo "==> 0. Clear any in-flight ceremony"
  bao operator generate-root -cancel >/dev/null 2>&1 || true

  echo "==> 1. Generate an OTP"
  # Not local. This calls sys/generate-root-token/attempt to learn the length.
  OTP="$(bao operator generate-root -generate-otp)"
  echo "   OTP: $OTP"
  echo "   Write it down. The final token cannot be recovered without it."

  echo "==> 2. Start the ceremony"
  NONCE="$(bao operator generate-root -init -otp="$OTP" -format=json | python3 -c "import sys,json;print(json.load(sys.stdin)['nonce'])")"
  echo "   nonce: $NONCE"

  echo "==> 3. Collect the quorum"
  ENC=""
  while read -r KEY; do
    [ -n "$KEY" ] || continue
    OUT="$(bao operator generate-root -nonce="$NONCE" -format=json "$KEY")"
    PROG="$(printf '%s' "$OUT" | python3 -c "import sys,json;d=json.load(sys.stdin);print(str(d['progress'])+'/'+str(d['required']))")"
    ENC="$(printf '%s' "$OUT" | python3 -c "import sys,json;print(json.load(sys.stdin).get('encoded_token',''))")"
    echo "   progress $PROG"
  done < "$QUORUM"

  [ -n "$ENC" ] || { echo "quorum never completed" >&2; exit 1; }

  echo "==> 4. Decode"
  NEW="$(bao operator generate-root -decode="$ENC" -otp="$OTP")"
  ;;

unauthed)
  # The CLI will not use these endpoints even when they are enabled, so this
  # half is raw API calls. Requires, in the listener stanza:
  #   disable_unauthed_generate_root_endpoints = false
  echo "==> 1. Start the ceremony, no credentials"
  ATT="$(curl -sf -X PUT "$BAO_ADDR/v1/sys/generate-root/attempt")" || {
    echo "   refused. The unauthenticated endpoints are disabled on this instance." >&2
    echo "   Set disable_unauthed_generate_root_endpoints = false and restart." >&2
    exit 1; }
  NONCE="$(printf '%s' "$ATT" | python3 -c "import sys,json;print(json.load(sys.stdin)['nonce'])")"
  # The legacy endpoint hands you the OTP. The authenticated one does not.
  OTP="$(printf '%s' "$ATT" | python3 -c "import sys,json;print(json.load(sys.stdin)['otp'])")"
  echo "   nonce: $NONCE"
  echo "   OTP:   $OTP"

  echo "==> 2. Collect the quorum"
  ENC=""
  while read -r KEY; do
    [ -n "$KEY" ] || continue
    OUT="$(curl -sf -X PUT -d "{\"key\":\"$KEY\",\"nonce\":\"$NONCE\"}" "$BAO_ADDR/v1/sys/generate-root/update")"
    ENC="$(printf '%s' "$OUT" | python3 -c "import sys,json;print(json.load(sys.stdin).get('encoded_token',''))")"
    printf '%s' "$OUT" | python3 -c "import sys,json;d=json.load(sys.stdin);print('   progress '+str(d['progress'])+'/'+str(d['required']))"
  done < "$QUORUM"

  [ -n "$ENC" ] || { echo "quorum never completed" >&2; exit 1; }

  echo "==> 3. Decode locally"
  # The encoded token is the new token XORed with the OTP, base64 encoded.
  # No server involved.
  NEW="$(python3 -c "
import base64
enc, otp = '$ENC', '$OTP'
raw = base64.b64decode(enc + '=' * (-len(enc) % 4))
print(''.join(chr(b ^ ord(otp[i])) for i, b in enumerate(raw)))
")"
  ;;
*)
  echo "mode must be authed or unauthed" >&2; exit 1 ;;
esac

echo
echo "==> New root token: $NEW"
cat <<'NOTE'

   NOT DONE YET.

   generate-root ADDS a root token. It does not replace or revoke any existing
   one. If you ran this because a root token leaked, that token is still valid
   right now. Revoke it:

       bao token revoke -accessor <accessor-of-the-old-token>
       bao list auth/token/accessors      # to find it

   And when the incident is over, revoke this one too. A root token that
   outlives its emergency is the next incident.
NOTE
