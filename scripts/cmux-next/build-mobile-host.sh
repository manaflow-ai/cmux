#!/usr/bin/env bash
# Build cmux-mobile-host, the cmux mobile iPhone host (cmux-next-ios/rust/crates/cmux-mobile-host),
# for cmux-next's Settings > Mobile > Allow iPhone Connections. The app runs it as a child
# (CMUX_MOBILE_CONTROL=stdio) from Contents/Resources/bin/cmux-mobile-host.
#
# Same contract as build-acpmux.sh: CI, fleet and nx-remote builds run Cargo on
# a miss; a developer Mac only reuses the cache and never runs Cargo. The cache
# is keyed by the source of cmux-next-ios/rust and the two cmux-tui crates it uses,
# so an app-only commit reuses the last build.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() {
  sed -n '2,9p' "$0" | sed 's/^# //'
  cat <<'USAGE'

Usage: build-mobile-host.sh [--output PATH] [--cached-only] [--print-path] [--check-build-allowed]
  --output PATH  also copy the binary (and PATH.ref) there
Environment:
  CMUX_NEXT_MOBILE_HOST_ARCHS  space/comma-separated arm64 and/or x86_64 (default: ARCHS, else host)
  CMUX_NEXT_MOBILE_HOST_CACHE  cache root (default: cmux-next-ios/rust/target/hosted/cmux-mobile-host)
USAGE
}

build_allowed() { [[ -n "${CI:-}${GITHUB_ACTIONS:-}${CMUX_FLEET_BUILD_TAG:-}${NX_JOB_ID:-}" ]]; }
cached_only=0
print_path=0
output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) output="${2:?missing path after --output}"; shift 2 ;;
    --cached-only) cached_only=1; shift ;;
    --print-path) print_path=1; shift ;;
    --check-build-allowed) build_allowed; exit $? ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

rust_root="$repo_root/cmux-next-ios/rust"
[[ -f "$rust_root/crates/cmux-mobile-host/Cargo.toml" ]] || { echo "error: cmux-next-ios/rust/crates/cmux-mobile-host is missing" >&2; exit 1; }

# The source key: the committed trees of every input, plus any uncommitted
# change to them (a --working-tree fleet build), so a stale build is never reused.
# cmux-mobile-host links the remote-desktop crates through cmux-mobile-link;
# include those path trees or an rd-only edit could reuse stale host bytes.
inputs=(cmux-next-ios/rust cmux-tui/crates/cmux-wg cmux-tui/crates/cmux-transport
  cmux-tui/crates/cmux-rd-proto cmux-tui/crates/cmux-rd-core
  cmux-tui/crates/cmux-rd-engine cmux-tui/crates/cmux-rd-ffi cmux-tui/Cargo.toml)
key_material=""
for input in "${inputs[@]}"; do
  key_material+="$(git -C "$repo_root" rev-parse "HEAD:$input" 2>/dev/null || echo "missing:$input")"$'\n'
done
key_material+="$(git -C "$repo_root" diff HEAD -- "${inputs[@]}" 2>/dev/null || true)"
key_material+="$(git -C "$repo_root" ls-files --others --exclude-standard -- "${inputs[@]}" 2>/dev/null || true)"
source_key="$(printf '%s' "$key_material" | shasum -a 256 | cut -c1-16)"

normalize_archs() {
  local raw="${CMUX_NEXT_MOBILE_HOST_ARCHS:-${ARCHS:-}}"
  [[ -n "$raw" ]] || raw="$(uname -m)"
  raw="${raw//,/ }"
  local arch normalized=() seen=" "
  for arch in $raw; do
    case "$arch" in
      arm64|aarch64|aarch64-apple-darwin) arch=arm64 ;;
      x86_64|x86_64-apple-darwin|amd64) arch=x86_64 ;;
      *) echo "error: unsupported cmux-mobile-host architecture '$arch'" >&2; exit 2 ;;
    esac
    if [[ "$seen" != *" $arch "* ]]; then normalized+=("$arch"); seen+="$arch "; fi
  done
  printf '%s\n' "${normalized[*]}"
}

archs="$(normalize_archs)"
arch_key="${archs// /-}"
cache_root="${CMUX_NEXT_MOBILE_HOST_CACHE:-$rust_root/target/hosted/cmux-mobile-host}"
cache_dir="$cache_root/$source_key/$arch_key"
cache_bin="$cache_dir/cmux-mobile-host"

copy_output() {
  [[ -n "$output" && "$output" != "$cache_bin" ]] || return 0
  mkdir -p "$(dirname "$output")"
  cp -f "$cache_bin" "$output"
  cp -f "$cache_bin.ref" "$output.ref" 2>/dev/null || true
  chmod 755 "$output"
}

if [[ -x "$cache_bin" ]]; then
  if [[ "$print_path" -eq 1 ]]; then printf '%s\n' "$cache_bin"; else echo "cmux-mobile-host $source_key $arch_key already cached at $cache_bin"; fi
  copy_output
  exit 0
fi
if [[ "$cached_only" -eq 1 ]]; then
  [[ "$print_path" -eq 1 ]] || echo "error: no cached cmux-mobile-host for $source_key $arch_key at $cache_bin" >&2
  exit 1
fi
build_allowed || { echo "error: cmux-mobile-host is not cached; build it on CI, the fleet or nx-remote, or set CMUX_NEXT_MOBILE_HOST_BIN" >&2; exit 1; }
command -v cargo >/dev/null 2>&1 || { echo "error: cargo is required to build cmux-mobile-host" >&2; exit 1; }
command -v rustup >/dev/null 2>&1 || { echo "error: rustup is required to provision cmux-mobile-host targets" >&2; exit 1; }

rust_targets=()
for arch in $archs; do
  rust_targets+=("$([[ "$arch" == arm64 ]] && printf aarch64 || printf x86_64)-apple-darwin")
done
echo "==> ensuring Rust targets ${rust_targets[*]} for the cmux-next-ios toolchain"
(cd "$rust_root" && rustup target add "${rust_targets[@]}")

# A persistent target dir in the tree's own (ignored) cmux-next-ios/rust/target, so
# the next build of a warm slot is incremental. Cargo locks it.
build_root="${CMUX_NEXT_MOBILE_HOST_TARGET_DIR:-$rust_root/target/cmux-mobile-host-app}"
mkdir -p "$build_root" "$cache_dir"
slices=()
for target in "${rust_targets[@]}"; do
  echo "==> building cmux-mobile-host ($source_key, $target)"
  (cd "$rust_root" && CARGO_TARGET_DIR="$build_root" cargo build --locked --release --package cmux-mobile-host --bin cmux-mobile-host --target "$target")
  slice="$build_root/$target/release/cmux-mobile-host"
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
if [[ "$print_path" -eq 1 ]]; then printf '%s\n' "$cache_bin"; else echo "cmux-mobile-host built at $cache_bin"; fi
