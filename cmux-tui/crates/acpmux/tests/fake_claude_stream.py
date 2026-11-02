#!/usr/bin/env python3
"""Recorded-shape stand-in for Claude Code's stream-json protocol (perf100 S2), for tests.

Each user message streams a long Markdown reply as Claude Code 2.1 does with
--include-partial-messages: message_start, N content_block_delta text deltas of
~4 characters (STREAM_TOKENS, default 2000), message_stop, the assistant
message, and a result. Deterministic: the reply text is a fixed seeded
Markdown document, no model call. FIX_TEXT=<path>: the reply text is written there.
"""
import json
import os
import sys

TOKENS = int(os.environ.get("STREAM_TOKENS", "2000"))
SESSION = "stream-claude-session"
for flag in ("--session-id", "--resume"):
    if flag in sys.argv[:-1]:
        SESSION = sys.argv[sys.argv.index(flag) + 1]

WORDS = ("The ", "daemon ", "keeps ", "**one** ", "record ", "per ", "`token` ", "and ", "the ",
         "client ", "renders ", "it.\n", "- ", "item ", "with ", "code\n", "```rust\n", "fn ",
         "main() ", "{}\n```\n", "## ", "Heading\n")


def send(obj):
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def reply(n):
    pieces = [WORDS[i % len(WORDS)] for i in range(n)]
    msg_id = "msg_%016x" % (hash(SESSION) & 0xFFFFFFFFFFFF)
    send({"type": "stream_event", "event": {"type": "message_start", "message": {
        "id": msg_id, "type": "message", "role": "assistant", "model": "fake", "content": [],
        "usage": {"input_tokens": 10, "output_tokens": 1}}}, "session_id": SESSION})
    send({"type": "stream_event", "event": {"type": "content_block_start", "index": 0,
          "content_block": {"type": "text", "text": ""}}, "session_id": SESSION})
    for p in pieces:
        send({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0,
              "delta": {"type": "text_delta", "text": p}}, "session_id": SESSION,
              "parent_tool_use_id": None, "uuid": "00000000-0000-4000-8000-000000000000"})
    send({"type": "stream_event", "event": {"type": "content_block_stop", "index": 0}, "session_id": SESSION})
    send({"type": "stream_event", "event": {"type": "message_delta", "delta": {"stop_reason": "end_turn"},
          "usage": {"output_tokens": n}}, "session_id": SESSION})
    send({"type": "stream_event", "event": {"type": "message_stop"}, "session_id": SESSION})
    text = "".join(pieces)
    if os.environ.get("FIX_TEXT"):
        with open(os.environ["FIX_TEXT"], "w") as f:
            f.write(text)
    send({"type": "assistant", "message": {"id": msg_id, "role": "assistant", "model": "fake",
          "content": [{"type": "text", "text": text}], "stop_reason": "end_turn",
          "usage": {"input_tokens": 10, "output_tokens": n}}, "session_id": SESSION})
    send({"type": "result", "subtype": "success", "result": text, "num_turns": 1, "duration_api_ms": 1,
          "session_id": SESSION, "usage": {"input_tokens": 10, "output_tokens": n}})


for line in sys.stdin:
    try:
        msg = json.loads(line)
    except ValueError:
        continue
    kind = msg.get("type")
    if kind == "control_request":
        sub = msg.get("request", {}).get("subtype")
        resp = {}
        if sub == "initialize":
            resp = {"commands": [], "models": [], "account": {}}
        send({"type": "control_response", "response": {"subtype": "success",
              "request_id": msg.get("request_id"), "response": resp}})
        if sub == "initialize":
            send({"type": "system", "subtype": "init", "session_id": SESSION, "model": "fake",
                  "permissionMode": "default", "tools": [], "mcp_servers": []})
    elif kind == "user":
        reply(TOKENS)
