#!/usr/bin/env bash
#
# Build the two tier CA: an offline-style root that signs one thing, and an
# intermediate that does all the day to day issuing.
#
#   kubectl -n openbao port-forward svc/openbao 8200:8200 &
#   export BAO_ADDR=https://127.0.0.1:8200
#   export BAO_SKIP_VERIFY=1      # still needed HERE, see close-the-loop.sh
#   export BAO_TOKEN=<your token>
#   ./configure-pki.sh
#
# Writes root_ca.crt into the current directory. That file is the trust anchor
# for everything afterwards, including the cert-manager Issuer's caBundle.
set -euo pipefail
: "${BAO_ADDR:?set BAO_ADDR}"
: "${BAO_TOKEN:?set BAO_TOKEN}"

SVC="${SVC:-openbao.openbao.svc.cluster.local}"

# ---------------------------------------------------------------------------
# Root CA. Ten years, and it signs exactly one certificate in its whole life:
# the intermediate. Everything else is signed by the intermediate.
#
# The split is about blast radius. If the intermediate key leaks you revoke the
# intermediate, issue a new one from the root, and re-issue end entity certs.
# If the ROOT key leaks, every certificate that chains to it is worthless and
# you rebuild the entire PKI, including redistributing the new trust anchor to
# every client. That second job is the one that takes months.
#
# In production the root lives somewhere the day to day system cannot reach: an
# HSM, an offline machine, a separate cluster. Here it is a separate mount that
# nothing issues from, which models the discipline without the hardware.
# ---------------------------------------------------------------------------
bao secrets enable -path=pki pki 2>/dev/null || echo "pki/ already enabled"
bao secrets tune -max-lease-ttl=87600h pki

# No key_type given, so this is RSA 2048 and sha256WithRSAEncryption. Worth
# knowing rather than assuming: the bootstrap certificate from lesson 1.3 was
# ECDSA P-256, so the algorithm changes here and nothing announces it.
bao write -field=certificate pki/root/generate/internal \
  common_name="OpenBao Root CA" \
  issuer_name="root-2026" \
  ttl=87600h > root_ca.crt

bao write pki/config/urls \
  issuing_certificates="https://${SVC}:8200/v1/pki/ca" \
  crl_distribution_points="https://${SVC}:8200/v1/pki/crl" > /dev/null

# ---------------------------------------------------------------------------
# Intermediate CA. Five years, deliberately shorter than the root's ten.
# ---------------------------------------------------------------------------
bao secrets enable -path=pki_int pki 2>/dev/null || echo "pki_int/ already enabled"
bao secrets tune -max-lease-ttl=43800h pki_int

bao write -field=csr pki_int/intermediate/generate/internal \
  common_name="OpenBao Intermediate CA" > pki_intermediate.csr

bao write -field=certificate pki/root/sign-intermediate \
  issuer_ref="root-2026" \
  csr=@pki_intermediate.csr \
  format=pem_bundle \
  ttl=43800h > intermediate.cert.pem

bao write pki_int/intermediate/set-signed certificate=@intermediate.cert.pem > /dev/null

# ---------------------------------------------------------------------------
# NAME THE ISSUER HERE, AFTER set-signed. THIS IS NOT OPTIONAL.
#
# Passing issuer_name= to intermediate/generate/internal looks like it names the
# resulting CA. It does not survive the round trip: set-signed imports fresh
# issuers and they come back with an empty issuer_name.
#
# That matters because roles reference the issuer by name. Writing a role with
# issuer_ref="intermediate-2026" against an issuer that has no name SUCCEEDS,
# stores the dangling reference verbatim, and fails only when somebody finally
# requests a certificate, as an HTTP 500:
#
#   Code: 500. Errors:
#   * 1 error occurred:
#       * could not fetch the CA certificate (was one set?): unable to find PKI
#         issuer for reference: intermediate-2026
#
# A 500 rather than a 400, at issuance time rather than at configuration time,
# for a reference the API accepted without a word. Name it now.
#
# set-signed also imports TWO issuers, because format=pem_bundle carries the
# root along with the intermediate. The real intermediate is the DEFAULT one and
# the one whose ca_chain has two certificates; the stray one is the root, with
# no private key, which can therefore sign nothing. Name it too so the mount
# does not read as a mystery in six months.
# ---------------------------------------------------------------------------
DEFAULT_ISSUER="$(bao read -field=default pki_int/config/issuers)"
bao write "pki_int/issuer/${DEFAULT_ISSUER}" issuer_name="intermediate-2026" > /dev/null

