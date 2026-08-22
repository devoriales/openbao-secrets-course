# A single image containing the three things a PKCS#11 seal needs in one place:
# the OpenBao binary, a PKCS#11 library, and the external KMS plugin that talks
# to it.
#
# They have to share a container because PKCS#11 is a C library API, not a
# network protocol. There is no "HSM service" to connect to: OpenBao dlopen()s
# the .so and calls into it in-process. That single fact decides the whole
# layout of this lesson's lab.
#
# Everything here is glibc. The default openbao/openbao image is Alpine (musl),
# and the published plugin binary is dynamically linked against glibc, so that
# combination cannot work. openbao/openbao-ubi is the glibc build.
#
#   docker build -t openbao-pkcs11:lab .
#   k3d image import openbao-pkcs11:lab -c openbao-dev

ARG BAO_VERSION=2.6.2

FROM openbao/openbao-ubi:${BAO_VERSION} AS bao

FROM debian:trixie-slim

ARG TARGETARCH
ARG PLUGIN_VERSION=0.1.0

# softhsm2 gives us /usr/lib/softhsm/libsofthsm2.so, which is a symlink to the
# architecture-specific path, so the seal config is the same on amd64 and arm64.
# opensc gives us pkcs11-tool, which is what actually generates the AES key:
# softhsm2-util can create tokens and import keys but not generate a symmetric
# key in place.
# iproute2 is for the entrypoint's optional BAO_*_INTERFACE address lookup.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      softhsm2 opensc iproute2 ca-certificates curl bash \
 && rm -rf /var/lib/apt/lists/*

# The chart's command and the entrypoint's chown logic both assume this exact
# user, and the token directory has to be writable by it.
RUN groupadd --gid 1000 openbao \
 && useradd --uid 100 --gid 1000 --home-dir /home/openbao --create-home openbao

COPY --from=bao /usr/bin/bao /usr/bin/bao
COPY --from=bao /usr/local/bin/docker-entrypoint.sh /usr/local/bin/openbao-entrypoint.sh

# The stock entrypoint ships with a #!/bin/sh shebang but uses the bash-only [[
# builtin. On the UBI base /bin/sh is bash, so it works there and nobody
# notices. On Debian /bin/sh is dash, where [[ is a syntax error and the pod
# dies before OpenBao is ever invoked.
RUN sed -i '1s|.*|#!/bin/bash|' /usr/local/bin/openbao-entrypoint.sh \
 && chmod +x /usr/local/bin/openbao-entrypoint.sh

# The chart calls /usr/local/bin/docker-entrypoint.sh by name and overrides the
# image's ENTRYPOINT, so our token-provisioning wrapper has to occupy that
# path rather than being wired in through ENTRYPOINT.
COPY hsm-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# The plugin is fetched by release tag and verified against the checksums file
# published alongside it. That same hash goes in the plugin stanza, which is
# how OpenBao refuses to execute a plugin that changed underneath it.
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) PLUGIN_ARCH=linux_amd64_v1 ;; \
      arm64) PLUGIN_ARCH=linux_arm64_v8 ;; \
      *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    BASE="https://github.com/openbao/openbao-plugins/releases/download/kms-pkcs11-v${PLUGIN_VERSION}"; \
    PLUGIN="openbao-plugin-kms-pkcs11_${PLUGIN_ARCH}"; \
    curl -fsSLo /tmp/plugin.tar.gz "${BASE}/${PLUGIN}.tar.gz"; \
    curl -fsSLo /tmp/checksums.txt "${BASE}/checksums-kms-pkcs11.txt"; \
    mkdir -p /openbao/plugins; \
    tar xzf /tmp/plugin.tar.gz -C /openbao/plugins "${PLUGIN}"; \
    cd /openbao/plugins; \
    grep " ${PLUGIN}\$" /tmp/checksums.txt | sha256sum -c -; \
    sha256sum "${PLUGIN}" > /openbao/plugins/.sha256; \
    rm -f /tmp/plugin.tar.gz /tmp/checksums.txt; \
    chmod 0755 "/openbao/plugins/${PLUGIN}"

# Debian installs /etc/softhsm as root:softhsm mode 0750 and puts nobody in the
# softhsm group, so uid 100 cannot read the packaged config. SoftHSM reports
# that as "Could not load the SoftHSM configuration", which says nothing about
# permissions and sends you looking at the file's contents instead.
COPY --chown=openbao:openbao softhsm2.conf /openbao/softhsm2.conf
ENV SOFTHSM2_CONF=/openbao/softhsm2.conf

# The token store lives under /openbao/data, which is the chart's persistent
# volume. It must survive a pod restart, or the key that encrypted the root key
# goes with it and the barrier is unopenable.
RUN mkdir -p /openbao/data/softhsm-tokens /openbao/config /openbao/logs /openbao/file \
 && chown -R openbao:openbao /openbao

USER openbao
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["bao", "server", "-config=/openbao/config"]
