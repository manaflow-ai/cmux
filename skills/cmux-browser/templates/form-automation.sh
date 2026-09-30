#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${1:-}" || -z "${2:-}" ]]; then
  printf 'Usage: %s <url> <tab_id|page>\n' "${0##*/}" >&2
  exit 2
fi

URL="$1"
TAB="$2"

cmux browser "$TAB" navigate "$URL"
cmux browser "$TAB" state
cmux browser "$TAB" snapshot --interactive

echo "Now run fill/click commands using refs from the snapshot above."
