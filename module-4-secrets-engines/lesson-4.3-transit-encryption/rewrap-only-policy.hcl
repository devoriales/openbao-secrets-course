# The policy for the batch job that upgrades old ciphertext after a key
# rotation. It is the most interesting of the three, because at first glance the
# job looks like it must decrypt.
#
# It does not. transit/rewrap does the decrypt and the re-encrypt inside
# OpenBao and returns only new ciphertext, so the migration runs end to end
# without the plaintext ever crossing the wire and without this token being able
# to produce plaintext at all. Verified: a token holding only this policy
# rewraps successfully and is refused on transit/decrypt with permission denied.
#
# A job that walks every row of a customer table is exactly the thing you least
# want holding decrypt. This is how it doesn't have to.

path "transit/rewrap/customer-data" {
  capabilities = ["update"]
}
