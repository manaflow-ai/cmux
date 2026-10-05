#!/usr/bin/env bash
# Build the sidebar resolver xcframework on a fleet build host.
set -euo pipefail
REPAIR_URL="https://github.com/manaflow-ai/cmuxterm-hq/blob/main/REPAIR.md"
repair_on_error() { echo "error: layout reducer FFI build failed; see $REPAIR_URL (sidebar layout reducer)" >&2; }
trap repair_on_error ERR

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
crate_dir="$repo_root/cmux-tui/crates/cmux-layout-reducer-ffi"
out_root="${CMUX_LAYOUT_REDUCER_FFI_OUT:-$repo_root/cmux-tui/target/cmux-layout-reducer-ffi}"
case "$out_root" in ""|"/") echo "error: CMUX_LAYOUT_REDUCER_FFI_OUT must name a directory; repair via REPAIR.md" >&2; exit 2;; esac
for tool in cargo rustup xcodebuild clang libtool lipo; do
  command -v "$tool" >/dev/null || { echo "error: $tool is required; repair via REPAIR.md" >&2; exit 1; }
done

archs="${CMUX_LAYOUT_REDUCER_FFI_ARCHS:-$(uname -m)}"
targets=(); libs=()
mkdir -p "$out_root/cargo" "$out_root/slices" "$out_root/macos"
for arch in ${archs//,/ }; do
  case "$arch" in
    arm64|aarch64) targets+=(aarch64-apple-darwin) ;;
    x86_64) targets+=(x86_64-apple-darwin) ;;
    *) echo "error: unsupported architecture $arch; repair via REPAIR.md" >&2; exit 2 ;;
  esac
done
installed="$(rustup target list --installed)"
for target in "${targets[@]}"; do
  grep -Fxq "$target" <<<"$installed" || { echo "error: Rust target $target is not installed; repair via REPAIR.md" >&2; exit 1; }
done
export CARGO_TARGET_DIR="$out_root/cargo"
for target in "${targets[@]}"; do
  (cd "$crate_dir" && cargo build --release --target "$target")
  lib="$out_root/cargo/$target/release/libcmux_layout_reducer_ffi.a"
  arch="${target%%-*}"; [[ "$arch" == aarch64 ]] && arch=arm64
  obj="$out_root/slices/$target.o"; out="$out_root/slices/$target.a"
  exports="$out_root/slices/$target.exports"
  grep -oE '\bcmux_layout_reducer_[a-z0-9_]+\(' "$crate_dir/include/cmux_layout_reducer_ffi.h" | tr -d '(' | sort -u | sed 's/^/_/' > "$exports"
  clang -target "$arch-apple-macos26.0" -r -nostdlib -Wl,-force_load,"$lib" -Wl,-exported_symbols_list,"$exports" -o "$obj"
  libtool -static -o "$out" "$obj"; libs+=("$out")
done
if ((${#libs[@]} == 1)); then
  cp "${libs[0]}" "$out_root/macos/libcmux_layout_reducer_ffi.a"
else
  lipo -create "${libs[@]}" -output "$out_root/macos/libcmux_layout_reducer_ffi.a"
fi
headers="$out_root/headers/CCmuxLayoutReducerFFI"
mkdir -p "$headers"
cp "$crate_dir/include/cmux_layout_reducer_ffi.h" "$headers/"
cat > "$headers/module.modulemap" <<'EOF'
module CCmuxLayoutReducerFFI {
    header "cmux_layout_reducer_ffi.h"
    export *
}
EOF
rm -rf "$out_root/CCmuxLayoutReducerFFI.xcframework"
xcodebuild -create-xcframework \
  -library "$out_root/macos/libcmux_layout_reducer_ffi.a" \
  -headers "$out_root/headers" \
  -output "$out_root/CCmuxLayoutReducerFFI.xcframework" >/dev/null
printf 'built %s\n' "$out_root/CCmuxLayoutReducerFFI.xcframework"
