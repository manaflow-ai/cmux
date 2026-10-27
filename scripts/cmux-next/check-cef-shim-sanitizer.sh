#!/usr/bin/env bash
# check-cef-shim-sanitizer.sh <app bundle> <main executable>
# An instrumented CEF shim (build-cef-shim.sh with CMUX_CEF_SHIM_SANITIZE, p10-stability-162) loads its sanitizer
# runtime, libclang_rt.<kind>_osx_dynamic.dylib; it belongs only in a sanitizer app, whose main executable loads that
# runtime first. This fails when Contents/Frameworks/libcmux_cef_shim.dylib loads a runtime the main executable does
# not, so a shipped app (no runtime, check-no-bench-hooks.sh) never carries one. check-no-bench-hooks.sh runs it.
set -euo pipefail
[[ $# -eq 2 && -d "$1" && -f "$2" ]] || { echo "usage: $0 <app bundle> <main executable>" >&2; exit 2; }
app="$1" exe="$2"
shim="$app/Contents/Frameworks/libcmux_cef_shim.dylib"
[[ -f "$shim" ]] || exit 0
runtimes() { # <Mach-O> -> the sanitizer runtimes it names, one per line
  { LC_ALL=C grep -aoE 'libclang_rt\.(asan|tsan|ubsan)_osx_dynamic\.dylib' "$1" || true; } |
    sed -E 's/^libclang_rt\.([a-z]+)_.*/\1/' | sort -u
}
missing="$(comm -23 <(runtimes "$shim") <(runtimes "$exe") | paste -sd' ' -)"
if [[ -n "$missing" ]]; then
  echo "error: $app has an instrumented CEF shim ($missing sanitizer, CMUX_CEF_SHIM_SANITIZE) that its main executable does not load; it is for sanitizer lab apps only and must not ship" >&2
  exit 1
fi
