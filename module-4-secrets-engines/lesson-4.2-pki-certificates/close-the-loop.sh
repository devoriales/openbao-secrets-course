#!/usr/bin/env bash
#
# Replace OpenBao's bootstrap listener certificate with one OpenBao issued
# itself, without restarting it and without an unseal ceremony.
#
#   ./configure-pki.sh          # first, writes root_ca.crt
#   kubectl apply -f cert-manager-rbac.yaml
#   ./close-the-loop.sh
#
# THE ORDERING PROBLEM THIS SCRIPT EXISTS TO SOLVE
#
# cert-manager has to reach OpenBao over TLS in order to ask it for a
# certificate. Right now OpenBao is still serving the self signed certificate
# from lesson 1.3, which the OpenBao root has not signed. So the Issuer's
# caBundle cannot start as the OpenBao root, however much you want it to:
#
#   error calling Vault server: Post ".../v1/auth/kubernetes/login":
#   tls: failed to verify certificate: x509: certificate signed by unknown authority
#
# The caBundle is therefore the BOOTSTRAP CA first and becomes the OpenBao root
# only after the listener has been switched over. Two states, in this order.
# Skipping the second one is the subject of step 6.
set -euo pipefail
: "${BAO_ADDR:?set BAO_ADDR}"
NS="${NS:-openbao}"
[ -s root_ca.crt ] || { echo "root_ca.crt missing, run ./configure-pki.sh first" >&2; exit 1; }

wait_issuer() {
  for _ in $(seq 1 20); do
    [ "$(kubectl -n "$NS" get issuer openbao-pki \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ] && return 0
    sleep 6
  done
  echo "Issuer never became Ready:" >&2
  kubectl -n "$NS" describe issuer openbao-pki | tail -6 >&2
  return 1
}

echo "== 1. Issuer, trusting the BOOTSTRAP CA that the listener is serving today =="
BOOT_CA="$(kubectl -n "$NS" get secret openbao-tls -o jsonpath='{.data.ca\.crt}')"
kubectl apply -f - <<YAML
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: openbao-pki
  namespace: ${NS}
spec:
  vault:
    server: https://openbao.${NS}.svc.cluster.local:8200
    # sign, never issue. issue/ makes its own key pair and ignores the CSR
    # cert-manager sent, so the certificate comes back signed, valid, and
    # unusable because its private key was discarded inside OpenBao.
    path: pki_int/sign/openbao-listener
    caBundle: ${BOOT_CA}
    auth:
      kubernetes:
        role: cert-manager
        mountPath: /v1/auth/kubernetes
        serviceAccountRef:
          name: cert-manager-pki
YAML
wait_issuer && echo "   Issuer Ready"

echo "== 2. retire the lesson 1.3 Certificate, keeping its Secret =="
kubectl -n "$NS" delete certificate openbao-tls --ignore-not-found
kubectl -n "$NS" get secret openbao-tls >/dev/null && echo "   Secret openbao-tls survived, listener unaffected"

echo "== 3. ask OpenBao for its own listener certificate =="
kubectl apply -f openbao-listener-cert.yaml
for _ in $(seq 1 20); do
  [ "$(kubectl -n "$NS" get certificate openbao-tls-from-pki \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ] && break
  sleep 6
done
kubectl -n "$NS" get certificate openbao-tls-from-pki

echo "== 4. wait for kubelet to project the new Secret into the pod =="
# Not instant. Measured around 50 seconds. Reloading before the file has changed
# does nothing at all, and looks exactly like a reload that failed.
for i in $(seq 1 24); do
  ISS="$(kubectl -n "$NS" exec openbao-0 -- cat /openbao/tls/tls.crt 2>/dev/null \
        | openssl x509 -noout -issuer 2>/dev/null || true)"
  case "$ISS" in
    *"Intermediate"*) echo "   file on disk updated after ~$((i*5))s"; break ;;
  esac
  sleep 5
done

echo "== 5. reload the listener in place, no restart =="
# A restart would work and would also leave a Shamir sealed instance behind,
# turning a certificate rotation into a key ceremony. SIGHUP avoids that.
#
# Signal the bao process, NOT PID 1. PID 1 is the chart's shell wrapper, and
# `kill -HUP 1` is silently ignored.
BAO_PID="$(kubectl -n "$NS" exec openbao-0 -- sh -c "ps -o pid,comm | awk '\$2==\"bao\"{print \$1; exit}'" | tr -d '[:space:]')"
[ -n "$BAO_PID" ] || { echo "could not find the bao pid" >&2; exit 1; }
echo "   bao is pid ${BAO_PID}, sending SIGHUP"
kubectl -n "$NS" exec openbao-0 -- kill -HUP "$BAO_PID"
sleep 6
kubectl -n "$NS" exec openbao-0 -- bao status 2>/dev/null | grep -E '^Sealed' || true

echo "== 6. point the Issuer at the OpenBao root, which is now the real anchor =="
# Leaving the bootstrap CA here is the trap. Everything keeps working: the
# Issuer stays Ready and renewals succeed, because cert-manager reuses a cached
# client. The failure surfaces the next time cert-manager restarts, which is a
# node drain or an upgrade, at which point all issuance stops for a reason that
# has nothing to do with anything that changed that day.
kubectl -n "$NS" patch issuer openbao-pki --type=merge \
  -p "{\"spec\":{\"vault\":{\"caBundle\":\"$(base64 < root_ca.crt | tr -d '\n')\"}}}"
wait_issuer && echo "   Issuer Ready against the OpenBao root"

echo "== 7. prove it =="
echo | openssl s_client -connect "${BAO_ADDR#https://}" -CAfile root_ca.crt -verify_return_error 2>/dev/null \
  | grep -E 'depth=|Verify return code' || true
echo
echo "BAO_SKIP_VERIFY is no longer needed. From here on:"
echo "  export BAO_CACERT=\$(pwd)/root_ca.crt"
echo "  unset BAO_SKIP_VERIFY"
