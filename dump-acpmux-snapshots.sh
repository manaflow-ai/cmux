#!/usr/bin/env bash
set -euo pipefail
cd cmux-tui
env ACPMUX_PROTOCOL_BLESS=1 cargo test -p acpmux --lib -- protocol::
printf '\n---PROTOCOL---\n'
base64 -w0 crates/acpmux/spec/acpmux-protocol.json
printf '\n---ABI---\n'
base64 -w0 crates/acpmux/spec/acpmux-abi.surface.json
printf '\n---END---\n'
