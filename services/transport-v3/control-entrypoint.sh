#!/bin/sh
set -eu
umask 077
: "${CMUX_V3_SIGNER_SEED_B64:?CMUX_V3_SIGNER_SEED_B64 is required}"
seed_file=/tmp/cmux-v3-signer-seed
printf '%s' "$CMUX_V3_SIGNER_SEED_B64" | base64 -d > "$seed_file"
chmod 600 "$seed_file"
test "$(wc -c < "$seed_file" | tr -d ' ')" = 32
export CMUX_V3_SIGNER_SEED_FILE="$seed_file"
exec /usr/local/bin/cmux-v3-control-server "$@"
