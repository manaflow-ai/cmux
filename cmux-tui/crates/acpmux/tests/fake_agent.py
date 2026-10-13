#!/usr/bin/env python3
"""A tiny ACP agent for tests.

Behaviour per prompt text:
  "ask: <x>"   -> requests permission, then replies with the chosen optionId
  "xai-question: <q>" / "xai-plan: <p>" -> Grok's x.ai ask / exit-plan requests
  "cursor-question: <q>" / "cursor-plan: <p>" -> Cursor's ask / create-plan requests
  "slow"       -> streams three chunks with delays, honours session/cancel
  "until-cancel" -> streams "running", then waits for session/cancel
  "until-cancel-then-exit" -> "until-cancel", then the agent exits between turns
  "answer-then-exit" -> answers, then the agent exits between turns
  "gate: <p>"  -> streams before-gate, waits for a write to FIFO <p>, then after-gate
  anything     -> echoes the text as one agent_message_chunk

FAKE_CODEX_STEER=1: steering as codex-acp 1.10.0 does it. The agent
advertises steering; a prompt while a turn runs joins that turn, and when
the turn ends only the last prompt gets an answer (the earlier ones never).

FAKE_SESSION_PREFIX=<p>: session ids are <p><n> instead of fake-<n> (an id as
long as a real agent's, for checks that refuse short ones).

FAKE_EXIT_AFTER_NEW=1: the agent exits once its session starts, before any prompt.

FAKE_CODEX_STORE=1 (with CODEX_HOME): Codex's own store, as codex-acp keeps it:
each session is <CODEX_HOME>/sessions/YYYY/MM/DD/rollout-<time>-<uuid>.jsonl,
a session_meta line, then per prompt task_started, the user message and
task_complete, written a moment after the turn answers. session/load finds a rollout by the id in its file name (an
unknown id fails), and "history-probe" replies with the prompts and session
ids the loaded rollout holds.

FAKE_ASK_MODE=1: the sample harness of `cmux harness add sample` (cx-00p) as a remote
start takes it: its one mode is "ask" (an acpmux config.json `webAskingModes` entry
{"sample": ["ask"]} lists it), and a prompt naming "hostname" runs `hostname` as a tool
call through the ACP permission flow: announced, asked, run only after an allow.
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
# Sessions this process created or finished loading.
known = set()


LAST_MCP_SERVERS = None
# Whether the client asked for native subagent sessions the way codex-acp 1.10.0
# reads it: the JetBrains AIR capability in clientCapabilities._meta (its ACP
# schema strips the draft `subagents` field, so that one does not count).
NATIVE_SUBAGENTS = False
SESSION_PREFIX = os.environ.get("FAKE_SESSION_PREFIX", "fake-")


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


CODEX_STORE = os.environ.get("FAKE_CODEX_STORE") == "1" and os.environ.get("CODEX_HOME")
# FAKE_CODEX_STORE: each session's rollout file.
rollouts = {}


def codex_now():
    t = time.time()
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + ".%03dZ" % (int(t * 1000) % 1000)


def codex_write(sid, kind, payload):
    with open(rollouts[sid], "a") as f:
        f.write(json.dumps({"timestamp": codex_now(), "type": kind, "payload": payload}) + "\n")


def codex_new():
    import uuid
    sid = str(uuid.uuid4())
    day = os.path.join(os.environ["CODEX_HOME"], "sessions", *time.strftime("%Y %m %d").split())
    os.makedirs(day, exist_ok=True)
    rollouts[sid] = os.path.join(day, time.strftime("rollout-%Y-%m-%dT%H-%M-%S-") + sid + ".jsonl")
    codex_write(sid, "session_meta", {"id": sid, "cwd": os.getcwd()})
    return sid


def codex_load(sid):
    suffix = "-" + sid + ".jsonl"
    for root, _, files in os.walk(os.path.join(os.environ["CODEX_HOME"], "sessions")):
        for name in files:
            if name.startswith("rollout-") and name.endswith(suffix):
                rollouts[sid] = os.path.join(root, name)
                return True
    return False


def codex_store_prompt(rid, params):
    sid = params["sessionId"]
    text = "".join(b.get("text", "") for b in params.get("prompt", []))
    codex_write(sid, "event_msg", {"type": "task_started"})
    codex_write(sid, "response_item", {"type": "message", "role": "user", "content": [{"type": "input_text", "text": text}]})
    # A turn takes time: it never ends in the millisecond it started.
    time.sleep(0.02)
    reply = "ok: " + text
    if text.strip() == "history-probe":
        with open(rollouts[sid]) as f:
            records = [json.loads(line) for line in f if line.strip()]
        reply = json.dumps({
            "prompts": [r["payload"]["content"][0]["text"] for r in records
                        if r["type"] == "response_item" and r["payload"].get("role") == "user"
                        and r["payload"]["content"][0]["text"] != "history-probe"],
            "sessions": sorted({r["payload"]["id"] for r in records if r["type"] == "session_meta"}),
        })
    update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": reply}})
    send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
    # Codex's rollout writer flushes a turn's last records after the turn
    # answers, so they can be stamped after acpmux logs the turn's end.
    time.sleep(0.05)
    codex_write(sid, "event_msg", {"type": "task_complete"})


def update(sid, upd):
    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": upd}})


# FAKE_CODEX_STEER: the running turn's prompt ids per session.
codex_turns = {}


def codex_prompt(rid, params):
    """codex-acp: the first prompt runs the turn; a prompt during it joins it.
    At the turn's end only the last joined prompt is answered."""
    sid = params["sessionId"]
    text = "".join(b.get("text", "") for b in params.get("prompt", []))
    with lock:
        running = codex_turns.get(sid)
        if running is not None:
            running.append(rid)
            return
        codex_turns[sid] = [rid]
    update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "turn: " + text}})
    # The turn runs until a joined prompt arrives (bounded), then a moment.
    for _ in range(300):
        with lock:
            joined = len(codex_turns[sid]) > 1
        if joined:
            break
        time.sleep(0.01)
    time.sleep(0.2)
    with lock:
        ids = codex_turns.pop(sid)
    update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": f"answered {len(ids)}"}})
    send({"jsonrpc": "2.0", "id": ids[-1], "result": {"stopReason": "end_turn"}})


