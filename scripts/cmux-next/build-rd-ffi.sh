#!/usr/bin/env bash
# Build the client xcframework of the remote desktop viewer core.
#
# Compiles the staticlib crate cmux-tui/crates/cmux-rd-ffi (own Cargo
# workspace, outside the cmux-tui build) for each selected slice and packs it
# with its C header and module map (module CCmuxRdFFI) into
# cmux-tui/target/cmux-rd-ffi/CCmuxRdFFI.xcframework. The CmuxNext package links
# it only into CmuxNextRemoteView, and only when CMUX_NEXT_RD_FFI=1
# (Packages/macOS/CmuxNext/Package.swift). Run it on a build host, never on the
# laptop: it runs cargo. It installs nothing: a missing Rust target fails.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
crate_dir="$repo_root/cmux-tui/crates/cmux-rd-ffi"
out_root="${CMUX_RD_FFI_OUT:-$repo_root/cmux-tui/target/cmux-rd-ffi}"
xcframework="$out_root/CCmuxRdFFI.xcframework"
lib_name="libcmux_rd_ffi.a"

usage() {
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'USAGE'

Usage: build-rd-ffi.sh [--ios] [--print-path]
  --ios          also add iOS device (arm64) and simulator (arm64) slices
  --print-path   print the xcframework path when done
Environment:
  CMUX_RD_FFI_ARCHS  macOS architectures, arm64 and/or x86_64 (default: host)
  CMUX_RD_FFI_OUT    output directory (default: cmux-tui/target/cmux-rd-ffi)
USAGE
}

with_ios=0
print_path=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ios) with_ios=1; shift ;;
    --print-path) print_path=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for tool in cargo rustup xcodebuild lipo nm; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is required" >&2; exit 1; }
done

mac_archs="${CMUX_RD_FFI_ARCHS:-$(uname -m)}"
mac_targets=()
for arch in ${mac_archs//,/ }; do
  case "$arch" in
    arm64|aarch64) mac_targets+=(aarch64-apple-darwin) ;;
    x86_64) mac_targets+=(x86_64-apple-darwin) ;;
    *) echo "error: unsupported macOS architecture '$arch' (use arm64 and/or x86_64)" >&2; exit 2 ;;
  esac
done
ios_targets=()
[[ "$with_ios" -eq 0 ]] || ios_targets=(aarch64-apple-ios aarch64-apple-ios-sim)

installed="$(cd "$crate_dir" && rustup target list --installed)"
for target in "${mac_targets[@]}" ${ios_targets[@]+"${ios_targets[@]}"}; do
  grep -Fxq "$target" <<<"$installed" || {
    echo "error: Rust target $target is not installed on this host; ask the host owner (no installs from jobs)" >&2
    exit 1
  }
done

export CARGO_TARGET_DIR="$out_root/cargo"
# Match the packages' deployment targets so the linker does not warn per object.
export MACOSX_DEPLOYMENT_TARGET=26.0
export IPHONEOS_DEPLOYMENT_TARGET=17.0

build() {
  echo "==> cargo build cmux-rd-ffi ($1)" >&2
  (cd "$crate_dir" && cargo build --locked --release --target "$1")
  printf '%s\n' "$CARGO_TARGET_DIR/$1/release/$lib_name"
}

headers="$out_root/headers"
rm -rf "$headers"
# The module map sits in its own folder: SwiftPM copies every binary target's
# Headers into one include directory, and GhosttyKit already has a top-level
# module.modulemap there.
mkdir -p "$headers/CCmuxRdFFI"
cp "$crate_dir/include/cmux_rd_ffi.h" "$headers/CCmuxRdFFI/"
cat > "$headers/CCmuxRdFFI/module.modulemap" <<'MAP'
module CCmuxRdFFI {
    header "cmux_rd_ffi.h"
    export *
}
MAP

