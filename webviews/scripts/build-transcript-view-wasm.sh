#!/usr/bin/env bash
# Rebuilds the native transcript's Rust (cmux-tui crate cmux-transcript-view) as the wasm the
# Worker loads (src/agent-session/acpmux/nativeTranscript/transcript_view.wasm, committed like
# web/public/ghostty-vt.wasm). Run after changing the crate; needs `rustup target add wasm32-unknown-unknown`.
set -euo pipefail
webviews="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tui="$webviews/../cmux-tui"
target="${CARGO_TARGET_DIR:-$tui/target}"
CARGO_PROFILE_RELEASE_STRIP=true CARGO_TARGET_DIR="$target" \
  cargo build --manifest-path "$tui/Cargo.toml" --release -p cmux-transcript-view --target wasm32-unknown-unknown
cp "$target/wasm32-unknown-unknown/release/cmux_transcript_view.wasm" \
  "$webviews/src/agent-session/acpmux/nativeTranscript/transcript_view.wasm"
