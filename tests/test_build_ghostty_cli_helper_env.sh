#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-ghostty-helper-env.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_ZIG="$TMP_DIR/zig"
FAKE_GHOSTTY_DIR="$TMP_DIR/ghostty"
OUTPUT_PATH="$TMP_DIR/ghostty-helper"
METAL_BIN="$TMP_DIR/Metal.xctoolchain/usr/bin"
SWB_BIN="$TMP_DIR/SWBUniversalPlatformPlugin.bundle/Contents/Resources"

mkdir -p "$METAL_BIN" "$SWB_BIN" "$FAKE_GHOSTTY_DIR"
touch "$FAKE_GHOSTTY_DIR/build.zig"

cat > "$FAKE_ZIG" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "version" ]]; then
  echo "0.15.2"
  exit 0
fi

case "${PATH:-}" in
  *Metal.xctoolchain*|*SWBUniversalPlatformPlugin.bundle*)
    echo "FAIL: Xcode script-phase toolchain paths leaked into zig PATH" >&2
    exit 1
    ;;
esac

for name in \
  ARCHS \
  ARCHS_STANDARD \
  BUILT_PRODUCTS_DIR \
  CURRENT_ARCH \
  LD_RUNPATH_SEARCH_PATHS \
  LIBRARY_SEARCH_PATHS \
  MACOSX_DEPLOYMENT_TARGET \
  OBJROOT \
  SDKROOT \
  TOOLCHAINS \
  TOOLCHAIN_DIR \
  TOOLCHAIN_VERSION
do
  if printenv "$name" >/dev/null; then
    echo "FAIL: $name leaked into zig environment" >&2
    exit 1
  fi
done

prefix=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      prefix="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ -z "$prefix" ]]; then
  echo "FAIL: fake zig did not receive --prefix" >&2
  exit 1
fi

mkdir -p "$prefix/bin"
printf '#!/bin/sh\nexit 0\n' > "$prefix/bin/ghostty"
chmod +x "$prefix/bin/ghostty"
EOF
chmod +x "$FAKE_ZIG"

export CMUX_ZIG="$FAKE_ZIG"
export CMUX_GHOSTTY_DIR="$FAKE_GHOSTTY_DIR"
export PATH="$METAL_BIN:$SWB_BIN:$PATH"
export ARCHS="arm64 x86_64"
export ARCHS_STANDARD="arm64 x86_64"
export BUILT_PRODUCTS_DIR="$TMP_DIR/products"
export CURRENT_ARCH="undefined_arch"
export LD_RUNPATH_SEARCH_PATHS=" @executable_path/../Frameworks"
export LIBRARY_SEARCH_PATHS="$TMP_DIR/products "
export MACOSX_DEPLOYMENT_TARGET="14.0"
export OBJROOT="$TMP_DIR/Intermediates.noindex"
export SDKROOT="$TMP_DIR/MacOSX.sdk"
export TOOLCHAINS="com.apple.dt.toolchain.Metal.32023.883 com.apple.dt.toolchain.XcodeDefault"
export TOOLCHAIN_DIR="$TMP_DIR/Metal.xctoolchain"
export TOOLCHAIN_VERSION="32023.883"

"$ROOT_DIR/scripts/build-ghostty-cli-helper.sh" \
  --target aarch64-macos \
  --output "$OUTPUT_PATH"

test -x "$OUTPUT_PATH"

echo "PASS: Ghostty CLI helper build sanitizes Xcode toolchain environment"
