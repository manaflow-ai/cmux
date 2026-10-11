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

sanitize_bundle() {
  local raw="$1"
  local cleaned
  cleaned="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/./g; s/^\.+//; s/\.+$//; s/\.+/./g')"
  if [[ -z "$cleaned" ]]; then
    cleaned="agent"
  fi
  printf '%s\n' "$cleaned"
}

sanitize_path() {
  local raw="$1"
  local cleaned
  cleaned="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  if [[ -z "$cleaned" ]]; then
    cleaned="agent"
  fi
  printf '%s\n' "$cleaned"
}

tag_slug="$(sanitize_path "$CMUX_TAG")"
tag_bundle_id="$(sanitize_bundle "$CMUX_TAG")"

socket_path="/tmp/cmux-debug-${tag_slug}.sock"
if [[ ! -S "$socket_path" ]]; then
  cat >&2 <<EOF
Tagged cmux socket not found:
  $socket_path

Launch the tagged app first:
  ./scripts/reload.sh --tag $CMUX_TAG --launch
EOF
  exit 1
fi

# Same default as reload.sh: a checkout that exports CMUX_DERIVED_DATA builds every tag there.
derived_data="${CMUX_DERIVED_DATA:-${HOME}/Library/Developer/Xcode/DerivedData/cmux-${tag_slug}}"
if [[ "$derived_data" != /* ]]; then
  echo "error: CMUX_DERIVED_DATA must be an absolute path, got '$derived_data'" >&2
  exit 1
fi
cli_path="${derived_data}/Build/Products/Debug/cmux DEV ${tag_slug}.app/Contents/Resources/bin/cmux"
# reload.sh --release builds the same tagged app under Build/Products/Release.
release_cli_path="${derived_data}/Build/Products/Release/cmux DEV ${tag_slug}.app/Contents/Resources/bin/cmux"
if [[ ! -x "$cli_path" && -x "$release_cli_path" ]]; then
  cli_path="$release_cli_path"
fi
# A fleet build restored with `cmux-ci publish-hq` lives in the HQ Tag Opener cache.
cached_cli_path="${HOME}/Library/Application Support/cmux/tag-app-cache/cmux-${tag_slug}/cmux DEV ${tag_slug}.app/Contents/Resources/bin/cmux"
if [[ ! -x "$cli_path" && -x "$cached_cli_path" ]]; then
  cli_path="$cached_cli_path"
fi
if [[ ! -x "$cli_path" ]]; then
  cat >&2 <<EOF
Tagged cmux CLI not found:
  $cli_path
  $cached_cli_path

Build the tagged app first:
  ./scripts/reload.sh --tag $CMUX_TAG
EOF
  exit 1
fi

unset CMUX_SOCKET
unset CMUX_SOCKET_PASSWORD
unset CMUX_WORKSPACE_ID
unset CMUX_SURFACE_ID
unset CMUX_TAB_ID
unset CMUX_PANEL_ID
unset CMUXD_UNIX_PATH
unset CMUX_DEBUG_LOG
# The CLI is the cmux-tui binary: a mux socket or terminal id inherited from
# the terminal this runs in would point it at that session, not the tag's
# (it derives cmux-app-<tag> from CMUX_TAG).
unset CMUX_MUX_SOCKET
for name in $(compgen -e); do
  [[ "$name" == CMUX_TUI_* ]] && unset "$name"
done
export CMUX_SOCKET_PATH="$socket_path"
export CMUX_TAG="$tag_slug"
export CMUX_BUNDLE_ID="com.cmuxterm.app.debug.${tag_bundle_id}"
export CMUX_BUNDLED_CLI_PATH="$cli_path"

# DEBUG app routes use the app-owned JSON-lines socket. The bundled CLI's
# `remote rpc` command is for workspace agent relays and does not expose these
# app-local debug methods.
if [[ "${1:-}" == "rpc" ]]; then
  method="${2:-}"
  params="${3:-}"
  [[ -n "$params" ]] || params='{}'
  if [[ -z "$method" ]]; then
    echo "Usage: CMUX_TAG=$CMUX_TAG $0 rpc METHOD [PARAMS_JSON]" >&2
    exit 2
  fi
  CMUX_DEBUG_METHOD="$method" CMUX_DEBUG_PARAMS="$params" CMUX_DEBUG_SOCKET="$socket_path" python3 - <<'PY'
import json
import os
import socket

request = {
    "id": 1,
    "method": os.environ["CMUX_DEBUG_METHOD"],
    "params": json.loads(os.environ["CMUX_DEBUG_PARAMS"]),
}
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.settimeout(30)
    client.connect(os.environ["CMUX_DEBUG_SOCKET"])
    client.sendall((json.dumps(request, separators=(",", ":")) + "\n").encode())
    response = bytearray()
    while not response.endswith(b"\n"):
        chunk = client.recv(65536)
        if not chunk:
            break
        response.extend(chunk)
print(response.decode().strip())
PY
  exit 0
fi
exec "$cli_path" "$@"
