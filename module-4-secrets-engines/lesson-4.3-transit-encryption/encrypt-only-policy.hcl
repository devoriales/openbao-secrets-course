# The policy for an application that writes encrypted data and never reads it
# back. A signup form that stores an SSN, an audit trail, an event log.
#
# This is the whole file. There is no decrypt path, no rewrap path, and no read
# on the key metadata. If this application is compromised the attacker inherits
# the ability to write new ciphertext, which is a nuisance, and nothing else.
# Every row already in the database stays closed.
#
# The mistake this file exists to prevent is granting decrypt "because the app
# talks to Transit anyway". Encrypt and decrypt are separate paths precisely so
# that they can be separate grants, and an application that never displays the
# data it encrypts has no reason to hold the second one.

path "transit/encrypt/customer-data" {
  capabilities = ["update"]
}
