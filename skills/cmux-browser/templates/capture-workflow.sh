#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${1:-}" ]]; then
  printf 'Usage: %s <tab_id|page> [output-directory]\n' "${0##*/}" >&2
  exit 2
fi

TAB="$1"
OUT_DIR="${2:-./browser-artifacts}"
mkdir -p "$OUT_DIR"

# Scripted screenshots were removed; save the snapshot and page state.
TS="$(date +%Y%m%d-%H%M%S)"
cmux browser "$TAB" snapshot --interactive > "$OUT_DIR/snapshot-$TS.txt"
cmux --json browser "$TAB" state > "$OUT_DIR/state-$TS.json"

echo "Wrote: $OUT_DIR/snapshot-$TS.txt"
echo "Wrote: $OUT_DIR/state-$TS.json"
