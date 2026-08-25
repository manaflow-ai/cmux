#!/bin/bash
set -euo pipefail

readonly tag="i10348-history"
readonly profile_root="/tmp/cmux-${tag}-profile"
readonly app="${profile_root}/cmux DEV ${tag}.app"
readonly pid_file="/tmp/cmux-${tag}-profile.pid"

if [[ -f "$pid_file" ]]; then
    pid="$(tr -d '[:space:]' < "$pid_file")"
    command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$command_line" == *"${app}/Contents/MacOS/"* ]]; then
        kill "$pid" 2>/dev/null || true
        for _ in $(seq 1 40); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.25
        done
    fi
    rm -f "$pid_file"
fi

spinner_pids="$(pgrep -f '[C]MUX10348_SPINNER_I10348=1' || true)"
if [[ -n "$spinner_pids" ]]; then
    while IFS= read -r spinner_pid; do
        kill "$spinner_pid" 2>/dev/null || true
    done <<< "$spinner_pids"
fi

if [[ "$profile_root" == "/tmp/cmux-i10348-history-profile" ]]; then
    rm -rf "$profile_root"
fi
