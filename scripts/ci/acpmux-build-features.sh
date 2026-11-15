#!/usr/bin/env bash
# Shipping features for the selected acpmux source tree and target. Older pinned
# trees have no tailnet or hub-carrier feature. Runtime enrollment remains explicitly opt-in.
set -euo pipefail
manifest=${1:?acpmux Cargo.toml}
target=${2:?Rust target triple}
has_feature() {
  awk -v name="$1" '
    /^\[features\][[:space:]]*$/ { features=1; next }
    /^\[/ { features=0 }
    features && $0 ~ "^[[:space:]]*" name "[[:space:]]*=" { found=1 }
    END { exit !found }
  ' "$manifest"
}
features=""
case "$target" in
  aarch64-apple-darwin|x86_64-apple-darwin)
    if has_feature tailnet; then features="tailnet"; fi
    ;;
esac
# The hub carrier (src/hub_carrier.rs) ships on macOS and Linux, whose package
# jobs build libghostty-vt with zig for cmux-tui anyway.
case "$target" in
  *-apple-darwin|*-linux-gnu|*-linux-musl)
    if has_feature hub-carrier; then features="${features:+$features,}hub-carrier"; fi
    ;;
esac
if [[ -n "$features" ]]; then
  printf '%s\n' "--features=$features"
fi
