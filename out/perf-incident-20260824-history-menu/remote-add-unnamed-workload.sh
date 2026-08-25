#!/bin/bash
set -euo pipefail

readonly tag="i10348-history"
readonly app="/tmp/cmux-${tag}-profile/cmux DEV ${tag}.app"
readonly cli="${app}/Contents/Resources/bin/cmux"
readonly socket="/tmp/cmux-debug-${tag}.sock"
readonly marker="CMUX10348_SPINNER_I10348"

unset CMUX_SOCKET CMUX_SOCKET_PASSWORD CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_TAB_ID CMUX_PANEL_ID CMUXD_UNIX_PATH CMUX_DEBUG_LOG
export CMUX_SOCKET_PATH="$socket"
export CMUX_TAG="$tag"
export CMUX_BUNDLE_ID="com.cmuxterm.app.debug.i10348.history"
export CMUX_BUNDLED_CLI_PATH="$cli"
export CMUX_QUIET=1

spinner_command="export ${marker}=1; while :; do printf '\\033]0;⠋ Working\\007'; sleep 0.07; printf '\\033]0;⠙ Working\\007'; sleep 0.07; done"
for _ in $(seq 1 20); do
    "$cli" new-workspace --command "$spinner_command" --focus false >/dev/null
done
sleep 15

printf 'workspace_count=%s\n' "$("$cli" list-workspaces | wc -l | tr -d ' ')"
printf 'menu_appear_count=%s\n' "$(grep -c 'history.menu.appear' "/tmp/cmux-debug-${tag}.log" 2>/dev/null || true)"
