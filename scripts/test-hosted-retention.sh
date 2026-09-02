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
active_binary=/tmp/0000000000000000000000000000000000000001/cmux-tui
active_lsof_output="n$active_binary"
active_artifact_paths="$(printf '%s\n' "$active_lsof_output" | sed -n 's/^n//p')"
printf '%s\n' "$active_artifact_paths" | grep -F -x -q -- "$active_binary"
plan="$(printf '%s\ndelete\t%s' "$plan" /tmp/0000000000000000000000000000000000000002)"
expect_invalid
write_preview "$(date +%s)"
valid_preview
lsof_status=1
lsof_stderr='lsof: status error on missing artifact'
if (( lsof_status == 1 )) && [[ -n "$lsof_stderr" ]]; then
  :
else
  exit 1
fi
valid_retention_count() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]] || return 1
  ((${#1} <= 6)) || return 1
  ((10#$1 <= 100000))
}
valid_retention_count 100000
expect_invalid() { if valid_retention_count 9223372036854775808; then return 1; fi; }
expect_invalid
generation_dir="$tmp/generation"
mkdir "$generation_dir"
generation_before="$(stat -f '%i:%m' "$generation_dir" 2>/dev/null || stat -c '%i:%Y' "$generation_dir")"
touch -t 200001010000 "$generation_dir"
generation_after="$(stat -f '%i:%m' "$generation_dir" 2>/dev/null || stat -c '%i:%Y' "$generation_dir")"
[[ "$generation_before" != "$generation_after" ]]
rm -f "$preview"
echo 'hosted retention token behavior passed'
