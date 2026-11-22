#!/usr/bin/env bash
# Builds CCmuxAppFFI.xcframework: the ONE Rust static library the cmux macOS
# app links (cmux-tui/crates/cmux-app-ffi = the remote desktop core C ABI +
# the sidebar layout reducer C ABI over one Rust runtime). Apple's compact
# unwind encodes at most three personality routines per image (C++, iroh,
# this library); every extra Rust static library breaks the app link. The
# headers keep their modules (CCmuxRdFFI, CCmuxLayoutReducerFFI), so Swift
# imports do not change. Published by app-ffi-release.yml and
# pinned in Packages/macOS/CmuxNext/Package.swift.
#
# Usage: build-app-ffi.sh
# Environment:
#   CMUX_APP_FFI_ARCHS  macOS architectures, arm64 and/or x86_64 (default: host)
#   CMUX_APP_FFI_OUT    output directory (default: cmux-tui/target/cmux-app-ffi)
set -euo pipefail
REPAIR_URL="https://github.com/manaflow-ai/cmuxterm-hq/blob/main/REPAIR.md"
trap 'echo "error: app FFI build failed; see $REPAIR_URL" >&2' ERR

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
crates="$repo_root/cmux-tui/crates"
crate_dir="$crates/cmux-app-ffi"
out_root="${CMUX_APP_FFI_OUT:-$repo_root/cmux-tui/target/cmux-app-ffi}"
case "$out_root" in ""|"/") echo "error: CMUX_APP_FFI_OUT must name a directory" >&2; exit 2 ;; esac
lib_name="libcmux_app_ffi.a"
headers_in=("$crates/cmux-rd-ffi/include/cmux_rd_ffi.h:CCmuxRdFFI"
            "$crates/cmux-layout-reducer-ffi/include/cmux_layout_reducer_ffi.h:CCmuxLayoutReducerFFI")

for tool in cargo rustup xcodebuild lipo clang libtool; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is required" >&2; exit 1; }
done

targets=()
for arch in ${CMUX_APP_FFI_ARCHS:-$(uname -m)}; do
  arch="${arch//,/ }"
  for one in $arch; do
    case "$one" in
      arm64|aarch64) targets+=(aarch64-apple-darwin) ;;
      x86_64) targets+=(x86_64-apple-darwin) ;;
      *) echo "error: unsupported architecture $one" >&2; exit 2 ;;
    esac
  done
done
installed="$(cd "$crate_dir" && rustup target list --installed)"
for target in "${targets[@]}"; do
  grep -Fxq "$target" <<<"$installed" || { echo "error: Rust target $target is not installed" >&2; exit 1; }
done

export CARGO_TARGET_DIR="$out_root/cargo"
export MACOSX_DEPLOYMENT_TARGET=26.0
# Machine code only: Xcode's ld and nm cannot read a newer rustc's bitcode.
export CARGO_PROFILE_RELEASE_LTO=off
export RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }-C embed-bitcode=no"

work="$(mktemp -d "${TMPDIR:-/tmp}/cmux-app-ffi.XXXXXX")"
trap 'rm -rf "$work"' EXIT
exports="$work/exports.txt"
for entry in "${headers_in[@]}"; do
  grep -oE '\bcmux_[a-z0-9_]+\(' "${entry%%:*}" | tr -d '(' | sort -u | sed 's/^/_/'
done | sort -u > "$exports"

headers="$out_root/headers"
rm -rf "$headers"
for entry in "${headers_in[@]}"; do
  header="${entry%%:*}"; module="${entry##*:}"
  # One folder per module: SwiftPM merges every binary target's Headers into
  # one include directory, and GhosttyKit owns the top-level module.modulemap.
  mkdir -p "$headers/$module"
  cp "$header" "$headers/$module/"
  printf 'module %s {\n    header "%s"\n    export *\n}\n' "$module" "$(basename "$header")" > "$headers/$module/module.modulemap"
done

mkdir -p "$out_root/slices" "$out_root/macos"
libs=()
for target in "${targets[@]}"; do
  echo "==> cargo build cmux-app-ffi ($target)" >&2
  (cd "$crate_dir" && cargo build --locked --release --target "$target")
  arch="${target%%-*}"; [[ "$arch" == aarch64 ]] && arch=arm64
  # One prelinked object whose only globals are the C ABIs: every Rust and std
  # symbol, rust_eh_personality included, becomes local (one copy per image).
  clang -target "$arch-apple-macos$MACOSX_DEPLOYMENT_TARGET" -r -nostdlib \
    -Wl,-force_load,"$CARGO_TARGET_DIR/$target/release/$lib_name" \
    -Wl,-exported_symbols_list,"$exports" -o "$work/$target.o"
  rm -f "$out_root/slices/$target.a"
  libtool -static -o "$out_root/slices/$target.a" "$work/$target.o"
  libs+=("$out_root/slices/$target.a")
done
if ((${#libs[@]} == 1)); then
  cp -f "${libs[0]}" "$out_root/macos/$lib_name"
else
  lipo -create "${libs[@]}" -output "$out_root/macos/$lib_name"
fi
rm -rf "$out_root/CCmuxAppFFI.xcframework"
xcodebuild -create-xcframework -library "$out_root/macos/$lib_name" -headers "$headers" \
  -output "$out_root/CCmuxAppFFI.xcframework" >/dev/null
printf 'built %s\n' "$out_root/CCmuxAppFFI.xcframework"
