#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: scripts/build-vnc-helper.sh --output-dir <dir> [--configuration Debug|Release] [--arch <arch> | --universal]

Builds the cmux VNC helper and copies cmux-vnc-helper plus libRoyalVNCKit.dylib
into the app bundle's Contents/Resources/bin directory.
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE_PATH="$REPO_ROOT/Packages/CMUXVNCHelper"
CONFIGURATION="Debug"
OUTPUT_DIR=""
ARCH=""
UNIVERSAL=0

require_value() {
  local flag="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    echo "error: $flag requires a value" >&2
    usage
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration|-c)
      require_value "$1" "${2:-}"
      CONFIGURATION="${2:-}"
      shift 2
      ;;
    --output-dir)
      require_value "$1" "${2:-}"
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --arch)
      require_value "$1" "${2:-}"
      ARCH="${2:-}"
      shift 2
      ;;
    --universal)
      UNIVERSAL=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$OUTPUT_DIR" ]]; then
  echo "error: --output-dir is required" >&2
  usage
  exit 2
fi
if [[ "$UNIVERSAL" == "1" && -n "$ARCH" ]]; then
  echo "error: --arch and --universal cannot be combined" >&2
  exit 2
fi

case "$CONFIGURATION" in
  Debug|debug)
    SWIFT_CONFIGURATION="debug"
    ;;
  Release|release)
    SWIFT_CONFIGURATION="release"
    ;;
  *)
    echo "error: unsupported configuration $CONFIGURATION" >&2
    exit 2
    ;;
esac

build_for_arch() {
  local arch="$1"
  swift build \
    --package-path "$PACKAGE_PATH" \
    --product cmux-vnc-helper \
    --configuration "$SWIFT_CONFIGURATION" \
    --arch "$arch" >/dev/null
  swift build \
    --package-path "$PACKAGE_PATH" \
    --configuration "$SWIFT_CONFIGURATION" \
    --arch "$arch" \
    --show-bin-path
}

build_native() {
  swift build \
    --package-path "$PACKAGE_PATH" \
    --product cmux-vnc-helper \
    --configuration "$SWIFT_CONFIGURATION" >/dev/null
  swift build \
    --package-path "$PACKAGE_PATH" \
    --configuration "$SWIFT_CONFIGURATION" \
    --show-bin-path
}

install_single_arch() {
  local bin_path="$1"
  mkdir -p "$OUTPUT_DIR"
  install -m 755 "$bin_path/cmux-vnc-helper" "$OUTPUT_DIR/cmux-vnc-helper"
  install -m 755 "$bin_path/libRoyalVNCKit.dylib" "$OUTPUT_DIR/libRoyalVNCKit.dylib"
}

if [[ "$UNIVERSAL" == "1" ]]; then
  ARM64_BIN_PATH="$(build_for_arch arm64)"
  X86_64_BIN_PATH="$(build_for_arch x86_64)"
  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-vnc-helper.XXXXXX")"
  trap 'rm -rf "$TMP_DIR"' EXIT
  mkdir -p "$OUTPUT_DIR"
  lipo -create \
    "$ARM64_BIN_PATH/cmux-vnc-helper" \
    "$X86_64_BIN_PATH/cmux-vnc-helper" \
    -output "$TMP_DIR/cmux-vnc-helper"
  lipo -create \
    "$ARM64_BIN_PATH/libRoyalVNCKit.dylib" \
    "$X86_64_BIN_PATH/libRoyalVNCKit.dylib" \
    -output "$TMP_DIR/libRoyalVNCKit.dylib"
  install -m 755 "$TMP_DIR/cmux-vnc-helper" "$OUTPUT_DIR/cmux-vnc-helper"
  install -m 755 "$TMP_DIR/libRoyalVNCKit.dylib" "$OUTPUT_DIR/libRoyalVNCKit.dylib"
elif [[ -n "$ARCH" ]]; then
  BIN_PATH="$(build_for_arch "$ARCH")"
  install_single_arch "$BIN_PATH"
else
  BIN_PATH="$(build_native)"
  install_single_arch "$BIN_PATH"
fi

if [[ ! -x "$OUTPUT_DIR/cmux-vnc-helper" ]]; then
  echo "error: cmux-vnc-helper was not created in $OUTPUT_DIR" >&2
  exit 1
fi
if [[ ! -f "$OUTPUT_DIR/libRoyalVNCKit.dylib" ]]; then
  echo "error: libRoyalVNCKit.dylib was not created in $OUTPUT_DIR" >&2
  exit 1
fi

echo "Built VNC helper at $OUTPUT_DIR/cmux-vnc-helper"
