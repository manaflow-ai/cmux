#!/usr/bin/env bash
# Fixture helper: give a scratch repository <dir> a stub for every blob and
# tree input of scripts/cmux-next/cmux-tui-tree-inputs.txt that it lacks, so a
# tree-key test keeps working when the key gains an input. Gitlinks are the
# test's own business.
set -euo pipefail
dir="${1:?usage: tree-inputs-fixture.sh <repo-dir>}"
inputs="$dir/scripts/cmux-next/cmux-tui-tree-inputs.txt"
while read -r kind path; do
  case "$kind" in
    blob) [[ -e "$dir/$path" ]] || { mkdir -p "$(dirname "$dir/$path")"; echo "fixture $path" > "$dir/$path"; chmod 755 "$dir/$path"; } ;;
    tree) mkdir -p "$dir/$path"; [[ -n "$(ls -A "$dir/$path")" ]] || echo fixture > "$dir/$path/fixture" ;;
  esac
done < <(grep -v -E '^[[:space:]]*(#|$)' "$inputs")
