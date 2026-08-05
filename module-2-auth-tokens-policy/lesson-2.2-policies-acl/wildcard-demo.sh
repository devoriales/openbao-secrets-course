#!/usr/bin/env bash
#
# Settles the * versus + question by experiment rather than argument.
#
# Creates four secrets at different depths, writes three policies, mints a token
# for each, and prints exactly which paths each token can read.
#
# Usage (against the lesson 1.3 deployment):
#   kubectl -n openbao port-forward svc/openbao 8200:8200 &
#   export BAO_ADDR='https://127.0.0.1:8200' BAO_SKIP_VERIFY=1 BAO_TOKEN=<root>
#   ./wildcard-demo.sh
set -euo pipefail
: "${BAO_ADDR:?}"; : "${BAO_TOKEN:?}"
ROOT="$BAO_TOKEN"

for p in production/db production/app/db staging/db staging/ci/db; do
  BAO_TOKEN=$ROOT bao kv put "secret/$p" password=placeholder >/dev/null
done

mint() { # $1 policy name, $2 path
  printf 'path "%s" {\n  capabilities = ["read"]\n}\n' "$2" > /tmp/p.hcl
  BAO_TOKEN=$ROOT bao policy write "$1" /tmp/p.hcl >/dev/null
  BAO_TOKEN=$ROOT bao token create -policy="$1" -ttl=10m -format=json \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["auth"]["client_token"])'
}

probe() { # $1 token, $2 secret path
  if BAO_TOKEN=$1 bao kv get -mount=secret "$2" >/dev/null 2>&1; then
    printf '  ALLOW  %s\n' "$2"
  else
    printf '  DENY   %s\n' "$2"
  fi
}

echo
echo 'path "secret/data/production/*"   <- glob, crosses slashes'
T=$(mint demo-star 'secret/data/production/*')
for s in production/db production/app/db staging/db; do probe "$T" "$s"; done

echo
echo 'path "secret/data/+/db"           <- exactly one segment'
T=$(mint demo-plus 'secret/data/+/db')
for s in production/db staging/db staging/ci/db; do probe "$T" "$s"; done

echo
echo 'path "secret/data/*/db"           <- accepted on write, matches NOTHING'
T=$(mint demo-midstar 'secret/data/*/db')
for s in production/db staging/db; do probe "$T" "$s"; done

cat <<'NOTE'

  The third policy is the dangerous one. It wrote without error, it reads back
  verbatim, and it grants nothing at all. A wildcard in the middle of a path is a
  literal asterisk; * is only meaningful as the final character. Use + there.
NOTE
