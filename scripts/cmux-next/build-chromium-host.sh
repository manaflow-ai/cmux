#!/usr/bin/env bash
# Builds cmux-chromium-host, the executable of the Chromium Host (behind
# browserHost.helper, plans/cmux-next/chrome-parity/p01-process.md 3.1-3.4), from
# Packages/macOS/CmuxNext/ChromiumHost and the real shim's sources
# (CEFShim/src/shim_*.mm, linked in: the host runs every cmux_shim_* call),
# against one single-arch shim build of build-cef-shim.sh (its
# libcef_dll_wrapper.a) and that build's CEF artifact, and
# libcmux_cef_shim_remote.dylib, the shim ABI cmux loads in host mode
# (ChromiumHost/client, p01-process.md 3.2). The remote shim links no CEF; its
# exports come from client/generated/remote_shim.inc
# (scripts/cmux-next/gen-chromium-host-wire.py), checked here against the
# header's cmux_shim_abi_id. scripts/cmux-next/tests/remote-shim-abi.test.sh
# builds it the same way on any machine.
#
# The host is not part of the Chromium runtime: its sources live outside
# CEFShim and this script is not build-cef-shim.sh, so neither the shim build
# key nor cef-runtime-pack.sh's pack key reads them. An edit to the host never
# makes Release users download the engine again or rebuilds the shim cache.
# embed-cef.sh calls this for every configuration.
#
# Every source compiles with the wrapper's own flags: `common` below is
# build-cef-shim.sh's `common`, copied here so the flags live in no file that
# a shim or pack key hashes. tests/chromium-host-flags.test.sh fails when the
# two differ. The shim's sources get exactly the shim build's flags; the
# host's own (ChromiumHost/src) also -Werror.
#
# ChromiumHost/src/generated/host_dispatch.inc and client/generated/remote_shim.inc
# come from scripts/cmux-next/gen-chromium-host-wire.py and are committed
# (its --check fails when one is stale); a checkout with a stale one builds no host.
#
# Usage: build-chromium-host.sh <cef_dir> <shim_dir> <cache_dir>
#   cef_dir:  the CEF artifact shim_dir was built from (one architecture).
#   shim_dir: that architecture's output of build-cef-shim.sh (not a lipo merge).
#   CMUX_CEF_ARCH / CMUX_CEF_MIN_OS: as for build-cef-shim.sh.
# Prints the output directory (cmux-chromium-host, libcmux_cef_shim_remote.dylib
# and .build-key) on stdout.
# Content-addressed like build-cef-shim.sh: the key hashes the shim build key
# (which covers the artifact, every CEFShim source, the shim header, clang,
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
SHIM_DIR="$REPO_ROOT/Packages/macOS/CmuxNext/CEFShim"
SHIM_SRC="$SHIM_DIR/src"
SHIM_HEADER_DIR="$REPO_ROOT/Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/Shim"
SHIM_HEADER="$SHIM_HEADER_DIR/cmux_cef_shim.h"
REMOTE_INC="$HOST_DIR/client/generated/remote_shim.inc"
ABI_ID="$(shasum -a 256 "$SHIM_HEADER" | awk '{print $1}')"

ARCH="${CMUX_CEF_ARCH:-arm64}"
MIN_OS="${CMUX_CEF_MIN_OS:-14.0}"

for need in .build-key libcef_dll_wrapper.a; do
  [[ -f "$SHIM_OUT/$need" ]] || { echo "error: $SHIM_OUT has no $need (not a single-arch shim build)" >&2; exit 1; }
done
[[ -d "$CEF_DIR/include" ]] || { echo "error: $CEF_DIR is not a CEF artifact (no include/)" >&2; exit 1; }
# A stale generated file carries another header's ABI id: CEFShimLibrary refuses the remote
# shim, and the host refuses the remote shim's HELLO. Both sides must also share one kWireID.
HOST_INC="$HOST_DIR/src/generated/host_dispatch.inc"
for inc in "$REMOTE_INC" "$HOST_INC"; do
  grep -q "kShimAbiID\[\] = \"$ABI_ID\"" "$inc" 2>/dev/null || {
    echo "error: $inc is missing or stale: run python3 scripts/cmux-next/gen-chromium-host-wire.py" >&2
    exit 1
  }
done
[[ "$(grep 'kWireID\[\] = ' "$REMOTE_INC")" == "$(grep 'kWireID\[\] = ' "$HOST_INC")" ]] || {
  echo "error: the host and the remote shim are of different wire generations: run python3 scripts/cmux-next/gen-chromium-host-wire.py" >&2
  exit 1
}

