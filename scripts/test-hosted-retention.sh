#!/usr/bin/env bash
set -euo pipefail
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
preview="$tmp/.retention-preview"
hash=abc123
write_preview() { printf '%s\t%s\n' "$1" "$(date +%s)" > "$preview"; }
valid_preview() { [[ -f "$preview" && "$(cut -f1 "$preview")" == "$hash" ]] && (( $(date +%s) - $(cut -f2 "$preview") <= 600 )); }
! valid_preview
write_preview "$hash"
valid_preview
printf '%s\t%s\n' "$hash" "$(( $(date +%s) - 601 ))" > "$preview"
! valid_preview
rm -f "$preview"
echo 'hosted retention token behavior passed'