# Every function the header declares must be a global symbol of the library.
check_symbols() {
  local lib="$1" name missing=0
  local symbols
  # nm exits non-zero for archive members without symbols; the list is what counts.
  symbols="$( (nm -gU "$lib" 2>/dev/null || true) | awk '{print $NF}')"
  [[ -n "$symbols" ]] || { echo "error: nm listed no symbols in $lib" >&2; return 1; }
  while read -r name; do
    grep -Fxq "_$name" <<<"$symbols" || { echo "error: $lib does not export $name" >&2; missing=1; }
  done < <(grep -oE '\bcmux_rd_[a-z0-9_]+\(' "$crate_dir/include/cmux_rd_ffi.h" | tr -d '(' | sort -u)
  # Nothing else may be global: another Rust library in the same app (iroh-ffi)
  # defines the same std symbols, and the link fails on duplicates.
  local extra
  extra="$(grep -v '^_cmux_rd_' <<<"$symbols" | grep -v -e '^$' -e ':$' | head -5 || true)"
  [[ -z "$extra" ]] || { echo "error: $lib exports more than the C ABI: $extra" >&2; missing=1; }
  [[ "$missing" -eq 0 ]]
}

# Prelinks a Rust staticlib into one object whose only global symbols are the
# C ABI (every Rust and std symbol becomes local), then archives it again.
hide_rust_symbols() {
  local lib="$1" triple="$2" out="$3" work
  work="$(mktemp -d "${TMPDIR:-/tmp}/cmux-rd-ffi.XXXXXX")"
  grep -oE '\bcmux_rd_[a-z0-9_]+\(' "$crate_dir/include/cmux_rd_ffi.h" | tr -d '(' | sort -u | sed 's/^/_/' > "$work/exports.txt"
  # clang drives ld so it passes the platform version for the triple.
  xcrun clang -target "$triple" -r -nostdlib -Wl,-force_load,"$lib" \
    -Wl,-exported_symbols_list,"$work/exports.txt" -o "$work/cmux_rd_ffi.o"
  rm -f "$out"
  xcrun libtool -static -o "$out" "$work/cmux_rd_ffi.o"
  rm -rf "$work"
}

args=()
mac_libs=()
mkdir -p "$out_root/macos" "$out_root/slices"
for target in "${mac_targets[@]}"; do
  arch="${target%%-*}"; [[ "$arch" == aarch64 ]] && arch=arm64
  hide_rust_symbols "$(build "$target")" "$arch-apple-macos$MACOSX_DEPLOYMENT_TARGET" "$out_root/slices/$target.a"
  mac_libs+=("$out_root/slices/$target.a")
done
if [[ ${#mac_libs[@]} -eq 1 ]]; then
  cp -f "${mac_libs[0]}" "$out_root/macos/$lib_name"
else
  lipo -create "${mac_libs[@]}" -output "$out_root/macos/$lib_name"
fi
check_symbols "$out_root/macos/$lib_name"
args+=(-library "$out_root/macos/$lib_name" -headers "$headers")
for target in ${ios_targets[@]+"${ios_targets[@]}"}; do
  lib="$out_root/slices/$target.a"
  triple="arm64-apple-ios$IPHONEOS_DEPLOYMENT_TARGET"
  [[ "$target" == *-sim ]] && triple="$triple-simulator"
  hide_rust_symbols "$(build "$target")" "$triple" "$lib"
  check_symbols "$lib"
  args+=(-library "$lib" -headers "$headers")
done

rm -rf "$xcframework"
xcodebuild -create-xcframework "${args[@]}" -output "$xcframework" >&2
source_commit="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo unknown)"
dirty="$(git -C "$repo_root" status --porcelain -- cmux-tui/crates/cmux-rd-ffi cmux-tui/crates/cmux-rd-core cmux-tui/crates/cmux-rd-proto 2>/dev/null | wc -l | tr -d ' ')"
printf '%s\n' "commit=$source_commit" "dirty_rd_files=$dirty" "macos=${mac_targets[*]}" "ios=${ios_targets[*]:-none}" \
  > "$out_root/CCmuxRdFFI.ref"
echo "built $xcframework (${mac_targets[*]}${ios_targets[*]:+ ${ios_targets[*]}})" >&2
[[ "$print_path" -eq 0 ]] || printf '%s\n' "$xcframework"
