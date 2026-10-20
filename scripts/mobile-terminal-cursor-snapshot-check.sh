#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s <mobile-snapshot.json>\n' "$(basename "$0")" >&2
}

if (( $# != 1 )); then
  usage
  exit 2
fi

snapshot_file="$1"

if [[ ! -f "$snapshot_file" ]]; then
  printf 'Snapshot file does not exist: %s\n' "$snapshot_file" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  printf 'jq is required to check the cursor snapshot.\n' >&2
  exit 2
fi

target_line="$(
  jq -r '
    .snapshot.visibleRows[]?.cells?
    | map(.text // "")
    | join("")
    | select(contains("cursor_row=") and contains("cursor_col="))
  ' "$snapshot_file" | head -n 1
)"

if [[ ! "$target_line" =~ cursor_row=([0-9]+)[[:space:]]+cursor_col=([0-9]+) ]]; then
  printf 'Could not find cursor_row/cursor_col target text in snapshot.\n' >&2
  exit 1
fi

target_row="${BASH_REMATCH[1]}"
target_col="${BASH_REMATCH[2]}"

read -r cursor_visible cursor_row_zero cursor_col_zero grid_rows grid_cols < <(
  jq -r '
    [
      (.snapshot.cursor.isVisible // false),
      (.snapshot.cursor.row // ""),
      (.snapshot.cursor.column // ""),
      (.snapshot.gridSize.rows // ""),
      (.snapshot.gridSize.columns // "")
    ]
    | @tsv
  ' "$snapshot_file"
)

if [[ "$cursor_visible" != "true" ]]; then
  printf 'Cursor is not visible in snapshot.\n' >&2
  exit 1
fi

if [[ ! "$cursor_row_zero" =~ ^[0-9]+$ || ! "$cursor_col_zero" =~ ^[0-9]+$ ]]; then
  printf 'Snapshot cursor row/column are missing or invalid.\n' >&2
  exit 1
fi

cursor_row=$(( cursor_row_zero + 1 ))
cursor_col=$(( cursor_col_zero + 1 ))

if (( cursor_row != target_row || cursor_col != target_col )); then
  printf 'Cursor mismatch: cursor row=%s col=%s, target row=%s col=%s\n' \
    "$cursor_row" "$cursor_col" "$target_row" "$target_col" >&2
  exit 1
fi

printf 'cursor snapshot ok: row=%s col=%s grid=%sx%s\n' \
  "$cursor_row" "$cursor_col" "$grid_rows" "$grid_cols"
