#!/usr/bin/env bash
set -euo pipefail

SURFACE="${1:-surface:1}"
OUT_DIR="${2:-./browser-artifacts}"
mkdir -p "$OUT_DIR"

TS="$(date +%Y%m%d-%H%M%S)"
cmux browser "$SURFACE" snapshot --interactive > "$OUT_DIR/snapshot-$TS.txt"
cmux browser "$SURFACE" screenshot > "$OUT_DIR/screenshot-$TS.b64"

echo "Wrote: $OUT_DIR/snapshot-$TS.txt"
echo "Wrote: $OUT_DIR/screenshot-$TS.b64"
