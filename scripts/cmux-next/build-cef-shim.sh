#!/usr/bin/env bash
# Builds the CEF glue for cmux-next from the pinned artifact:
#   libcef_dll_wrapper.a      CEF's C++ wrapper (from the artifact's libcef_dll/)
#   libcmux_cef_shim.dylib    Packages/macOS/CmuxNext/CEFShim (C ABI for Swift)
#   cmux-cef-helper           the subprocess binary for the helper apps
#
# Usage: build-cef-shim.sh <cef_dir> <out_dir>
# Prints nothing but progress; exits non-zero on compile errors. Reuses an
# existing build when the inputs (artifact, shim sources, this script, clang)
# are unchanged, so it is cheap to call from every Xcode build.
set -euo pipefail

CEF_DIR="${1:?usage: build-cef-shim.sh <cef_dir> <out_dir>}"
OUT_DIR="${2:?usage: build-cef-shim.sh <cef_dir> <out_dir>}"
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
stamp="$OUT_DIR/.build-key"
if [[ -f "$stamp" && "$(cat "$stamp")" == "$key" && -f "$OUT_DIR/libcmux_cef_shim.dylib" && -x "$OUT_DIR/cmux-cef-helper" ]]; then
  exit 0
fi

echo "==> building CEF shim into $OUT_DIR"
rm -rf "$OUT_DIR"
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
  "$OUT_DIR/libcef_dll_wrapper.a" -framework AppKit -framework Cocoa -framework IOSurface -lobjc

"$CXX" -arch "$ARCH" -isysroot "$SDK" -mmacosx-version-min="$MIN_OS" \
  -o "$OUT_DIR/cmux-cef-helper" \
  "$OUT_DIR/obj/shim/helper_main.mm.o" \
  "$OUT_DIR/libcef_dll_wrapper.a" -framework AppKit -framework Cocoa -framework IOSurface

rm -rf "$OUT_DIR/obj"
printf '%s' "$key" > "$stamp"
echo "==> CEF shim ready (abi ${ABI_ID:0:12})"
