#!/usr/bin/env bash
# Builds CCmuxAppFFI.xcframework: the ONE Rust static library the cmux macOS
# app links (cmux-tui/crates/cmux-app-ffi = the remote desktop core C ABI +
# the sidebar layout reducer C ABI + the cmux-motion C ABI over one Rust
# runtime). Apple's compact
# unwind encodes at most three personality routines per image (C++, iroh,
# this library); every extra Rust static library breaks the app link. The
# headers keep their modules (CCmuxRdFFI, CCmuxLayoutReducerFFI), so Swift
# imports do not change. Published by app-ffi-release.yml and
# pinned in Packages/macOS/CmuxNext/Package.swift.
#
# Usage: build-app-ffi.sh [--linux]
#   --linux  The same library for the Linux SwiftPM tier (p15-oracle), built
#            from a git worktree at the source sha pinned in Package.swift, so
#            Linux links what the macOS build downloads. Writes the per-module
#            header folders and lib/libcmux_app_ffi.a to
#            Packages/macOS/CmuxNext/.build-linux/ffi, which
#            Sources/CCmuxAppFFILinux/module.modulemap reads. No xcodebuild or lipo.
# Environment:
#   CMUX_APP_FFI_ARCHS  macOS architectures, arm64 and/or x86_64 (default: host)
#   CMUX_APP_FFI_OUT    output directory (default: cmux-tui/target/cmux-app-ffi;
#                       with --linux, Packages/macOS/CmuxNext/.build-linux/ffi)
set -euo pipefail
REPAIR_URL="https://github.com/manaflow-ai/cmuxterm-hq/blob/main/REPAIR.md"
trap 'echo "error: app FFI build failed; see $REPAIR_URL" >&2' ERR

linux=0
case "${1:-}" in
  "") ;;
  --linux) linux=1 ;;
  *) echo "usage: $0 [--linux]" >&2; exit 2 ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
crates="$repo_root/cmux-tui/crates"
default_out="$repo_root/cmux-tui/target/cmux-app-ffi"
if ((linux)); then default_out="$repo_root/Packages/macOS/CmuxNext/.build-linux/ffi"; fi
out_root="${CMUX_APP_FFI_OUT:-$default_out}"
case "$out_root" in ""|"/") echo "error: CMUX_APP_FFI_OUT must name a directory" >&2; exit 2 ;; esac
lib_name="libcmux_app_ffi.a"

if ((linux)); then
  for tool in cargo rustup git ld objcopy ar nm flock; do
    command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is required" >&2; exit 1; }
  done
  manifest="$repo_root/Packages/macOS/CmuxNext/Package.swift"
  # The pin parse of scripts/cmux-next/check-app-ffi-pin.sh.
  sha="$(grep -oE 'releases/download/cmux-app-ffi-[0-9a-f]{40}/CCmuxAppFFI\.xcframework\.zip' "$manifest" \
    | head -n 1 | grep -oE '[0-9a-f]{40}' || true)"
  [[ -n "$sha" ]] || { echo "error: no cmux-app-ffi pin in $manifest" >&2; exit 1; }
  if ! git -C "$repo_root" cat-file -e "$sha^{commit}" 2>/dev/null; then
    remote=origin
    git -C "$repo_root" remote get-url origin >/dev/null 2>&1 \
      || remote="${CMUX_APP_FFI_PIN_REMOTE:-https://github.com/manaflow-ai/cmux.git}"
    git -C "$repo_root" fetch --quiet "$remote" "$sha" \
      || { echo "error: pinned source sha $sha is not available from $remote" >&2; exit 1; }
  fi
  mkdir -p "$out_root"
  # Build output only: the folder ignores itself, wherever it is.
  printf '*\n' > "$out_root/.gitignore"
  # Agents share the VM: one build per output folder at a time.
  exec 9>"$out_root/.lock"
  flock 9
  # One worktree per output folder, kept across runs so cargo stays incremental.
  src="$out_root/src"
  if [[ "$(git -C "$src" rev-parse HEAD 2>/dev/null || true)" != "$sha" ]]; then
    if [[ -e "$src" ]]; then
      git -C "$repo_root" worktree remove --force "$src" 2>/dev/null || rm -rf "$src"
    fi
    git -C "$repo_root" worktree prune
    echo "==> worktree $src at the pinned source $sha" >&2
    git -C "$repo_root" worktree add --quiet --detach "$src" "$sha"
  fi
  crates="$src/cmux-tui/crates"
