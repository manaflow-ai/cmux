#!/usr/bin/env bash
# Builds cmux-chromium-host, the executable of the Chromium host app
# (prototype behind browserHost.helperPrototype,
# plans/cmux-next/cef-helper-app-DESIGN.md), from
# Packages/macOS/CmuxNext/ChromiumHost against one shim build of
# build-cef-shim.sh: its libcef_dll_wrapper.a and its compile flags.
#
# The host is not part of the Chromium runtime: its sources live outside
# CEFShim and this script is not build-cef-shim.sh, so neither the shim build
# key nor cef-runtime-pack.sh's pack key reads them. An edit to the host never
# makes Release users download the engine again or rebuilds the shim cache.
# embed-cef.sh calls this for Debug builds only.
#
# Usage: build-chromium-host.sh <shim_dir> <cache_dir>
#   shim_dir: one architecture's output of build-cef-shim.sh (not a lipo merge).
# Prints the output directory (cmux-chromium-host and .build-key) on stdout.
# Content-addressed like build-cef-shim.sh: the key hashes the shim build key
# (which covers the artifact, the CEFShim headers the host includes, the
# flags, clang and the target), the host sources and this script. A finished
# directory is never changed; a build renames a private temporary directory
# into place.
set -euo pipefail

SHIM_OUT="${1:?usage: build-chromium-host.sh <shim_dir> <cache_dir>}"
CACHE_DIR="${2:?usage: build-chromium-host.sh <shim_dir> <cache_dir>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOST_DIR="$REPO_ROOT/Packages/macOS/CmuxNext/ChromiumHost"
SHIM_SRC="$REPO_ROOT/Packages/macOS/CmuxNext/CEFShim/src"

for need in .build-key compile-flags libcef_dll_wrapper.a; do
  [[ -f "$SHIM_OUT/$need" ]] || { echo "error: $SHIM_OUT has no $need (not a single-arch shim build)" >&2; exit 1; }
done
flags=()
while IFS= read -r flag; do flags+=("$flag"); done < "$SHIM_OUT/compile-flags"

CXX="$(xcrun --sdk macosx --find clang++)"
key="$(
  {
    echo "shim $(cat "$SHIM_OUT/.build-key")"
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
"$CXX" "${flags[@]}" -I"$SHIM_SRC" \
  -o "$OUT_DIR/cmux-chromium-host" \
  "$HOST_DIR/src/browser_host_main.mm" \
  "$SHIM_OUT/libcef_dll_wrapper.a" -framework AppKit -framework Cocoa -framework IOSurface -framework QuartzCore
printf '%s' "$key" > "$OUT_DIR/.build-key"
if ! /usr/bin/python3 -c 'import os, sys; os.rename(sys.argv[1], sys.argv[2])' "$OUT_DIR" "$FINAL_DIR" 2>/dev/null; then
  complete "$FINAL_DIR" || { echo "error: $FINAL_DIR exists but is incomplete" >&2; exit 1; }
fi
find "$CACHE_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +7 ! -path "$FINAL_DIR" -exec rm -rf {} + 2>/dev/null || true
echo "$FINAL_DIR"
