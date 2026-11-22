#!/usr/bin/env bash
# Build the Screen Sharing helper's executable (plans/cmux-next/screen-sharing-helper.md): the
# cmux.rd/1 host, `cmux-rd` from cmux-tui/crates/cmux-rd-host (its own Cargo workspace) with
# only the `link` feature, as the cmux CLI links it. bundle-screen-sharing-helper.sh wraps it
# in "<app> Screen Sharing.app" (Contents/Library), which the app starts with responsibility
# disclaimed so the Screen Recording and Accessibility grants are the helper's, never cmux's.
#
# Same contract as build-mobile-host.sh: CI, fleet and nx-remote builds run Cargo on a miss; a
# developer Mac only reuses the cache and never runs Cargo. The cache is keyed by the source of
# cmux-rd-host's path-dependency crates and cmux-tui/vendor, so an
# app-only commit reuses the last build.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() {
  sed -n '2,11p' "$0" | sed 's/^# //'
  cat <<'USAGE'

Usage: build-screen-sharing-helper.sh [--output PATH] [--cached-only] [--print-path] [--check-build-allowed] [--print-key]
  --output PATH  also copy the binary (and PATH.ref) there
  --print-key    print the source key and exit (no build; runs on Linux too): the key the
                 signed helper `cmux app try` carries is published under
                 (cmux-tui/screen-sharing-helper/<key>/, cmux-tui-team-signed.yml)
Environment:
  CMUX_NEXT_SCREEN_HELPER_ARCHS  space/comma-separated arm64 and/or x86_64 (default: ARCHS, else host)
  CMUX_NEXT_SCREEN_HELPER_CACHE  cache root (default: cmux-tui/crates/cmux-rd-host/target/hosted/screen-sharing-helper)
USAGE
}

build_allowed() { [[ -n "${CI:-}${GITHUB_ACTIONS:-}${CMUX_FLEET_BUILD_TAG:-}${NX_JOB_ID:-}" ]]; }
cached_only=0
print_path=0
print_key=0
output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) output="${2:?missing path after --output}"; shift 2 ;;
    --cached-only) cached_only=1; shift ;;
    --print-path) print_path=1; shift ;;
    --check-build-allowed) build_allowed; exit $? ;;
    --print-key) print_key=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

crate="$repo_root/cmux-tui/crates/cmux-rd-host"
[[ -f "$crate/Cargo.toml" ]] || { echo "error: cmux-tui/crates/cmux-rd-host is missing" >&2; exit 1; }

# The source key: the committed trees of every input, plus any uncommitted change to them (a
# --working-tree fleet build), so a stale build is never reused. The size profile is part of it.
# cmux-rd-host and every crate it reaches through a path dependency (optional ones too), not all
# of cmux-tui/crates: a daemon-only crate (acpmux, cmux-app-host) neither rebuilds the helper nor
# routes a pull request to the app scheme compile. The Xcode phase "Bundle Screen Sharing helper"
# lists the same crates; scripts/cmux-next/tests/test_screen_sharing_helper_inputs.py checks both
# against Cargo.toml.
inputs=(cmux-tui/crates/cmux-rd-host cmux-tui/crates/cmux-codecs cmux-tui/crates/cmux-computer-use cmux-tui/crates/cmux-encode
  cmux-tui/crates/cmux-file-lock
  cmux-tui/crates/cmux-hub-host cmux-tui/crates/cmux-process cmux-tui/crates/cmux-rd-core
  cmux-tui/crates/cmux-rd-engine cmux-tui/crates/cmux-rd-link cmux-tui/crates/cmux-rd-proto
  cmux-tui/crates/cmux-transport cmux-tui/vendor cmux-tui/Cargo.toml)
size_profile=(CARGO_PROFILE_RELEASE_LTO=fat CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 CARGO_PROFILE_RELEASE_DEBUG=0)
features="link computer-use"
key_material="${size_profile[*]} features=$features"$'\n'
for input in "${inputs[@]}"; do
  key_material+="$(git -C "$repo_root" rev-parse "HEAD:$input" 2>/dev/null || echo "missing:$input")"$'\n'
done
key_material+="$(git -C "$repo_root" diff HEAD -- "${inputs[@]}" 2>/dev/null || true)"
# Untracked files by content, not only by name: editing a new, uncommitted module must change the key.
while IFS= read -r untracked; do
  [[ -n "$untracked" ]] || continue
  key_material+="$untracked $(git -C "$repo_root" hash-object -- "$untracked" 2>/dev/null || echo unreadable)"$'\n'
