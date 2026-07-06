#!/bin/sh

set -u

if [ -z "${CMUX_MUX_SOCKET:-}" ]; then
    exit 0
fi

surface="${CMUX_MUX_SURFACE:-${CMUX_MUX_SURFACE_ID:-}}"
case "$surface" in
    ''|*[!0-9]*) exit 0 ;;
esac

if ! command -v python3 >/dev/null 2>&1; then
    exit 0
fi

payload="$(cat 2>/dev/null || printf '')"

CMUX_CLAUDE_HOOK_PAYLOAD="$payload" python3 - "$CMUX_MUX_SOCKET" "$surface" <<'PY'
import json
import os
import socket
import sys


def text(value):
    if value is None:
        return None
    if isinstance(value, str):
        return value
    return str(value)


def send(request):
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(0.5)
        sock.connect(sys.argv[1])
        sock.sendall(json.dumps(request, separators=(",", ":")).encode("utf-8") + b"\n")
        try:
            sock.recv(4096)
        except OSError:
            pass
        sock.close()
    except OSError:
        pass


try:
    surface = int(sys.argv[2])
except (IndexError, ValueError):
    sys.exit(0)

try:
    payload = json.loads(os.environ.get("CMUX_CLAUDE_HOOK_PAYLOAD") or "{}")
except json.JSONDecodeError:
    payload = {}

event = (
    payload.get("hook_event_name")
    or payload.get("event")
    or payload.get("type")
    or os.environ.get("CLAUDE_HOOK_EVENT")
)

request = {
    "cmd": "report-agent",
    "surface": surface,
    "source": "hook",
    "agent": "claude",
}

if event == "Notification":
    message = text(payload.get("message") or payload.get("notification") or payload.get("title"))
    request["state"] = "blocked"
    if message:
        request["custom_status"] = message
elif event == "Stop":
    request["state"] = "done"
elif event == "SessionStart":
    session = text(payload.get("session_id") or payload.get("transcript_path"))
    if session:
        request["session"] = session
    else:
        sys.exit(0)
else:
    sys.exit(0)

send(request)
PY
