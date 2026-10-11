#!/usr/bin/env bash
# Rebuilds src/optchat-wasm from Native/OptChat/optchat-wasm (Rust) on the build host: Cargo never runs on
# the laptop. Needs the wasm32-unknown-unknown target and wasm-bindgen-cli 0.2.129 there.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$(git rev-parse --show-toplevel)"
rel="Native/OptChat/optchat-wasm"
nx-remote --cwd "$rel" --fetch "$rel/pkg" -- bash -c \
  'umask 022; cargo build --release --target wasm32-unknown-unknown && wasm-bindgen --target web --out-dir pkg target/wasm32-unknown-unknown/release/optchat_wasm.wasm'
job="$(ls -t "$root/artifacts/nx-remote" | head -1)"
cp "$root/artifacts/nx-remote/$job/$rel/pkg/"optchat_wasm{.js,.d.ts,_bg.wasm,_bg.wasm.d.ts} src/optchat-wasm/
echo "src/optchat-wasm updated from job $job"
