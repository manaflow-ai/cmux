#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 <cmux-diff-sidecar> [--archs \"arm64 x86_64\"] [--require-signed]" >&2
  exit 2
}

[[ $# -ge 1 ]] || usage
BINARY="$1"
shift
ARCHS="arm64 x86_64"
REQUIRE_SIGNED=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --archs)
      [[ $# -ge 2 ]] || usage
      ARCHS="$2"
      shift 2
      ;;
    --require-signed)
      REQUIRE_SIGNED=1
      shift
      ;;
    *) usage ;;
  esac
done

[[ -f "$BINARY" ]] || { echo "error: missing diff sidecar at $BINARY" >&2; exit 1; }
[[ -x "$BINARY" ]] || { echo "error: diff sidecar is not executable: $BINARY" >&2; exit 1; }

MAX_BYTES="${CMUX_DIFF_SIDECAR_MAX_BYTES:-5242880}"
SIZE_BYTES="$(stat -f %z "$BINARY")"
if (( SIZE_BYTES > MAX_BYTES )); then
  echo "error: diff sidecar is ${SIZE_BYTES} bytes; limit is ${MAX_BYTES} bytes" >&2
  exit 1
fi

for arch in $ARCHS; do
  lipo "$BINARY" -verify_arch "$arch"
  MINOS="$(otool -arch "$arch" -l "$BINARY" | awk '/LC_BUILD_VERSION/{found=1; next} found && /minos / && !printed {print $2; printed=1}')"
  if [[ "$MINOS" != "14.0" ]]; then
    echo "error: $arch diff sidecar has macOS minimum $MINOS, expected 14.0" >&2
    exit 1
  fi
  while IFS= read -r dependency; do
    case "$dependency" in
      /usr/lib/*|/System/Library/*) ;;
      *) echo "error: unexpected $arch dependency: $dependency" >&2; exit 1 ;;
    esac
  done < <(otool -arch "$arch" -L "$BINARY" | tail -n +2 | awk '{print $1}')
  LOCAL_SYMBOLS="$(nm -arch "$arch" -a "$BINARY" 2>/dev/null | awk '$2 ~ /^[NnSsTt]$/ && $3 != "__mh_execute_header" {count++} END {print count+0}')"
  if (( LOCAL_SYMBOLS != 0 )); then
    echo "error: $arch diff sidecar retains ${LOCAL_SYMBOLS} local or debug symbols" >&2
    exit 1
  fi
done

DEBUG_INFO="$(dwarfdump --debug-info "$BINARY" 2>&1)"
if [[ "$DEBUG_INFO" == *"DW_TAG_"* ]]; then
  echo "error: diff sidecar retains embedded DWARF debug information" >&2
  exit 1
fi

if codesign --verify --strict "$BINARY" >/dev/null 2>&1; then
  SIGNING_STATE="signed"
elif (( REQUIRE_SIGNED )); then
  echo "error: diff sidecar is not validly signed" >&2
  exit 1
else
  SIGNING_STATE="unsigned"
fi

HANDSHAKE="$("$BINARY" handshake)"
python3 - "$HANDSHAKE" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
assert payload["id"] == "handshake", payload
assert payload["version"] == 1, payload
assert payload["error"] is None, payload
assert payload["result"]["type"] == "handshake", payload
capabilities = payload["result"]["value"]["capabilities"]
assert "transport.webkit" in capabilities, payload
assert "transport.stdio" in capabilities, payload
assert "transport.fetch" not in capabilities, payload
assert "transport.websocket" not in capabilities, payload
PY

echo "diff sidecar: ${SIZE_BYTES} bytes, architectures: ${ARCHS}, minimum macOS: 14.0, ${SIGNING_STATE}"
