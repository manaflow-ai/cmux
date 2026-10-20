#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLCHAIN_FILE="$ROOT/Native/DiffSidecar/rust-toolchain.toml"
TOOLCHAIN="$(awk -F '"' '/^[[:space:]]*channel[[:space:]]*=/{print $2; exit}' "$TOOLCHAIN_FILE")"

if [[ -z "$TOOLCHAIN" ]]; then
  echo "error: missing Rust channel in $TOOLCHAIN_FILE" >&2
  exit 1
fi
if ! command -v rustup >/dev/null 2>&1; then
  echo "error: rustup is required for the pinned Rust $TOOLCHAIN toolchain" >&2
  exit 1
fi

exec rustup run "$TOOLCHAIN" cargo "$@"
