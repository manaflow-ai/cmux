#!/usr/bin/env bash
# Build the OptChat Chief brain host (cmux-tui/crates/optchat-chief, its own
# Cargo workspace and lockfile) for the cmux-next app bundle, the same way build-acpmux.sh builds acpmux:
# only on CI or a fleet build (CMUX_FLEET_BUILD_TAG), into an immutable,
# commit-addressed cache that a later local reload may reuse. It never runs
# Cargo on a developer machine, and --cached-only never builds.
#
# The app starts Contents/Resources/bin/optchat-chief as its Home brain host
# when CMUX_NEXT_MUX_HOST names no other host (HomeBrainHost.swift). The
# nightly-next build passes --output and hands the file to the Release build
# through CMUX_NEXT_OPTCHAT_CHIEF_BIN (bundle-optchat-chief.sh).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
crate="$repo_root/cmux-tui/crates/optchat-chief"

usage() {
  sed -n '2,12p' "$0" | sed 's/^# //'
  cat <<'USAGE'

Usage: build-optchat-chief.sh [--output PATH] [--cached-only] [--print-path]
Environment:
  CMUX_NEXT_OPTCHAT_CHIEF_ARCHS  arm64 and/or x86_64 (default: ARCHS, else the host)
  CMUX_NEXT_OPTCHAT_CHIEF_CACHE  cache root (default: <crate>/target/hosted)
USAGE
}

output=""
cached_only=0
print_path=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) output="${2:?missing path after --output}"; shift 2 ;;
    --cached-only) cached_only=1; shift ;;
    --print-path) print_path=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -f "$crate/Cargo.toml" ]] || { echo "error: $crate is missing" >&2; exit 1; }
commit="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "error: cannot determine the source commit" >&2; exit 1; }

raw="${CMUX_NEXT_OPTCHAT_CHIEF_ARCHS:-${ARCHS:-$(uname -m)}}"
archs=""
for arch in ${raw//,/ }; do
  case "$arch" in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64) arch=x86_64 ;;
    *) echo "error: unsupported architecture '$arch'" >&2; exit 2 ;;
  esac
  [[ " $archs " == *" $arch "* ]] || archs="${archs:+$archs }$arch"
done
cache_dir="${CMUX_NEXT_OPTCHAT_CHIEF_CACHE:-$crate/target/hosted}/$commit/${archs// /-}"
cache_bin="$cache_dir/optchat-chief"

# Copies the cached binary to --output (when given) and reports where it is.
deliver() {
  local found="$cache_bin" verb="$1"
  if [[ -n "$output" && "$output" != "$cache_bin" ]]; then
    mkdir -p "$(dirname "$output")"
    cp -f "$cache_bin" "$output"
    cp -f "$cache_bin.ref" "$output.ref" 2>/dev/null || true
    chmod 755 "$output"
    found="$output"
  fi
  if [[ "$print_path" -eq 1 ]]; then printf '%s\n' "$found"; else echo "optchat-chief $verb at $found"; fi
}

if [[ -x "$cache_bin" ]]; then
  deliver "already cached"
  exit 0
fi
if [[ "$cached_only" -eq 1 ]]; then
  [[ "$print_path" -eq 1 ]] || echo "error: no cached optchat-chief at $cache_bin" >&2
  exit 1
fi
[[ -n "${CI:-}${GITHUB_ACTIONS:-}${CMUX_FLEET_BUILD_TAG:-}" ]] || {
  echo "error: optchat-chief is not cached; build it on CI or the fleet (cargo never runs on a developer Mac)" >&2
  exit 1
}
command -v cargo >/dev/null 2>&1 || { echo "error: cargo is required to build optchat-chief" >&2; exit 1; }

# The crate is its own workspace (no rust-toolchain.toml); build it with the
# toolchain cmux-tui pins, which the fleet already has for acpmux.
toolchain="$(sed -n 's/^channel *= *"\(.*\)"/\1/p' "$repo_root/cmux-tui/rust-toolchain.toml")"
[[ -n "$toolchain" ]] || { echo "error: cannot read cmux-tui/rust-toolchain.toml" >&2; exit 1; }
targets=()
for arch in $archs; do targets+=("$([[ "$arch" == arm64 ]] && printf aarch64 || printf x86_64)-apple-darwin"); done
if command -v rustup >/dev/null 2>&1; then
  rustup toolchain install "$toolchain" --profile minimal >/dev/null
  rustup target add --toolchain "$toolchain" "${targets[@]}" >/dev/null
fi

mkdir -p "$cache_dir"
slices=()
for target in "${targets[@]}"; do
  echo "==> building optchat-chief ($commit, $target)"
  # A persistent target dir under the crate keeps later fleet builds incremental.
  (cd "$crate" && OPTCHAT_BUILD_COMMIT="${commit:0:11}" CARGO_TARGET_DIR="$crate/target/app" \
    cargo "+$toolchain" build --locked --release --bin optchat-chief --target "$target")
  slice="$crate/target/app/$target/release/optchat-chief"
  [[ -x "$slice" ]] || { echo "error: cargo did not produce $slice" >&2; exit 1; }
  slices+=("$slice")
done
staged="$cache_bin.tmp.$$"
if [[ ${#slices[@]} -eq 1 ]]; then cp "${slices[0]}" "$staged"; else lipo -create "${slices[@]}" -output "$staged"; fi
chmod 755 "$staged"
mv -f "$staged" "$cache_bin"
printf '%s\n' "commit=$commit" "archs=$archs" "sha256=$(shasum -a 256 "$cache_bin" | awk '{print $1}')" > "$cache_bin.ref"
deliver built
