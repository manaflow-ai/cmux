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
mkdir -p "$headers"
cp "$crate_dir/include/cmux_rd_ffi.h" "$headers/"
cat > "$headers/module.modulemap" <<'MAP'
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
  [[ "$missing" -eq 0 ]]
}

args=()
mac_libs=()
for target in "${mac_targets[@]}"; do
  mac_libs+=("$(build "$target")")
done
mkdir -p "$out_root/macos"
if [[ ${#mac_libs[@]} -eq 1 ]]; then
  cp -f "${mac_libs[0]}" "$out_root/macos/$lib_name"
else
  lipo -create "${mac_libs[@]}" -output "$out_root/macos/$lib_name"
fi
check_symbols "$out_root/macos/$lib_name"
args+=(-library "$out_root/macos/$lib_name" -headers "$headers")
for target in ${ios_targets[@]+"${ios_targets[@]}"}; do
  lib="$(build "$target")"
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
