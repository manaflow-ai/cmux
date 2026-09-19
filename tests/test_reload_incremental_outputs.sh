#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/reload-incremental.sh"

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-reload-incremental.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

for STEP in cmuxd ghostty cua tui; do
  INPUT="$TEMP_DIR/${STEP}.input"
  OUTPUT="$TEMP_DIR/${STEP}.output"
  RECEIPT="$TEMP_DIR/${STEP}.receipt"
  printf 'initial\n' > "$INPUT"
  printf 'built\n' > "$OUTPUT"
  INPUT_DIGEST="$(reload_incremental_tree_digest "$INPUT")"
  reload_incremental_record "$RECEIPT" "$INPUT_DIGEST" "$OUTPUT"

  ! reload_incremental_needs_update "$RECEIPT" "$INPUT_DIGEST" "$OUTPUT"
  printf 'changed\n' >> "$INPUT"
  CHANGED_DIGEST="$(reload_incremental_tree_digest "$INPUT")"
  reload_incremental_needs_update "$RECEIPT" "$CHANGED_DIGEST" "$OUTPUT"
  rm "$OUTPUT"
  reload_incremental_needs_update "$RECEIPT" "$INPUT_DIGEST" "$OUTPUT"
  printf 'recreated\n' > "$OUTPUT"
  reload_incremental_record "$RECEIPT" "$INPUT_DIGEST" "$OUTPUT"
  printf 'corrupted\n' > "$OUTPUT"
  reload_incremental_needs_update "$RECEIPT" "$INPUT_DIGEST" "$OUTPUT"
done

echo "reload incremental output checks passed"
