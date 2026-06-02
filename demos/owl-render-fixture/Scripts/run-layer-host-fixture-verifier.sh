#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

HOST="${OWL_CHROMIUM_HOST:-$HOME/chromium/src/out/Release/Content Shell.app/Contents/MacOS/Content Shell}"
RUNTIME="${OWL_MOJO_RUNTIME_PATH:-$HOME/chromium/src/out/Release/libowl_fresh_mojo_runtime.dylib}"
OUT_DIR="${OWL_LAYER_HOST_FIXTURE_OUT:-$ROOT_DIR/artifacts/layer-host-fixture-latest}"
CHROMIUM_OUT="$(cd "$(dirname "$RUNTIME")" && pwd)"

if [ ! -x "$HOST" ]; then
  echo "Missing Chromium host executable: $HOST" >&2
  exit 1
fi

if [ ! -f "$RUNTIME" ]; then
  echo "Missing OWL Mojo runtime dylib: $RUNTIME" >&2
  exit 1
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

cd "$ROOT_DIR"
OWL_FRESH_LAYER_FIXTURE=1 \
DYLD_LIBRARY_PATH="$CHROMIUM_OUT${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
  swift run -c release OwlLayerHostVerifier \
    --chromium-host "$HOST" \
    --mojo-runtime "$RUNTIME" \
    --output-dir "$OUT_DIR" \
    --skip-example
