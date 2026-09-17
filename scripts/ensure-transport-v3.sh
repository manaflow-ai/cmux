#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"
rustup toolchain install 1.98.1 --profile minimal
exec python3 "$repo_root/services/transport-v3/ops/apple/build.py" \
  --package "$repo_root/Packages/Shared/CmuxV3Transport" \
  --target-dir "${CMUX_V3_CARGO_TARGET_DIR:-$repo_root/services/transport-v3/target-apple}" \
  --release --if-stale
