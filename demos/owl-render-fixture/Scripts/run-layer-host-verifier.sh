#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

HOST="${OWL_CHROMIUM_HOST:-$HOME/chromium/src/out/Release/Content Shell.app/Contents/MacOS/Content Shell}"
RUNTIME="${OWL_MOJO_RUNTIME_PATH:-$HOME/chromium/src/out/Release/libowl_fresh_mojo_runtime.dylib}"
OUT_DIR="${OWL_LAYER_HOST_RENDER_OUT:-$ROOT_DIR/artifacts/layer-host-latest}"
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

args=(
  --chromium-host "$HOST"
  --mojo-runtime "$RUNTIME"
  --output-dir "$OUT_DIR"
)

if [ "${OWL_LAYER_HOST_SKIP_EXAMPLE:-}" = "1" ]; then
  args+=(--skip-example)
fi
if [ "${OWL_LAYER_HOST_SKIP_CANVAS:-}" = "1" ]; then
  args+=(--skip-canvas)
fi
if [ "${OWL_LAYER_HOST_INPUT_CHECK:-}" = "1" ]; then
  args+=(--input-check)
fi
if [ "${OWL_LAYER_HOST_RESIZE_CHECK:-}" = "1" ]; then
  args+=(--resize-check)
fi
if [ "${OWL_LAYER_HOST_LIFECYCLE_CHECK:-}" = "1" ]; then
  args+=(--lifecycle-check)
fi
if [ "${OWL_LAYER_HOST_SCALE_CHECK:-}" = "1" ]; then
  args+=(--scale-check)
fi
if [ "${OWL_LAYER_HOST_GOOGLE_CHECK:-}" = "1" ]; then
  args+=(--google-check)
fi
if [ "${OWL_LAYER_HOST_WIDGET_CHECK:-}" = "1" ]; then
  args+=(--widget-check)
fi
if [ "${OWL_LAYER_HOST_INPUT_DIAGNOSTIC_CAPTURE:-}" = "1" ]; then
  args+=(--input-diagnostic-capture)
fi
if [ -n "${OWL_LAYER_HOST_ONLY_TARGETS:-}" ]; then
  IFS=',' read -ra only_targets <<< "$OWL_LAYER_HOST_ONLY_TARGETS"
  for target in "${only_targets[@]}"; do
    args+=(--only-target "$target")
  done
fi

cd "$ROOT_DIR"
DYLD_LIBRARY_PATH="$CHROMIUM_OUT${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
  swift run -c release OwlLayerHostVerifier \
    "${args[@]}"
