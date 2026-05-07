#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CMX_DIR="$REPO_ROOT/rust/cmux-cli"
CMX_RUST_PROFILE="${CMX_RUST_PROFILE:-release}"
if [ "$CMX_RUST_PROFILE" = "release" ]; then
    CARGO_PROFILE_ARGS=(--release)
else
    CARGO_PROFILE_ARGS=()
fi
CMX_BIN="$CMX_DIR/target/$CMX_RUST_PROFILE/cmx"
BRIDGE_BIN="$CMX_DIR/target/$CMX_RUST_PROFILE/cmux-iroh-bridge"

usage() {
    cat <<'EOF'
Usage:
  ios/scripts/reload-with-bridge.sh --tag <tag> [--simulator-only]
  ios/scripts/reload-with-bridge.sh --tag <tag> --skip-reload

Starts a tag-scoped cmux iroh bridge for /tmp/cmx-ios-<tag>.sock, then reloads
the iOS app with that exact bridge ticket.

Examples:
  ios/scripts/reload-with-bridge.sh --tag rcnx --simulator-only
  ios/scripts/reload-with-bridge.sh --tag rcnx --skip-reload
EOF
}

tag_slug() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/./g; s/^\.+//; s/\.+$//; s/\.+/./g'
}

require_binary() {
    local binary="$1"
    local package="$2"
    if [ -x "$binary" ]; then
        return 0
    fi

    echo "Building missing Rust binary: $package ($CMX_RUST_PROFILE)" >&2
    (cd "$CMX_DIR" && cargo build "${CARGO_PROFILE_ARGS[@]}" -p "$package" >/dev/null)
    if [ ! -x "$binary" ]; then
        echo "error: missing binary after build: $binary" >&2
        exit 1
    fi
}

require_socket_ready() {
    local socket_path="$1"
    if [ ! -S "$socket_path" ]; then
        echo "error: socket does not exist: $socket_path" >&2
        echo "hint: start the tagged cmx server first, then rerun this script" >&2
        exit 1
    fi

    if ! env CMX_SOCKET_PATH="$socket_path" "$CMX_BIN" ping >/dev/null; then
        echo "error: cmx server is not responding on $socket_path" >&2
        exit 1
    fi
}

xml_escape() {
    sed \
        -e 's/&/\&amp;/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g' \
        -e "s/'/\&apos;/g" <<< "$1"
}

stop_launch_agent() {
    local label="$1"
    local plist_path="$2"
    if command -v launchctl >/dev/null 2>&1; then
        launchctl bootout "gui/$(id -u)" "$plist_path" >/dev/null 2>&1 || true
        launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
    fi
    rm -f "$plist_path"
}

stop_bridge_pidfile() {
    local pid_file="$1"
    local socket_path="$2"
    [ -f "$pid_file" ] || return 0

    local pid command
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [ -z "$pid" ] || ! kill -0 "$pid" >/dev/null 2>&1; then
        rm -f "$pid_file"
        return 0
    fi

    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$command" != *"cmux-iroh-bridge"* ]] || [[ "$command" != *"$socket_path"* ]]; then
        echo "error: refusing to kill pid $pid because it is not this tag's bridge" >&2
        echo "pid command: $command" >&2
        exit 1
    fi

    kill "$pid" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if ! kill -0 "$pid" >/dev/null 2>&1; then
            rm -f "$pid_file"
            return 0
        fi
        sleep 0.1
    done

    kill -9 "$pid" >/dev/null 2>&1 || true
    rm -f "$pid_file"
}

launchd_pid_for_label() {
    local label="$1"
    launchctl print "gui/$(id -u)/$label" 2>/dev/null | awk '/pid = / { print $3; exit }'
}

write_launch_agent_plist() {
    local label="$1"
    local plist_path="$2"
    local socket_path="$3"
    local tag="$4"
    local ticket_log="$5"
    local bridge_log="$6"
    local node_id_file="$7"

    mkdir -p "$(dirname "$plist_path")"
    cat >"$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$(xml_escape "$label")</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(xml_escape "$BRIDGE_BIN")</string>
        <string>--socket</string>
        <string>$(xml_escape "$socket_path")</string>
        <string>--allow-insecure-direct</string>
        <string>--node-id-file</string>
        <string>$(xml_escape "$node_id_file")</string>
        <string>--node-subtitle</string>
        <string>$(xml_escape "cmux $tag")</string>
        <string>--node-kind</string>
        <string>macos</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>RUST_LOG</key>
        <string>$(xml_escape "${RUST_LOG:-}")</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$(xml_escape "$ticket_log")</string>
    <key>StandardErrorPath</key>
    <string>$(xml_escape "$bridge_log")</string>
</dict>
</plist>
EOF
}

start_bridge_launchd() {
    local label="$1"
    local plist_path="$2"
    local tag="$3"
    local socket_path="$4"
    local pid_file="$5"
    local ticket_log="$6"
    local bridge_log="$7"
    local node_id_file="$8"

    write_launch_agent_plist "$label" "$plist_path" "$socket_path" "$tag" "$ticket_log" "$bridge_log" "$node_id_file"
    launchctl bootstrap "gui/$(id -u)" "$plist_path"

    for _ in $(seq 1 100); do
        local bridge_pid ticket
        bridge_pid="$(launchd_pid_for_label "$label")"
        if [ -n "$bridge_pid" ]; then
            echo "$bridge_pid" >"$pid_file"
        fi

        ticket="$(grep -m 1 '^[[:space:]]*{' "$ticket_log" 2>/dev/null || true)"
        if [ -n "$ticket" ]; then
            if [ -z "$bridge_pid" ]; then
                bridge_pid="$(launchd_pid_for_label "$label")"
                [ -n "$bridge_pid" ] && echo "$bridge_pid" >"$pid_file"
            fi
            echo "$ticket"
            return 0
        fi

        if launchctl print "gui/$(id -u)/$label" 2>/dev/null | grep -q "state = exited"; then
            echo "error: bridge exited before printing a ticket" >&2
            [ -s "$bridge_log" ] && tail -n 40 "$bridge_log" >&2
            rm -f "$pid_file"
            exit 1
        fi
        sleep 0.1
    done

    echo "error: bridge did not print a ticket in time" >&2
    [ -s "$bridge_log" ] && tail -n 40 "$bridge_log" >&2
    rm -f "$pid_file"
    exit 1
}

