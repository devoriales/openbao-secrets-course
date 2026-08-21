#!/usr/bin/env bash
#
# Enable the Transit engine and create the application encryption key.
#
#   kubectl -n openbao port-forward svc/openbao 8200:8200 &
#   export BAO_ADDR=https://127.0.0.1:8200
#   export BAO_CACERT=/path/to/root_ca.crt      # from lesson 4.2
#   export BAO_TOKEN=<your token>
#   ./configure-transit.sh
#
# BAO_SKIP_VERIFY is not used here and is not used anywhere from lesson 4.2
# onward. OpenBao issues its own listener certificate now, so there is a real
# trust anchor to point at.
set -euo pipefail
: "${BAO_ADDR:?set BAO_ADDR}"
: "${BAO_TOKEN:?set BAO_TOKEN}"
: "${BAO_CACERT:?set BAO_CACERT to the root_ca.crt from lesson 4.2}"

KEY="${KEY:-customer-data}"

bao secrets enable transit 2>/dev/null || echo "transit/ already enabled"

# No type given, so this is aes256-gcm96: AES-256 in Galois/Counter Mode with a
# 96 bit nonce. GCM is authenticated encryption, so a ciphertext that has been
# tampered with fails to decrypt rather than returning wrong plaintext.
#
# The nonce is generated per operation and is why encrypting the same plaintext
# twice gives two different ciphertexts. That is a property worth having: it
# means an observer holding your database cannot tell which of two rows share a
# value. It also means ciphertext is useless as a lookup key, and applications
# that want to search on an encrypted column need a separate deterministic
# scheme, which this key type deliberately does not provide.
bao write -f "transit/keys/${KEY}" > /dev/null

echo
echo "Transit ready. Key: ${KEY}"
bao read "transit/keys/${KEY}"