def run_hostname(rid, sid):
    """FAKE_ASK_MODE: `hostname` as a tool call, run only after the person's allow."""
    call = {"toolCallId": "hostname-1", "title": "hostname", "kind": "execute", "status": "pending",
            "rawInput": {"command": "hostname"}}
    update(sid, dict(call, sessionUpdate="tool_call"))
    res = request("session/request_permission", {"sessionId": sid, "toolCall": call, "options": [
        {"optionId": "allow", "name": "Allow", "kind": "allow_once"},
        {"optionId": "reject", "name": "Reject", "kind": "reject_once"},
    ]})
    if ((res or {}).get("outcome") or {}).get("optionId") == "allow":
        import subprocess
        out = subprocess.run(["hostname"], capture_output=True, text=True).stdout.strip()
        update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": "hostname-1", "status": "completed",
                     "content": [{"type": "content", "content": {"type": "text", "text": out}}]})
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "hostname: " + out}})
    else:
        update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": "hostname-1", "status": "failed"})
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "hostname: not run"}})
    send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})


def handle_prompt(rid, params):
    sid = params["sessionId"]
    blocks = params.get("prompt", [])
    text = "".join(b.get("text", "") for b in blocks)
    if os.environ.get("FAKE_ASK_MODE") == "1" and "hostname" in text:
        return run_hostname(rid, sid)
    links = [b for b in blocks if isinstance(b, dict) and b.get("type") == "resource_link"]
    if links:
        text += " " + " ".join(
            "resource_link:{name}:{mime}:{uri}".format(
                name=b.get("name", ""),
                mime=b.get("mimeType", ""),
                uri=b.get("uri", "")
            )
            for b in links
        )
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
    # "gate: PATH" streams "before-gate", blocks until the test writes to
    # the FIFO at PATH (no timers), then streams "after-gate" and ends.
    if text.startswith("gate:"):
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "before-gate"}})
        with open(text[5:].strip()) as gate:
            gate.read()
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "after-gate"}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "question: Q" asks Q the way Claude Code's AskUserQuestion does and
    # echoes the outcome plus the answers acpmux put into the tool input.
    if text.startswith("question:"):
        res = request(
            "session/request_permission",
            {
                "sessionId": sid,
                "toolCall": {"toolCallId": "q1", "title": "Question", "kind": "other", "status": "pending",
                             "rawInput": {"questions": [{"question": text[9:].strip(), "header": "Pick",
                                                         "multiSelect": False,
                                                         "options": [{"label": "A", "description": "first"},
                                                                     {"label": "B"}]}]},
                             "_meta": {"claude": {"tool": "AskUserQuestion", "interactive": True}}},
                "options": [
                    {"optionId": "allow_once", "name": "Answer", "kind": "allow_once"},
                    {"optionId": "reject_once", "name": "Reject", "kind": "reject_once"},
                ],
            },
        )
        res = res or {}
        chosen = res.get("outcome", {}).get("optionId", res.get("outcome", {}).get("outcome"))
        answers = res.get("_meta", {}).get("updatedInput", {}).get("answers")
        update(sid, {"sessionUpdate": "agent_message_chunk",
                     "content": {"type": "text", "text": f"chose {chosen} {json.dumps(answers, sort_keys=True)}"}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "xai-question: Q" asks Q the way Grok does (`_x.ai/ask_user_question`)
    # and "xai-plan: P" asks to leave plan mode with plan P
    # (`_x.ai/exit_plan_mode`); both echo the client's JSON reply.
    if text.startswith("xai-question:"):
        res = request("_x.ai/ask_user_question", {
            "sessionId": sid, "toolCallId": "xq1", "mode": "default",
            "questions": [{"question": text[13:].strip(), "multiSelect": False,
                           "options": [{"label": "A", "description": "first"}, {"label": "B"}]}],
        })
        update(sid, {"sessionUpdate": "agent_message_chunk",
                     "content": {"type": "text", "text": "xai " + json.dumps(res, sort_keys=True)}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    if text.startswith("xai-plan:"):
        res = request("x.ai/exit_plan_mode", {"sessionId": sid, "toolCallId": "xp1", "planContent": text[9:].strip()})
        update(sid, {"sessionUpdate": "agent_message_chunk",
                     "content": {"type": "text", "text": "xai " + json.dumps(res, sort_keys=True)}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "cursor-question: Q" asks Q the way Cursor does (`cursor/ask_question`,
    # option ids distinct from labels) and "cursor-plan: P" proposes plan P
    # (`cursor/create_plan`); both echo the client's JSON reply.
    if text.startswith("cursor-question:"):
        res = request("cursor/ask_question", {
            "toolCallId": "cq1", "title": "Pick one",
            "questions": [{"id": "which", "prompt": text[16:].strip(), "allowMultiple": True,
                           "options": [{"id": "opt-a", "label": "A"}, {"id": "opt-b", "label": "B"}]}],
        })
        update(sid, {"sessionUpdate": "agent_message_chunk",
                     "content": {"type": "text", "text": "cursor " + json.dumps(res, sort_keys=True)}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    if text.startswith("cursor-plan:"):
        res = request("cursor/create_plan", {"toolCallId": "cp1", "name": "Fix", "plan": text[12:].strip(),
                                             "todos": [{"id": "t1", "content": "read", "status": "pending"}]})
        update(sid, {"sessionUpdate": "agent_message_chunk",
                     "content": {"type": "text", "text": "cursor " + json.dumps(res, sort_keys=True)}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "gate-ask: PATH" blocks on the FIFO at PATH (as "gate:"), then asks
    # like "ask:"; "drift-ask: MODE" changes its own mode to MODE, then asks.
    # Both let a test change the session between the dispatch and the ask.
    if text.startswith("gate-ask:"):
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "before-gate"}})
        with open(text[9:].strip()) as gate:
            gate.read()
        text = "ask: gated command"
    if text.startswith("drift-ask:"):
        update(sid, {"sessionUpdate": "current_mode_update", "currentModeId": text[10:].strip()})
        text = "ask: drifted command"
    # "ask-always: X" asks with an "allow always" option (a lasting grant).
    if text.startswith("ask-always:"):
        res = request(
            "session/request_permission",
            {
                "sessionId": sid,
                "toolCall": {"toolCallId": "t1", "title": text[11:].strip(), "kind": "execute", "status": "pending"},
                "options": [
                    {"optionId": "always", "name": "Always", "kind": "allow_always"},
                    {"optionId": "no", "name": "Reject", "kind": "reject_once"},
                ],
            },
        )
        chosen = (res or {}).get("outcome", {}).get("optionId", (res or {}).get("outcome", {}).get("outcome"))
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": f"chose {chosen}"}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
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
    # "set-mode: X": the harness changes its own mode, as a real one may.
    if text.startswith("set-mode:"):
        update(sid, {"sessionUpdate": "current_mode_update", "currentModeId": text[9:].strip()})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "env: NAME" replies with that environment variable, for spawn-time checks.
    if text.startswith("env:"):
        name = text[4:].strip()
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": f"{name}={os.environ.get(name, '')}"}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "http: URL KEY" posts a one-message chat request to URL with KEY as the
    # bearer (a model call) and replies "HTTP <status> <body>".
    if text.startswith("http:"):
        import urllib.request, urllib.error
        url, key = text[5:].split()
        body = json.dumps({"model": "m", "messages": [{"role": "user", "content": "hi"}]}).encode()
        req = urllib.request.Request(url, data=body, method="POST", headers={"authorization": f"Bearer {key}", "content-type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                reply = f"HTTP {resp.status} {resp.read().decode()[:300]}"
        except urllib.error.HTTPError as e:
            reply = f"HTTP {e.code} {e.read().decode()[:300]}"
        except Exception as e:
            reply = f"HTTP error {e}"
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": reply}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "mcp" replies with the mcpServers of the last session/new, load or fork.
    if text == "mcp":
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": json.dumps(LAST_MCP_SERVERS)}})
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
    # finishes the message with a tool call before the retry notice;
    # "codex-retry-after-subagent" has a subagent end there instead.
    if text.startswith("codex-retry"):
        after_tool = text == "codex-retry-after-tool"
        after_subagent = text == "codex-retry-after-subagent"
        if after_subagent:
            update(sid, {"sessionUpdate": "subagent_spawned", "subagentSessionId": "child-1", "name": "Branch A", "task": "Branch A", "capabilities": {}})
        update(sid, {"sessionUpdate": "agent_message_chunk", "messageId": "m1", "content": {"type": "text", "text": "partial"}})
        if after_tool:
            update(sid, {"sessionUpdate": "tool_call", "toolCallId": "tc1", "title": "ls", "kind": "read", "status": "completed"})
        if after_subagent:
            update(sid, {"sessionUpdate": "subagent_state_update", "subagentSessionId": "child-1", "state": "completed"})
        update(sid, {"sessionUpdate": "session_info_update", "_meta": {"codex": {"error": {"message": "Reconnecting... 1", "willRetry": True, "additionalDetails": "stream disconnected"}}}})
        update(sid, {"sessionUpdate": "agent_message_chunk", "messageId": "m2", "content": {"type": "text", "text": "partial answer"}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "codex-subagents" starts two subagents as codex-acp 1.10.0 does: with native
    # subagent sessions, a subagent_spawned per child and each child's own
    # updates under its session id; without, only "Start subagent" tool calls.
    if text == "codex-subagents":
        children = [("child-a", "/root/read_a", "Read a", "a.txt"), ("child-b", "/root/read_b", "Read b", "b.txt")]
        for child, path, name, _ in children:
            if NATIVE_SUBAGENTS:
                update(sid, {"sessionUpdate": "subagent_spawned", "subagentSessionId": child, "name": name, "task": f"Delegated task for {name}", "capabilities": {}})
            else:
                update(sid, {"sessionUpdate": "tool_call", "toolCallId": f"start-{child}", "title": f"Start subagent {path[6:]}", "kind": "other", "status": "completed",
                             "_meta": {"codex": {"subagent": {"threadId": child, "path": path, "activity": "started"}}}})
        if NATIVE_SUBAGENTS:
            for child, _, _, file in children:
                update(child, {"sessionUpdate": "tool_call", "toolCallId": f"read-{child}", "title": f"Read file '{file}'", "kind": "read", "status": "completed"})
                update(child, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": f"{file} says hello"}})
                update(sid, {"sessionUpdate": "subagent_state_update", "subagentSessionId": child, "state": "completed"})
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "both read"}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "codex-late-subagent-ask": a native subagent that outlives its parent's turn and asks
    # for permission after that turn ended (cx-jo8yo): the turn ends at once, then the child
    # asks under its own session id and says what it was answered.
    if text == "codex-late-subagent-ask" and NATIVE_SUBAGENTS:
        update(sid, {"sessionUpdate": "subagent_spawned", "subagentSessionId": "late-child", "name": "Late", "task": "Late", "capabilities": {}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})

        def late():
            call = {"toolCallId": "late-1", "title": "touch late.txt", "kind": "edit", "status": "pending"}
            res = request("session/request_permission", {"sessionId": "late-child", "toolCall": call, "options": [
                {"optionId": "yes", "name": "Allow", "kind": "allow_once"},
                {"optionId": "no", "name": "Reject", "kind": "reject_once"},
            ]})
            outcome = (res or {}).get("outcome") or {}
            update("late-child", {"sessionUpdate": "agent_message_chunk", "content": {"type": "text",
                   "text": "late " + (outcome.get("optionId") or outcome.get("outcome") or "none")}})
            update(sid, {"sessionUpdate": "subagent_state_update", "subagentSessionId": "late-child", "state": "completed"})
        threading.Thread(target=late, daemon=True).start()
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
    # "until-cancel" streams "running" and ends only on session/cancel (bounded at 30 s).
    if text == "until-cancel":
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "running"}})
        for _ in range(600):
            if sid in cancelled:
                cancelled.discard(sid)
                send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "cancelled"}})
                return
            time.sleep(0.05)
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "answer-then-exit" answers, then the agent exits between turns.
    if text == "answer-then-exit":
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "answered"}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        time.sleep(0.3)
        os._exit(0)
    # "until-cancel-then-exit" is "until-cancel", then the agent exits between
    # turns: a chat whose process is gone with no answer.
    if text == "until-cancel-then-exit":
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "running"}})
        for _ in range(600):
            if sid in cancelled:
                cancelled.discard(sid)
                send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "cancelled"}})
                time.sleep(0.3)
                os._exit(0)
            time.sleep(0.05)
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
    global LAST_MCP_SERVERS
    # `--fake-login` (the terminal sign-in): sign in and exit.
    if "--fake-login" in sys.argv[1:]:
        open(os.environ["FAKE_AUTH_FILE"], "w").close()
        return
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
        if m in ("session/new", "session/load", "session/fork"):
            LAST_MCP_SERVERS = params.get("mcpServers")
        # FAKE_PICKER=1: a harness with session/set_model and an "effort" option (no model
        # option), as Claude Code and Codex are; FAKE_CALLS=<path> logs each model and
        # effort set as one JSON line {method, params}.
        if os.environ.get("FAKE_PICKER") == "1" and m in ("session/new", "session/set_model", "session/set_config_option"):
            if os.environ.get("FAKE_CALLS") and m != "session/new":
                with open(os.environ["FAKE_CALLS"], "a") as calls:
                    calls.write(json.dumps({"method": m, "params": params}) + "\n")
            effort = {"id": "effort", "name": "Reasoning", "category": "thought_level", "type": "select", "currentValue": "high",
                      "options": [{"value": v, "name": v} for v in ("low", "medium", "high")]}
            if m == "session/new":
                sessions += 1
                send({"jsonrpc": "2.0", "id": rid, "result": {"sessionId": f"{SESSION_PREFIX}{sessions}", "configOptions": [effort]}})
            elif m == "session/set_model":
                send({"jsonrpc": "2.0", "id": rid, "result": {}})
            else:
                effort["currentValue"] = params.get("value")
                send({"jsonrpc": "2.0", "id": rid, "result": {"configOptions": [effort]}})
            continue
        # FAKE_SETSID_CHILD=<path>: on session/new (the session's harness, not a probe),
        # start a child that leaves this process group (setsid), as a harness that
        # daemonizes a helper does, and write its pid to that file.
        if m == "session/new" and os.environ.get("FAKE_SETSID_CHILD"):
            import subprocess
            helper = subprocess.Popen(
                [sys.executable, "-c", "import os, time; os.setsid(); time.sleep(600)"],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            tmp = f"{os.environ['FAKE_SETSID_CHILD']}.{os.getpid()}.tmp"
            with open(tmp, "w") as f:
                f.write(str(helper.pid))
            os.replace(tmp, os.environ["FAKE_SETSID_CHILD"])
        # FAKE_CWD_LOG=<path>: append the process folder and the session/new cwd.
        if m == "session/new" and os.environ.get("FAKE_CWD_LOG"):
            with open(os.environ["FAKE_CWD_LOG"], "a") as log:
                log.write(json.dumps({"process": os.getcwd(), "session": params.get("cwd")}) + "\n")
        if m == "authenticate":
            # FAKE_AUTH_FILE: "fake-login" signs in (writes the file).
            if params.get("methodId") == "fake-login" and os.environ.get("FAKE_AUTH_FILE"):
                open(os.environ["FAKE_AUTH_FILE"], "w").close()
                send({"jsonrpc": "2.0", "id": rid, "result": {}})
            else:
                send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32602, "message": "no such auth method"}})
            continue
        if (m == "session/new" and os.environ.get("FAKE_AUTH_FILE")
                and not os.path.exists(os.environ["FAKE_AUTH_FILE"])):
            send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32000, "message": "Authentication required"}})
            continue
        if m == "initialize":
            global NATIVE_SUBAGENTS
            air = ((params.get("clientCapabilities") or {}).get("_meta") or {}).get("jetbrains", {}).get("air", {})
            NATIVE_SUBAGENTS = air.get("version", 0) >= 1 and "nativeSubagentSessions" in air.get("capabilities", [])
            # FAKE_INIT_DELAY_MS / FAKE_NEW_DELAY_MS: an adapter boot and a
            # session start that take time (MCP servers), for pool latency.
            if os.environ.get("FAKE_INIT_DELAY_MS"):
                import time as pause  # main() binds `time` locally
                pause.sleep(int(os.environ["FAKE_INIT_DELAY_MS"]) / 1000)
            send({"jsonrpc": "2.0", "id": rid, "result": {
                "protocolVersion": 1,
                "_meta": {"steering": {"supported": os.environ.get("FAKE_CODEX_STEER") == "1"}},
                "agentInfo": {"name": "fake", "version": "0"},
                "agentCapabilities": {"loadSession": os.environ.get("FAKE_NO_LOAD") != "1", "sessionCapabilities": {"fork": {}}},
                "authMethods": [] if not os.environ.get("FAKE_AUTH_FILE") else [
                    {"id": "fake-login", "name": "Fake login", "description": "opens a browser"},
                    {"id": "fake-terminal", "name": "Terminal login", "type": "terminal", "args": ["--fake-login"]},
                    {"id": "fake-key", "name": "API key", "type": "env_var", "varName": "FAKE_API_KEY"},
                    {"id": "odd", "type": "carrier-pigeon"},
                ],
            }})
        elif m == "session/new":
            if os.environ.get("FAKE_NEW_DELAY_MS"):
                import time as pause  # main() binds `time` locally
                pause.sleep(int(os.environ["FAKE_NEW_DELAY_MS"]) / 1000)
            sessions += 1
            new_sid = codex_new() if CODEX_STORE else f"{SESSION_PREFIX}{sessions}"
            known.add(new_sid)
            result = {
                "sessionId": new_sid,
                "modes": {"currentModeId": "normal", "availableModes": [{"id": "normal", "name": "Normal"}, {"id": "strict", "name": "Strict"}]},
                "configOptions": [{"id": "model", "name": "Model", "type": "select", "currentValue": "m1", "options": [{"value": "m1", "name": "m1"}, {"value": "m2", "name": "m2"}]}],
            }
            # FAKE_NO_MODES=1: an adapter that reports no session modes.
            if os.environ.get("FAKE_NO_MODES") == "1":
                del result["modes"]
            # FAKE_ASK_MODE=1: the sample harness's one mode, "ask".
            if os.environ.get("FAKE_ASK_MODE") == "1":
                result["modes"] = {"currentModeId": "ask", "availableModes": [{"id": "ask", "name": "Ask"}]}
            send({"jsonrpc": "2.0", "id": rid, "result": result})
            # FAKE_EXIT_AFTER_NEW=1: the agent exits once its session starts,
            # before any prompt.
            if os.environ.get("FAKE_EXIT_AFTER_NEW") == "1":
                os._exit(0)
        elif m == "session/load" and CODEX_STORE:
            if codex_load(params["sessionId"]):
                send({"jsonrpc": "2.0", "id": rid, "result": None})
            else:
                send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "Internal error", "data": {"details": "no rollout found for thread id " + params["sessionId"]}}})
        elif m == "session/load":
            # FAKE_LOAD_ERROR=<details>: the load fails as codex-acp does while
            # another Codex holds the thread: "Internal error", the reason in data.details.
            if os.environ.get("FAKE_LOAD_ERROR"):
                error = {"code": -32603, "message": "Internal error", "data": {"details": os.environ["FAKE_LOAD_ERROR"]}}
                send({"jsonrpc": "2.0", "id": rid, "error": error})
                continue
            # FAKE_LOAD_GATE=<path>: the load answers once that file exists, on
            # its own thread, and until then the session is unknown: a prompt
            # for it fails "Session not found", as real adapters answer.
            load_gate = os.environ.get("FAKE_LOAD_GATE")
            if load_gate:
                def finish_load(rid=rid, sid=params["sessionId"]):
                    import time as clock  # main() imports `time` locally
                    while not os.path.exists(load_gate):
                        clock.sleep(0.01)
                    update(sid, {"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": "replayed"}})
                    known.add(sid)
                    send({"jsonrpc": "2.0", "id": rid, "result": None})
                threading.Thread(target=finish_load, daemon=True).start()
                continue
            update(params["sessionId"], {"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": "replayed"}})
            send({"jsonrpc": "2.0", "id": rid, "result": None})
        elif m == "session/fork":
            sessions += 1
            send({"jsonrpc": "2.0", "id": rid, "result": {"sessionId": f"{SESSION_PREFIX}{sessions}"}})
        elif m == "session/set_mode":
            send({"jsonrpc": "2.0", "id": rid, "result": {}})
        elif m == "session/set_config_option":
            v = params.get("value")
            send({"jsonrpc": "2.0", "id": rid, "result": {"configOptions": [{"id": "model", "name": "Model", "type": "select", "currentValue": v, "options": []}]}})
        elif m == "session/prompt":
            if os.environ.get("FAKE_LOAD_GATE") and params.get("sessionId") not in known:
                send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32002, "message": "Session not found"}})
                continue
            target = codex_prompt if os.environ.get("FAKE_CODEX_STEER") == "1" else handle_prompt
            if CODEX_STORE:
                target = codex_store_prompt
            threading.Thread(target=target, args=(rid, params), daemon=True).start()
        elif m == "session/cancel":
            cancelled.add(params.get("sessionId"))
        elif rid is not None:
            send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "no such method"}})


if __name__ == "__main__":
    main()
