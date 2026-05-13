#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${CMUX_TAG:-}" ]]; then
  cat >&2 <<'EOF'
CMUX_TAG is required.

Usage:
  CMUX_TAG=<tag> scripts/cmux-debug-cli.sh <cmux-command> [args...]

Example:
  CMUX_TAG=codext scripts/cmux-debug-cli.sh list-workspaces
EOF
  exit 2
fi

if [[ ! "$CMUX_TAG" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Invalid CMUX_TAG: $CMUX_TAG" >&2
  exit 2
fi

if [[ $# -eq 0 ]]; then
  echo "Usage: CMUX_TAG=$CMUX_TAG scripts/cmux-debug-cli.sh <cmux-command> [args...]" >&2
  exit 2
fi

socket_path="/tmp/cmux-debug-${CMUX_TAG}.sock"
if [[ ! -S "$socket_path" ]]; then
  cat >&2 <<EOF
Tagged cmux socket not found:
  $socket_path

Launch the tagged app first:
  ./scripts/reload.sh --tag $CMUX_TAG --launch
EOF
  exit 1
fi

cli_path="${HOME}/Library/Developer/Xcode/DerivedData/cmux-${CMUX_TAG}/Build/Products/Debug/cmux DEV ${CMUX_TAG}.app/Contents/Resources/bin/cmux"
if [[ ! -x "$cli_path" ]]; then
  cat >&2 <<EOF
Tagged cmux CLI not found:
  $cli_path

Build the tagged app first:
  ./scripts/reload.sh --tag $CMUX_TAG
EOF
  exit 1
fi

unset CMUX_SOCKET
export CMUX_SOCKET_PATH="$socket_path"
exec "$cli_path" "$@"
