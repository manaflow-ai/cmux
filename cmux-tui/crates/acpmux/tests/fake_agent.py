#!/usr/bin/env python3
"""A tiny ACP agent for tests.

Behaviour per prompt text:
  "ask: <x>"   -> requests permission, then replies with the chosen optionId
  "slow"       -> streams three chunks with delays, honours session/cancel
  anything     -> echoes the text as one agent_message_chunk
"""
import json
import sys
import os
import threading
import time

lock = threading.Lock()
cancelled = set()
failed_once = set()
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
    if text.startswith("permission-batch:"):
        with open(os.path.join(os.path.dirname(__file__), "fixtures", "permission-batches.json")) as f:
            fixture = json.load(f)[text.split(":", 1)[1].strip()]
        choices = []
        for wave in [fixture["items"], fixture.get("after", [])]:
            wave_ids = []
            for item in wave:
                global next_id
                with lock:
                    aid = next_id
                    next_id += 1
                ev = threading.Event()
                pending[aid] = [ev, None]
                wave_ids.append(aid)
                allow_kind = item.get("allowKind", "allow_once")
                send({"jsonrpc":"2.0", "id":aid, "method":"session/request_permission", "params":{
                    "sessionId":sid,
                    "toolCall":{"toolCallId":str(aid), "title":item["title"], "kind":item["kind"],
                                "rawInput":{"fixture":item["title"]},
                                "_meta":{"acpmux":{"interactive":item.get("interactive", False)}}},
                    "options":[{"optionId":f"yes-{aid}", "kind":allow_kind, "name":"Allow"}] +
                              ([{"optionId":f"no-{aid}", "kind":"reject_once", "name":"Deny"}]
                               if item.get("reject", True) else [])
                }})
            for aid in wave_ids:
                pending[aid][0].wait()
                reply = pending.pop(aid)[1] or {}
                choices.append(reply.get("outcome", {}))
        update(sid, {"sessionUpdate":"agent_message_chunk", "content":{"type":"text", "text":json.dumps(choices)}})
        send({"jsonrpc":"2.0", "id":rid, "result":{"stopReason":"end_turn"}})
        return
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
    # Failure simulation for retry tests. "fail-once: X" fails the first
    # prompt of a session with an ACP internal error and echoes X after that;
    # "fail-after-update: X" streams a chunk first, then fails every time.
    if text.startswith("fail-once:"):
        if sid not in failed_once:
            failed_once.add(sid)
            send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "simulated internal error"}})
            return
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "echo: " + text[10:].strip()}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "env: NAME" replies with that environment variable, for spawn-time checks.
    if text.startswith("env:"):
        name = text[4:].strip()
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": f"{name}={os.environ.get(name, '')}"}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "argv" replies with this process's arguments as JSON, for spawn-time checks.
    if text == "argv":
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": json.dumps(sys.argv[1:])}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "fswrite: PATH" and "fsread: PATH" delegate the file operation to the
    # client (ACP fs/write_text_file, fs/read_text_file) and report the result.
    if text.startswith("fswrite:") or text.startswith("fsread:"):
        write = text.startswith("fswrite:")
        path = os.path.abspath(text.split(":", 1)[1].strip())
        params = {"sessionId": sid, "path": path}
        if write:
            params["content"] = "ok\n"
        res = request("fs/write_text_file" if write else "fs/read_text_file", params)
        if isinstance(res, dict) and "error" in res:
            reply = "rejected: " + res["error"].get("message", "")
        elif write:
            reply = "wrote"
        else:
            reply = "read: " + (res or {}).get("content", "").strip()
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": reply}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "die: X" prints X on stderr and exits without answering, like a
    # launcher that fails before the harness starts.
    if text.startswith("die:"):
        sys.stderr.write(text[4:].strip() + "\n")
        sys.stderr.flush()
        os._exit(3)
    if text.startswith("limit:"):
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "You've reached your usage limit for this account"}})
        return
    if text.startswith("fail-after-update:"):
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "partial "}})
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "simulated internal error after output"}})
        return
    # "meta: X" sends a chunk whose notification carries the agent's own _meta.
    if text.startswith("meta:"):
        send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text[5:].strip()}}, "_meta": {"fake": {"n": 1}}}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn", "_meta": {"fake": {"done": True}}}})
        return
    # "codex-retry" streams a partial message, reports a Codex stream retry,
    # then redelivers the answer under a new messageId. "codex-retry-after-tool"
    # finishes the message with a tool call before the retry notice.
    if text.startswith("codex-retry"):
        after_tool = text == "codex-retry-after-tool"
        update(sid, {"sessionUpdate": "agent_message_chunk", "messageId": "m1", "content": {"type": "text", "text": "partial"}})
        if after_tool:
            update(sid, {"sessionUpdate": "tool_call", "toolCallId": "tc1", "title": "ls", "kind": "read", "status": "completed"})
        update(sid, {"sessionUpdate": "session_info_update", "_meta": {"codex": {"error": {"message": "Reconnecting... 1", "willRetry": True, "additionalDetails": "stream disconnected"}}}})
        update(sid, {"sessionUpdate": "agent_message_chunk", "messageId": "m2", "content": {"type": "text", "text": "partial answer"}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "codex-fail" reports a terminal Codex error in-band, then ends the turn.
    if text == "codex-fail":
        update(sid, {"sessionUpdate": "session_info_update", "_meta": {"codex": {"error": {"message": "Error", "willRetry": False, "additionalDetails": "Selected model is at capacity.", "codexErrorInfo": {"serverOverloaded": {}}}}}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "fail-streamed: X" streams X as the answer, then fails with X.
    if text.startswith("fail-streamed:"):
        msg = text[14:].strip()
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": msg}})
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32000, "message": msg}})
        return
    # "hang" starts a turn that never ends: a busy agent.
    if text == "hang":
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "working"}})
        time.sleep(3600)
        return
    # "refuse": the backend refuses the request; the agent streams its error object as the reply.
    if text == "refuse":
        err = {"type": "error", "error": {"message": "Image web search is not supported by the backend.", "code": "unsupported_parameter"}, "status": 400}
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": json.dumps(err)}})
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
    # FAKE_IGNORE_TERM=1: behave like an agent that ignores SIGTERM.
    if os.environ.get("FAKE_IGNORE_TERM") == "1":
        import signal
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    # FAKE_START_GATE=<path>: start (read stdin) only once that file exists: a slow agent start.
    gate = os.environ.get("FAKE_START_GATE")
    if gate:
        import time
        while not os.path.exists(gate):
            time.sleep(0.02)
    sessions = 0
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        msg = json.loads(line)
        if "method" not in msg:
            p = pending.get(msg.get("id"))
            if p:
                p[1] = msg.get("result") if "error" not in msg else {"error": msg["error"]}
                p[0].set()
            continue
        m = msg["method"]
        rid = msg.get("id")
        params = msg.get("params") or {}
        if m == "initialize":
            send({"jsonrpc": "2.0", "id": rid, "result": {
                "protocolVersion": 1,
                "agentInfo": {"name": "fake", "version": "0"},
                "agentCapabilities": {"loadSession": os.environ.get("FAKE_NO_LOAD") != "1", "sessionCapabilities": {"fork": {}}},
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
