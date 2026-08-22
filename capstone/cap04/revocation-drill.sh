#!/usr/bin/env bash
#
# CAP04, the revocation drill. This one is not a skeleton: run it as written,
# watch three services react three different ways, and write down what you saw
# in observations-template.md.
#
#   export BAO_ADDR=https://127.0.0.1:8200
#   export BAO_CACERT=<the production cluster's CA>
#   export BAO_TOKEN=<a token that can revoke leases>
#   ./revocation-drill.sh
#
# What it does NOT do is tell you what to expect. Predict first, then run it.
set -euo pipefail
: "${BAO_ADDR:?}"; : "${BAO_TOKEN:?}"; : "${BAO_CACERT:?}"

ROLE="${ROLE:-payments-ro}"
NS="${NS:-payments}"

banner() { printf '\n== %s ==\n' "$1"; }

banner "1. before: what each service is doing"
kubectl -n "$NS" logs -l app=svc-a-sidecar -c app --tail=2 || true
kubectl -n "$NS" logs -l app=svc-b-eso --tail=2 || true
echo "(service C logs wherever you are running it)"

banner "2. how many credentials are outstanding for this role"
# Every one of these is a live PostgreSQL role that OpenBao created and will
# drop again. If this number surprises you, that is worth understanding before
# you revoke anything.
bao list "sys/leases/lookup/database/creds/${ROLE}" || true

banner "3. predict, in one line each, then continue"
cat <<'PREDICT'
   A, the sidecar service : what happens on its next query, and when does the file change?
   B, the ESO service     : does anything happen at all?
   C, the SDK service     : when does it find out, and how?
PREDICT
read -r -p "press enter when you have written your predictions down " _

banner "4. revoke every lease on the role"
date -u +"revoked at %H:%M:%SZ"
bao lease revoke -prefix "database/creds/${ROLE}"

banner "5. wait, then look"
sleep 45
kubectl -n "$NS" logs -l app=svc-a-sidecar -c app --tail=3 || true
kubectl -n "$NS" logs -l app=svc-b-eso --tail=2 || true

banner "6. the audit log knows who was reading what"
# Attribution is the point. Note which identity each read appears under, and in
# particular which service does NOT appear as itself.
cat <<'HINT'
   kubectl -n openbao exec openbao-1 -- cat /openbao/audit/audit.log \
     | jq -R 'fromjson? // empty' -c \
     | jq -r 'select(.type=="response") | "\(.auth.display_name // "-")  \(.request.path)"' \
     | sort | uniq -c | sort -rn
HINT

banner "7. now write it up"
echo "observations-template.md, while it is fresh."
