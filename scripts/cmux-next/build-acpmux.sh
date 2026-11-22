#!/usr/bin/env bash
# Build the acpmux daemon from the in-tree cmux-tui workspace for cmux-next.
#
# CI and fleet reload jobs call this script after installing Rust. It keeps an
# immutable, commit-addressed result under cmux-tui/target/hosted so a tagged
# reload can reuse the result without compiling locally. The script never
# downloads or builds when --cached-only is used.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() {
  sed -n '2,9p' "$0" | sed 's/^# //'
  cat <<'USAGE'

Usage: build-acpmux.sh [--output PATH] [--cached-only] [--print-path] [--check-build-allowed]
  --check-build-allowed  exit 0 when this host may build acpmux on a miss
Environment:
  CMUX_NEXT_ACPMUX_ARCHS  space/comma-separated arm64 and/or x86_64 (default: host)
  CMUX_NEXT_ACPMUX_CACHE  cache root (default: cmux-tui/target/hosted/acpmux)
USAGE
}

# A build host may run Cargo on a miss: CI, a fleet build (CMUX_FLEET_BUILD_TAG)
# or an nx-remote job on a build host (NX_JOB_ID). A developer Mac never does.
build_allowed() { [[ -n "${CI:-}${GITHUB_ACTIONS:-}${CMUX_FLEET_BUILD_TAG:-}${NX_JOB_ID:-}" ]]; }
cached_only=0
print_path=0
output=""
build_root=""
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

source_mode=in-tree
source_root="$repo_root"
source_commit="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)"
[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || {
  echo "error: cannot determine the in-tree acpmux source commit" >&2
  exit 1
}
[[ -f "$source_root/cmux-tui/crates/acpmux/Cargo.toml" ]] || {
  echo "error: in-tree cmux-tui/crates/acpmux is missing" >&2
  exit 1
}

normalize_archs() {
  local raw="${CMUX_NEXT_ACPMUX_ARCHS:-${ARCHS:-}}"
  if [[ -z "$raw" ]]; then
    raw="$(uname -m)"
  fi
  raw="${raw//,/ }"
  local arch normalized=() seen=" "
  for arch in $raw; do
    case "$arch" in
      arm64|aarch64|aarch64-apple-darwin) arch=arm64 ;;
      x86_64|x86_64-apple-darwin|amd64) arch=x86_64 ;;
      *) echo "error: unsupported acpmux architecture '$arch' (use arm64 and/or x86_64)" >&2; exit 2 ;;
    esac
    if [[ "$seen" != *" $arch "* ]]; then
      normalized+=("$arch")
      seen+="$arch "
    fi
  done
  [[ ${#normalized[@]} -gt 0 ]] || { echo "error: no acpmux architectures selected" >&2; exit 2; }
  printf '%s\n' "${normalized[*]}"
}

archs="$(normalize_archs)"
arch_key="${archs// /-}"
cache_root="${CMUX_NEXT_ACPMUX_CACHE:-$repo_root/cmux-tui/target/hosted/acpmux}"
cache_dir="$cache_root/in-tree-$source_commit/$arch_key"
cache_bin="$cache_dir/acpmux"

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

if [[ -x "$cache_bin" ]]; then
  if [[ "$print_path" -eq 1 ]]; then
    printf '%s\n' "$cache_bin"
  else
    echo "acpmux ${source_mode} $arch_key already cached at $cache_bin"
  fi
  if [[ -n "$output" && "$output" != "$cache_bin" ]]; then
    mkdir -p "$(dirname "$output")"
    cp -f "$cache_bin" "$output"
    cp -f "$cache_bin.ref" "$output.ref"
    chmod 755 "$output"
  fi
  exit 0
fi

if [[ "$cached_only" -eq 1 ]]; then
  [[ "$print_path" -eq 1 ]] || echo "error: no cached acpmux for ${source_mode} ${arch_key} at $cache_bin" >&2
  exit 1
fi

build_allowed || {
  echo "error: acpmux is not cached; build it on CI, the fleet or nx-remote, or set CMUX_NEXT_ACPMUX_BIN" >&2
  exit 1
}

command -v cargo >/dev/null 2>&1 || { echo "error: cargo is required to build acpmux" >&2; exit 1; }
command -v rustup >/dev/null 2>&1 || { echo "error: rustup is required to provision acpmux targets" >&2; exit 1; }
# Install the targets into the toolchain cargo actually uses: cmux-tui pins its
# own channel in rust-toolchain.toml, so rustup must run from that directory
# (from the repo root it would provision the default toolchain instead, and the
# x86_64 slice would fail with "can't find crate for core"). Idempotent.
rust_targets=()
for arch in $archs; do
  rust_targets+=("$([[ "$arch" == arm64 ]] && printf aarch64 || printf x86_64)-apple-darwin")
done
echo "==> ensuring Rust targets ${rust_targets[*]} for the cmux-tui toolchain"
(cd "$source_root/cmux-tui" && rustup target add "${rust_targets[@]}")

# A persistent target dir in the tree's own (ignored) cmux-tui/target: the
# next commit of a warm tree or fleet slot compiles incrementally instead of
# all 200+ crates (cx-t3e5). Cargo locks it against concurrent builds.
build_root="${CMUX_NEXT_ACPMUX_TARGET_DIR:-$source_root/cmux-tui/target/acpmux-app}"
mkdir -p "$build_root" "$cache_dir"
built_slices=()
for arch in $archs; do
  target="$([[ "$arch" == arm64 ]] && printf aarch64 || printf x86_64)-apple-darwin"
  target_dir="$build_root"
  echo "==> building acpmux ($source_mode $source_commit, $target)"
  (cd "$source_root/cmux-tui" && CARGO_TARGET_DIR="$target_dir" cargo build \
    --locked --release --package acpmux --target "$target")
  slice="$target_dir/$target/release/acpmux"
  [[ -x "$slice" ]] || { echo "error: cargo did not produce $slice" >&2; exit 1; }
  built_slices+=("$slice")
done

staged="$cache_bin.tmp.$$"
rm -f "$staged"
if [[ ${#built_slices[@]} -eq 1 ]]; then
  cp "${built_slices[0]}" "$staged"
else
  command -v lipo >/dev/null 2>&1 || { echo "error: lipo is required for a universal acpmux" >&2; exit 1; }
  lipo -create "${built_slices[@]}" -output "$staged"
fi
chmod 755 "$staged"
mv -f "$staged" "$cache_bin"
printf '%s\n' "commit=$source_commit" "source=$source_mode" "archs=$archs" "sha256=$(sha256_of "$cache_bin")" > "$cache_bin.ref"

if [[ -n "$output" && "$output" != "$cache_bin" ]]; then
  mkdir -p "$(dirname "$output")"
  cp -f "$cache_bin" "$output"
  cp -f "$cache_bin.ref" "$output.ref"
  chmod 755 "$output"
  [[ "$print_path" -eq 1 ]] && printf '%s\n' "$output"
  echo "built acpmux at $output"
elif [[ "$print_path" -eq 1 ]]; then
  printf '%s\n' "$cache_bin"
else
  echo "built acpmux at $cache_bin"
fi
