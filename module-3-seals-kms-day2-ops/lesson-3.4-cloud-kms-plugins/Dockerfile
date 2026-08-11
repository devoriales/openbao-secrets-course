# The stock OpenBao image plus one file: the AWS KMS seal plugin.
#
# What goes in here and why
# -------------------------
#   openbao/openbao:2.6.1
#       The DEFAULT distribution, Alpine based. Note this is the plain image,
#       not the openbao-ubi one lesson 3.3 needed. Nothing here requires glibc,
#       for the reason immediately below.
#
#   openbao-plugin-kms-aws, release kms-aws-v0.1.0
#       From github.com/openbao/openbao-plugins. This is the external KMS
#       plugin that implements `seal "awskms"`. It talks to the KMS HTTP API
#       with the AWS SDK for Go, so it needs no C libraries and is built
#       CGO_ENABLED=0: the binary is STATICALLY LINKED and runs unmodified on
#       Alpine's musl.
#
#       That is the whole difference from lesson 3.3. kms-pkcs11 had to call
#       into a vendor's C library, so it needed cgo, glibc and a custom base
#       image. kms-aws makes network calls, so it needs none of that. You can
#       read this off the release page without downloading anything: kms-aws
#       publishes linux builds for amd64, arm64, arm 6, ppc64le, riscv64 and
#       s390x, while kms-pkcs11 publishes amd64 and arm64 only. That spread is
#       the signature of a pure-Go build.
#
# Build and load it into the lesson 1.2 cluster:
#   docker build -t openbao-awskms:lab .
#   k3d image import openbao-awskms:lab -c openbao-dev

ARG BAO_VERSION=2.6.1
FROM openbao/openbao:${BAO_VERSION}

ARG TARGETARCH
ARG PLUGIN_VERSION=0.1.0

USER root

# curl is not in the base image and is only needed to fetch the plugin, so it
# is removed again in the same layer to keep it out of the runtime image.
RUN set -eux; \
    apk add --no-cache --virtual .fetch curl; \
    case "${TARGETARCH}" in \
      amd64) PLUGIN_ARCH=linux_amd64_v1 ;; \
      arm64) PLUGIN_ARCH=linux_arm64_v8 ;; \
      *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    BASE="https://github.com/openbao/openbao-plugins/releases/download/kms-aws-v${PLUGIN_VERSION}"; \
    PLUGIN="openbao-plugin-kms-aws_${PLUGIN_ARCH}"; \
    curl -fsSLo /tmp/plugin.tar.gz "${BASE}/${PLUGIN}.tar.gz"; \
    curl -fsSLo /tmp/checksums.txt "${BASE}/checksums-kms-aws.txt"; \
    mkdir -p /openbao/plugins; \
    tar xzf /tmp/plugin.tar.gz -C /openbao/plugins "${PLUGIN}"; \
    cd /openbao/plugins; \
    grep " ${PLUGIN}\$" /tmp/checksums.txt | sha256sum -c -; \
    sha256sum "${PLUGIN}" > /openbao/plugins/.sha256; \
    chmod 0755 "${PLUGIN}"; \
    chown -R openbao:openbao /openbao/plugins; \
    rm -f /tmp/plugin.tar.gz /tmp/checksums.txt; \
    apk del .fetch

USER openbao
