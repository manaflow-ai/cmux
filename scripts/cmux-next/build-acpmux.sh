#!/usr/bin/env bash
# Build the acpmux daemon from the pinned source ref for cmux-next.
#
# CI and fleet reload jobs call this script after installing Rust. It keeps an
# immutable, ref-addressed result under cmux-tui/target/hosted so a tagged
# reload can reuse the result without compiling locally. The script never
# downloads or builds when --cached-only is used.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ref_file="$repo_root/scripts/cmux-next/acpmux.ref"

usage() {
  sed -n '2,9p' "$0" | sed 's/^# //'
  cat <<'USAGE'

Usage: build-acpmux.sh [--output PATH] [--cached-only] [--print-path]
Environment:
  CMUX_NEXT_ACPMUX_ARCHS  space/comma-separated arm64 and/or x86_64 (default: host)
  CMUX_NEXT_ACPMUX_CACHE  cache root (default: cmux-tui/target/hosted/acpmux)
USAGE
}

cached_only=0
print_path=0
output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) output="${2:?missing path after --output}"; shift 2 ;;
    --cached-only) cached_only=1; shift ;;
    --print-path) print_path=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

pin_field() { awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$ref_file"; }
[[ -f "$ref_file" ]] || { echo "error: missing $ref_file" >&2; exit 1; }
pinned_commit="$(pin_field commit)"
repository="$(pin_field repository)"
[[ "$pinned_commit" =~ ^[0-9a-f]{40}$ ]] || { echo "error: malformed acpmux ref commit in $ref_file" >&2; exit 1; }
[[ "$repository" == https://* ]] || { echo "error: malformed acpmux ref repository in $ref_file" >&2; exit 1; }

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
cache_dir="$cache_root/$pinned_commit/$arch_key"
cache_bin="$cache_dir/acpmux"

if [[ -f "$repo_root/cmux-tui/crates/acpmux/Cargo.toml" ]]; then
  # Once the source branch merges, use the in-tree crate and key its cache by
  # the checkout. Keep the ref file as the transition marker for old builds.
  source_mode=in-tree
  source_root="$repo_root"
  source_commit="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || printf '%s' in-tree)"
  cache_dir="$cache_root/in-tree-$source_commit/$arch_key"
  cache_bin="$cache_dir/acpmux"
else
  source_mode=pinned
  source_root=""
fi

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
    chmod 755 "$output"
  fi
  exit 0
fi

if [[ "$cached_only" -eq 1 ]]; then
  [[ "$print_path" -eq 1 ]] || echo "error: no cached acpmux for ${source_mode} ${arch_key} at $cache_bin" >&2
  exit 1
fi

if [[ "$source_mode" == pinned ]]; then
  [[ -n "${CI:-}${GITHUB_ACTIONS:-}" ]] || {
    echo "error: acpmux is not cached; build it on CI/fleet and set CMUX_NEXT_ACPMUX_BIN (or run this script there)" >&2
    exit 1
  }
  source_checkout="$(mktemp -d "${TMPDIR:-/tmp}/cmux-acpmux-src.XXXXXX")"
  trap 'rm -rf "$source_checkout"' EXIT
  git -C "$source_checkout" init -q
  git -C "$source_checkout" remote add origin "$repository"
  echo "==> fetching acpmux source $pinned_commit"
  git -C "$source_checkout" fetch --depth=1 origin "$pinned_commit"
  git -C "$source_checkout" checkout -q --detach FETCH_HEAD
  source_root="$source_checkout"
fi

command -v cargo >/dev/null 2>&1 || { echo "error: cargo is required to build acpmux" >&2; exit 1; }
command -v rustup >/dev/null 2>&1 || { echo "error: rustup is required to provision acpmux targets" >&2; exit 1; }
for arch in $archs; do
  target="$([[ "$arch" == arm64 ]] && printf aarch64 || printf x86_64)-apple-darwin"
  if ! rustup target list --installed | grep -Fxq "$target"; then
    echo "==> installing Rust target $target"
    rustup target add "$target"
  fi
done

build_root="$(mktemp -d "${TMPDIR:-/tmp}/cmux-acpmux-build.XXXXXX")"
trap 'rm -rf "$build_root"' EXIT
mkdir -p "$cache_dir"
built_slices=()
for arch in $archs; do
  target="$([[ "$arch" == arm64 ]] && printf aarch64 || printf x86_64)-apple-darwin"
  target_dir="$build_root/$target"
  echo "==> building acpmux ($source_mode $pinned_commit, $target)"
  CARGO_TARGET_DIR="$target_dir" cargo build --manifest-path "$source_root/cmux-tui/Cargo.toml" \
    --locked --release --package acpmux --target "$target"
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
printf '%s\n' "commit=$pinned_commit" "source=$source_mode" "archs=$archs" "sha256=$(sha256_of "$cache_bin")" > "$cache_bin.ref"

if [[ -n "$output" && "$output" != "$cache_bin" ]]; then
  mkdir -p "$(dirname "$output")"
  cp -f "$cache_bin" "$output"
  chmod 755 "$output"
  [[ "$print_path" -eq 1 ]] && printf '%s\n' "$output"
  echo "built acpmux at $output"
elif [[ "$print_path" -eq 1 ]]; then
  printf '%s\n' "$cache_bin"
else
  echo "built acpmux at $cache_bin"
fi
