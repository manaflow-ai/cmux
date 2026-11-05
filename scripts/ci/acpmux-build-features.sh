#!/usr/bin/env bash
# Shipping features for the selected acpmux source tree and target. Older pinned
# trees have no tailnet feature. Runtime enrollment remains explicitly opt-in.
set -euo pipefail
manifest=${1:?acpmux Cargo.toml}
target=${2:?Rust target triple}
case "$target" in
  aarch64-apple-darwin|x86_64-apple-darwin)
    if awk '
      /^\[features\][[:space:]]*$/ { features=1; next }
      /^\[/ { features=0 }
      features && /^[[:space:]]*tailnet[[:space:]]*=/ { found=1 }
      END { exit !found }
    ' "$manifest"; then
      printf '%s\n' '--features=tailnet'
    fi
    ;;
esac
