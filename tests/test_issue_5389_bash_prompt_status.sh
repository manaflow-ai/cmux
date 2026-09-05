#!/usr/bin/env bash
set -eo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Source the production integration in an isolated, transport-free shell. The
# prompt hook should preserve the failed command's status even on this early
# return path so the next PROMPT_COMMAND entry can observe it.
CMUX_SOCKET_PATH=""
CMUX_TAB_ID="tab-test"
CMUX_PANEL_ID="panel-test"
TMUX=""
PROMPT_COMMAND=""
source "$repo_root/Resources/shell-integration/cmux-bash-integration.bash"

_cmux_test_cleanup() {
    [[ -n "${_CMUX_GIT_ACTIVE_PWD_FILE:-}" ]] \
        && /bin/rm -f -- "$_CMUX_GIT_ACTIVE_PWD_FILE" >/dev/null 2>&1 \
        || true
}
trap _cmux_test_cleanup EXIT

# Never let this isolated test publish its fake cmux IDs to a real tmux server.
_cmux_tmux_sync_cmux_environment() { :; }

_cmux_status_observer() {
    printf '%s\n' "$?"
}

_assert_prompt_status_preserved() {
    local route="$1"
    local prompt_form="$2"
    local observed=""

    unset PROMPT_COMMAND
    if [[ "$prompt_form" == "array" ]]; then
        PROMPT_COMMAND=("_cmux_prompt_command" "_cmux_status_observer")
        observed="$(
            set +e
            false
            eval "${PROMPT_COMMAND[0]}"
            eval "${PROMPT_COMMAND[1]}"
        )"
    else
        PROMPT_COMMAND="_cmux_prompt_command;_cmux_status_observer"
        observed="$(
            set +e
            false
            eval "$PROMPT_COMMAND"
        )"
    fi

    if [[ "$observed" != "1" ]]; then
        printf 'FAIL: %s (%s) downstream hook observed status %q, expected 1\n' \
            "$route" "$prompt_form" "$observed" >&2
        exit 1
    fi
}

_assert_route_preserves_status() {
    local route="$1"
    _assert_prompt_status_preserved "$route" string
    _assert_prompt_status_preserved "$route" array
}

# Exercise the first early return with the production transport checks.
_assert_route_preserves_status "no transport"

# Stub only the integration's external effects so the remaining cases can
# deterministically drive every other return path without a live cmux process.
_cmux_socket_is_unix() { return 0; }
_cmux_report_tty_once() { :; }
_cmux_report_shell_activity_state() { :; }
_cmux_reset_terminal_keyboard_protocols() { :; }
_cmux_set_git_active_pwd() { :; }
_cmux_stop_pr_poll_loop() { :; }
_cmux_clear_pr_command_hint_file() { :; }
_cmux_ports_kick() { :; }
_cmux_send_bg() { :; }

CMUX_TAB_ID=""
_assert_route_preserves_status "missing tab"

CMUX_TAB_ID="tab-test"
CMUX_PANEL_ID=""
_CMUX_TTY_NAME="tty-test"
_assert_route_preserves_status "missing panel"

CMUX_PANEL_ID="panel-test"
CMUX_NO_GIT_WATCH=1
_CMUX_PWD_LAST_PWD="$PWD"
_assert_route_preserves_status "normal completion"

printf 'PASS: downstream prompt hooks preserved status across all routes and forms\n'
