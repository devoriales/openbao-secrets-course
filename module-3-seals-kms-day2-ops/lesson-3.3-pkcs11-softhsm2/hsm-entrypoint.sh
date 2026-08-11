#!/bin/bash
# Installed as /usr/local/bin/docker-entrypoint.sh, which is the path the
# OpenBao Helm chart invokes. It makes sure a SoftHSM token exists, then hands
# over to the stock OpenBao entrypoint unchanged.
#
# Why the token is created here and the key is not
# ------------------------------------------------
# A real HSM already has a partition before OpenBao ever talks to it. Somebody
# provisioned the appliance, created the slot and handed you a PIN. SoftHSM has
# no such history, so something has to play that part, and doing it at
# container start is the closest honest analogue.
#
# The KEY is a different matter and is deliberately NOT created here. OpenBao
# never generates PKCS#11 key material, unlike a Transit or cloud KMS seal
# where the backend will make a key on demand. Generating it is an operator
# step that has to happen before `bao operator init`, and the lesson leaves it
# exposed rather than hiding it behind automation, because getting the order
# wrong destroys the instance.
set -e

TOKEN_LABEL="${HSM_TOKEN_LABEL:-openbao}"
SO_PIN="${BAO_HSM_SO_PIN:-5678}"
PIN="${BAO_HSM_PIN:?BAO_HSM_PIN must be set}"

# The persistent volume mounts over the image's copy of this directory, so it
# is empty on a first boot and has to be recreated.
TOKEN_DIR="$(sed -n 's/^directories.tokendir *= *//p' "${SOFTHSM2_CONF}" | tr -d ' ')"
mkdir -p "${TOKEN_DIR}"

if softhsm2-util --show-slots 2>/dev/null | grep -q "Label: *${TOKEN_LABEL}\b"; then
    echo "hsm-entrypoint: token '${TOKEN_LABEL}' already present in ${TOKEN_DIR}"
else
    echo "hsm-entrypoint: initialising token '${TOKEN_LABEL}' in ${TOKEN_DIR}"
    softhsm2-util --init-token --free \
        --label "${TOKEN_LABEL}" --so-pin "${SO_PIN}" --pin "${PIN}"
fi

exec /usr/local/bin/openbao-entrypoint.sh "$@"
