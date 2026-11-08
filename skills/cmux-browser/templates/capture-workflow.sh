#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${1:-}" ]]; then
  printf 'Usage: %s <surface> [output-directory]\n' "${0##*/}" >&2
  exit 2
fi

SURFACE="$1"
OUT_DIR="${2:-./browser-artifacts}"
mkdir -p "$OUT_DIR"

TS="$(date +%Y%m%d-%H%M%S)"
cmux browser --surface "$SURFACE" snapshot --interactive > "$OUT_DIR/snapshot-$TS.txt"
cmux browser --surface "$SURFACE" screenshot > "$OUT_DIR/screenshot-$TS.b64"

echo "Wrote: $OUT_DIR/snapshot-$TS.txt"
echo "Wrote: $OUT_DIR/screenshot-$TS.b64"
