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
        text = "".join(block.get("text", "") for block in params.get("prompt", []))
        first = first or text
        if first in ("route-failure", "route-failure-schema") and "alternate" not in sys.argv:
            send({"id": rid, "error": {"code": -32000, "message": "workflow route unavailable",
                "data": {"reason": "route.unavailable"}}})
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
