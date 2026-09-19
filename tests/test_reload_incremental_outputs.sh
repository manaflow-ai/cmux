#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../scripts/lib/reload-incremental.sh"
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
for s in cmuxd ghostty cua tui; do
 i="$t/$s.i"; o="$t/$s.o"; r="$t/$s.r"; echo i > "$i"; echo o > "$o"
 d=$(reload_incremental_digest "$i"); reload_incremental_record "$r" "$d" "$o"; ! reload_incremental_needs_update "$r" "$d" "$o"
 echo x >> "$i"; nd=$(reload_incremental_digest "$i"); reload_incremental_needs_update "$r" "$nd" "$o"
 rm "$o"; reload_incremental_needs_update "$r" "$d" "$o"
 echo repaired > "$o"; reload_incremental_record "$r" "$d" "$o"; echo corrupt > "$o"; reload_incremental_needs_update "$r" "$d" "$o"
done
echo passed
