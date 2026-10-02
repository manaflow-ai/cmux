#!/usr/bin/env bash
# Builds the CEF glue for cmux-next from the pinned artifact:
#   libcef_dll_wrapper.a      CEF's C++ wrapper (from the artifact's libcef_dll/)
#   libcmux_cef_shim.dylib    Packages/macOS/CmuxNext/CEFShim (C ABI for Swift)
#   cmux-cef-helper           the subprocess binary for the helper apps
#
# Usage: build-cef-shim.sh <cef_dir> <cache_dir>
# Prints the output directory on stdout (progress goes to stderr); exits
# non-zero on compile errors. The output is content-addressed,
# <cache_dir>/<artifact>-<key>, where the key hashes the artifact, the shim
# header (the ABI identity) and sources, this script, clang and the target.
# A finished directory is never changed or deleted, so worktrees and
# concurrent builds that share the cache cannot disturb each other: a build
# writes to a private temporary directory and renames it into place; when
# another build got there first, that result is used.
set -euo pipefail

CEF_DIR="${1:?usage: build-cef-shim.sh <cef_dir> <cache_dir>}"
CACHE_DIR="${2:?usage: build-cef-shim.sh <cef_dir> <cache_dir>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHIM_DIR="$REPO_ROOT/Packages/macOS/CmuxNext/CEFShim"
# The public header lives in the Swift target (it is also a SwiftPM resource
# there). Its SHA-256 is the ABI identity on both sides; see the header.
SHIM_HEADER_DIR="$REPO_ROOT/Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/Shim"
SHIM_HEADER="$SHIM_HEADER_DIR/cmux_cef_shim.h"
ABI_ID="$(shasum -a 256 "$SHIM_HEADER" | awk '{print $1}')"
ARCH="${CMUX_CEF_ARCH:-arm64}"
MIN_OS="${CMUX_CEF_MIN_OS:-26.0}"

CXX="$(xcrun --sdk macosx --find clang++)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
key="$(
  {
    cat "$CEF_DIR/CMUX-ARTIFACT.json" 2>/dev/null || cat "$CEF_DIR/archive.json"
    find "$SHIM_DIR" -type f \( -name '*.h' -o -name '*.mm' \) -print0 | sort -z | xargs -0 shasum -a 256
    echo "abi $ABI_ID"
    shasum -a 256 "${BASH_SOURCE[0]}"
    "$CXX" --version | head -n 1
    echo "$ARCH $MIN_OS"
  } | shasum -a 256 | awk '{print $1}'
)"
FINAL_DIR="$CACHE_DIR/$(basename "$CEF_DIR")-${key:0:16}"
complete() { [[ -f "$1/.build-key" && "$(cat "$1/.build-key")" == "$key" && -f "$1/libcmux_cef_shim.dylib" && -x "$1/cmux-cef-helper" ]]; }
if complete "$FINAL_DIR"; then
  echo "$FINAL_DIR"
  exit 0
fi

mkdir -p "$CACHE_DIR"
OUT_DIR="$(mktemp -d "$CACHE_DIR/.building.XXXXXX")"
trap 'rm -rf "$OUT_DIR"' EXIT
echo "==> building CEF shim into $FINAL_DIR" >&2
mkdir -p "$OUT_DIR/obj/wrapper" "$OUT_DIR/obj/shim"

common=(
  -arch "$ARCH" -isysroot "$SDK" -mmacosx-version-min="$MIN_OS" -O2
  -std=c++20 -fno-exceptions -fno-rtti -fno-strict-aliasing -fstack-protector -funwind-tables
  -fvisibility=hidden -fvisibility-inlines-hidden -fobjc-call-cxx-cdtors
  -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS
  -I"$CEF_DIR"
  -Wno-deprecated-declarations -Wno-undefined-var-template
)
export CXX CEF_DIR OUT_DIR
export COMMON_FLAGS="${common[*]}"

# Wrapper: every translation unit under libcef_dll, as its CMake target does.
jobs="$(sysctl -n hw.ncpu)"
(cd "$CEF_DIR/libcef_dll" && find . -type f \( -name '*.cc' -o -name '*.mm' \) -print0) |
  xargs -0 -P "$jobs" -I{} sh -c '
    src="$1"
    obj="$OUT_DIR/obj/wrapper/$(printf "%s" "$src" | sed "s#^\./##; s#/#_#g").o"
    # shellcheck disable=SC2086
    "$CXX" $COMMON_FLAGS -DWRAPPING_CEF_SHARED -c "$CEF_DIR/libcef_dll/$src" -o "$obj"
  ' _ {} || { echo "error: CEF wrapper compile failed" >&2; exit 1; }
libtool -static -no_warning_for_no_symbols -o "$OUT_DIR/libcef_dll_wrapper.a" "$OUT_DIR"/obj/wrapper/*.o

for src in "$SHIM_DIR"/src/*.mm; do
  "$CXX" "${common[@]}" -I"$SHIM_DIR" -I"$SHIM_HEADER_DIR" -DCMUX_CEF_SHIM_ABI_ID="\"$ABI_ID\"" -c "$src" -o "$OUT_DIR/obj/shim/$(basename "$src").o"
done

"$CXX" -arch "$ARCH" -isysroot "$SDK" -mmacosx-version-min="$MIN_OS" -dynamiclib \
  -install_name "@rpath/libcmux_cef_shim.dylib" \
  -o "$OUT_DIR/libcmux_cef_shim.dylib" \
  "$OUT_DIR/obj/shim/shim_process.mm.o" "$OUT_DIR/obj/shim/shim_client.mm.o" "$OUT_DIR/obj/shim/shim_browser.mm.o" \
  "$OUT_DIR/obj/shim/shim_site.mm.o" "$OUT_DIR/obj/shim/shim_devtools.mm.o" \
  "$OUT_DIR/obj/shim/shim_windows.mm.o" "$OUT_DIR/obj/shim/shim_proxy.mm.o" \
  "$OUT_DIR/obj/shim/shim_extensions_ui.mm.o" "$OUT_DIR/obj/shim/shim_webstore.mm.o" \
  "$OUT_DIR/obj/shim/shim_cookie_import.mm.o" \
  "$OUT_DIR/obj/shim/shim_password_import.mm.o" \
  "$OUT_DIR/libcef_dll_wrapper.a" -framework AppKit -framework Cocoa -framework IOSurface -lobjc

"$CXX" -arch "$ARCH" -isysroot "$SDK" -mmacosx-version-min="$MIN_OS" \
  -o "$OUT_DIR/cmux-cef-helper" \
  "$OUT_DIR/obj/shim/helper_main.mm.o" \
  "$OUT_DIR/libcef_dll_wrapper.a" -framework AppKit -framework Cocoa -framework IOSurface

rm -rf "$OUT_DIR/obj"
printf '%s' "$key" > "$OUT_DIR/.build-key"
# Atomic publish: rename(2) fails when the target already exists (another
# build published the same key meanwhile, from the same inputs); keep that.
if ! /usr/bin/python3 -c 'import os, sys; os.rename(sys.argv[1], sys.argv[2])' "$OUT_DIR" "$FINAL_DIR" 2>/dev/null; then
  complete "$FINAL_DIR" || { echo "error: $FINAL_DIR exists but is incomplete" >&2; exit 1; }
fi
# Entries of older inputs: drop those unused for a week (and stale
# temporary directories of crashed builds).
find "$CACHE_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +7 ! -path "$FINAL_DIR" -exec rm -rf {} + 2>/dev/null || true
echo "==> CEF shim ready (abi ${ABI_ID:0:12})" >&2
echo "$FINAL_DIR"
