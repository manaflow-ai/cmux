#!/usr/bin/env python3
"""Small ACP fixture for workflow correction and cancellation lifecycle tests."""
import json
import sys

count = 0
first = None
pending = None


def send(value):
    print(json.dumps({"jsonrpc": "2.0", **value}), flush=True)


def reply(session, request, text, reason="end_turn"):
    send({"method": "session/update", "params": {"sessionId": session, "update": {
        "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}})
    send({"id": request, "result": {"stopReason": reason}})


def command_text(blocks):
    """Match workflow commands while leaving the hidden context on the wire."""
    out = []
    for block in blocks:
        if not isinstance(block, dict):
            continue
        source = (block.get("_meta") or {}).get("acpmux", {}).get("contextSource")
        text = block.get("text", "")
        if source in {"cmux-default", "cmux-user", "cmux-project"}:
            continue
        if isinstance(text, str) and text.startswith(("<cmux-default-context>",
                                                       "<cmux-user-context>",
                                                       "<cmux-project-context>")):
            continue
        out.append(text)
    return "".join(out)


for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    params = request.get("params", {})
    rid = request.get("id")
    if method == "initialize":
        send({"id": rid, "result": {"protocolVersion": 1, "agentCapabilities": {
            "loadSession": True, "promptCapabilities": {}},
            "agentInfo": {"name": "workflow-fixture", "version": "1"},
            "_meta": {"steering": {"supported": True}}}})
    elif method == "session/new":
        send({"id": rid, "result": {"sessionId": "workflow-fixture-session"}})
    elif method == "session/load":
        send({"id": rid, "result": {}})
    elif method == "session/prompt":
        count += 1
        text = command_text(params.get("prompt", []))
        first = first or text
        if first in ("route-failure", "route-failure-schema") and "alternate" not in sys.argv:
            send({"id": rid, "error": {"code": -32000, "message": "workflow route unavailable",
                "data": {"reason": "route.unavailable"}}})
        elif first == "capacity-then-stall" and "alternate" not in sys.argv and count == 1:
            send({"id": rid, "error": {"code": -32000, "message": "HTTP 503 overloaded"}})
        elif first == "capacity-then-stall" and "alternate" not in sys.argv and count == 2:
            pending = (params["sessionId"], rid)
            send({"method": "session/update", "params": {"sessionId": params["sessionId"],
                "update": {"sessionUpdate": "agent_message_chunk", "content": {
                    "type": "text", "text": "retry working"}}}})
        elif pending and text.startswith("Please continue"):
            send({"method": "session/update", "params": {"sessionId": params["sessionId"],
                "update": {"sessionUpdate": "agent_message_chunk", "content": {
                    "type": "text", "text": "nudge accepted"}}}})
            send({"id": rid, "result": {"stopReason": "steered"}})
        elif text == "until-cancel" and count == 1:
            pending = (params["sessionId"], rid)
            send({"method": "session/update", "params": {"sessionId": params["sessionId"],
                "update": {"sessionUpdate": "agent_message_chunk", "content": {
                    "type": "text", "text": "working"}}}})
        else:
            value = "invalid" if first == "schema-twice" or count == 1 and first == "schema-once" else '{"ok":true}'
            reply(params["sessionId"], rid, value)
    elif method == "session/cancel":
        if pending:
            session, original = pending
            pending = None
            send({"id": original, "result": {"stopReason": "cancelled"}})
        if rid is not None:
            send({"id": rid, "result": {}})
    elif rid is not None:
        send({"id": rid, "result": {}})
