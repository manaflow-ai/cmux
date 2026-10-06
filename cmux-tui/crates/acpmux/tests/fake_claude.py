#!/usr/bin/env python3
"""A tiny stand-in for Claude Code's stream-json protocol, for tests.

It answers every control_request with success, reports system/init after
initialize, and replies to every user message with its own arguments as
JSON (spawn-time checks of the Claude command line).
"""
import json
import sys


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


# Like Claude Code, init reports the mode `--permission-mode` pinned.
MODE = "default"
if "--permission-mode" in sys.argv[:-1]:
    MODE = sys.argv[sys.argv.index("--permission-mode") + 1]

for line in sys.stdin:
    try:
        msg = json.loads(line)
    except ValueError:
        continue
    kind = msg.get("type")
    if kind == "control_request":
        request = msg.get("request") or {}
        send({"type": "control_response", "response": {"subtype": "success", "request_id": msg.get("request_id"), "response": {}}})
        if request.get("subtype") == "initialize":
            send({"type": "system", "subtype": "init", "session_id": "fake-claude-session", "model": "fake",
                  "permissionMode": MODE, "tools": [], "mcp_servers": []})
    elif kind == "user":
        text = json.dumps(sys.argv[1:])
        send({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0,
                                                 "delta": {"type": "text_delta", "text": text}}})
        send({"type": "result", "subtype": "success", "result": text, "num_turns": 1, "duration_api_ms": 1,
              "usage": {"input_tokens": 1, "output_tokens": 1}})
