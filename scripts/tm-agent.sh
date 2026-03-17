#!/bin/bash
# tm-agent: ultra-lightweight RPC for team agents (~5ms vs Rust tm-agent ~2ms)
# Shell fallback when the Rust binary is not available.
# Bypasses Python startup entirely using macOS native nc (netcat).
#
# Usage:
#   tm-agent.sh report "task completed successfully"
#   tm-agent.sh ping "working on feature X"
#   tm-agent.sh heartbeat "progress update"
#   tm-agent.sh msg send "need help with Y"
#   tm-agent.sh msg send "directed message" --to reviewer
#   tm-agent.sh msg list
#   tm-agent.sh msg clear
#   tm-agent.sh task start <task_id>
#   tm-agent.sh task done <task_id> "result summary"
#   tm-agent.sh task block <task_id> "reason"
#   tm-agent.sh task list
#   tm-agent.sh status
#   tm-agent.sh inbox
#   tm-agent.sh batch '{"method":"team.agent.heartbeat",...}' '{"method":"team.task.list",...}'
#
# Environment:
#   TERMMESH_SOCKET    - socket path (auto-detected if unset)
#   TERMMESH_TEAM      - team name (default: live-team)
#   TERMMESH_AGENT_NAME - agent name (default: anonymous)

set -e

# Auto-detect socket
if [ -n "$TERMMESH_SOCKET" ]; then
    SOCK="$TERMMESH_SOCKET"
else
    for f in /tmp/term-mesh-debug-*.sock /tmp/term-mesh-debug.sock /tmp/term-mesh.sock /tmp/cmux.sock; do
        [ -S "$f" ] && SOCK="$f" && break
    done
fi
[ -z "$SOCK" ] && echo "Error: no socket found" >&2 && exit 1

TEAM="${TERMMESH_TEAM:-live-team}"
AGENT="${TERMMESH_AGENT_NAME:-anonymous}"

# JSON-escape a string in pure bash (no Python dependency)
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"    # backslash
    s="${s//\"/\\\"}"    # double quote
    s="${s//$'\n'/\\n}"  # newline
    s="${s//$'\r'/\\r}"  # carriage return
    s="${s//$'\t'/\\t}"  # tab
    printf '"%s"' "$s"
}

# Send RPC and print response
send_rpc() {
    local payload="$1"
    echo "$payload" | nc -U "$SOCK" -w 2 2>/dev/null | head -1
}

CMD="$1"
shift || { echo "Usage: tm-agent.sh <command> [args...]" >&2; exit 1; }