fi
crate_dir="$crates/cmux-app-ffi"
headers_in=("$crates/cmux-rd-ffi/include/cmux_rd_ffi.h:CCmuxRdFFI"
            "$crates/cmux-layout-reducer-ffi/include/cmux_layout_reducer_ffi.h:CCmuxLayoutReducerFFI"
            "$crates/cmux-palette-ranker/include/cmux_palette_ranker.h:CCmuxPaletteRankerFFI"
            "$crates/cmux-app-ffi/include/cmux_motion_ffi.h:CCmuxMotionFFI")

# One header folder per module: SwiftPM merges every binary target's Headers
# into one include directory, and GhosttyKit owns the top-level
# module.modulemap. $1: lines added to each module (the Linux link list).
write_headers() {
  local headers="$out_root/headers" entry header module
  rm -rf "$headers"
  for entry in "${headers_in[@]}"; do
    header="${entry%%:*}"; module="${entry##*:}"
    mkdir -p "$headers/$module"
    cp "$header" "$headers/$module/"
    printf 'module %s {\n    header "%s"\n%s    export *\n}\n' \
      "$module" "$(basename "$header")" "${1:-}" > "$headers/$module/module.modulemap"
  done
}

# The C ABI names the headers declare: the only globals the library keeps.
c_abi_symbols() {
  local entry
  for entry in "${headers_in[@]}"; do
    grep -oE '\bcmux_[a-z0-9_]+\(' "${entry%%:*}" | tr -d '(' | sort -u
  done | sort -u
}

if ((linux)); then
  export CARGO_TARGET_DIR="$out_root/cargo"
  work="$(mktemp -d "${TMPDIR:-/tmp}/cmux-app-ffi.XXXXXX")"
  trap 'rm -rf "$work"' EXIT
  c_abi_symbols > "$work/exports.txt"
  # The pinned tree's rust-toolchain.toml picks the toolchain. rustc's
  # native-static-libs note names the system libraries the staticlib needs;
  # they become the module maps' link lines, so Swift autolinks them.
  rustc_native_libs() {
    (cd "$crate_dir" && cargo rustc --locked --release --lib -- --print native-static-libs 2>&1) \
      | tee "$work/cargo.log" >&2 || return 1
    sed -nE 's/.*native-static-libs: //p' "$work/cargo.log" | tail -n 1
  }
  echo "==> cargo rustc cmux-app-ffi (host, source $sha)" >&2
  native="$(rustc_native_libs)"
  if [[ -z "$native" ]]; then
    # A fresh crate is not compiled again, so rustc prints no note.
    touch "$crate_dir/src/lib.rs"
    native="$(rustc_native_libs)"
  fi
  [[ -n "$native" ]] || { echo "error: rustc printed no native-static-libs" >&2; exit 1; }
  links=$'    link "cmux_app_ffi"\n'
  for flag in $native; do
    case "$flag" in
      -l*) links+="    link \"${flag#-l}\""$'\n' ;;
      *) echo "error: unexpected native-static-libs entry $flag" >&2; exit 1 ;;
    esac
  done
  write_headers "$links"
  # The macOS slices' shape: one prelinked object whose only globals are the
  # C ABIs, so Linux resolves exactly the symbols macOS exports.
  ld -r --whole-archive "$CARGO_TARGET_DIR/release/$lib_name" -o "$work/cmux_app_ffi.o"
  objcopy --keep-global-symbols="$work/exports.txt" "$work/cmux_app_ffi.o"
  nm -g --defined-only "$work/cmux_app_ffi.o" | awk '{print $NF}' | sort -u > "$work/defined.txt"
  missing="$(comm -23 "$work/exports.txt" "$work/defined.txt")"
  if [[ -n "$missing" ]]; then
    echo "error: the headers declare symbols the library does not define:" >&2
    echo "$missing" >&2
    exit 1
  fi
  mkdir -p "$out_root/lib"
  rm -f "$out_root/lib/$lib_name"
  ar rcs "$out_root/lib/$lib_name" "$work/cmux_app_ffi.o"
  printf '%s\n' "$sha" > "$out_root/SOURCE_SHA"
  printf 'built %s (source %s)\n' "$out_root/lib/$lib_name" "$sha"
  exit 0
fi

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
export MACOSX_DEPLOYMENT_TARGET=14.0
# Machine code only: Xcode's ld and nm cannot read a newer rustc's bitcode.
export CARGO_PROFILE_RELEASE_LTO=off
export RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }-C embed-bitcode=no"

work="$(mktemp -d "${TMPDIR:-/tmp}/cmux-app-ffi.XXXXXX")"
trap 'rm -rf "$work"' EXIT
exports="$work/exports.txt"
c_abi_symbols | sed 's/^/_/' > "$exports"

headers="$out_root/headers"
write_headers

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
