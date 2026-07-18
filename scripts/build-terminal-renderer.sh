#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE_DIR="$REPO_ROOT/Packages/macOS/CmuxTerminalRenderer"
OUTPUT_PATH=""
CONFIGURATION="release"
ARCHITECTURES=""
SIGN_IDENTITY="${CMUX_TERMINAL_RENDERER_SIGN_IDENTITY:--}"
SHOULD_SIGN=1
ENTITLEMENTS_PATH="$REPO_ROOT/Resources/cmux-terminal-backend.entitlements"
SIGNING_IDENTIFIER="com.cmuxterm.cmux-terminal-renderer"
ZIG_BIN="${ZIG:-/opt/homebrew/opt/zig@0.15/bin/zig}"

usage() {
  echo "Usage: ./scripts/build-terminal-renderer.sh --output <path> [--configuration debug|release] [--architectures \"arm64 x86_64\"] [--sign-identity <identity> | --skip-signing] [--entitlements <path>]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --configuration)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      CONFIGURATION="$2"
      shift 2
      ;;
    --architectures)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      ARCHITECTURES="$2"
      shift 2
      ;;
    --sign-identity)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      SIGN_IDENTITY="$2"
      SHOULD_SIGN=1
      shift 2
      ;;
    --skip-signing)
      SHOULD_SIGN=0
      shift
      ;;
    --entitlements)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      ENTITLEMENTS_PATH="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$OUTPUT_PATH" ]] || { echo "error: --output is required" >&2; exit 2; }
case "$CONFIGURATION" in
  debug|release) ;;
  *) echo "error: --configuration must be debug or release" >&2; exit 2 ;;
esac
[[ -x "$ZIG_BIN" ]] || { echo "error: Zig 0.15 is required at $ZIG_BIN" >&2; exit 1; }
[[ -f "$ENTITLEMENTS_PATH" ]] || { echo "error: renderer entitlements are missing: $ENTITLEMENTS_PATH" >&2; exit 1; }

if [[ "${CMUX_TERMINAL_RENDERER_SKIP_GHOSTTYKIT:-0}" != "1" ]]; then
  PATH="$(dirname "$ZIG_BIN"):$PATH" \
    CMUX_GHOSTTYKIT_NO_PREBUILT="${CMUX_GHOSTTYKIT_NO_PREBUILT:-0}" \
    "$REPO_ROOT/scripts/ensure-ghosttykit.sh"
fi
[[ -d "$REPO_ROOT/GhosttySceneRendererKit.xcframework" ]] || {
  echo "error: GhosttySceneRendererKit.xcframework is missing" >&2
  exit 1
}

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-terminal-renderer.XXXXXX")"
cleanup() {
  case "$TEMP_DIR" in
    "${TMPDIR:-/tmp}"/cmux-terminal-renderer.*) rm -rf "$TEMP_DIR" ;;
  esac
}
trap cleanup EXIT

mkdir -p "$(dirname "$OUTPUT_PATH")"
read -r -a BUILD_ARCHITECTURES <<< "${ARCHITECTURES:-$(uname -m)}"
BUILT_SLICES=()
for architecture in "${BUILD_ARCHITECTURES[@]}"; do
  case "$architecture" in
    arm64) triple="arm64-apple-macosx14.0" ;;
    x86_64) triple="x86_64-apple-macosx14.0" ;;
    *) echo "error: unsupported architecture $architecture" >&2; exit 2 ;;
  esac
  scratch="$REPO_ROOT/.build/terminal-renderer-$CONFIGURATION-$architecture"
  xcrun swift build \
    --package-path "$PACKAGE_DIR" \
    --scratch-path "$scratch" \
    --configuration "$CONFIGURATION" \
    --triple "$triple" \
    --product cmux-terminal-renderer
  bin_path="$(xcrun swift build \
    --package-path "$PACKAGE_DIR" \
    --scratch-path "$scratch" \
    --configuration "$CONFIGURATION" \
    --triple "$triple" \
    --show-bin-path)"
  slice="$TEMP_DIR/cmux-terminal-renderer-$architecture"
  /usr/bin/install -m 0755 "$bin_path/cmux-terminal-renderer" "$slice"
  BUILT_SLICES+=("$slice")
done

if [[ ${#BUILT_SLICES[@]} -eq 1 ]]; then
  /usr/bin/install -m 0755 "${BUILT_SLICES[0]}" "$OUTPUT_PATH"
else
  /usr/bin/lipo -create "${BUILT_SLICES[@]}" -output "$OUTPUT_PATH"
  chmod 0755 "$OUTPUT_PATH"
fi

"$REPO_ROOT/scripts/audit-terminal-renderer-linkage.sh" \
  --binary "$OUTPUT_PATH" \
  --xcframework "$REPO_ROOT/GhosttySceneRendererKit.xcframework"

if [[ "$SHOULD_SIGN" -eq 1 ]]; then
  /usr/bin/codesign \
    --force \
    --options runtime \
    --identifier "$SIGNING_IDENTIFIER" \
    --sign "$SIGN_IDENTITY" \
    --timestamp=none \
    --generate-entitlement-der \
    --entitlements "$ENTITLEMENTS_PATH" \
    "$OUTPUT_PATH" >/dev/null
fi
