#!/bin/bash
set -euo pipefail

readonly tag="i10348-history"
readonly pid_file="/tmp/cmux-${tag}-profile.pid"
readonly top_output="/tmp/cmux-${tag}-top.txt"
readonly sample_output="/tmp/cmux-${tag}-sample.txt"
readonly debug_log="/tmp/cmux-debug-${tag}.log"

pid="$(tr -d '[:space:]' < "$pid_file")"
if ! kill -0 "$pid" 2>/dev/null; then
    echo "tagged app is not running: $pid" >&2
    exit 1
fi

/usr/bin/top -l 8 -s 1 -pid "$pid" -stats cpu,threads > "$top_output"
/usr/bin/sample "$pid" 5 -file "$sample_output" >/dev/null

printf 'pid=%s\n' "$pid"
printf 'menu_appear_count=%s\n' "$(grep -c 'history.menu.appear' "$debug_log" 2>/dev/null || true)"
printf 'title_update_count=%s\n' "$(grep -c 'workspace.title.updatePanel' "$debug_log" 2>/dev/null || true)"
printf '%s\n' '--- top ---'
cat "$top_output"
printf '%s\n' '--- selected sample frames ---'
grep -E 'HistoryMenu|historyMenu|focusHistory|CommandMenu|AppBodyAccessor|makeMainMenu|ViewGraphRootValueUpdater' "$sample_output" | head -n 120 || true
