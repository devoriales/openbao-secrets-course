# Verified version matrix

Every version below was resolved against the authoritative source named in the last column,
not from documentation or memory. Nothing here is a floating `latest` tag.

**Verification date: 2026-08-04.** Baseline: OpenBao **v2.6.1**, Helm chart **openbao-0.28.6**.

| Component | Version | Source |
|---|---|---|
| OpenBao | `v2.6.1` (2026-07-22) | `api.github.com/repos/openbao/openbao/releases` |
| OpenBao Helm chart | `openbao-0.28.6` (2026-07-22) | Chart `appVersion: v2.6.1` |
| k3d | `v5.9.0` | `api.github.com/repos/k3d-io/k3d/releases/latest` |
| k3s / Kubernetes | `v1.36.2+k3s1` → Kubernetes `1.36.2` | `api.github.com/repos/k3s-io/k3s/releases/latest` |
| kubectl | `v1.36.3` | `dl.k8s.io/release/stable.txt` |
| Helm | `v3.21.3` | `api.github.com/repos/helm/helm/releases` |
| cert-manager | `v1.21.1` | `api.github.com/repos/cert-manager/cert-manager/releases/latest` |
| PostgreSQL | `postgres:18.4-trixie` | Docker Hub `library/postgres` |
| MinIO | `RELEASE.2025-10-15T17-29-55Z` | `api.github.com/repos/minio/minio/releases/latest` |
| SoftHSM2 | upstream `2.6.1`, Debian trixie package `2.6.1-3` | `sources.debian.org/api/src/softhsm2` |
| External Secrets Operator | operator `v2.8.0`, chart `2.8.0` | `api.github.com/repos/external-secrets/external-secrets/releases` |
| Go | `go1.26.5` | `go.dev/dl/?mode=json` |
| OpenBao Go API module | `github.com/openbao/openbao/api/v2` `v2.6.0` | `proxy.golang.org` |
| Vault OSS (migration source) | `v1.14.10` | `api.github.com/repos/hashicorp/vault` tags |

## Images shipped by the chart

These come from `openbao-0.28.6`'s `values.yaml` and are not separately selectable:

| Image | Tag | Used by |
|---|---|---|
| `hashicorp/vault-k8s` (Agent injector) | `1.7.2` | Lesson 5.3 |
| `openbao/openbao-csi-provider` | `2.0.2` | Lesson 5.1 |
| `ghcr.io/openbao/openbao-snapshot-agent` | `0.3.0` | Lesson 3.8 |

The Agent injector really is upstream `vault-k8s`, which is why injector annotations use the
`vault.hashicorp.com/` prefix and never `bao.hashicorp.com/`.

## Compatibility, verified as a set

Not just row by row. The full set was installed onto a clean k3d cluster and confirmed running.

- `openbao-0.28.6` declares `kubeVersion: >= 1.30.0-0`. More usefully, the chart's own acceptance
  suite runs against Kubernetes 1.34.8, 1.35.5, and 1.36.1, so the pinned 1.36.2 sits at the top
  of a tested range.
- cert-manager 1.21 supports and tests Kubernetes 1.33 → 1.36.
- External Secrets Operator chart 2.8.0 declares `kubeVersion: >= 1.19.0-0`.
- kubectl 1.36.3 against Kubernetes 1.36.2 is the same minor, well inside the supported skew.
- **k3d's default k3s is not this pin.** k3d 5.9.0 defaults to `v1.35.5-k3s1`. Every
  `k3d cluster create` must pass `--image rancher/k3s:v1.36.2-k3s1`.

## Two version notes worth reading

**The Go API module is not `github.com/openbao/openbao/api`.** That path resolves to `v1.12.2`,
published March 2024, and has not moved since. The live module is
`github.com/openbao/openbao/api/v2`. It also trails the server by a patch: there is no
`api/v2.6.1` tag, so `api/v2 v2.6.0` is correct against server v2.6.1.

**MinIO's latest release is from October 2025.** Its open-source release cadence has stalled. It
stays pinned because Lesson 3.8 needs a free S3-compatible target and MinIO remains the best one,
but the date is stated rather than implied.

## Re-validation

OpenBao maintains only its latest release cycle; older minors stop receiving fixes, including
security fixes. This course re-validates on every new OpenBao minor and at minimum quarterly.
Each pass that moves the baseline cuts a new tag rather than overwriting an existing one.
