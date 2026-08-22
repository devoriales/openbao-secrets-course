# Verified version matrix

Every version below was resolved against the authoritative source named in the last column,
not from documentation or memory. Nothing here is a floating `latest` tag.

**Verification date: 2026-08-22.** Baseline: OpenBao **v2.6.2**, Helm chart **openbao-0.29.2**.

**Validated on macOS (Apple silicon).** Every lab in this course was executed on macOS arm64
with Colima or Docker Desktop. Linux and WSL2 are supported and the artifacts are written for
them (POSIX shell, an `ss` fallback where `lsof` is absent, per-platform install paths with
verified checksums), but they have not been executed there. If you hit a platform-specific
problem on Linux or WSL2, that is a gap in testing rather than a gap in intent, and an issue
on the repository is welcome.

| Component | Version | Source |
|---|---|---|
| OpenBao | `v2.6.2` (2026-08-18) | `api.github.com/repos/openbao/openbao/releases` |
| OpenBao Helm chart | `openbao-0.29.2` (2026-08-18) | Chart `appVersion: v2.6.2` |
| k3d | `v5.9.0` | `api.github.com/repos/k3d-io/k3d/releases/latest` |
| k3s / Kubernetes | `v1.36.2+k3s1` → Kubernetes `1.36.2` | `api.github.com/repos/k3s-io/k3s/releases/latest` |
| kubectl | `v1.36.4` | `dl.k8s.io/release/stable.txt` |
| Helm | `v3.21.4` | `api.github.com/repos/helm/helm/releases` |
| cert-manager | `v1.21.1` | `api.github.com/repos/cert-manager/cert-manager/releases/latest` |
| PostgreSQL | `postgres:18.4-trixie` | Docker Hub `library/postgres` |
| Garage (S3-compatible target) | `v2.3.0`, image `dxflrs/garage:v2.3.0` | `github.com/deuxfleurs-org/garage` tags + Docker Hub |
| SoftHSM2 | Debian trixie package `2.6.1-3` (upstream is `2.7.0`, see note) | `github.com/opendnssec/SoftHSMv2` + `sources.debian.org` |
| External Secrets Operator | operator `v2.9.0`, chart `2.9.0` | `api.github.com/repos/external-secrets/external-secrets/releases` |
| Go | `go1.26.5` | `go.dev/dl/?mode=json` |
| OpenBao Go API module | `github.com/openbao/openbao/api/v2` `v2.6.0` | `proxy.golang.org` |
| Vault OSS (migration source) | `v1.14.10` | `api.github.com/repos/hashicorp/vault` tags |

## Images shipped by the chart

These come from `openbao-0.29.2`'s `values.yaml` and are not separately selectable:

| Image | Tag | Used by |
|---|---|---|
| `hashicorp/vault-k8s` (Agent injector) | `1.7.2` | Lesson 5.3 |
| `openbao/openbao-csi-provider` | `2.0.3` | Lesson 5.1 |
| `ghcr.io/openbao/openbao-snapshot-agent` | `0.4.1` | Lesson 3.8 |

The Agent injector really is upstream `vault-k8s`, which is why injector annotations use the
`vault.hashicorp.com/` prefix and never `bao.hashicorp.com/`.

## Compatibility, verified as a set

Not just row by row. The full set was installed onto a clean k3d cluster and confirmed running.

- `openbao-0.29.2` declares `kubeVersion: >= 1.30.0-0`. More usefully, the chart's own acceptance
  suite runs against Kubernetes 1.34.8, 1.35.5, and 1.36.1, so the pinned 1.36.2 sits at the top
  of a tested range.
- cert-manager 1.21 supports and tests Kubernetes 1.33 → 1.36.
- External Secrets Operator chart 2.9.0 declares `kubeVersion: >= 1.19.0-0`.
- kubectl 1.36.4 against Kubernetes 1.36.2 is the same minor, well inside the supported skew.
- **k3d's default k3s is not this pin.** k3d 5.9.0 defaults to `v1.35.5-k3s1`. Every
  `k3d cluster create` must pass `--image rancher/k3s:v1.36.2-k3s1`.

## Two version notes worth reading

**The Go API module is not `github.com/openbao/openbao/api`.** That path resolves to `v1.12.2`,
published March 2024, and has not moved since. The live module is
`github.com/openbao/openbao/api/v2`. It also trails the server by a patch: there is no
`api/v2.6.2` tag, so `api/v2 v2.6.0` is correct against server v2.6.2.

**The S3 target is Garage.** It is S3-compatible, so the `aws` CLI and lesson 3.8's snapshot
CronJob talk to it unmodified, and at 25.8 MB it is far lighter on a laptop already running a
3-node cluster. Any S3-compatible target works if you prefer another one.

There is no "OpenBao snapshot agent" and no `S3_HOST`, which an earlier revision of this file
claimed. Automated snapshots to object storage are a Vault Enterprise feature;
`sys/storage/raft/snapshot-auto/config` returns **404 unsupported path** on OpenBao 2.6.2, so
the schedule and the upload are written by hand. See lesson 3.8.

Two things to know about the Garage pin. Its GitHub repository is a **mirror**: it publishes no
GitHub releases, and the canonical repository is `git.deuxfleurs.fr/Deuxfleurs/garage`, so the pin
comes from the mirror's git tags plus the Docker Hub image tag rather than from a releases API like
every other entry here. And it is **AGPL-3.0**, which is unremarkable for running it yourself in a
lab, but worth knowing rather than discovering.

**SoftHSM2 is pinned to what Debian ships, not to upstream.** Lesson 3.3 installs SoftHSM2 from the
distribution package inside a container, so `2.6.1-3` from Debian trixie is what you actually get.
Upstream `opendnssec/SoftHSMv2` is further ahead at `2.7.0` (January 2026) and actively maintained.
Pinning the package your package manager installs is the right call for reproducibility; the gap is
stated here so it is not a surprise.

Note also how close SoftHSM2's `2.6.1-3` sits to OpenBao's own `2.6.2`. The two are unrelated,
they were briefly identical while OpenBao sat at 2.6.1, and Lesson 3.3 puts both in the same
commands. Read the package name, not the number.

## Re-validation

OpenBao maintains only its latest release cycle; older minors stop receiving fixes, including
security fixes. This course re-validates on every new OpenBao minor and at minimum quarterly.
Each pass that moves the baseline cuts a new tag rather than overwriting an existing one.

Every pass also checks whether each GitHub-hosted dependency is **archived or disabled**, not just
whether it released recently. A repository can look merely quiet by release date while having been
archived for months, and an archived dependency takes no security fixes.
