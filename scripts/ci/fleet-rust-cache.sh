#!/usr/bin/env bash
# Configure the shared Rust cache for a managed fleet build.
#
# This file is sourced by the fleet recipe after the worker's Rust toolchain
# and CARGO_HOME are ready. It is deliberately opt-in: public CI and
# pull-request forks never receive the worker secret file.

if [[ "${CMUX_FLEET_RUST_CACHE:-0}" != 1 ]]; then
  return 0 2>/dev/null || exit 0
fi

if [[ "${CMUX_FLEET_WORKER:-0}" != 1 ]]; then
  echo "fleet-rust-cache: refusing to enable outside a managed fleet worker" >&2
  return 78 2>/dev/null || exit 78
fi

secret_file="${CMUX_FLEET_RUST_CACHE_SECRET_FILE:-/Users/Shared/cmux-build-fleet/secrets/cmux-rust-cache.env}"
if [[ ! -r "$secret_file" ]]; then
  echo "fleet-rust-cache: worker secret file is missing: $secret_file" >&2
  return 78 2>/dev/null || exit 78
fi

# shellcheck disable=SC1090
set -a
source "$secret_file"
set +a

: "${SCCACHE_BUCKET:?fleet-rust-cache: SCCACHE_BUCKET is missing from the worker secret file}"
: "${SCCACHE_ENDPOINT:?fleet-rust-cache: SCCACHE_ENDPOINT is missing from the worker secret file}"
: "${AWS_ACCESS_KEY_ID:?fleet-rust-cache: AWS_ACCESS_KEY_ID is missing from the worker secret file}"
: "${AWS_SECRET_ACCESS_KEY:?fleet-rust-cache: AWS_SECRET_ACCESS_KEY is missing from the worker secret file}"

# One dedicated bucket is the boundary for this cache. The fleet operator
# provisions a token scoped to this bucket only; refusing another bucket keeps
# an accidentally broad credential from being used by this path.
expected_bucket="cmux-rust-sccache"
if [[ "$SCCACHE_BUCKET" != "$expected_bucket" ]]; then
  echo "fleet-rust-cache: refusing non-dedicated bucket '$SCCACHE_BUCKET'" >&2
  return 78 2>/dev/null || exit 78
fi
if [[ "$SCCACHE_ENDPOINT" != https://* || "$SCCACHE_ENDPOINT" == */ ]]; then
  echo "fleet-rust-cache: SCCACHE_ENDPOINT must be an https URL without a trailing slash" >&2
  return 78 2>/dev/null || exit 78
fi

sccache_bin="${SCCACHE_BIN:-$(command -v sccache || true)}"
if [[ -z "$sccache_bin" || ! -x "$sccache_bin" ]]; then
  echo "fleet-rust-cache: sccache is not installed on this worker" >&2
  return 78 2>/dev/null || exit 78
fi

rust_release="$(rustc -Vv | awk -F': ' '$1 == "release" {print $2; exit}')"
rust_host="$(rustc -Vv | awk -F': ' '$1 == "host" {print $2; exit}')"
toolchain="${RUSTUP_TOOLCHAIN:-$(rustup show active-toolchain | awk '{print $1; exit}')}"
[[ -n "$rust_release" && -n "$rust_host" && -n "$toolchain" ]] || {
  echo "fleet-rust-cache: could not identify the active Rust toolchain" >&2
  return 78 2>/dev/null || exit 78
}

slug() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g'; }
toolchain_slug="$(slug "$toolchain")"
target_hint="$(slug "${CARGO_BUILD_TARGET:-$rust_host}")"
target_root="${CMUX_FLEET_RUST_TARGET_ROOT:-${CI_SHARED_CACHE_DIR:-$HOME/.cache/cmux-build-fleet}/rust-targets}"
export CMUX_FLEET_RUST_TOOLCHAIN="$toolchain_slug"
export CMUX_FLEET_RUST_TARGET_DIR="$target_root/$toolchain_slug"
export CARGO_TARGET_DIR="$CMUX_FLEET_RUST_TARGET_DIR"
export SCCACHE_NAMESPACE="cmux-rust-v1-$toolchain_slug-$target_hint"
export RUSTC_WRAPPER="$sccache_bin"
export SCCACHE_DIR="${CMUX_FLEET_RUST_SCCACHE_DIR:-${CI_SHARED_CACHE_DIR:-$HOME/.cache/cmux-build-fleet}/sccache}"
mkdir -p "$CMUX_FLEET_RUST_TARGET_DIR" "$SCCACHE_DIR"

# sccache includes the complete rustc argument vector in its object key. That
# includes --target for cross builds; the namespace additionally separates the
# pinned compiler and host target so unrelated toolchains cannot share entries.
echo "fleet-rust-cache: enabled bucket=$SCCACHE_BUCKET toolchain=$toolchain_slug target-dir=$CARGO_TARGET_DIR namespace=$SCCACHE_NAMESPACE" >&2
