#!/usr/bin/env bash
set -euo pipefail

OUTPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT="${2:-}"
      if [[ -z "$OUTPUT" ]]; then
        echo "error: --output requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    -h|--help)
      echo "Usage: scripts/build-agent-launcher-tui.sh --output <path>"
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$OUTPUT" ]]; then
  echo "error: --output is required" >&2
  exit 1
fi

if ! command -v go >/dev/null 2>&1; then
  echo "error: go is required to build cmux-agent-launcher-tui" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SRC_DIR="${ROOT_DIR}/Tools/agent-launcher-tui"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$(dirname "$OUTPUT")"

build_arch() {
  local goarch="$1"
  local out="$2"
  (
    cd "$SRC_DIR"
    GOOS=darwin GOARCH="$goarch" CGO_ENABLED=0 go build \
      -trimpath \
      -buildvcs=false \
      -ldflags="-s -w" \
      -o "$out" .
  )
}

HAS_ARM64=0
HAS_X86_64=0
if [[ -z "${ARCHS:-}" ]]; then
  case "$(uname -m)" in
    x86_64) HAS_X86_64=1 ;;
    *) HAS_ARM64=1 ;;
  esac
else
  ARCHS_LIST=" ${ARCHS} "
  case "$ARCHS_LIST" in
    *" arm64 "*) HAS_ARM64=1 ;;
  esac
  case "$ARCHS_LIST" in
    *" x86_64 "*) HAS_X86_64=1 ;;
  esac
fi

if [[ "$HAS_ARM64" -eq 1 && "$HAS_X86_64" -eq 1 ]]; then
  build_arch arm64 "$TMP_DIR/cmux-agent-launcher-tui-arm64"
  build_arch amd64 "$TMP_DIR/cmux-agent-launcher-tui-amd64"
  lipo -create "$TMP_DIR/cmux-agent-launcher-tui-arm64" "$TMP_DIR/cmux-agent-launcher-tui-amd64" -output "$OUTPUT"
elif [[ "$HAS_X86_64" -eq 1 ]]; then
  build_arch amd64 "$OUTPUT"
else
  build_arch arm64 "$OUTPUT"
fi

chmod +x "$OUTPUT"
