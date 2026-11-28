#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "Running release pre-tag checks..."
"$ROOT_DIR/tests/test_ci_sparkle_build_monotonic.sh"
python3 "$ROOT_DIR/scripts/release_whats_new_gate.py" ${CMUX_RELEASE_VERSION:+--version "$CMUX_RELEASE_VERSION"}
echo "Release pre-tag checks passed."
