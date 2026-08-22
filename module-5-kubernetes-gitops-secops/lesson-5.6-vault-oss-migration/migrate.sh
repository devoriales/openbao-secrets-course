#!/usr/bin/env bash
#
# Vault OSS 1.14 to OpenBao 2.6.2, on file storage, with the restore path built
# before anything is touched.
#
#   ./migrate.sh backup     # seal Vault, take the archive, verify it opens
#   ./migrate.sh cutover    # stop Vault, load the archive into OpenBao, start it
#   ./migrate.sh verify     # prove the data survived
#   ./migrate.sh rollback   # put Vault back, using the archive from step 1
#
# Run the steps in that order and read the output of each before running the
# next. This is a runbook, not an installer.
#
# ASSUMPTIONS
#
#   Vault   release "vault"   in namespace vault,   PVC data-vault-0,   /vault/data
#   OpenBao release "openbao" in namespace openbao, PVC data-openbao-0, /openbao/data
#
# Both are standalone with the file storage backend and a Shamir seal. That is
# the migration this lesson validates. Raft is a different procedure, and an
# auto-unseal Vault is a different procedure again: with Transit or a cloud KMS
# seal you migrate the seal first, on Vault, before you touch OpenBao.
set -euo pipefail

ARCHIVE="${ARCHIVE:-vault-data-$(date +%Y%m%d-%H%M%S).tgz}"
LATEST="vault-data-latest.tgz"

vault_exec() { kubectl -n vault exec vault-0 -- "$@"; }

case "${1:-}" in

backup)
  echo "== 1. what is in Vault right now =="
  # Write this down. It is the checklist you verify against afterwards, and the
  # only way to notice that something did not come across.
  vault_exec sh -c 'VAULT_ADDR=http://127.0.0.1:8200 vault status | head -6' || true

  echo
  echo "== 2. seal Vault, so the storage stops changing =="
  # Sealing is not stopping. The process keeps running and keeps the pod
  # healthy enough to exec into, while no further writes reach the files. That
  # is exactly what you want for a consistent copy.
  vault_exec sh -c "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=\${VAULT_TOKEN:-} vault operator seal" 2> /dev/null \
    || echo "   (seal needs a token; if this failed, run it yourself before continuing)"

  echo
  echo "== 3. take the archive =="
  kubectl -n vault exec vault-0 -- tar czf - -C /vault/data . > "$ARCHIVE"
  cp "$ARCHIVE" "$LATEST"
  ls -lh "$ARCHIVE"

  echo
  echo "== 4. prove the archive opens, before trusting it =="
  # An untested backup is not a backup. This is the failure mode the lesson is
  # built around: teams take the archive, start the cutover, hit a problem, and
  # only then discover the archive was empty, truncated or written by a
  # different pod.
  tar tzf "$ARCHIVE" > /dev/null && echo "   archive is readable"
  echo "   entries: $(tar tzf "$ARCHIVE" | wc -l | tr -d ' ')"
  tar tzf "$ARCHIVE" | grep -q './core/' \
    && echo "   contains ./core/, which is where the barrier keeps its own state" \
    || { echo "   ./core/ is MISSING. This archive is not a Vault data directory. Stop." >&2; exit 1; }
  ;;

cutover)
  [ -s "$LATEST" ] || { echo "no $LATEST; run ./migrate.sh backup first" >&2; exit 1; }

  echo "== 1. stop Vault =="
  # Scale rather than delete. The PVC, and therefore the original data, stays
  # exactly where it was, which is half of the rollback plan.
  kubectl -n vault scale statefulset vault --replicas=0
  kubectl -n vault wait --for=delete pod/vault-0 --timeout=120s || true

  echo
  echo "== 2. stop OpenBao and load the data into its volume =="
  # OpenBao must not be initialised. It is adopting Vault's storage, barrier
  # and all, so anything it wrote for itself would be in the way.
  kubectl -n openbao scale statefulset openbao --replicas=0
  kubectl -n openbao wait --for=delete pod/openbao-0 --timeout=120s || true

  # Pipe an archive into a pod through `kubectl run -i` and you are trusting an
  # attach that races the container's own startup; when it loses, kubectl
  # returns "timed out waiting for the condition" and the copy never happened.
  # A helper pod that just sleeps, plus kubectl cp, has no race in it.
  kubectl -n openbao delete pod migrate-loader --ignore-not-found --wait=true > /dev/null
  kubectl -n openbao apply -f - > /dev/null <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: migrate-loader
spec:
  restartPolicy: Never
  containers:
    - name: loader
      image: busybox:1.37
      command: ["sh", "-c", "sleep 900"]
      volumeMounts:
        - name: data
          mountPath: /openbao/data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: data-openbao-0
YAML
  kubectl -n openbao wait --for=condition=Ready pod/migrate-loader --timeout=120s > /dev/null

  kubectl -n openbao cp "$LATEST" migrate-loader:/tmp/vault-data.tgz
  kubectl -n openbao exec migrate-loader -- sh -c \
    'rm -rf /openbao/data/* && tar xzf /tmp/vault-data.tgz -C /openbao/data && echo COPIED && ls /openbao/data'

  kubectl -n openbao delete pod migrate-loader --wait=false > /dev/null

  echo
  echo "== 3. start OpenBao on Vault's storage =="
  kubectl -n openbao scale statefulset openbao --replicas=1
  # The pod will never become Ready here, and that is correct: readiness is the
  # seal status, and OpenBao comes up sealed on somebody else's barrier.
  for _ in $(seq 1 30); do
    [ "$(kubectl -n openbao get pod openbao-0 -o jsonpath='{.status.phase}' 2> /dev/null)" = "Running" ] && break
    sleep 4
  done
  kubectl -n openbao exec openbao-0 -- bao status || true

  echo
  echo "Now unseal with VAULT's unseal keys. They are the same keys: the barrier"
  echo "is the same barrier, and OpenBao 2.6.2 reads the format Vault 1.14 wrote."
  ;;

verify)
  echo "== the checklist from step 1 of the backup, on the other side =="
  # BAO_TOKEN here is VAULT's root token. It came across with everything else.
  kubectl -n openbao exec openbao-0 -- sh -c '
    bao status | head -6
    echo
    echo "-- secrets engines --"; bao secrets list | head -8
    echo
    echo "-- auth methods --";    bao auth list | head -8
    echo
    echo "-- policies --";        bao policy list
    echo
    echo "-- the actual secret --"; bao kv get -field=api_key secret/apps/reporting
  '
  ;;

rollback)
  [ -s "$LATEST" ] || { echo "no $LATEST; there is nothing to roll back to" >&2; exit 1; }
  echo "== stop OpenBao, restart Vault on its own untouched volume =="
  # Note what rollback does NOT need: the archive. Vault's PVC was never
  # modified, so the archive is the second line of defence rather than the
  # first. That is why the cutover scales instead of deleting.
  kubectl -n openbao scale statefulset openbao --replicas=0
  kubectl -n vault scale statefulset vault --replicas=1
  # Poll rather than `kubectl wait`: the pod does not exist yet at this point,
  # and wait treats a missing object as an error rather than as "not yet".
  for _ in $(seq 1 45); do
    [ "$(kubectl -n vault get pod vault-0 -o jsonpath='{.status.phase}' 2> /dev/null)" = "Running" ] && break
    sleep 4
  done
  echo "Unseal Vault with the same keys. Everything is where it was."
  ;;

*)
  echo "usage: $0 {backup|cutover|verify|rollback}" >&2
  exit 1
  ;;
esac
