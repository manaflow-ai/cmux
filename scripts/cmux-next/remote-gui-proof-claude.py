#!/usr/bin/python3
"""Stand-in Claude Code for the Remote GUI proof (remote-gui-proof.yml): no model call, every turn answers PONG.

The same stand-in as the remote-ssh scoreboard probe: it speaks Claude Code's -p stream-json enough for acpmux
to run a turn (shaped on acpmux tests/fake_claude_stream.py)."""
import json
import sys

ARGS = sys.argv[1:]
if "--version" in ARGS or "-v" in ARGS:
    print("2.1.999 (Claude Code)")
    sys.exit(0)
if "-p" not in ARGS and "--print" not in ARGS:
    print("{}")
    sys.exit(0)
SESSION = "remote-ssh-probe-session"
for flag in ("--session-id", "--resume"):
    if flag in ARGS[:-1]:
        SESSION = ARGS[ARGS.index(flag) + 1]
REPLAY = "--replay-user-messages" in ARGS
REPLY = "PONG"


def send(obj):
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def stream(event):
    send({"type": "stream_event", "event": event, "session_id": SESSION})


def turn(n):
    msg_id = "msg_remote_ssh_probe_%d" % n
    stream({"type": "message_start", "message": {"id": msg_id, "type": "message", "role": "assistant",
            "model": "fake", "content": [], "usage": {"input_tokens": 1, "output_tokens": 1}}})
    stream({"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
    stream({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": REPLY}})
    stream({"type": "content_block_stop", "index": 0})
    stream({"type": "message_delta", "delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 1}})
    stream({"type": "message_stop"})
    send({"type": "assistant", "message": {"id": msg_id, "role": "assistant", "model": "fake",
          "content": [{"type": "text", "text": REPLY}], "stop_reason": "end_turn",
          "usage": {"input_tokens": 1, "output_tokens": 1}}, "session_id": SESSION})
    send({"type": "result", "subtype": "success", "result": REPLY, "num_turns": 1, "duration_api_ms": 1,
          "session_id": SESSION, "usage": {"input_tokens": 1, "output_tokens": 1}})


turns = 0
for line in sys.stdin:
    try:
        msg = json.loads(line)
    except ValueError:
        continue
    if not isinstance(msg, dict):
        continue
    kind = msg.get("type")
    if kind == "control_request":
        sub = (msg.get("request") or {}).get("subtype")
        resp = {"commands": [], "models": [], "account": {}} if sub == "initialize" else {}
        send({"type": "control_response", "response": {"subtype": "success",
              "request_id": msg.get("request_id"), "response": resp}})
        if sub == "initialize":
            send({"type": "system", "subtype": "init", "session_id": SESSION, "model": "fake",
                  "permissionMode": "default", "tools": [], "mcp_servers": []})
    elif kind == "user":
        if REPLAY:
            send({"type": "user", "isReplay": True, "uuid": msg.get("uuid"), "message": msg.get("message"),
                  "session_id": SESSION})
        turns += 1
        turn(turns)
