#!/bin/sh
set -eu

: "${CMUX_BROKER_URL:?CMUX_BROKER_URL is required}"
CMUX_RELAY_ENVIRONMENT="${CMUX_RELAY_ENVIRONMENT:-production}"
CMUX_SESSION_SOCKET="/run/cmux/stage1.sock"
CMUX_SESSION_STATE="/state/session"
CMUX_IROH_STATE="/state/transport"
CMUX_PROVISIONING_TOKEN_FILE="${CMUX_PROVISIONING_TOKEN_FILE:-}"

if [ -n "${CMUX_BROKER_FORWARD:-}" ]; then
    case "$CMUX_BROKER_FORWARD" in
        *[!A-Za-z0-9.:-]*)
            echo "cmux-tui-iroh: invalid development broker forward" >&2
            exit 1
            ;;
    esac
    socat \
        TCP4-LISTEN:43100,bind=127.0.0.1,fork,reuseaddr \
        "TCP:$CMUX_BROKER_FORWARD" &
fi

if [ ! -f "$CMUX_IROH_STATE/iroh-tui/server/credential.json" ]; then
    if [ -n "$CMUX_PROVISIONING_TOKEN_FILE" ]; then
        if [ ! -r "$CMUX_PROVISIONING_TOKEN_FILE" ]; then
            echo "cmux-tui-iroh: provisioning token file is not readable" >&2
            exit 1
        fi
        IFS= read -r provisioning_token < "$CMUX_PROVISIONING_TOKEN_FILE"
    else
        IFS= read -r provisioning_token
    fi
    if [ -z "$provisioning_token" ]; then
        echo "cmux-tui-iroh: initial provisioning token is required" >&2
        exit 1
    fi
    printf '%s\n' "$provisioning_token" \
        | cmux-tui-iroh enroll \
            --state-root "$CMUX_IROH_STATE" \
            --identity server \
            --broker "$CMUX_BROKER_URL" \
            --token-stdin
    unset provisioning_token
fi

cmux-tui \
    --headless \
    --session iroh-stage1 \
    --socket "$CMUX_SESSION_SOCKET" \
    --state "$CMUX_SESSION_STATE" &
session_pid=$!

server_pid=""
watcher_pid=""

# The server runs as a supervised child (never exec) so these traps stay
# alive to stop and reap both processes on container shutdown.
# shellcheck disable=SC2329  # invoked via trap
cleanup() {
    if [ -n "$watcher_pid" ]; then
        kill "$watcher_pid" 2>/dev/null || true
    fi
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    kill "$session_pid" 2>/dev/null || true
    wait "$session_pid" 2>/dev/null || true
}
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 130' INT
trap cleanup EXIT

# Readiness: wait for the session socket, fail immediately if the session
# process exits first, and bound the wait with a configurable deadline.
ready_timeout="${CMUX_SESSION_READY_TIMEOUT_SECONDS:-10}"
attempt=0
attempts=$((ready_timeout * 20))
while [ ! -S "$CMUX_SESSION_SOCKET" ]; do
    if ! kill -0 "$session_pid" 2>/dev/null; then
        echo "cmux-tui-iroh: session process exited before its socket became ready" >&2
        exit 1
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -ge "$attempts" ]; then
        echo "cmux-tui-iroh: session socket did not become ready within ${ready_timeout}s" >&2
        exit 1
    fi
    sleep 0.05
done

cmux-tui-iroh server \
    --state-root "$CMUX_IROH_STATE" \
    --identity server \
    --broker "$CMUX_BROKER_URL" \
    --relay-environment "$CMUX_RELAY_ENVIRONMENT" \
    --display-name docker-stage1 \
    --session-socket "$CMUX_SESSION_SOCKET" &
server_pid=$!

# Stop the server if the session dies so the container exits instead of
# serving a dead session socket.
(
    while kill -0 "$session_pid" 2>/dev/null && kill -0 "$server_pid" 2>/dev/null; do
        sleep 1
    done
    kill "$server_pid" 2>/dev/null || true
) &
watcher_pid=$!

server_status=0
wait "$server_pid" || server_status=$?
exit "$server_status"
