# shellcheck shell=bash
# Sourced by `scripts/cmux-next/build-app-ffi.sh --linux`,
# which defines repo_root, lib_name, header_entries, write_headers and
# c_abi_symbols.
# shellcheck disable=SC2154 # repo_root and lib_name come from build-app-ffi.sh
# Not an app FFI pin input (scripts/cmux-next/check-app-ffi-pin.sh): the
# macOS xcframework never runs this, so a Linux edit never stales its release.
#
# Builds the app FFI static library for the Linux SwiftPM tier from the
# source sha pinned in Package.swift, so Linux links what macOS downloads, and
# writes only what the tier reads to Packages/macOS/CmuxNext/.build-linux/ffi:
#   headers/<module>/  the crate headers and module maps with link lines
#   lib/libcmux_app_ffi.a, SOURCE_SHA
# Sources/CCmuxAppFFILinux/module.modulemap names that folder, so it is fixed.
# The pinned worktree and cargo target dir live once per pin sha in the
# clone's git common dir, shared by all its checkouts under one flock.

if [[ -n "${CMUX_APP_FFI_OUT:-}" ]]; then
  echo "error: --linux always writes Packages/macOS/CmuxNext/.build-linux/ffi (CCmuxAppFFILinux/module.modulemap reads it); unset CMUX_APP_FFI_OUT" >&2
  exit 2
fi
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

out_root="$repo_root/Packages/macOS/CmuxNext/.build-linux/ffi"
cache_root="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir)/cmux-app-ffi-linux"
build="$cache_root/$sha"
# Locked only when the lock is still $build's: the drop below may delete a
# folder between our mkdir and flock.
while :; do
  mkdir -p "$build"
  exec 9>"$build/.lock"
  flock 9
  [[ "$build/.lock" -ef /proc/self/fd/9 ]] && break
done
# Drop other pins' builds that no checkout is building now.
for old in "$cache_root"/*/; do
  old="${old%/}"
  [[ "$old" == "$build" ]] && continue
  { flock -n 8 && { git -C "$repo_root" worktree remove --force "$old/src" 2>/dev/null || true; rm -rf "$old"; }; } \
    8>"$old/.lock" 2>/dev/null || true
done
src="$build/src"
if [[ "$(git -C "$src" rev-parse HEAD 2>/dev/null || true)" != "$sha" ]]; then
  rm -rf "$src"
  git -C "$repo_root" worktree prune
  echo "==> worktree $src at the pinned source $sha" >&2
  git -C "$repo_root" worktree add --quiet --detach "$src" "$sha"
fi
crates="$src/cmux-tui/crates"
crate_dir="$crates/cmux-app-ffi"
export CARGO_TARGET_DIR="$build/cargo"

work="$(mktemp -d "${TMPDIR:-/tmp}/cmux-app-ffi.XXXXXX")"
trap 'rm -rf "$work"' EXIT
c_abi_symbols > "$work/exports.txt"
# The pinned tree's rust-toolchain.toml picks the toolchain. rustc's
# native-static-libs note names the system libraries the staticlib needs;
# they become the module maps' link lines, which Swift autolinks.
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

stage="$work/ffi"
write_headers "$stage/headers" "$links"
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
mkdir -p "$stage/lib"
ar rcs "$stage/lib/$lib_name" "$work/cmux_app_ffi.o"
printf '%s\n' "$sha" > "$stage/SOURCE_SHA"
# Build output only: the folder ignores itself.
printf '*\n' > "$stage/.gitignore"
mkdir -p "$(dirname "$out_root")"
rm -rf "$out_root"
cp -R "$stage" "$out_root"
printf 'built %s (source %s)\n' "$out_root/lib/$lib_name" "$sha"
