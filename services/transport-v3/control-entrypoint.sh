#!/bin/sh
set -eu
umask 077
: "${CMUX_V3_SIGNER_SEED_B64:?CMUX_V3_SIGNER_SEED_B64 is required}"
mkdir -p /run/cmux-v3
printf '%s' "$CMUX_V3_SIGNER_SEED_B64" | base64 -d > /run/cmux-v3/signer-seed
test "$(wc -c < /run/cmux-v3/signer-seed | tr -d ' ')" = 32
export CMUX_V3_SIGNER_SEED_FILE=/run/cmux-v3/signer-seed
exec /usr/local/bin/cmux-v3-control-server "$@"
