#!/bin/sh
set -eu

: "${CMUX_BROKER_URL:?CMUX_BROKER_URL is required}"
CMUX_RELAY_ENVIRONMENT="${CMUX_RELAY_ENVIRONMENT:-production}"
CMUX_SESSION_SOCKET="/run/cmux/stage1.sock"
CMUX_SESSION_STATE="/state/session"
CMUX_IROH_STATE="/state/transport"

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
    IFS= read -r provisioning_token
    if [ -z "$provisioning_token" ]; then
        echo "cmux-tui-iroh: initial provisioning token is required on stdin" >&2
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

cleanup() {
    kill "$session_pid" 2>/dev/null || true
    wait "$session_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

attempt=0
while [ ! -S "$CMUX_SESSION_SOCKET" ]; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 200 ]; then
        echo "cmux-tui-iroh: session socket did not become ready" >&2
        exit 1
    fi
    sleep 0.05
done

exec cmux-tui-iroh server \
    --state-root "$CMUX_IROH_STATE" \
    --identity server \
    --broker "$CMUX_BROKER_URL" \
    --relay-environment "$CMUX_RELAY_ENVIRONMENT" \
    --display-name docker-stage1 \
    --session-socket "$CMUX_SESSION_SOCKET"