case "$CMD" in
    report)
        CONTENT=$(json_escape "$1")
        send_rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.report\",\"params\":{\"team_name\":\"$TEAM\",\"agent_name\":\"$AGENT\",\"content\":$CONTENT}}"
        ;;
    reply)
        CONTENT=$(json_escape "$1")
        # Send message to leader (type=report) AND register as report — matches Rust binary behavior
        send_rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.message.post\",\"params\":{\"team_name\":\"$TEAM\",\"from\":\"$AGENT\",\"content\":$CONTENT,\"to\":\"leader\",\"type\":\"report\"}}"
        send_rpc "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"team.report\",\"params\":{\"team_name\":\"$TEAM\",\"agent_name\":\"$AGENT\",\"content\":$CONTENT}}"
        ;;
    ping|heartbeat)
        SUMMARY=$(json_escape "${1:-alive}")
        send_rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.agent.heartbeat\",\"params\":{\"team_name\":\"$TEAM\",\"agent_name\":\"$AGENT\",\"summary\":$SUMMARY}}"
        ;;
    msg)
        SUB="$1"
        shift || { echo "Usage: tm-agent.sh msg <send|list|clear> [args...]" >&2; exit 1; }
        case "$SUB" in
            send)
                CONTENT=$(json_escape "$1")
                TO_PARAM=""
                if [ "$2" = "--to" ] && [ -n "$3" ]; then
                    TO_PARAM=",\"to\":\"$3\""
                fi
                send_rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.message.post\",\"params\":{\"team_name\":\"$TEAM\",\"from\":\"$AGENT\",\"content\":$CONTENT,\"type\":\"note\"$TO_PARAM}}"
                ;;
            list)
                FROM_PARAM=""
                if [ "$1" = "--from-agent" ] && [ -n "$2" ]; then
                    FROM_PARAM=",\"from\":\"$2\""
                fi
                send_rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.message.list\",\"params\":{\"team_name\":\"$TEAM\"$FROM_PARAM}}"
                ;;
            clear)
                send_rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.message.clear\",\"params\":{\"team_name\":\"$TEAM\"}}"
                ;;
            *)
                echo "Unknown msg subcommand: $SUB" >&2
                echo "Usage: tm-agent.sh msg <send|list|clear>" >&2
                exit 1
                ;;
        esac
        ;;
    task)
        SUB="$1"
        shift || { echo "Usage: tm-agent.sh task <start|done|block|list|...> [args...]" >&2; exit 1; }
        case "$SUB" in
            start)
                [ -z "$1" ] && echo "Usage: tm-agent.sh task start <task_id>" >&2 && exit 1
                send_rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.task.update\",\"params\":{\"team_name\":\"$TEAM\",\"task_id\":\"$1\",\"status\":\"in_progress\"}}"
                ;;
            done)
                [ -z "$1" ] && echo "Usage: tm-agent.sh task done <task_id> [result]" >&2 && exit 1
                RESULT=$(json_escape "${2:-done}")
                send_rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.task.done\",\"params\":{\"team_name\":\"$TEAM\",\"task_id\":\"$1\",\"result\":$RESULT}}"
                ;;
            block)
                [ -z "$1" ] && echo "Usage: tm-agent.sh task block <task_id> <reason>" >&2 && exit 1
                REASON=$(json_escape "${2:-blocked}")
                send_rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.task.block\",\"params\":{\"team_name\":\"$TEAM\",\"task_id\":\"$1\",\"blocked_reason\":$REASON}}"
                ;;
            review)
                [ -z "$1" ] && echo "Usage: tm-agent.sh task review <task_id> [summary]" >&2 && exit 1
                SUMMARY=$(json_escape "${2:-ready for review}")
                send_rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.task.review\",\"params\":{\"team_name\":\"$TEAM\",\"task_id\":\"$1\",\"review_summary\":$SUMMARY}}"
                ;;
            list)
                send_rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.task.list\",\"params\":{\"team_name\":\"$TEAM\"}}"
                ;;
            get)
                [ -z "$1" ] && echo "Usage: tm-agent.sh task get <task_id>" >&2 && exit 1
                send_rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.task.get\",\"params\":{\"team_name\":\"$TEAM\",\"task_id\":\"$1\"}}"
                ;;
            update)
                [ -z "$1" ] || [ -z "$2" ] && echo "Usage: tm-agent.sh task update <task_id> <status>" >&2 && exit 1
                send_rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.task.update\",\"params\":{\"team_name\":\"$TEAM\",\"task_id\":\"$1\",\"status\":\"$2\"}}"
                ;;
            create)
                [ -z "$1" ] && echo "Usage: tm-agent.sh task create '<title>' [--assign <agent>]" >&2 && exit 1
                TITLE=$(json_escape "$1")
                ASSIGN_PARAM=""
                if [ "$2" = "--assign" ] && [ -n "$3" ]; then
                    ASSIGN_PARAM=",\"assignee\":\"$3\""
                fi
                send_rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.task.create\",\"params\":{\"team_name\":\"$TEAM\",\"title\":$TITLE$ASSIGN_PARAM}}"
                ;;
            reassign)
                [ -z "$1" ] || [ -z "$2" ] && echo "Usage: tm-agent.sh task reassign <task_id> <agent>" >&2 && exit 1
                send_rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.task.reassign\",\"params\":{\"team_name\":\"$TEAM\",\"task_id\":\"$1\",\"assignee\":\"$2\"}}"
                ;;
            unblock)
                [ -z "$1" ] && echo "Usage: tm-agent.sh task unblock <task_id>" >&2 && exit 1
                send_rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.task.unblock\",\"params\":{\"team_name\":\"$TEAM\",\"task_id\":\"$1\"}}"
                ;;
            clear)
                send_rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.task.clear\",\"params\":{\"team_name\":\"$TEAM\"}}"
                ;;
            *)
                echo "Unknown task subcommand: $SUB" >&2
                echo "Usage: tm-agent.sh task <start|done|block|review|list|get|update|create|reassign|unblock|clear>" >&2
                exit 1
                ;;
        esac
        ;;
    status)
        send_rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.status\",\"params\":{\"team_name\":\"$TEAM\"}}"
        ;;
    inbox)
        send_rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.inbox\",\"params\":{\"team_name\":\"$TEAM\",\"agent_name\":\"$AGENT\"}}"
        ;;
    batch)
        # Send multiple JSON-RPC payloads over a single connection
        PAYLOAD=""
        for arg in "$@"; do PAYLOAD+="$arg"$'\n'; done
        printf '%s' "$PAYLOAD" | nc -U "$SOCK" -w 2 2>/dev/null
        ;;
    raw)
        # Send raw JSON-RPC: tm-agent.sh raw '{"method":"team.status",...}'
        send_rpc "$1"
        ;;
    *)
        echo "Unknown command: $CMD" >&2
        echo "Commands: report, reply, ping, heartbeat, msg <send|list|clear>, task <start|done|block|review|list|create|get|update|reassign|unblock|clear>, status, inbox, batch, raw" >&2
        exit 1
        ;;
esac