CXX="$(xcrun --sdk macosx --find clang++)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
key="$(
  {
    echo "shim $(cat "$SHIM_OUT/.build-key")"
    echo "$ARCH $MIN_OS"
    (cd "$HOST_DIR" && find src client -type f \( -name '*.h' -o -name '*.mm' -o -name '*.cc' -o -name '*.inc' \) -print0 |
      sort -z | xargs -0 shasum -a 256)
    shasum -a 256 "${BASH_SOURCE[0]}" | awk '{print $1}'
  } | shasum -a 256 | awk '{print $1}'
)"
FINAL_DIR="$CACHE_DIR/host-${key:0:16}"
complete() {
  [[ -f "$1/.build-key" && "$(cat "$1/.build-key")" == "$key" && -x "$1/cmux-chromium-host" &&
    -f "$1/libcmux_cef_shim_remote.dylib" ]]
}
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
  -arch "$ARCH" -isysroot "$SDK" -mmacosx-version-min="$MIN_OS" -O2 -gline-tables-only
  -std=c++20 -fno-exceptions -fno-rtti -fno-strict-aliasing -fstack-protector -funwind-tables
  -fvisibility=hidden -fvisibility-inlines-hidden -fobjc-call-cxx-cdtors
  -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS
  -I"$CEF_DIR"
  -Wno-deprecated-declarations -Wno-undefined-var-template -Werror=unguarded-availability-new
)
mkdir -p "$OUT_DIR/obj"
objects=()
# The real shim, as build-cef-shim.sh compiles it (helper_main.mm is the helpers' own executable).
for src in "$SHIM_SRC"/shim_*.mm; do
  obj="$OUT_DIR/obj/shim_$(basename "$src").o"
  "$CXX" "${common[@]}" -I"$SHIM_DIR" -I"$SHIM_HEADER_DIR" -DCMUX_CEF_SHIM_ABI_ID="\"$ABI_ID\"" -c "$src" -o "$obj"
  objects+=("$obj")
done
# The host's own sources: the dispatcher, the control channel, main.
for src in "$HOST_DIR"/src/*.mm "$HOST_DIR"/src/*.cc; do
  [[ -f "$src" ]] || continue
  obj="$OUT_DIR/obj/host_$(basename "$src").o"
  "$CXX" "${common[@]}" -Werror -Wno-unused-command-line-argument -I"$HOST_DIR/src" -I"$SHIM_SRC" \
    -I"$SHIM_HEADER_DIR" -c "$src" -o "$obj"
  objects+=("$obj")
done
"$CXX" -arch "$ARCH" -isysroot "$SDK" -mmacosx-version-min="$MIN_OS" \
  -o "$OUT_DIR/cmux-chromium-host" "${objects[@]}" \
  "$SHIM_OUT/libcef_dll_wrapper.a" -framework AppKit -framework Cocoa -framework IOSurface -framework QuartzCore \
  -framework Security -lobjc
# The remote shim links neither CEF nor the wrapper, so it takes the flags of
# tests/remote-shim-abi.test.sh, not the wrapper's `common`.
"$CXX" -arch "$ARCH" -isysroot "$SDK" -mmacosx-version-min="$MIN_OS" -O2 -gline-tables-only \
  -std=c++20 -fno-exceptions -fvisibility=hidden -fvisibility-inlines-hidden -Wall -Wextra -Werror \
  -I"$(dirname "$SHIM_HEADER")" -I"$SHIM_SRC" -I"$HOST_DIR/src" -I"$HOST_DIR/client" \
  -dynamiclib -install_name @rpath/libcmux_cef_shim_remote.dylib \
  -o "$OUT_DIR/libcmux_cef_shim_remote.dylib" \
  "$HOST_DIR"/client/*.mm "$HOST_DIR/src/chromium_host_control.cc" -lobjc
# A dSYM beside each binary, as build-cef-shim.sh writes. clang already wrote
# the remote shim's: it compiled and linked in one step, from temporary objects.
for binary in cmux-chromium-host libcmux_cef_shim_remote.dylib; do
  [[ -d "$OUT_DIR/$binary.dSYM" ]] || xcrun dsymutil "$OUT_DIR/$binary" -o "$OUT_DIR/$binary.dSYM" >&2 ||
    { echo "warning: no dSYM for $binary" >&2; rm -rf "$OUT_DIR/$binary.dSYM"; }
done
rm -rf "$OUT_DIR/obj"
printf '%s' "$key" > "$OUT_DIR/.build-key"
if ! /usr/bin/python3 -c 'import os, sys; os.rename(sys.argv[1], sys.argv[2])' "$OUT_DIR" "$FINAL_DIR" 2>/dev/null; then
  complete "$FINAL_DIR" || { echo "error: $FINAL_DIR exists but is incomplete" >&2; exit 1; }
fi
find "$CACHE_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +7 ! -path "$FINAL_DIR" -exec rm -rf {} + 2>/dev/null || true
echo "$FINAL_DIR"