start_bridge() {
    local tag="$1"
    local socket_path="$2"
    local pid_file="$3"
    local ticket_log="$4"
    local bridge_log="$5"
    local label="$6"
    local plist_path="$7"
    local node_id_file="$8"

    rm -f "$ticket_log" "$bridge_log"
    if command -v launchctl >/dev/null 2>&1; then
        start_bridge_launchd "$label" "$plist_path" "$tag" "$socket_path" "$pid_file" "$ticket_log" "$bridge_log" "$node_id_file"
        return 0
    fi

    nohup "$BRIDGE_BIN" \
        --socket "$socket_path" \
        --allow-insecure-direct \
        --node-id-file "$node_id_file" \
        --node-subtitle "cmux $tag" \
        --node-kind macos \
        >"$ticket_log" 2>"$bridge_log" < /dev/null &

    local bridge_pid="$!"
    echo "$bridge_pid" >"$pid_file"

    for _ in $(seq 1 100); do
        if ! kill -0 "$bridge_pid" >/dev/null 2>&1; then
            echo "error: bridge exited before printing a ticket" >&2
            [ -s "$bridge_log" ] && tail -n 40 "$bridge_log" >&2
            rm -f "$pid_file"
            exit 1
        fi

        if [ -s "$ticket_log" ]; then
            local ticket
            ticket="$(grep -m 1 '^[[:space:]]*{' "$ticket_log" || true)"
            if [ -n "$ticket" ]; then
                echo "$ticket"
                return 0
            fi
        fi
        sleep 0.1
    done

    echo "error: bridge did not print a ticket in time" >&2
    [ -s "$bridge_log" ] && tail -n 40 "$bridge_log" >&2
    kill "$bridge_pid" >/dev/null 2>&1 || true
    rm -f "$pid_file"
    exit 1
}

TAG=""
SIMULATOR_ONLY=0
SKIP_RELOAD=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h)
            usage
            exit 0
            ;;
        --tag)
            TAG="${2:-}"
            if [ -z "$TAG" ] || [[ "$TAG" == -* ]]; then
                echo "error: --tag requires a non-empty value" >&2
                exit 1
            fi
            shift 2
            continue
            ;;
        --tag=*)
            TAG="${1#--tag=}"
            ;;
        --simulator-only|--sim-only)
            SIMULATOR_ONLY=1
            ;;
        --skip-reload)
            SKIP_RELOAD=1
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
    shift
done

if [ -z "$TAG" ]; then
    echo "error: --tag is required" >&2
    usage >&2
    exit 1
fi

TAG_SLUG="$(tag_slug "$TAG")"
if [ -z "$TAG_SLUG" ]; then
    echo "error: tag must contain at least one letter or digit" >&2
    exit 1
fi

SOCKET_PATH="/tmp/cmx-ios-$TAG_SLUG.sock"
PID_FILE="/tmp/cmx-ios-$TAG_SLUG-bridge.pid"
TICKET_LOG="/tmp/cmx-ios-$TAG_SLUG-ticket.log"
BRIDGE_LOG="/tmp/cmx-ios-$TAG_SLUG-bridge.log"
NODE_ID_FILE="$HOME/Library/Application Support/cmux/node-identities/dev/$TAG_SLUG.json"
LAUNCHD_LABEL="dev.cmux.ios.bridge.$TAG_SLUG"
LAUNCHD_PLIST="$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist"

require_binary "$CMX_BIN" cmx
require_binary "$BRIDGE_BIN" cmux-iroh-bridge
require_socket_ready "$SOCKET_PATH"
stop_launch_agent "$LAUNCHD_LABEL" "$LAUNCHD_PLIST"
stop_bridge_pidfile "$PID_FILE" "$SOCKET_PATH"

TICKET="$(start_bridge "$TAG_SLUG" "$SOCKET_PATH" "$PID_FILE" "$TICKET_LOG" "$BRIDGE_LOG" "$LAUNCHD_LABEL" "$LAUNCHD_PLIST" "$NODE_ID_FILE")"

echo "Bridge tag: $TAG_SLUG"
echo "Bridge socket: $SOCKET_PATH"
echo "Bridge pid: $(cat "$PID_FILE")"
echo "Bridge ticket log: $TICKET_LOG"
echo "Bridge stderr log: $BRIDGE_LOG"
echo "Bridge launchd label: $LAUNCHD_LABEL"

if [ "$SKIP_RELOAD" -eq 1 ]; then
    exit 0
fi

RELOAD_ARGS=(--tag "$TAG_SLUG")
if [ "$SIMULATOR_ONLY" -eq 1 ]; then
    RELOAD_ARGS+=(--simulator-only)
fi

env \
    CMUX_IOS_BRIDGE_TICKET="$TICKET" \
    CMUX_IOS_AUTOCONNECT=1 \
    "$SCRIPT_DIR/reload.sh" "${RELOAD_ARGS[@]}"
