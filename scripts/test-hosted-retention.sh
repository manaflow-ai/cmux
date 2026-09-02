#!/usr/bin/env bash
set -euo pipefail
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
preview="$tmp/.retention-preview"
commit=abc123
retention_count=2
plan="$(printf 'commit\t%s\nretention_count\t%s\ncandidate\t%s\ncandidate\t%s' \
  "$commit" "$retention_count" \
  /tmp/0000000000000000000000000000000000000001 \
  /tmp/0000000000000000000000000000000000000002)"
write_preview() {
  {
    printf '%s\n' "$plan"
    printf 'timestamp\t%s\n' "$1"
  } > "$preview"
}
valid_preview() {
  [[ -f "$preview" ]] || return 1
  preview_timestamp="$(tail -n 1 "$preview" | cut -f2)"
  [[ "$preview_timestamp" =~ ^[0-9]+$ ]] || return 1
  [[ "$(sed '$d' "$preview")" == "$plan" ]] || return 1
  now="$(date +%s)"
  (( preview_timestamp <= now && now - preview_timestamp <= 600 ))
}
expect_invalid() { if valid_preview; then return 1; fi; }
expect_invalid
write_preview "$(date +%s)"
valid_preview
plan=$'commit\tchanged\nretention_count\t2\ncandidate\t/tmp/0000000000000000000000000000000000000001\ncandidate\t/tmp/0000000000000000000000000000000000000002'
expect_invalid
plan=$'commit\tabc123\nretention_count\t3\ncandidate\t/tmp/0000000000000000000000000000000000000001\ncandidate\t/tmp/0000000000000000000000000000000000000002'
expect_invalid
plan=$'commit\tabc123\nretention_count\t2\ncandidate\t/tmp/0000000000000000000000000000000000000001\ncandidate\t/tmp/0000000000000000000000000000000000000002'
write_preview "$(( $(date +%s) - 601 ))"
expect_invalid
write_preview "$(( $(date +%s) + 1 ))"
expect_invalid
rm -f "$preview"
echo 'hosted retention token behavior passed'