for id in $(bao list -format=json pki_int/issuers | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)))'); do
  if [ -z "$(bao read -field=issuer_name "pki_int/issuer/${id}" 2>/dev/null)" ]; then
    bao write "pki_int/issuer/${id}" issuer_name="root-2026-imported" > /dev/null
  fi
done

bao write pki_int/config/urls \
  issuing_certificates="https://${SVC}:8200/v1/pki_int/ca" \
  crl_distribution_points="https://${SVC}:8200/v1/pki_int/crl" > /dev/null

# ---------------------------------------------------------------------------
# Roles.
#
# ttl is the default when the caller asks for nothing. max_ttl is the ceiling,
# and the ceiling is enforced by SILENT TRUNCATION, not by an error. Ask for
# 5000h against max_ttl=720h and you get a 720h certificate and no warning.
# Anything that schedules its own renewal must read notAfter off the certificate
# it received, never the TTL it asked for.
# ---------------------------------------------------------------------------
bao write pki_int/roles/openbao-listener \
  issuer_ref="intermediate-2026" \
  allowed_domains="openbao,openbao.openbao,openbao.openbao.svc,openbao.openbao.svc.cluster.local,localhost" \
  allow_bare_domains=true \
  allow_subdomains=false \
  allow_ip_sans=true \
  allow_localhost=true \
  require_cn=false \
  key_type="rsa" key_bits=2048 \
  ttl="168h" max_ttl="720h" > /dev/null

bao write pki_int/roles/kubernetes-services \
  issuer_ref="intermediate-2026" \
  allowed_domains="svc.cluster.local" \
  allow_subdomains=true \
  allow_ip_sans=true \
  allow_localhost=true \
  require_cn=false \
  key_type="rsa" key_bits=2048 \
  ttl="168h" max_ttl="720h" > /dev/null

# ---------------------------------------------------------------------------
# Policy for cert-manager.
#
# sign, NOT issue. The difference is not stylistic:
#
#   issue/  OpenBao generates the private key and hands it back over the wire.
#   sign/   the caller generates its own key and sends a CSR. The private key
#           never exists anywhere but the caller.
#
# cert-manager always generates its own key, so it needs sign. Granting it issue
# additionally would let an automation account request private keys it has no
# use for, and pointing the Issuer at issue/ produces a certificate whose key
# nobody holds. Neither is a capability worth having.
# ---------------------------------------------------------------------------
bao policy write cert-manager - <<'HCL' > /dev/null
path "pki_int/sign/openbao-listener" {
  capabilities = ["create", "update"]
}

path "pki_int/sign/kubernetes-services" {
  capabilities = ["create", "update"]
}
HCL

bao auth enable kubernetes 2>/dev/null || echo "kubernetes auth already enabled"
bao write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc.cluster.local:443" > /dev/null

# bound to the ServiceAccount in the ISSUER's namespace, which is openbao and
# not cert-manager. See cert-manager-rbac.yaml for why.
bao write auth/kubernetes/role/cert-manager \
  bound_service_account_names=cert-manager-pki \
  bound_service_account_namespaces=openbao \
  policies=cert-manager \
  ttl=1h > /dev/null

echo
echo "PKI ready. root_ca.crt written to $(pwd)/root_ca.crt"
echo "Next: kubectl apply -f cert-manager-rbac.yaml, then ./close-the-loop.sh"
