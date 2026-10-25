#!/usr/bin/env bash
# scripts/cmux-next/build-app-ffi.sh --linux (p15-oracle-003), on Linux:
#  - the library is built from the pinned source sha (SOURCE_SHA);
#  - every `cmux_*(` that CmuxNext Sources call and no in-package C header
#    declares (CEFShim, CmuxNextMallocZone) is a global the .a defines;
#  - the .a has no other globals: Rust and std symbols stay local, like the
#    macOS slices;
#  - each of the four modules has its pinned crate header and the link line,
#    and Sources/CCmuxAppFFILinux/module.modulemap imports and links from C.
# Usage: build-app-ffi-linux.test.sh [--no-build]   (--no-build checks the last output)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
pkg="$root/Packages/macOS/CmuxNext"
out="${CMUX_APP_FFI_OUT:-$pkg/.build-linux/ffi}"
fail() { echo "FAIL: $*" >&2; exit 1; }
[[ "$(uname -s)" == Linux ]] || { echo "skip: Linux only"; exit 0; }
[[ "${1:-}" == --no-build ]] || bash "$root/scripts/cmux-next/build-app-ffi.sh" --linux
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

sha="$(grep -oE 'cmux-app-ffi-[0-9a-f]{40}/' "$pkg/Package.swift" | head -n 1 | grep -oE '[0-9a-f]{40}')"
[[ "$(cat "$out/SOURCE_SHA")" == "$sha" ]] || fail "SOURCE_SHA $(cat "$out/SOURCE_SHA") is not the pin $sha"

lib="$out/lib/libcmux_app_ffi.a"
nm -g --defined-only "$lib" | awk 'NF == 3 {print $3}' | sort -u > "$tmp/defined"
# Calls only: comment lines name C functions in prose.
git -C "$root" grep -hE '\bcmux_[a-z0-9_]+\(' -- 'Packages/macOS/CmuxNext/Sources/*.swift' \
  | grep -vE '^[[:space:]]*//' | grep -oE '\bcmux_[a-z0-9_]+\(' | tr -d '(' | sort -u > "$tmp/called"
git -C "$root" grep -ohE '\bcmux_[a-z0-9_]+\(' -- 'Packages/macOS/CmuxNext/*.h' \
  | tr -d '(' | sort -u > "$tmp/in-package"
comm -23 "$tmp/called" "$tmp/in-package" > "$tmp/required"
[[ -s "$tmp/required" ]] || fail "no FFI calls found in Sources"
missing="$(comm -23 "$tmp/required" "$tmp/defined")"
[[ -z "$missing" ]] || fail "Sources call symbols the .a does not define:"$'\n'"$missing"
extra="$(grep -v '^cmux_' "$tmp/defined" || true)"
[[ -z "$extra" ]] || fail "the .a exports non-C-ABI globals:"$'\n'"$(head -n 20 <<<"$extra")"

crates_at_pin() { git -C "$root" show "$sha:cmux-tui/crates/$1"; }
for entry in cmux-rd-ffi/include/cmux_rd_ffi.h:CCmuxRdFFI \
             cmux-layout-reducer-ffi/include/cmux_layout_reducer_ffi.h:CCmuxLayoutReducerFFI \
             cmux-palette-ranker/include/cmux_palette_ranker.h:CCmuxPaletteRankerFFI \
             cmux-app-ffi/include/cmux_motion_ffi.h:CCmuxMotionFFI; do
  header="${entry%%:*}"; module="${entry##*:}"
  dir="$out/headers/$module"
  cmp -s <(crates_at_pin "$header") "$dir/$(basename "$header")" || fail "$module header is not the pinned $header"
  grep -q 'link "cmux_app_ffi"' "$dir/module.modulemap" || fail "$module module map has no link line"
  grep -q "extern module $module \"" "$pkg/Sources/CCmuxAppFFILinux/module.modulemap" \
    || fail "CCmuxAppFFILinux does not name $module"
done

if command -v clang >/dev/null 2>&1; then
  cat > "$tmp/t.m" <<'EOF'
@import CCmuxRdFFI;
@import CCmuxLayoutReducerFFI;
@import CCmuxPaletteRankerFFI;
@import CCmuxMotionFFI;
int main(void) { return cmux_motion_ffi_abi_version() > 0 && cmux_rd_ffi_abi_version() > 0 ? 0 : 1; }
EOF
  libs="$(sed -nE 's/^ *link "([^"]+)"/-l\1/p' "$out/headers/CCmuxRdFFI/module.modulemap" | tr '\n' ' ')"
  # shellcheck disable=SC2086 # one flag per word
  clang -x objective-c -fmodules -fmodules-cache-path="$tmp/mc" \
    -fmodule-map-file="$pkg/Sources/CCmuxAppFFILinux/module.modulemap" \
    "$tmp/t.m" -L"$out/lib" $libs -o "$tmp/t" || fail "a C client of the module map does not build"
  "$tmp/t" || fail "the ABI version calls returned 0"
fi
echo "ok: $(wc -l < "$tmp/required") FFI symbols called by Sources, all defined at $sha"