done < <(git -C "$repo_root" ls-files --others --exclude-standard -- "${inputs[@]}" 2>/dev/null || true)
# shasum on a Mac; sha256sum where perl's shasum is missing (a Linux runner reading --print-key).
if command -v shasum >/dev/null 2>&1; then sha256() { shasum -a 256; }; else sha256() { sha256sum; }; fi
source_key="$(printf '%s' "$key_material" | sha256 | cut -c1-16)"
if [[ "$print_key" -eq 1 ]]; then printf '%s\n' "$source_key"; exit 0; fi

normalize_archs() {
  local raw="${CMUX_NEXT_SCREEN_HELPER_ARCHS:-${ARCHS:-}}"
  [[ -n "$raw" ]] || raw="$(uname -m)"
  raw="${raw//,/ }"
  local arch normalized=() seen=" "
  for arch in $raw; do
    case "$arch" in
      arm64|aarch64|aarch64-apple-darwin) arch=arm64 ;;
      x86_64|x86_64-apple-darwin|amd64) arch=x86_64 ;;
      *) echo "error: unsupported Screen Sharing helper architecture '$arch'" >&2; exit 2 ;;
    esac
    if [[ "$seen" != *" $arch "* ]]; then normalized+=("$arch"); seen+="$arch "; fi
  done
  printf '%s\n' "${normalized[*]}"
}

archs="$(normalize_archs)"
arch_key="${archs// /-}"
cache_root="${CMUX_NEXT_SCREEN_HELPER_CACHE:-$crate/target/hosted/screen-sharing-helper}"
cache_dir="$cache_root/$source_key/$arch_key"
cache_bin="$cache_dir/cmux-screen-sharing"

copy_output() {
  [[ -n "$output" && "$output" != "$cache_bin" ]] || return 0
  mkdir -p "$(dirname "$output")"
  cp -f "$cache_bin" "$output"
  cp -f "$cache_bin.ref" "$output.ref" 2>/dev/null || true
  chmod 755 "$output"
}

if [[ -x "$cache_bin" ]]; then
  if [[ "$print_path" -eq 1 ]]; then printf '%s\n' "$cache_bin"; else echo "Screen Sharing helper $source_key $arch_key already cached at $cache_bin"; fi
  copy_output
  exit 0
fi
if [[ "$cached_only" -eq 1 ]]; then
  [[ "$print_path" -eq 1 ]] || echo "error: no cached Screen Sharing helper for $source_key $arch_key at $cache_bin" >&2
  exit 1
fi
build_allowed || { echo "error: the Screen Sharing helper is not cached; build it on CI, the fleet or nx-remote, or set CMUX_NEXT_SCREEN_HELPER_BIN" >&2; exit 1; }
command -v cargo >/dev/null 2>&1 || { echo "error: cargo is required to build the Screen Sharing helper" >&2; exit 1; }
command -v rustup >/dev/null 2>&1 || { echo "error: rustup is required to provision the Screen Sharing helper's targets" >&2; exit 1; }

rust_targets=()
for arch in $archs; do
  rust_targets+=("$([[ "$arch" == arm64 ]] && printf aarch64 || printf x86_64)-apple-darwin")
done
echo "==> ensuring Rust targets ${rust_targets[*]} for cmux-rd-host"
# shellcheck source=scripts/lib/rust-targets.sh
source "$repo_root/scripts/lib/rust-targets.sh"
(cd "$crate" && ensure_rust_targets "${rust_targets[@]}")

# A persistent target dir in the crate's own (ignored) target, so the next build of a warm slot
# is incremental. Cargo locks it.
build_root="${CMUX_NEXT_SCREEN_HELPER_TARGET_DIR:-$crate/target/screen-sharing-helper-app}"
mkdir -p "$build_root" "$cache_dir"
slices=()
for target in "${rust_targets[@]}"; do
  echo "==> building the Screen Sharing helper ($source_key, $target)"
  (cd "$crate" && env "${size_profile[@]}" CARGO_TARGET_DIR="$build_root" cargo build --locked --release \
    --no-default-features --features "$features" --bin cmux-rd --target "$target")
  slice="$build_root/$target/release/cmux-rd"
  [[ -x "$slice" ]] || { echo "error: cargo did not produce $slice" >&2; exit 1; }
  slices+=("$slice")
done

staged="$cache_bin.tmp.$$"
rm -f "$staged"
if [[ ${#slices[@]} -eq 1 ]]; then cp "${slices[0]}" "$staged"; else lipo -create "${slices[@]}" -output "$staged"; fi
chmod 755 "$staged"
mv -f "$staged" "$cache_bin"
printf '%s\n' "key=$source_key" "commit=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)" "archs=$archs" \
  "sha256=$(shasum -a 256 "$cache_bin" | awk '{print $1}')" > "$cache_bin.ref"
copy_output
if [[ "$print_path" -eq 1 ]]; then printf '%s\n' "$cache_bin"; else echo "Screen Sharing helper built at $cache_bin"; fi
