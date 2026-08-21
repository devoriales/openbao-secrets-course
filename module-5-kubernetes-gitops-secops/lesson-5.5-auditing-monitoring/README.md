# Lesson 5.5 — Auditing, Monitoring & Security Operations

Artifacts for lesson 5.5 of [OpenBao Secrets Management: Production Operations on Kubernetes](https://devoriales.com/quiz/27/openbao-secrets-management-production-operations-on-kubernetes).

The lesson itself lives on devoriales.com. This folder holds only what that lesson asks you
to apply.

Validated on 2026-08-22 against OpenBao **v2.6.1** and chart **openbao-0.28.6** on k3d. See
[`VERSIONS.md`](../../VERSIONS.md) for the full pinned toolchain.

## Contents

| File | What it is |
|---|---|
| `values-audit-volume.yaml` | Helm overlay: two declarative audit devices, telemetry, and a deliberately tiny audit volume to fill |
| `parse-audit-log.sh` | Reading the log with `jq`, including the field that lies about denials |
| `alerts.yaml` | Prometheus rules written against the metric names 2.6.1 actually emits |

## Setup

```bash
helm upgrade openbao openbao/openbao --version 0.28.6 -n openbao \
  -f ../../module-1-architecture-first-deployment/lesson-1.3-standalone-helm-tls/values-standalone.yaml \
  -f values-audit-volume.yaml

# The chart's updateStrategy is OnDelete, so the upgrade alone changes nothing.
kubectl -n openbao delete pod openbao-0
# then unseal again, three shares
```

## Apply

```bash
bao audit list -detailed
./parse-audit-log.sh

curl -s --cacert "$BAO_CACERT" "$BAO_ADDR/v1/sys/metrics?format=prometheus" | grep ^vault_core

# The drill. Fill the audit volume, then try to use OpenBao.
kubectl -n openbao exec openbao-0 -- sh -c 'dd if=/dev/zero of=/openbao/audit/filler bs=64k count=100'
bao kv get secret/apps/reporting
kubectl -n openbao logs openbao-0 --tail=5

# Recovery, with no restart and no unseal.
kubectl -n openbao exec openbao-0 -- rm -f /openbao/audit/filler
bao kv get secret/apps/reporting
```

## What the artifacts prove

**Audit devices are configuration now, not an API call.** On 2.6.1, `bao audit enable file ...`,
which the CLI's own help still documents, returns:

```
Code: 400. Errors:
* cannot enable audit device via API; use declarative, config-based audit device management instead
```

The devices in `values-audit-volume.yaml` are declared in the server config and arrive with the
process.

**Values are HMACed, paths are not.** An audit entry carries
`"client_token":"hmac-sha256:fa8489d1..."` and `"api_key":"hmac-sha256:7419dc4a..."`, while
`"path":"secret/data/apps/reporting"` is in clear. The hashes are stable, so one token is
correlatable across entries without anybody holding it.

**`auth.policy_results.allowed` lies.** With a token that does not exist, the response entry
carries `"error":"permission denied"` at the top level while `policy_results.allowed` is still
`true`. A detection keyed on `allowed == false` finds nothing and reports a clean cluster.
`parse-audit-log.sh` uses the top-level `.error` instead.

**A single blocked audit device is an outage.** With the file device on a full volume, every
request returns:

```
{"errors":["internal error"]}   HTTP 500
```

and the server log carries the only useful detail:

```
[ERROR] audit: backend failed to log request: backend=local-file/ error="write /openbao/audit/audit.log: ..."
[ERROR] core: failed to audit response: ... no audit backend succeeded in logging the response
```

**A second device turns that outage into a warning.** With `stdout` enabled alongside the file
device, the same full volume produced HTTP 200 and a working read while the file device kept
logging errors. One device succeeding is enough.

**Which means the metric that alerts you fires too late.**
`vault_audit_log_request_failure` increments only when no device logged the request, which is the
same moment clients start seeing 500s. There is no per-device failure metric, so the degraded
state is visible only in the server log.

**Metric names are `vault_*`.** Alerts written as `openbao_*` never fire. And
`vault_core_unsealed` is emitted twice, `{cluster=""} 0` alongside `{cluster="..."} 1`, so
`vault_core_unsealed == 0` alerts permanently on a healthy instance. `alerts.yaml` filters the
empty label out.

**Metrics need two config stanzas.** `telemetry { prometheus_retention_time = "24h" }` at the top
level, and `telemetry { unauthenticated_metrics_access = true }` inside the listener if Prometheus
is to scrape without a token. Without the first, the endpoint has nothing to return.

## Cleanup

```bash
helm upgrade openbao openbao/openbao --version 0.28.6 -n openbao \
  -f ../../module-1-architecture-first-deployment/lesson-1.3-standalone-helm-tls/values-standalone.yaml
kubectl -n openbao delete pod openbao-0   # then unseal
```
