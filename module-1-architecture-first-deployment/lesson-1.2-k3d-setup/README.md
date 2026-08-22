# Lesson 1.2 — Local Development Infrastructure with k3d

Artifacts for lesson 1.2 of [OpenBao Secrets Management: Production Operations on Kubernetes](https://devoriales.com/quiz/27/openbao-secrets-management-production-operations-on-kubernetes).

This builds the cluster **every later lesson assumes**. Get it right once and the rest of
the course has somewhere to run.

## Contents

| File | What it is |
|---|---|
| `k3d-openbao-dev.yaml` | Cluster definition: 1 server, 2 agents, pinned k3s image, Traefik, local registry |
| `bootstrap.sh` | Preflight checks, creates the cluster, waits for it to actually be usable |
| `teardown.sh` | Destroys it completely |

## Before you start

**Resource requirements, stated honestly.** Module 1 is light. Module 3 and the capstone
run a 3-node Raft cluster, a second OpenBao acting as the Transit unsealer, PostgreSQL,
Garage, and SoftHSM2 at the same time. If you size only for Module 1 you will hit a wall
later, so provision for the whole course now:

| Resource | Minimum | Why |
|---|---|---|
| Host RAM | 16 GB | 8 GB of it allocated to Docker |
| Docker memory | 8 GB | Module 3 workloads run concurrently |
| CPU | 4 cores | Raft elections get unhappy when starved |
| **Docker disk** | **15 GB free** | See below, this is the one people miss |

**Watch the Docker VM's disk, not your host's.** k3d nodes share the container runtime's
virtual disk, and kubelet starts evicting pods on `ephemeral-storage` pressure well before
that disk is full. During development of this course, a two node cluster running only
cert-manager, External Secrets Operator and a single OpenBao evicted pods while the host
still had 66 GiB free, because the Docker VM's 19 GB disk was at 90%. `bootstrap.sh`
checks this for you and warns.

```bash
docker system df                          # what is using the space
docker exec <k3d-node> df -h /            # what the node actually sees
docker system prune -a                    # reclaim it
```

Raising the ceiling depends on which runtime you use:

**Docker Desktop.** Settings > Resources, raise the disk image size and the memory.

**Colima.** The VM is sized at start time, so the change needs a restart. Disk can be grown
but never shrunk, so overshoot rather than doing this twice:

```bash
colima list                               # find your running profile and its current size
colima stop <profile>
colima start <profile> --cpu 4 --memory 10 --disk 80
```

Colima's own default is 2 CPUs and 2 GiB of memory, which is well under what this course
needs. If you created your profile a while ago for something else, check it before you start
Module 3 rather than after.

**Linux with native Docker.** No VM, so there is no separate limit. Your host disk and
memory are what the cluster gets.

## Required tooling

Versions this lesson was validated against are in [`VERSIONS.md`](../../VERSIONS.md).

```bash
k3d version          # v5.9.0
kubectl version      # v1.36.4  (within one minor of the cluster is fine)
helm version         # v3.21.4  — Helm 3.x, NOT Helm 4
bao version          # OpenBao v2.6.2
```

**Helm must be 3.x.** Helm's current release is 4.x, but the OpenBao chart has no Helm 4
test coverage upstream, so this course pins 3.21.4. `bootstrap.sh` refuses to run on
Helm 4 rather than letting you discover it three lessons later.

### Installing the `bao` CLI on your host

You need it on the host, not only inside the cluster.

```bash
# macOS
brew install openbao

# Linux / WSL2 (x86_64)
curl -sSLO https://github.com/openbao/openbao/releases/download/v2.6.2/openbao_2.6.2_linux_amd64.tar.gz
echo "8dc11cc5fca0b539a9e352727dacb4e2d304daffcf9a66e0718ac325a20d05aa  openbao_2.6.2_linux_amd64.tar.gz" | sha256sum -c
tar -xzf openbao_2.6.2_linux_amd64.tar.gz bao
sudo install -m 0755 bao /usr/local/bin/bao
```

Verified SHA-256 sums for v2.6.2, taken from the release's `checksums.txt`:

| Archive | SHA-256 |
|---|---|
| `openbao_2.6.2_linux_amd64.tar.gz` | `8dc11cc5fca0b539a9e352727dacb4e2d304daffcf9a66e0718ac325a20d05aa` |
| `openbao_2.6.2_linux_arm64.tar.gz` | `1b408e01f3565ac0cbcb88d637dca271d0515148fb72efdeff4473a34fa50c4e` |
| `openbao_2.6.2_darwin_arm64.tar.gz` | `4e495376174accc0e014d31e9901f518a974f966850c839f626347eaac05fd52` |
| `openbao_2.6.2_darwin_amd64.tar.gz` | `64fdf1ce8f410bbc1531d2f0ea142d21b4e755b986542025a00294999a8cfaa5` |

Homebrew's `openbao` formula conflicts with a separate `bao` formula, since both install a
`bao` binary. If `brew install openbao` complains, uninstall the other one first.

## Create the cluster

```bash
./bootstrap.sh
```

Then confirm:

```bash
kubectl get nodes
kubectl get pods -A
```

All three nodes should read `Ready` on `v1.36.2+k3s1`.

## Ports

| Port | What |
|---|---|
| `8880` | Traefik HTTP |
| `8843` | Traefik HTTPS |
| `5050` | Local image registry (`registry.localhost:5050`) |

These are deliberately not the conventional 8080, 8443 and 5000. **Port 5000 is bound by
Control Center for the AirPlay Receiver on a default macOS install**, and 8080 is taken on
a lot of developer machines. A clash makes k3d fail at its last step and roll the whole
cluster back, which reads as a far worse problem than it is, so `bootstrap.sh` checks these
three ports up front and tells you which process is holding one.

## Tear it down

```bash
./teardown.sh
```

This is total: the node containers hold the PersistentVolume data, so OpenBao's barrier
goes with them.

**There is deliberately no host volume mount for cluster storage.** It is tempting to
bind-mount a host directory onto `/var/lib/rancher/k3s/storage` so PVC data survives a
delete. Do not. OpenBao writes its barrier to a PVC, and surviving barrier data means a
rebuilt cluster comes up already initialized, holding a keyring encrypted under unseal keys
that were printed to a terminal you have since closed. You would be locked out of your own
lab with no way in.

## Troubleshooting

**Pods in `CrashLoopBackOff`, or vanishing and being recreated.** Usually not the
application. Check for eviction and OOM first:

```bash
kubectl describe pod <name> | grep -A5 -E 'Last State|Events'
```

`OOMKilled` means Docker memory is too low. `The node was low on resource: ephemeral-storage`
means Docker disk is too low. Neither says "you are out of resources" in plain language,
which is why they cost people so much time.

**`Bind for 0.0.0.0:8880 failed: port is already allocated`.** Something else has the port.
`bootstrap.sh` catches this before creating anything; if you see it from `k3d` directly,
find the holder with `lsof -nP -iTCP:8880 -sTCP:LISTEN`.

**`helm-install-traefik` shows `Error`, then `Completed` with restarts.** Normal. k3s installs
Traefik through two Jobs, and the chart Job races the CRD Job, failing its first attempt with
`Required CRDs are missing`. k3s retries and the retry succeeds.

**`deployments.apps "traefik" not found`.** You looked too early. The Deployment does not
exist for the first ~30 seconds. `bootstrap.sh` waits for it to appear before checking rollout.
