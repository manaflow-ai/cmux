#!/usr/bin/env bash
set -euo pipefail

tag="${CMUX_TAG:-swmob}"
repo="${CMUX_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
app="${CMUX_SWAPP:-$HOME/Library/Developer/Xcode/DerivedData/cmux-${tag}/Build/Products/Debug/cmux DEV ${tag}.app}"
port="${CMUX_PORT:-9300}"
port_range="${CMUX_PORT_RANGE:-10}"
port_end="${CMUX_PORT_END:-$((port + port_range - 1))}"
dev_origin="${CMUX_DEV_ORIGIN:-http://localhost:${port}}"
bin="$app/Contents/MacOS/cmux DEV"
tag_bundle_id="$(printf '%s' "$tag" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/./g; s/^\.+//; s/\.+$//; s/\.+/./g')"
if [[ -z "$tag_bundle_id" ]]; then
  tag_bundle_id="agent"
fi

if [[ ! -x "$bin" ]]; then
  echo "missing tagged app binary: $bin" >&2
  exit 1
fi

exec env \
  CMUX_BUNDLE_ID="com.cmuxterm.app.debug.${tag_bundle_id}" \
  CMUX_SOCKET_ENABLE=1 \
  CMUX_SOCKET_MODE=allowAll \
  CMUX_SOCKET_PATH="/tmp/cmux-debug-${tag}.sock" \
  CMUXD_UNIX_PATH="$HOME/Library/Application Support/cmux/cmuxd-dev-${tag}.sock" \
  CMUX_DEBUG_LOG="/tmp/cmux-debug-${tag}.log" \
  CMUX_API_BASE_URL="$dev_origin" \
  CMUX_AUTH_WWW_ORIGIN="$dev_origin" \
  CMUX_VM_API_BASE_URL="$dev_origin" \
  CMUX_PORT="$port" \
  CMUX_PORT_RANGE="$port_range" \
  CMUX_PORT_END="$port_end" \
  PORT="$port" \
  CMUX_BUNDLED_CLI_PATH="$app/Contents/Resources/bin/cmux" \
  CMUX_SHELL_INTEGRATION_DIR="$app/Contents/Resources/shell-integration" \
  CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD=1 \
  CMUXTERM_REPO_ROOT="$repo" \
  "$bin"
