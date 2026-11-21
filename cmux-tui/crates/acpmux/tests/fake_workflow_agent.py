#!/usr/bin/env python3
"""Small ACP fixture for workflow correction and cancellation lifecycle tests."""
import json
import os
import sys

count = 0
first = None
pending = None
# The workflow harness runs in a test-owned temporary cwd. Keeping this tiny
# record there lets a replacement process restore the same session's prompt
# counter without sharing state with another test or the real user's files.
state_path = os.path.join(os.getcwd(), ".fake-workflow-agent-state.json")


def load_state():
    try:
        with open(state_path) as state:
            value = json.load(state)
        return value if isinstance(value, dict) else {}
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_state(session, cancelled=False):
    state = load_state()
    state[session] = {"count": count, "first": first, "cancelled": cancelled}
    temporary = f"{state_path}.{os.getpid()}.tmp"
    with open(temporary, "w") as output:
        json.dump(state, output)
        output.write("\n")
    os.replace(temporary, state_path)


def restore_state(session):
    global count, first
    value = load_state().get(session, {})
    if isinstance(value, dict):
        count = int(value.get("count", 0))
        first = value.get("first") if isinstance(value.get("first"), str) else None


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
        mux = (block.get("_meta") or {}).get("acpmux", {})
        source = mux.get("contextSource")
        text = block.get("text", "")
        if source in {"cmux-default", "cmux-user", "cmux-project", "cmux-guidance"}:
            continue
        # Who wrote it (hub/prompt_attribution.rs): a workflow's prompt is another agent's.
        if mux.get("attribution") is True:
            continue
        if isinstance(text, str) and text.startswith(("<cmux-default-context>",
                                                       "<cmux-user-context>",
                                                       "<cmux-project-context>", "<cmux-guidance-context>")):
            continue
        out.append(text)
    return "".join(out)


for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    params = request.get("params", {})
    rid = request.get("id")
    if method == "initialize":
        # It runs no tool, so it asks before every one it runs: any acpmux policy holds.
        send({"id": rid, "result": {"protocolVersion": 1, "agentCapabilities": {
            "loadSession": True, "promptCapabilities": {},
            "_meta": {"acpmux": {"asksBeforeTools": True}}},
            "agentInfo": {"name": "workflow-fixture", "version": "1"},
            "_meta": {"steering": {"supported": True}}}})
    elif method == "session/new":
        send({"id": rid, "result": {"sessionId": "workflow-fixture-session"}})
    elif method == "session/load":
        restore_state(params.get("sessionId", ""))
        send({"id": rid, "result": {}})
    elif method == "session/prompt":
        count += 1
        text = command_text(params.get("prompt", []))
        first = first or text
        save_state(params["sessionId"])
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
            save_state(session, cancelled=True)
            send({"id": original, "result": {"stopReason": "cancelled"}})
        if rid is not None:
            send({"id": rid, "result": {}})
    elif rid is not None:
        send({"id": rid, "result": {}})
