#!/usr/bin/env bash
#
# Creates the canonical k3d cluster for the OpenBao Secrets Management course.
# Safe to re-run: it refuses to clobber an existing cluster rather than
# silently recreating one you still had work in.
#
set -euo pipefail

CLUSTER_NAME="openbao-dev"
CONFIG_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/k3d-openbao-dev.yaml"

# Versions this course was validated against.
WANT_K3S_IMAGE="rancher/k3s:v1.36.2-k3s1"
WANT_KUBECTL_MINOR="1.36"
WANT_HELM_MAJOR="3"

# Free space the Docker VM needs, in GB. This number is not arbitrary: a two node
# cluster running cert-manager, External Secrets Operator and a single OpenBao
# evicted pods on ephemeral-storage pressure with 66 GiB still free on the host,
# because the Docker VM's own disk was at 90%. Module 3 and the capstone are
# heavier than that.
MIN_DOCKER_DISK_GB=15

info()  { printf '\033[0;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[0;32m  ok\033[0m %s\n' "$*"; }
warn()  { printf '\033[0;33m  !!\033[0m %s\n' "$*"; }
die()   { printf '\033[0;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

info "Preflight"

command -v docker  >/dev/null 2>&1 || die "docker not found on PATH"
command -v k3d     >/dev/null 2>&1 || die "k3d not found on PATH. See the lesson for install steps."
command -v kubectl >/dev/null 2>&1 || die "kubectl not found on PATH"
command -v helm    >/dev/null 2>&1 || die "helm not found on PATH"

docker info >/dev/null 2>&1 || die "Docker is installed but not running. Start Docker and try again."
ok "docker is running"

# kubectl must be within one minor of the API server.
KUBECTL_VER="$(kubectl version --client -o json 2>/dev/null | sed -n 's/.*"gitVersion": *"v\([0-9]*\.[0-9]*\).*/\1/p' | head -1)"
if [ -n "$KUBECTL_VER" ] && [ "$KUBECTL_VER" != "$WANT_KUBECTL_MINOR" ]; then
  warn "kubectl is ${KUBECTL_VER}, course validated on ${WANT_KUBECTL_MINOR}. Within one minor is fine."
else
  ok "kubectl ${KUBECTL_VER:-unknown}"
fi

HELM_VER="$(helm version --short 2>/dev/null | sed -n 's/^v\([0-9]*\).*/\1/p')"
[ "${HELM_VER:-0}" = "$WANT_HELM_MAJOR" ] || die "Helm ${HELM_VER:-unknown} found, this course requires Helm ${WANT_HELM_MAJOR}.x (validated on 3.21.4). The OpenBao chart has no Helm 4 test coverage upstream."
ok "helm $(helm version --short)"

# Disk headroom inside the Docker VM, which is not the same as host free space.
DOCKER_FREE_GB="$(docker run --rm --entrypoint sh alpine:3 -c "df -P /  | awk 'NR==2 {print int(\$4/1024/1024)}'" 2>/dev/null || echo "")"
if [ -n "$DOCKER_FREE_GB" ]; then
  if [ "$DOCKER_FREE_GB" -lt "$MIN_DOCKER_DISK_GB" ]; then
    warn "Docker VM has ${DOCKER_FREE_GB}GB free, recommended minimum is ${MIN_DOCKER_DISK_GB}GB."
    warn "Pods will be evicted with 'The node was low on resource: ephemeral-storage'."
    warn "Reclaim some with 'docker system prune -a'. To raise the ceiling:"
    # The fix differs per runtime, and pointing a Colima user at Docker Desktop's
    # settings panel is a dead end, so detect which one is actually in use.
    #
    # Gate on 'colima list' rather than 'colima status': with no profile argument
    # 'colima status' reports on the profile named "default", which is very often
    # stopped while a differently-named profile is the one actually running. That
    # makes it exit non-zero and silently mis-detect the runtime.
    profile=""
    if command -v colima >/dev/null 2>&1; then
      profile="$(colima list 2>/dev/null | awk '$2=="Running" {print $1; exit}')"
    fi
    if [ -n "$profile" ]; then
      warn "  Colima detected (profile '${profile}'). Disk grows but never shrinks, and the VM must restart:"
      warn "    colima stop ${profile:-default}"
      warn "    colima start ${profile:-default} --cpu 4 --memory 10 --disk 80"
    else
      warn "  Docker Desktop: Settings > Resources, then raise the disk image size."
    fi
  else
    ok "Docker VM disk: ${DOCKER_FREE_GB}GB free"
  fi
else
  warn "Could not measure Docker VM free disk, continuing anyway"
fi

if k3d cluster list "$CLUSTER_NAME" >/dev/null 2>&1; then
  die "Cluster '$CLUSTER_NAME' already exists. Run ./teardown.sh first if you want a clean one."
fi

# Host ports must be free before k3d tries to bind them. k3d discovers a clash
# only at the very last step, then rolls the entire cluster back, so the failure
# reads as "cluster creation FAILED" rather than "something else has your port".
# Check first and say which port and which process.
port_busy() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
  else
    # Fallback for hosts without lsof (common in minimal WSL2 images).
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"
  fi
}

for port in 8880 8843 5050; do
  if port_busy "$port"; then
    holder="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $1" (pid "$2")"}')"
    warn "Port ${port} is already in use by ${holder:-another process}"
    if [ "$port" = "5050" ]; then
      warn "  This port serves the local image registry."
    else
      warn "  This port publishes Traefik on your host."
    fi
    die "Free port ${port} and re-run, or edit the ports in k3d-openbao-dev.yaml. On macOS, note that port 5000 is taken by Control Center for AirPlay Receiver, which is why this course uses 5050."
  fi
done
ok "host ports 8880, 8843, 5050 are free"

info "Creating cluster '$CLUSTER_NAME' on ${WANT_K3S_IMAGE}"
k3d cluster create --config "$CONFIG_FILE"

info "Waiting for nodes to become Ready"
kubectl wait --for=condition=Ready nodes --all --timeout=180s

info "Waiting for cluster components"
kubectl -n kube-system rollout status deployment/coredns --timeout=180s

# Traefik is not a static manifest. k3s installs it through a HelmChart custom
# resource, which runs two Jobs: one for the CRDs and one for the chart itself.
# Two consequences that matter here:
#
#   1. The Deployment does not exist for the first ~30s, so going straight to
#      'rollout status' fails with 'deployments.apps "traefik" not found'.
#   2. The chart Job frequently fails its first attempt with "Required CRDs are
#      missing", because it races the CRD Job. k3s retries it and the retry
#      succeeds. A failed first attempt here is normal and self-healing.
#
# So: wait for the Deployment to appear, then wait for it to roll out.
info "Waiting for Traefik to be installed by k3s (first attempt may retry, this is normal)"
deadline=$(( $(date +%s) + 300 ))
until kubectl -n kube-system get deployment traefik >/dev/null 2>&1; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    kubectl -n kube-system get jobs,pods 2>/dev/null | grep -i traefik || true
    die "Traefik Deployment did not appear within 300s. Inspect: kubectl -n kube-system logs job/helm-install-traefik"
  fi
  sleep 5
done
ok "Traefik Deployment created"
kubectl -n kube-system rollout status deployment/traefik --timeout=300s

info "Cluster state"
kubectl get nodes -o wide
echo
kubectl get pods -A

cat <<EOF

Cluster '$CLUSTER_NAME' is ready.

  context   : $(kubectl config current-context)
  ingress   : Traefik, published on http://localhost:8880 and https://localhost:8843
  registry  : registry.localhost:5050

Tear it down with ./teardown.sh
EOF
