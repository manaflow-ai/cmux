#!/usr/bin/env bash
# Builds and tests rust-change-class (a fleet step: cmux-ci test --setup rust -- bash scripts/cmux-next/rust-change-class/check.sh).
set -euo pipefail
cd "$(dirname "$0")"
cargo test --locked 2>&1 | tail -30
