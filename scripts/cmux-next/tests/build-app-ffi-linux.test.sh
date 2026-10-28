#!/usr/bin/env bash
# scripts/cmux-next/build-app-ffi.sh --linux, on Linux:
#  - the library is built from the pinned source sha (SOURCE_SHA);
#  - every `cmux_*(` that CmuxNext Sources call and no in-package C header
#    declares (CEFShim, CmuxNextMallocZone) is a global the .a defines;
#  - the .a has no other globals: Rust and std symbols stay local, like the
#    macOS slices;
#  - the exports list keeps cmux_ffi_take_panic and cmux_ffi_panic_count,
#   and a pin with the guard crate ships its header
#    as CCmuxFfiGuardFFI and keeps both global in the .a;
#  - each of the four modules has its pinned crate header and the link line,
#    and Sources/CCmuxAppFFILinux/module.modulemap imports and links from C
#    with only the -L that Package.swift's Linux mode passes: the libraries
#    come from the module maps' link lines, as Swift autolinks them;
#  - the package folder holds only headers, lib and SOURCE_SHA (the pinned
#    worktree and cargo target dir stay in the shared git common dir);
#  - CMUX_APP_FFI_OUT is refused: the checked-in module map fixes the path.
# Usage: build-app-ffi-linux.test.sh [--no-build]   (--no-build checks the last output)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
pkg="$root/Packages/macOS/CmuxNext"
out="$pkg/.build-linux/ffi"
fail() { echo "FAIL: $*" >&2; exit 1; }
[[ "$(uname -s)" == Linux ]] || { echo "skip: Linux only"; exit 0; }
# The panic ring's readers (cmux-ffi-guard) are C ABI the library keeps
# global, on macOS and Linux alike.
guard_symbols=(cmux_ffi_panic_count cmux_ffi_take_panic)
exports="$(bash "$root/scripts/cmux-next/build-app-ffi.sh" --exports)"
for symbol in "${guard_symbols[@]}"; do
  grep -Fxq "$symbol" <<<"$exports" || fail "build-app-ffi.sh does not export $symbol"
done
[[ "${1:-}" == --no-build ]] || bash "$root/scripts/cmux-next/build-app-ffi.sh" --linux
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

rc=0
CMUX_APP_FFI_OUT="$tmp/elsewhere" bash "$root/scripts/cmux-next/build-app-ffi.sh" --linux >/dev/null 2>&1 || rc=$?
[[ "$rc" == 2 && ! -e "$tmp/elsewhere" ]] || fail "--linux with CMUX_APP_FFI_OUT exited $rc, not 2 (refused)"
listing="$(cd "$out" && find . -mindepth 1 -maxdepth 1 | sort | tr '\n' ' ')"
[[ "$listing" == "./.gitignore ./SOURCE_SHA ./headers ./lib " ]] || fail "unexpected files in $out: $listing"

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
# A pin from p10-stability-152 on has the guard crate: its header ships as a
# module and the .a keeps the ring's readers global.
guard_header=cmux-ffi-guard/include/cmux_ffi_guard.h
if git -C "$root" cat-file -e "$sha:cmux-tui/crates/$guard_header" 2>/dev/null; then
  dir="$out/headers/CCmuxFfiGuardFFI"
  cmp -s <(crates_at_pin "$guard_header") "$dir/cmux_ffi_guard.h" \
    || fail "CCmuxFfiGuardFFI header is not the pinned $guard_header"
  grep -q 'link "cmux_app_ffi"' "$dir/module.modulemap" || fail "CCmuxFfiGuardFFI module map has no link line"
  for symbol in "${guard_symbols[@]}"; do
    grep -Fxq "$symbol" "$tmp/defined" || fail "the .a does not keep $symbol global"
  done
fi

# A module map cannot carry a search path: once Package.swift declares the
# target (002), it must pass the -L the link below uses.
# linux-tier.py writes the directory as libraryDirectory and joins it to the
# package directory in one -L flag; an inline "/.build-linux/ffi/lib" also counts.
if grep -q 'CCmuxAppFFILinux' "$pkg/Package.swift"; then
  if ! grep -qF '"/.build-linux/ffi/lib"' "$pkg/Package.swift"; then
    grep -qF 'libraryDirectory: ".build-linux/ffi/lib"' "$pkg/Package.swift" \
      && grep -qF '.unsafeFlags(["-L", packageDirectory + "/" + ffi.libraryDirectory])' "$pkg/Package.swift" \
      || fail "Package.swift declares CCmuxAppFFILinux without -L .../.build-linux/ffi/lib"
  fi
fi

if command -v clang >/dev/null 2>&1; then
  cat > "$tmp/t.m" <<'EOF'
@import CCmuxRdFFI;
@import CCmuxLayoutReducerFFI;
@import CCmuxPaletteRankerFFI;
@import CCmuxMotionFFI;
int main(void) { return cmux_motion_ffi_abi_version() > 0 && cmux_rd_ffi_abi_version() > 0 ? 0 : 1; }
EOF
  clang -x objective-c -fmodules -fmodules-cache-path="$tmp/mc" \
    -fmodule-map-file="$pkg/Sources/CCmuxAppFFILinux/module.modulemap" \
    -c "$tmp/t.m" -o "$tmp/t.o" || fail "a C client of the module map does not compile"
  # The libraries are the compiler's autolink entries (.linker-options: lib,
  # name pairs), as Swift autolinks the module maps' link lines; the one
  # search path is Package.swift's. No -l or -L of our own.
  mapfile -t autolink < <(readelf -p .linker-options "$tmp/t.o" \
    | awk '/^ *\[/ { if (n++ % 2 == 0) key = $NF; else if (key == "lib") print "-l" $NF }' | awk '!seen[$0]++')
  [[ " ${autolink[*]} " == *" -lcmux_app_ffi "* ]] || fail "the object autolinks no cmux_app_ffi: ${autolink[*]}"
  clang "$tmp/t.o" -L "$pkg/.build-linux/ffi/lib" "${autolink[@]}" -o "$tmp/t" \
    || fail "a C client of the module map does not link with its autolink entries and the package -L"
  "$tmp/t" || fail "the ABI version calls returned 0"
fi
echo "ok: $(wc -l < "$tmp/required") FFI symbols called by Sources, all defined at $sha"
