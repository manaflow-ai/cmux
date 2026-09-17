#!/usr/bin/env python3
"""A tiny ACP agent for tests.

Behaviour per prompt text:
  "ask: <x>"   -> requests permission, then replies with the chosen optionId
  "slow"       -> streams three chunks with delays, honours session/cancel
  anything     -> echoes the text as one agent_message_chunk
"""
import json
import sys
import threading
import time

lock = threading.Lock()
cancelled = set()
next_id = 100
pending = {}


def send(obj):
    with lock:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()


def request(method, params):
    global next_id
    with lock:
        rid = next_id
        next_id += 1
    ev = threading.Event()
    pending[rid] = [ev, None]
    send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
    ev.wait()
    return pending.pop(rid)[1]


def update(sid, upd):
    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": upd}})


def handle_prompt(rid, params):
    sid = params["sessionId"]
    text = "".join(b.get("text", "") for b in params.get("prompt", []))
    if text.startswith("ask:"):
        res = request(
            "session/request_permission",
            {
                "sessionId": sid,
                "toolCall": {"toolCallId": "t1", "title": text[4:].strip(), "kind": "execute", "status": "pending"},
                "options": [
                    {"optionId": "yes", "name": "Allow", "kind": "allow_once"},
                    {"optionId": "no", "name": "Reject", "kind": "reject_once"},
                ],
            },
        )
        chosen = (res or {}).get("outcome", {}).get("optionId", (res or {}).get("outcome", {}).get("outcome"))
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": f"chose {chosen}"}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    if text == "slow":
        for i in range(3):
            if sid in cancelled:
                send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "cancelled"}})
                cancelled.discard(sid)
                return
            update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": f"tick{i} "}})
            time.sleep(0.3)
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    update(sid, {"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "thinking"}})
    update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "echo: " + text}})
    send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})


def main():
    sessions = 0
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        msg = json.loads(line)
        if "method" not in msg:
            p = pending.get(msg.get("id"))
            if p:
                p[1] = msg.get("result")
                p[0].set()
            continue
        m = msg["method"]
        rid = msg.get("id")
        params = msg.get("params") or {}
        if m == "initialize":
            send({"jsonrpc": "2.0", "id": rid, "result": {
                "protocolVersion": 1,
                "agentInfo": {"name": "fake", "version": "0"},
                "agentCapabilities": {"loadSession": True, "sessionCapabilities": {"fork": {}}},
                "authMethods": [],
            }})
        elif m == "session/new":
            sessions += 1
            send({"jsonrpc": "2.0", "id": rid, "result": {
                "sessionId": f"fake-{sessions}",
                "modes": {"currentModeId": "normal", "availableModes": [{"id": "normal", "name": "Normal"}, {"id": "strict", "name": "Strict"}]},
                "configOptions": [{"id": "model", "name": "Model", "type": "select", "currentValue": "m1", "options": [{"value": "m1", "name": "m1"}, {"value": "m2", "name": "m2"}]}],
            }})
        elif m == "session/load":
            update(params["sessionId"], {"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": "replayed"}})
            send({"jsonrpc": "2.0", "id": rid, "result": None})
        elif m == "session/fork":
            sessions += 1
            send({"jsonrpc": "2.0", "id": rid, "result": {"sessionId": f"fake-{sessions}"}})
        elif m == "session/set_mode":
            send({"jsonrpc": "2.0", "id": rid, "result": {}})
        elif m == "session/set_config_option":
            v = params.get("value")
            send({"jsonrpc": "2.0", "id": rid, "result": {"configOptions": [{"id": "model", "name": "Model", "type": "select", "currentValue": v, "options": []}]}})
        elif m == "session/prompt":
            threading.Thread(target=handle_prompt, args=(rid, params), daemon=True).start()
        elif m == "session/cancel":
            cancelled.add(params.get("sessionId"))
        elif rid is not None:
            send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "no such method"}})


if __name__ == "__main__":
    main()
