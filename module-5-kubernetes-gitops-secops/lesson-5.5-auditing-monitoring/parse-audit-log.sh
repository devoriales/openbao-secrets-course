#!/usr/bin/env bash
#
# Reading an OpenBao audit log, which is one JSON object per line and two lines
# per request: a "request" and a "response".
#
#   ./parse-audit-log.sh                       # pulls the log out of the pod
#   ./parse-audit-log.sh /path/to/audit.log    # or reads one you already have
#
# What you can and cannot answer from this file:
#
#   You CAN see which path was touched, by which operation, from which address,
#   under which policies, and whether it was allowed.
#
#   You CANNOT see the token, the accessor, or any secret value: those are
#   HMAC-SHA256 of the value with a per-device key. That is deliberate. The
#   hashes are stable, so you can correlate "the same token did these fifty
#   things" without ever holding the token.
set -euo pipefail
command -v jq > /dev/null || { echo "this script needs jq" >&2; exit 1; }

RAW="${1:-}"
if [ -z "$RAW" ]; then
  RAW="$(mktemp)"
  kubectl -n openbao exec openbao-0 -- cat /openbao/audit/audit.log > "$RAW"
  echo "pulled $(wc -l < "$RAW" | tr -d ' ') lines from openbao-0"
fi

# Drop lines that are not complete JSON before doing anything else.
#
# This is not defensive programming for its own sake. A device that ran out of
# disk, or a pod that was killed mid-write, leaves a truncated final line, and
# every jq expression below would otherwise die on it with
# "Unfinished JSON term at EOF". Observed in this lesson's own disk-full drill.
LOG="$(mktemp)"
jq -R 'fromjson? // empty' -c < "$RAW" > "$LOG"
BAD=$(( $(wc -l < "$RAW") - $(wc -l < "$LOG") ))
[ "$BAD" -gt 0 ] && echo "skipped $BAD unparseable line(s), which usually means a writer died mid-line"

echo
echo "== what was touched, most recent first =="
jq -r 'select(.type=="response")
       | "\(.time[11:19])  \(.request.operation | ascii_upcase)  \(.request.path)  \(.auth.display_name // "-")"' \
   "$LOG" | tail -20

echo
echo "== requests per path =="
jq -r 'select(.type=="request") | .request.path' "$LOG" | sort | uniq -c | sort -rn | head -15

echo
echo "== anything refused =="
# READ THIS BEFORE WRITING A DETECTION ON THIS FILE.
#
# The obvious field is auth.policy_results.allowed, and it lies. Measured on
# 2.6.2 with a token that does not exist: the response entry carries
# "error":"permission denied" at the TOP LEVEL, while
# auth.policy_results.allowed is still true. A query keyed on allowed == false
# finds nothing and quietly reports a clean cluster.
#
# The top-level .error field is the one to trust.
jq -r 'select(.type=="response" and (.error // "") != "")
       | "\(.time[11:19])  \(.request.path)  \(.error)  token=\(.request.client_token[12:24])"' "$LOG" \
  | tail -20

echo
echo "== distinct callers, by token hash =="
# The hash, not the token. Same token, same hash, for as long as this device's
# HMAC key lives, which is what makes correlation possible without exposure.
jq -r 'select(.type=="request") | .request.client_token' "$LOG" \
  | sort | uniq -c | sort -rn | head -10

echo
echo "== what each caller touched, by token hash =="
# Token usage tracking, which is the thing this file is uniquely good at: one
# hash, every path it reached, without anybody holding the token.
jq -r 'select(.type=="response")
       | "\(.request.client_token[12:24])  \(.request.path)"' "$LOG" \
  | sort | uniq -c | sort -rn | head -12
