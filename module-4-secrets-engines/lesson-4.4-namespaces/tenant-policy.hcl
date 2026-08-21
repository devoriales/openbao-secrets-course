# A tenant's own policy, written inside the tenant's namespace.
#
# Every path here is relative to the namespace the policy is written into. The
# string "tenant-a" does not appear, and must not: a policy that names its own
# namespace is a policy that breaks the moment the same definition is applied to
# tenant-b, which is the normal way these are managed.
#
# Read the paths as a tenant would. secret/data/app/* is the tenant's own K/V v2
# engine, mounted at secret/ inside their namespace, with the v2 data/ segment
# that lesson 1.4 explained.

path "secret/data/app/*" {
  capabilities = ["read"]
}

# Listing metadata is a separate grant from reading values. An application that
# only ever reads one known key does not need it. A human debugging in the UI
# does, and giving it to the application "so the UI works" is how a read-only
# credential quietly becomes an inventory of every secret in the namespace.
path "secret/metadata/app/*" {
  capabilities = ["list"]
}
