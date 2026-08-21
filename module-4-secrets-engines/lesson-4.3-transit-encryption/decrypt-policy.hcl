# The policy for something that genuinely needs to read plaintext back: a
# reporting job, a support tool, a compliance export.
#
# Note what is NOT here. There is no rewrap, because rewrapping is a migration
# job's work and not a reader's, and there is no read on transit/keys/*, because
# knowing the key's rotation history is not needed in order to decrypt with it.
#
# Grant this to as few identities as you can name. It is the only policy in this
# folder whose compromise loses you the data itself rather than the ability to
# write more of it.

path "transit/encrypt/customer-data" {
  capabilities = ["update"]
}

path "transit/decrypt/customer-data" {
  capabilities = ["update"]
}
