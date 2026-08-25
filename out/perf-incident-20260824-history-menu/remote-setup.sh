#!/bin/bash
set -euo pipefail

readonly tag="i10348-history"
readonly app="/tmp/cmux-${tag}-profile/cmux DEV ${tag}.app"
readonly cli="${app}/Contents/Resources/bin/cmux"
readonly socket="/tmp/cmux-debug-${tag}.sock"
readonly pid_file="/tmp/cmux-${tag}-profile.pid"
readonly marker="CMUX10348_SPINNER_I10348"

find_tagged_pid() {
    ps -axo pid=,command= \
        | awk -v needle="${app}/Contents/MacOS/" 'index($0, needle) && $0 !~ /awk -v needle/ { print $1 }' \
        | tail -n 1
}

if [[ ! -x "$cli" ]]; then
    echo "missing tagged build: $app" >&2
    exit 1
fi
if [[ -n "$(find_tagged_pid)" ]]; then
    echo "tagged app is already running" >&2
    exit 1
fi
if [[ -S "$socket" ]]; then
    echo "tagged socket already exists without a matching process: $socket" >&2
    exit 1
fi

open -na "$app"
pid=""
for _ in $(seq 1 120); do
    pid="$(find_tagged_pid)"
    [[ -n "$pid" ]] && break
    sleep 0.25
done
if [[ -z "$pid" ]]; then
    echo "tagged app did not launch" >&2
    exit 1
fi
printf '%s\n' "$pid" > "$pid_file"

setup_failed=1
cleanup_failed_setup() {
    if [[ "$setup_failed" == "1" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
    fi
}
trap cleanup_failed_setup EXIT

for _ in $(seq 1 120); do
    [[ -S "$socket" ]] && break
    sleep 0.25
done
if [[ ! -S "$socket" ]]; then
    echo "tagged socket did not appear" >&2
    exit 1
fi

unset CMUX_SOCKET CMUX_SOCKET_PASSWORD CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_TAB_ID CMUX_PANEL_ID CMUXD_UNIX_PATH CMUX_DEBUG_LOG
export CMUX_SOCKET_PATH="$socket"
export CMUX_TAG="$tag"
export CMUX_BUNDLE_ID="com.cmuxterm.app.debug.i10348.history"
export CMUX_BUNDLED_CLI_PATH="$cli"

spinner_command="export ${marker}=1; while :; do printf '\\033]0;⠋ Working\\007'; sleep 0.07; printf '\\033]0;⠙ Working\\007'; sleep 0.07; done"
for index in $(seq 1 20); do
    "$cli" new-workspace \
        --command "$spinner_command" \
        --focus false >/dev/null
done

sleep 15
setup_failed=0
printf 'pid=%s\n' "$pid"
printf 'workspace_count=%s\n' "$("$cli" list-workspaces | wc -l | tr -d ' ')"
printf 'menu_appear_count=%s\n' "$(grep -c 'history.menu.appear' "/tmp/cmux-debug-${tag}.log" 2>/dev/null || true)"
printf 'title_update_count=%s\n' "$(grep -c 'workspace.title.updatePanel' "/tmp/cmux-debug-${tag}.log" 2>/dev/null || true)"
