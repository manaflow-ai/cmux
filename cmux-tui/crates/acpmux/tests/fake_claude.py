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
        content = (msg.get("message") or {}).get("content") or []
        said = "".join(b.get("text", "") for b in content if isinstance(b, dict))
        text = json.dumps(sys.argv[1:])
        # "sandbox-probe OUTSIDE PORT": what this process may do, as JSON:
        # write a file at OUTSIDE, connect to 127.0.0.1:PORT, write in its cwd.
        # "keychain-probe": whether this process may query the keychain
        # (`security dump-keychain` lists item metadata when it may).
        if said.strip() == "keychain-probe":
            import subprocess
            rc = subprocess.run(["/usr/bin/security", "dump-keychain"], capture_output=True).returncode
            text = json.dumps({"keychain": "allowed" if rc == 0 else "denied"})
        if said.startswith("sandbox-probe "):
            import os
            import socket
            outside, port = said.split()[1], int(said.split()[2])
            result = {}
            try:
                with open(outside, "w") as f:
                    f.write("x")
                result["outside"] = "allowed"
            except OSError:
                result["outside"] = "denied"
            try:
                socket.create_connection(("127.0.0.1", port), timeout=3).close()
                result["loopback"] = "allowed"
            except OSError:
                result["loopback"] = "denied"
            try:
                with open(os.path.join(os.getcwd(), "sandbox-probe.txt"), "w") as f:
                    f.write("x")
                result["cwd"] = "allowed"
            except OSError:
                result["cwd"] = "denied"
            text = json.dumps(result)
        send({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0,
                                                 "delta": {"type": "text_delta", "text": text}}})
        send({"type": "result", "subtype": "success", "result": text, "num_turns": 1, "duration_api_ms": 1,
              "usage": {"input_tokens": 1, "output_tokens": 1}})
