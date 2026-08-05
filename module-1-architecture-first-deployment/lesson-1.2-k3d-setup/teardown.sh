#!/usr/bin/env bash
#
# Destroys the course cluster. This is total: the node containers hold the
# PersistentVolume data, so deleting them deletes OpenBao's barrier along with
# everything else. That is deliberate. Rebuild with ./bootstrap.sh.
#
set -euo pipefail

CLUSTER_NAME="openbao-dev"

info() { printf '\033[0;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m  ok\033[0m %s\n' "$*"; }

if ! k3d cluster list "$CLUSTER_NAME" >/dev/null 2>&1; then
  ok "Cluster '$CLUSTER_NAME' does not exist, nothing to do."
  exit 0
fi

info "Deleting cluster '$CLUSTER_NAME'"
k3d cluster delete "$CLUSTER_NAME"

# k3d removes its own context, but check rather than assume.
if kubectl config get-contexts -o name 2>/dev/null | grep -qx "k3d-${CLUSTER_NAME}"; then
  info "Removing leftover kubeconfig context"
  kubectl config delete-context "k3d-${CLUSTER_NAME}" >/dev/null 2>&1 || true
fi

ok "Cluster destroyed."

cat <<'EOF'

Two things survive on purpose:

  * Images pulled into your local Docker cache. Reclaim with 'docker system prune -a'
    if you are short on disk.
  * Any unseal keys or root tokens you saved outside the cluster. Those are yours
    to manage; nothing here deletes them.

EOF
