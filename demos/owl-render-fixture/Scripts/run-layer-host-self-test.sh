#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="${OWL_LAYER_HOST_SELF_TEST_OUT:-$ROOT_DIR/artifacts/layer-host-self-test-latest}"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

cd "$ROOT_DIR"
swift run -c release OwlLayerHostSelfTest \
  --output-dir "$OUT_DIR/direct" \
  --mode direct

swift run -c release OwlLayerHostSelfTest \
  --output-dir "$OUT_DIR/layer-host" \
  --mode layer-host
