#!/usr/bin/env bash
# Builds cmux-chromium-host, the executable of the Chromium host app
# (prototype behind browserHost.helperPrototype,
# plans/cmux-next/cef-helper-app-DESIGN.md), from
# Packages/macOS/CmuxNext/ChromiumHost against one single-arch shim build of
# build-cef-shim.sh (its libcef_dll_wrapper.a) and that build's CEF artifact.
#
# The host is not part of the Chromium runtime: its sources live outside
# CEFShim and this script is not build-cef-shim.sh, so neither the shim build
# key nor cef-runtime-pack.sh's pack key reads them. An edit to the host never
# makes Release users download the engine again or rebuilds the shim cache.
# embed-cef.sh calls this for Debug builds only.
#
# The host links libcef_dll_wrapper.a, so it compiles with the wrapper's own
# flags: `common` below is build-cef-shim.sh's `common`, copied here so the
# flags live in no file that a shim or pack key hashes.
# tests/chromium-host-flags.test.sh fails when the two differ.
#
# Usage: build-chromium-host.sh <cef_dir> <shim_dir> <cache_dir>
#   cef_dir:  the CEF artifact shim_dir was built from (one architecture).
#   shim_dir: that architecture's output of build-cef-shim.sh (not a lipo merge).
#   CMUX_CEF_ARCH / CMUX_CEF_MIN_OS: as for build-cef-shim.sh.
# Prints the output directory (cmux-chromium-host and .build-key) on stdout.
# Content-addressed like build-cef-shim.sh: the key hashes the shim build key
# (which covers the artifact, the CEFShim headers the host includes, clang,
# the architecture and the minimum macOS), the host sources and this script
# (so the flags). A finished directory is never changed; a build renames a
# private temporary directory into place.
set -euo pipefail

usage="usage: build-chromium-host.sh <cef_dir> <shim_dir> <cache_dir>"
CEF_DIR="${1:?$usage}"
SHIM_OUT="${2:?$usage}"
CACHE_DIR="${3:?$usage}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOST_DIR="$REPO_ROOT/Packages/macOS/CmuxNext/ChromiumHost"
SHIM_SRC="$REPO_ROOT/Packages/macOS/CmuxNext/CEFShim/src"

ARCH="${CMUX_CEF_ARCH:-arm64}"
MIN_OS="${CMUX_CEF_MIN_OS:-14.0}"

for need in .build-key libcef_dll_wrapper.a; do
  [[ -f "$SHIM_OUT/$need" ]] || { echo "error: $SHIM_OUT has no $need (not a single-arch shim build)" >&2; exit 1; }
done
[[ -d "$CEF_DIR/include" ]] || { echo "error: $CEF_DIR is not a CEF artifact (no include/)" >&2; exit 1; }

CXX="$(xcrun --sdk macosx --find clang++)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
key="$(
  {
    echo "shim $(cat "$SHIM_OUT/.build-key")"
    echo "$ARCH $MIN_OS"
    (cd "$HOST_DIR/src" && find . -type f \( -name '*.h' -o -name '*.mm' \) -print0 | sort -z | xargs -0 shasum -a 256)
    shasum -a 256 "${BASH_SOURCE[0]}" | awk '{print $1}'
  } | shasum -a 256 | awk '{print $1}'
)"
FINAL_DIR="$CACHE_DIR/host-${key:0:16}"
complete() { [[ -f "$1/.build-key" && "$(cat "$1/.build-key")" == "$key" && -x "$1/cmux-chromium-host" ]]; }
if complete "$FINAL_DIR"; then
  echo "$FINAL_DIR"
  exit 0
fi

mkdir -p "$CACHE_DIR"
OUT_DIR="$(mktemp -d "$CACHE_DIR/.building.XXXXXX")"
trap 'rm -rf "$OUT_DIR"' EXIT
echo "==> building the Chromium host into $FINAL_DIR" >&2
# build-cef-shim.sh's `common`, unchanged (tests/chromium-host-flags.test.sh).
common=(
  -arch "$ARCH" -isysroot "$SDK" -mmacosx-version-min="$MIN_OS" -O2
  -std=c++20 -fno-exceptions -fno-rtti -fno-strict-aliasing -fstack-protector -funwind-tables
  -fvisibility=hidden -fvisibility-inlines-hidden -fobjc-call-cxx-cdtors
  -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS
  -I"$CEF_DIR"
  -Wno-deprecated-declarations -Wno-undefined-var-template -Werror=unguarded-availability-new
)
"$CXX" "${common[@]}" -I"$SHIM_SRC" \
  -o "$OUT_DIR/cmux-chromium-host" \
  "$HOST_DIR/src/browser_host_main.mm" \
  "$SHIM_OUT/libcef_dll_wrapper.a" -framework AppKit -framework Cocoa -framework IOSurface -framework QuartzCore
printf '%s' "$key" > "$OUT_DIR/.build-key"
if ! /usr/bin/python3 -c 'import os, sys; os.rename(sys.argv[1], sys.argv[2])' "$OUT_DIR" "$FINAL_DIR" 2>/dev/null; then
  complete "$FINAL_DIR" || { echo "error: $FINAL_DIR exists but is incomplete" >&2; exit 1; }
fi
find "$CACHE_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +7 ! -path "$FINAL_DIR" -exec rm -rf {} + 2>/dev/null || true
echo "$FINAL_DIR"
