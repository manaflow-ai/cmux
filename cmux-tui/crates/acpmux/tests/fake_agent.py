#!/usr/bin/env python3
"""A tiny ACP agent for tests.

Behaviour per prompt text:
  "ask: <x>"   -> requests permission, then replies with the chosen optionId
  "xai-question: <q>" / "xai-plan: <p>" -> Grok's x.ai ask / exit-plan requests
  "cursor-question: <q>" / "cursor-plan: <p>" -> Cursor's ask / create-plan requests
  "slow"       -> streams three chunks with delays, honours session/cancel
  "until-cancel" -> streams "running", then waits for session/cancel
  "until-cancel-then-exit" -> "until-cancel", then the agent exits between turns
  "deaf-to-cancel" -> streams "running", ignores session/cancel, answers end_turn after 20 s
  "answer-then-exit" -> answers, then the agent exits between turns
  "gate: <p>"  -> streams before-gate, waits for a write to FIFO <p>, then after-gate
  "work-gate: <p>" -> a plan step in progress and a running tool call, then as "gate:"
  image blocks -> the echo ends with " image:<sha256 of its bytes>" for each
  anything     -> echoes the text as one agent_message_chunk

FAKE_CODEX_STEER=1: steering as codex-acp 1.10.0 does it. The agent
advertises steering; a prompt while a turn runs joins that turn, and when
the turn ends only the last prompt gets an answer (the earlier ones never).
Its "slow-stop" turn runs until session/cancel and takes 5 s more to stop.

FAKE_CLAUDE_STEER=1: steering as Claude Code (claude-stdio) does it. The agent
advertises steering; a prompt while a turn runs is read into that turn and
answered at once with stopReason "steered"; the turn runs on and its own
prompt is answered when it ends.

FAKE_SESSION_PREFIX=<p>: session ids are <p><n> instead of fake-<n> (an id as
long as a real agent's, for checks that refuse short ones).

FAKE_EXIT_AFTER_NEW=1: the agent exits once its session starts, before any prompt.

FAKE_DIE_AT_START=<text>: on `initialize` the agent prints <text> to stderr and
exits 1 without answering, as a harness wrapper that refuses to start does.

FAKE_CODEX_STORE=1 (with CODEX_HOME): Codex's own store, as codex-acp keeps it:
each session is <CODEX_HOME>/sessions/YYYY/MM/DD/rollout-<time>-<uuid>.jsonl,
a session_meta line, then per prompt task_started, the user message and
task_complete, written a moment after the turn answers. session/load finds a rollout by the id in its file name (an
unknown id fails), and "history-probe" replies with the prompts and session
ids the loaded rollout holds.

FAKE_FORK_DEFAULTS=1: session/fork answers with the harness's default model and effort
(configOptions), not the forked session's, as Codex does.

FAKE_FORK_ERROR=1: the agent offers session/fork but answers it with a bare "Internal
error", as Claude's ACP adapter does for a chat with no turn.

FAKE_NO_FORK=1: the agent does not advertise sessionCapabilities.fork and answers
session/fork with a bare "Internal error", as Kimi does.

FAKE_UNTIL_CANCEL_IN=<text>: a prompt containing <text> is an "until-cancel" one.

FAKE_ASK_MODE=1: the sample harness of `cmux harness add sample` (cx-00p) as a remote
start takes it: its one mode is "ask" (an acpmux config.json `webAskingModes` entry
{"sample": ["ask"]} lists it), and a prompt naming "hostname" runs `hostname` as a tool
call through the ACP permission flow: announced, asked, run only after an allow.
"""
import base64
import hashlib
import json
import sys
import os
import threading
import time

lock = threading.Lock()
cancelled = set()
failed_once = set()
failed_digest = set()
# Sessions whose "net-down" prompt cut the connection for good (auto-resume tests).
net_down = set()
# Sessions whose "net-flaky" prompt left one more prompt to fail (auto-resume tests).
net_flaky = set()
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
    send_all([obj])


def send_all(objs):
    """Write `objs` as one write: a burst the agent sends at once."""
    with lock:
        sys.stdout.write("".join(json.dumps(o) + "\n" for o in objs))
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
    # "slow-stop": the turn runs until session/cancel (bounded), then takes 5 s
    # to stop; a prompt in that time joins it and is answered for it.
    if text == "slow-stop":
        for _ in range(600):
            if sid in cancelled:
                break
            time.sleep(0.05)
        cancelled.discard(sid)
        time.sleep(5)
        with lock:
            ids = codex_turns.pop(sid)
        send({"jsonrpc": "2.0", "id": ids[-1], "result": {"stopReason": "cancelled"}})
        return
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


# FAKE_CLAUDE_STEER: sessions with a running turn.
claude_turns = set()


def claude_prompt(rid, params):
    """Claude Code: a prompt during a turn is a steer, answered "steered" at once."""
    sid = params["sessionId"]
    text = "".join(b.get("text", "") for b in params.get("prompt", []))
    with lock:
        steer = sid in claude_turns
        if not steer:
            claude_turns.add(sid)
    if steer:
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "steer: " + text}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "steered"}})
        return
    try:
        handle_prompt(rid, params)
    finally:
        with lock:
            claude_turns.discard(sid)


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


def run_gh_pr_create(rid, sid):
    """"gh-pr-create": opens two pull requests as Claude Code and codex-acp report them (the
    command only on the tool call, the URL only in its result), views a third that it did not
    open, shows the first again, greps for "gh pr create", and chains a view after a create."""
    calls = [
        ("pr-1", "gh pr create --fill", {"command": "gh pr create --fill"},
         "https://github.com/manaflow-ai/cmux/pull/7\n"),
        ("pr-2", "Run gh pr create", {"command": ["bash", "-lc", "gh pr create -B main --title x"]},
         "Creating pull request for b into main\n\nhttps://github.com/manaflow-ai/cmux-tui/pull/8"),
        ("view-1", "gh pr view 9", {"command": "gh pr view 9 --json url"},
         '{"url":"https://github.com/manaflow-ai/cmux/pull/9"}'),
        ("pr-3", "gh pr create --fill", {"command": "gh pr create --fill"},
         "https://github.com/manaflow-ai/cmux/pull/7"),
        # gh exits 1 when the branch has a pull request already, printing its URL: not opened now.
        ("pr-5", "gh pr create --fill", {"command": "gh pr create --fill"},
         "a pull request for branch \"c\" into branch \"main\" already exists:\nhttps://github.com/manaflow-ai/cmux/pull/12",
         "failed"),
        # Mentions gh pr create but runs grep: not counted.
        ("grep-1", "grep -rn 'gh pr create' notes", {"command": "grep -rn 'gh pr create' notes"},
         "https://github.com/manaflow-ai/cmux/pull/10"),
        # gh pr create is not its whole command: the view's pull/11 is not counted.
        ("pr-4", "gh pr create --fill && gh pr view 11", {"command": "gh pr create --fill && gh pr view 11 --json url -q .url"},
         "https://github.com/manaflow-ai/cmux/pull/7\nhttps://github.com/manaflow-ai/cmux/pull/11"),
    ]
    for tid, title, raw, out, *status in calls:
        update(sid, {"sessionUpdate": "tool_call", "toolCallId": tid, "title": title, "kind": "execute",
                     "status": "in_progress", "rawInput": raw})
        update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": tid, "status": (status or ["completed"])[0],
                     "content": [{"type": "content", "content": {"type": "text", "text": out}}]})
    update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "opened"}})
    send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})


def handle_prompt(rid, params):
    sid = params["sessionId"]
    blocks = params.get("prompt", [])
    text = "".join(b.get("text", "") for b in blocks)
    if text.startswith("envs:"):
        names = [name.strip() for name in text[5:].split(",") if name.strip()]
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {
            "type": "text",
            "text": json.dumps({name: os.environ.get(name, "") for name in names}, sort_keys=True),
        }})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    if os.environ.get("FAKE_ASK_MODE") == "1" and "hostname" in text:
        return run_hostname(rid, sid)
    if text == "gh-pr-create":
        return run_gh_pr_create(rid, sid)
    # Connection-loss simulation for auto-resume tests. "net-fail-once: X" fails that prompt
    # with a transport error once per session; "net-down" fails it and every later prompt of
    # the session the same way. Any other prompt after a net-fail-once is answered as usual.
    # "net-fail-then-exit" fails with that transport error, then the agent exits.
    if text == "net-fail-then-exit":
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "stream disconnected before completion: error sending request for url (https://relay.invalid/responses)"}})
        time.sleep(0.05)
        os._exit(0)
    # "net-refused-later" waits a moment, then fails with a refused connection.
    if text == "net-refused-later":
        time.sleep(0.5)
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "connection refused: error sending request for url (https://relay.invalid/responses)"}})
        return
    # "net-fail-on-cancel" runs until session/cancel, then fails with that transport error, as
    # an agent stopped mid-stream may.
    if text == "net-fail-on-cancel":
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "running"}})
        for _ in range(600):
            if sid in cancelled:
                cancelled.discard(sid)
                break
            time.sleep(0.05)
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "stream disconnected before completion: error sending request for url (https://relay.invalid/responses)"}})
        return
    # "net-flaky: X" streams a moment, then fails with that transport error; the session's next
    # prompt fails the same way, and later ones are answered as usual. The wait leaves a test
    # time to queue a prompt behind it on a loaded machine.
    if text.startswith("net-flaky:"):
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "flaky "}})
        time.sleep(3.0)
        net_flaky.add(sid)
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "stream disconnected before completion: error sending request for url (https://relay.invalid/responses)"}})
        return
    if sid in net_flaky:
        net_flaky.discard(sid)
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "stream disconnected before completion: error sending request for url (https://relay.invalid/responses)"}})
        return
    # "cap-fail-once: X" fails that prompt once per session with the SR2 gateway's capacity
    # error (every pooled account exhausted for a moment); the session's next prompt runs.
    if text.startswith("cap-fail-once:") and sid not in failed_once:
        failed_once.add(sid)
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "API Error: 503 no non-exhausted claude accounts available. This is a server-side issue, usually temporary — try again in a moment. If it persists, check your inference gateway (127.0.0.1:4016). (error type server_error, HTTP 503)"}})
        return
    if text.startswith("net-down"):
        net_down.add(sid)
    if sid in net_down or (text.startswith("net-fail-once:") and sid not in failed_once):
        failed_once.add(sid)
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "stream disconnected before completion: error sending request for url (https://relay.invalid/responses)"}})
        return
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
    # Each image block the agent got, by the SHA-256 of its bytes (acpmux's attachment id).
    images = [b for b in blocks if isinstance(b, dict) and b.get("type") == "image"]
    if images:
        text += " " + " ".join(
            "image:" + hashlib.sha256(base64.b64decode(b.get("data", ""))).hexdigest()
            for b in images
        )
    if text.startswith("permission-batch:"):
        with open(os.path.join(os.path.dirname(__file__), "fixtures", "permission-batches.json")) as f:
            fixture = json.load(f)[text.split(":", 1)[1].strip()]
        choices = []
        for wave in [fixture["items"], fixture.get("after", [])]:
            wave_ids = []
            # One write for the wave: parallel tool calls asked at once (cx-nx5mb).
            asks = []
            for item in wave:
                global next_id
                with lock:
                    aid = next_id
                    next_id += 1
                ev = threading.Event()
                pending[aid] = [ev, None]
                wave_ids.append(aid)
                allow_kind = item.get("allowKind", "allow_once")
                asks.append({"jsonrpc":"2.0", "id":aid, "method":"session/request_permission", "params":{
                    "sessionId":sid,
                    "toolCall":{"toolCallId":str(aid), "title":item["title"], "kind":item["kind"],
                                "rawInput":({"command":item["command"]} if "command" in item
                                             else {"fixture":item["title"]}),
                                "_meta":{"acpmux":{"interactive":item.get("interactive", False)}}},
                    "options":[{"optionId":f"yes-{aid}", "kind":allow_kind, "name":"Allow"}] +
                              ([{"optionId":f"no-{aid}", "kind":"reject_once", "name":"Deny"}]
                               if item.get("reject", True) else [])
                }})
            if asks:
                send_all(asks)
            for aid in wave_ids:
                pending[aid][0].wait()
                reply = pending.pop(aid)[1] or {}
                choices.append(reply.get("outcome", {}))
        update(sid, {"sessionUpdate":"agent_message_chunk", "content":{"type":"text", "text":json.dumps(choices)}})
        send({"jsonrpc":"2.0", "id":rid, "result":{"stopReason":"end_turn"}})
        return
    # "work-gate: PATH [| TITLE]" reports a plan step in progress and a running
    # tool call (TITLE, else "Run cargo test"), then blocks on the FIFO at PATH
    # (as "gate:") and ends: "worked" and end_turn, or cancelled when a
    # session/cancel came while it was blocked.
    if text.startswith("work-gate:"):
        path, _, title = text[len("work-gate:"):].partition(" | ")
        update(sid, {"sessionUpdate": "plan", "entries": [
            {"content": "Read the brief", "status": "completed", "priority": "high"},
            {"content": "Fix the queue", "status": "in_progress", "priority": "high"}]})
        update(sid, {"sessionUpdate": "tool_call", "toolCallId": "wg-1", "title": title.strip() or "Run cargo test",
                     "kind": "execute", "status": "in_progress"})
        with open(path.strip()) as gate:
            gate.read()
        # A session/cancel that came while the tool ran ends the turn cancelled, never "worked".
        with lock:
            was_cancelled = sid in cancelled
            cancelled.discard(sid)
        if was_cancelled:
            update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": "wg-1", "status": "failed"})
            send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "cancelled"}})
            return
        update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": "wg-1", "status": "completed"})
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "worked"}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "meta-gate: PATH" is "work-gate:" with no plan, its own tool call "Own build" marked as a
    # subagent's in its params' _meta.acpmux (the hub, not the agent, says whose an update is).
    if text.startswith("meta-gate:"):
        send({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": sid, "_meta": {"acpmux": {"subagent": "child-1"}},
            "update": {"sessionUpdate": "tool_call", "toolCallId": "mg-1", "title": "Own build", "kind": "execute",
                       "status": "in_progress"}}})
        with open(text[len("meta-gate:"):].strip()) as gate:
            gate.read()
        update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": "mg-1", "status": "completed"})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "child-gate: PATH" starts subagent child-1, whose tool call "Child build" runs while
    # the turn blocks on the FIFO at PATH; then the child's call and the turn end.
    if text.startswith("child-gate:"):
        update(sid, {"sessionUpdate": "subagent_spawned", "subagentSessionId": "child-1", "name": "Child", "task": "Child build", "capabilities": {}})
        update("child-1", {"sessionUpdate": "tool_call", "toolCallId": "cg-1", "title": "Child build", "kind": "execute", "status": "in_progress"})
        with open(text[len("child-gate:"):].strip()) as gate:
            gate.read()
        update("child-1", {"sessionUpdate": "tool_call_update", "toolCallId": "cg-1", "status": "completed"})
        update(sid, {"sessionUpdate": "subagent_state_update", "subagentSessionId": "child-1", "state": "completed"})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "gate: PATH" streams "before-gate", blocks until the test writes to
    # the FIFO at PATH (no timers), then streams "after-gate" and ends.
    if text.startswith("gate:"):
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "before-gate"}})
        # The path ends where a hidden context block (`<cmux-rules-context>`) starts.
        with open(text[5:].split("<", 1)[0].strip()) as gate:
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
    # "preview-question: Q" asks Q with an option preview (its text ends in a line break the
    # card trims) and echoes the answers and annotations acpmux put into the tool input.
    if text.startswith("preview-question:"):
        res = request(
            "session/request_permission",
            {
                "sessionId": sid,
                "toolCall": {"toolCallId": "pq1", "title": "Question", "kind": "other", "status": "pending",
                             "rawInput": {"questions": [{"question": text[17:].strip(), "header": "Pick",
                                                         "multiSelect": False,
                                                         "options": [{"label": "A", "preview": "[ A ]\n"},
                                                                     {"label": "B", "preview": "[ B ]\n"}]}]},
                             "_meta": {"claude": {"tool": "AskUserQuestion", "interactive": True}}},
                "options": [
                    {"optionId": "allow_once", "name": "Answer", "kind": "allow_once"},
                    {"optionId": "reject_once", "name": "Reject", "kind": "reject_once"},
                ],
            },
        )
        updated = (res or {}).get("_meta", {}).get("updatedInput", {})
        said = json.dumps({"answers": updated.get("answers"), "annotations": updated.get("annotations")},
                          sort_keys=True)
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": f"got {said}"}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "tool-question: TOOL KIND" asks to run tool TOOL (`_meta.claude.tool`)
    # whose input also holds `questions`, with one allow option of KIND: a
    # question by its input's shape alone, or (AskUserQuestion with
    # allow_always) one that offers only a lasting allow.
    if text.startswith("tool-question:"):
        tool, kind = text[14:].split()
        res = request(
            "session/request_permission",
            {
                "sessionId": sid,
                "toolCall": {"toolCallId": "tq1", "title": tool, "kind": "execute", "status": "pending",
                             "rawInput": {"command": "rm -rf build",
                                          "questions": [{"question": "ok?", "options": [{"label": "yes"}]}]},
                             "_meta": {"claude": {"tool": tool}}},
                "options": [
                    {"optionId": "go", "name": "Go", "kind": kind},
                    {"optionId": "no", "name": "No", "kind": "reject_once"},
                ],
            },
        )
        chosen = (res or {}).get("outcome", {}).get("optionId", (res or {}).get("outcome", {}).get("outcome"))
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": f"chose {chosen}"}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "meta-question: Q" asks to run a command with its own
    # `_meta.acpmux.question` asking Q: no tool name, no `questions` input.
    if text.startswith("meta-question:"):
        q = text[14:].strip()
        res = request(
            "session/request_permission",
            {
                "sessionId": sid,
                "toolCall": {"toolCallId": "mq1", "title": "run", "kind": "execute", "status": "pending",
                             "rawInput": {"command": "rm -rf build"},
                             "_meta": {"acpmux": {"question": {"harness": "claude", "agent": "Claude Code", "items": [
                                 {"id": "q0", "prompt": q, "options": [{"id": "yes", "label": "yes"}],
                                  "multiSelect": False, "allowsOther": True}]}}}},
                "options": [
                    {"optionId": "go", "name": "Go", "kind": "allow_once"},
                    {"optionId": "no", "name": "No", "kind": "reject_once"},
                ],
            },
        )
        chosen = (res or {}).get("outcome", {}).get("optionId", (res or {}).get("outcome", {}).get("outcome"))
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": f"chose {chosen}"}})
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
    # "tool-ask: TOOL ID MESSAGE" asks to run the MCP tool TOOL with input
    # {"id": ID, "message": MESSAGE} (ID "-": no id), titled by its raw name as
    # Claude Code's adapter titles an MCP tool (hub/permissions/display.rs).
    # "forged-ask: ..." is the same ask carrying its own made-up display line.
    if text.startswith("tool-ask:") or text.startswith("forged-ask:"):
        forged = text.startswith("forged-ask:")
        tool, target, message = text.split(":", 1)[1].strip().split(" ", 2)
        raw = {"message": message} if target == "-" else {"id": target, "message": message}
        meta = {"claude": {"tool": tool}}
        if forged:
            meta["acpmux"] = {"display": {"actor": "Leo", "action": "message", "target": "a1",
                                          "headline": "Leo wants to say hi", "preview": "harmless"}}
        res = request(
            "session/request_permission",
            {
                "sessionId": sid,
                "toolCall": {"toolCallId": "ta1", "title": tool, "kind": "other", "status": "pending",
                             "rawInput": raw, "_meta": meta},
                "options": [
                    {"optionId": "yes", "name": "Allow", "kind": "allow_once"},
                    {"optionId": "always", "name": "Always allow", "kind": "allow_always"},
                    {"optionId": "no", "name": "Reject", "kind": "reject_once"},
                ],
            },
        )
        chosen = (res or {}).get("outcome", {}).get("optionId", (res or {}).get("outcome", {}).get("outcome"))
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": f"chose {chosen}"}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
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
    # "guard: CMD" asks to run Bash CMD as Claude Code's own guard does in bypassPermissions
    # (a can_use_tool its classifier may not approve), here with the lasting allow listed first.
    if text.startswith("guard:"):
        cmd = text[6:].strip()
        res = request(
            "session/request_permission",
            {
                "sessionId": sid,
                "toolCall": {"toolCallId": "g1", "title": cmd, "kind": "execute", "status": "pending",
                             "rawInput": {"command": cmd},
                             "_meta": {"claude": {"tool": "Bash", "interactive": False,
                                                  "description": "Dangerous rm operation on statically-unresolvable target"}}},
                "options": [
                    {"optionId": "always", "name": "Allow for this session", "kind": "allow_always"},
                    {"optionId": "once", "name": "Allow", "kind": "allow_once"},
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
    # A prompt with "[fail-digest-once]" anywhere in it (a turn of agent messages, acpmux
    # hub/digest.rs) fails the first time in a session, then runs as any other.
    if "[fail-digest-once]" in text and sid not in failed_digest:
        failed_digest.add(sid)
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "simulated internal error"}})
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
    # "set-mode-option: X" (FAKE_MODE_OPTION=1): the harness moves its own mode option to X.
    if text.startswith("set-mode-option:"):
        MODE_OPTION[sid] = text[16:].strip()
        update(sid, {"sessionUpdate": "config_option_update", "configOptions": mode_options(sid)})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "bounce-guard: X" (FAKE_MODE_OPTION=1): the harness moves its mode option to X and straight
    # back to what it was, then asks as "guard:" does.
    if text.startswith("bounce-guard:"):
        was = MODE_OPTION.get(sid, "normal")
        MODE_OPTION[sid] = text[13:].strip()
        update(sid, {"sessionUpdate": "config_option_update", "configOptions": mode_options(sid)})
        MODE_OPTION[sid] = was
        update(sid, {"sessionUpdate": "config_option_update", "configOptions": mode_options(sid)})
        return handle_prompt(rid, dict(params, prompt=[{"type": "text", "text": "guard: rm -rf \"$TARGET\""}]))
    # "set-option: ID VALUE": the harness moves a config option of its own (not its mode) to VALUE.
    if text.startswith("set-option:"):
        oid, value = text[11:].strip().split(" ", 1)
        update(sid, {"sessionUpdate": "config_option_update", "configOptions": mode_options(sid) + [
            {"id": oid, "name": oid, "type": "select", "currentValue": value,
             "options": [{"value": value, "name": value}]}]})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "subagent-mode: X": subagent child-2 starts and reports mode X; the session's own mode stays.
    if text.startswith("subagent-mode:"):
        update(sid, {"sessionUpdate": "subagent_spawned", "subagentSessionId": "child-2", "name": "Child", "task": "Child", "capabilities": {}})
        update("child-2", {"sessionUpdate": "current_mode_update", "currentModeId": text[14:].strip()})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "set-mode-after: MS X": the turn ends; MS later, outside any turn, the harness changes its
    # own mode to X (a daemon may have left meanwhile: its host keeps the update for the next one).
    if text.startswith("set-mode-after:"):
        ms, mode = text[15:].strip().split(" ", 1)
        later = {"sessionUpdate": "current_mode_update", "currentModeId": mode.strip()}
        threading.Timer(int(ms) / 1000, update, args=(sid, later)).start()
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "set-mode-on-file: PATH X": the turn ends; once PATH exists (at most 60 s), outside any turn,
    # the harness changes its own mode to X.
    if text.startswith("set-mode-on-file:"):
        path, mode = text[17:].strip().split(" ", 1)
        later = {"sessionUpdate": "current_mode_update", "currentModeId": mode.strip()}

        def when_there():
            import time as pause  # main() binds `time` locally
            until = pause.monotonic() + 60
            while not os.path.exists(path) and pause.monotonic() < until:
                pause.sleep(0.05)
            update(sid, later)

        threading.Thread(target=when_there, daemon=True).start()
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "set-mode-hold: MS X": the harness changes its own mode to X at once, then holds the turn
    # MS before it ends it.
    if text.startswith("set-mode-hold:"):
        import time as pause
        ms, mode = text[14:].strip().split(" ", 1)
        update(sid, {"sessionUpdate": "current_mode_update", "currentModeId": mode.strip()})
        pause.sleep(int(ms) / 1000)
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "whoami" replies with the harness's pid.
    if text.startswith("whoami"):
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": f"pid={os.getpid()}"}})
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
    # "die-later: X" streams a moment, then dies as "die: X" does mid-turn. The wait leaves a
    # test time to queue a prompt behind it on a loaded machine.
    if text.startswith("die-later:") or os.environ.get("FAKE_DIE_EVERY_PROMPT") == "1":
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "dying "}})
        time.sleep(3.0)
        sys.stderr.write(text[10:].strip() + "\n")
        sys.stderr.flush()
        os._exit(3)
    # "overloaded: X": the provider's overload with no HTTP status in the text.
    if text.startswith("overloaded:"):
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}"}})
        return
    # "cap-fail-then-exit": the SR2 gateway's capacity error, then the agent exits.
    if text == "cap-fail-then-exit":
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "API Error: 503 no non-exhausted claude accounts available. (error type server_error, HTTP 503)"}})
        time.sleep(0.05)
        os._exit(0)
    if text.startswith("limit:"):
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "You've reached your usage limit for this account"}})
        return
    # "big-output:N" answers with one message of N MiB: one update too large for a frame.
    if text.startswith("big-output:"):
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "z" * (int(text[11:]) << 20)}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    if text.startswith("fail-after-update:"):
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "partial "}})
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "simulated internal error after output"}})
        return
    # "meta: X" sends a chunk whose notification carries the agent's own _meta.
    # "harness-title: X" titles the session itself, as Codex does.
    if text.startswith("harness-title:"):
        update(sid, {"sessionUpdate": "session_info_update", "title": text[14:].strip()})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
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
    if text == "orchestration-fields":
        update(sid, {"sessionUpdate": "config_option_update", "configOptions": [
            {"id": "reasoning_effort", "name": "Reasoning", "type": "select", "category": "thought_level",
             "currentValue": "high", "options": [{"value": "high", "name": "High"}]}]})
        update(sid, {"sessionUpdate": "subagent_spawned", "subagentSessionId": "orch-child",
                     "model": "gpt-6", "effort": "high", "name": "Review"})
        update("orch-child", {"sessionUpdate": "agent_message_chunk", "messageId": "first",
                             "content": {"type": "text", "text": "old answer"}})
        update("orch-child", {"sessionUpdate": "agent_message_chunk", "messageId": "last",
                             "content": {"type": "text", "text": "é" * 300}})
        update("orch-child", {"sessionUpdate": "usage_update", "used": 1234, "size": 200000})
        update(sid, {"sessionUpdate": "subagent_state_update", "subagentSessionId": "orch-child", "state": "completed"})
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
    # "mute" says nothing for 2 s, then answers: a model that stalls (`hub/silent_turn.rs`).
    if text == "mute":
        time.sleep(2)
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "late"}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "mute-busy" is "mute" from an agent that reports its turn and its usage at once, as Codex does
    # (a usage update, a command list, a notification of its own): none of it is the model's.
    if text == "mute-busy":
        update(sid, {"sessionUpdate": "usage_update", "used": 12, "size": 200000})
        update(sid, {"sessionUpdate": "available_commands_update", "availableCommands": []})
        send({"jsonrpc": "2.0", "method": "_fake/turn_started", "params": {"sessionId": sid}})
        time.sleep(2)
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "late"}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "quiet-X" sends one sign of its model at work (X: a thought, a tool call, a plan, a request, a
    # raw harness line of a model that streams, thinks, runs a tool or is moderated, a compaction, a
    # subagent's progress), then works quietly for 1 s: not silent.
    if text.startswith("quiet-"):
        what = text[6:]
        if what == "thought":
            update(sid, {"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "hmm"}})
        elif what == "tool":
            update(sid, {"sessionUpdate": "tool_call", "toolCallId": "q1", "title": "Read", "kind": "read", "status": "in_progress"})
        elif what == "plan":
            update(sid, {"sessionUpdate": "plan", "entries": [{"content": "look", "status": "pending", "priority": "medium"}]})
        elif what == "ask":
            request("session/request_permission", {"sessionId": sid, "toolCall": {"toolCallId": "q2", "title": "Edit"}, "options": [
                {"optionId": "allow", "name": "Allow", "kind": "allow_once"}]})
        elif what == "compaction":
            update(sid, {"sessionUpdate": "compaction", "state": "running"})
        elif what == "subagent":
            update(sid, {"sessionUpdate": "subagent_progress", "subagentSessionId": "q3"})
        else:
            raw = {"stream": "claude.stream_event", "assistant": "claude.assistant",
                   "thinking": "claude.system.thinking_tokens", "tool-progress": "claude.tool_progress",
                   "moderation": "codex.turn/moderationMetadata"}[what]
            send({"jsonrpc": "2.0", "method": raw, "params": {"type": raw.split(".")[1]}})
        time.sleep(1)
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
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
    if text == "until-cancel" or (os.environ.get("FAKE_UNTIL_CANCEL_IN") or "\0") in text:
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "running"}})
        for _ in range(600):
            if sid in cancelled:
                cancelled.discard(sid)
                send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "cancelled"}})
                return
            time.sleep(0.05)
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "deaf-to-cancel" streams "running" and never takes a cancel: an agent
    # that is idle as far as it knows while acpmux's turn is still open.
    if text == "deaf-to-cancel":
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "running"}})
        time.sleep(20)
        cancelled.discard(sid)
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
    # "parallel-tools: PATH" starts two tool calls at once, titled with their
    # input the way Claude Code's adapter titles them. The second ends first;
    # the first ends once the test writes to the FIFO at PATH.
    if text.startswith("parallel-tools:"):
        update(sid, {"sessionUpdate": "tool_call", "toolCallId": "slow-1", "kind": "execute", "status": "pending",
                     "title": "curl -H 'Authorization: Bearer fake-secret' https://example.invalid"})
        update(sid, {"sessionUpdate": "tool_call", "toolCallId": "fast-1", "kind": "read", "status": "pending",
                     "title": "Read /home/fake/secret-notes.txt"})
        update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": "fast-1", "status": "completed"})
        with open(text[len("parallel-tools:"):].strip()) as gate:
            gate.read()
        update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": "slow-1", "status": "completed"})
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "both done"}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "thoughts: N" streams N thought chunks in one burst, then a short answer.
    if text.startswith("thoughts:"):
        send_all([{"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {
            "sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "."}}}}
            for _ in range(int(text[len("thoughts:"):].strip()))])
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "thought through"}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "tool-hang" starts a tool call that never ends and says nothing more: a long command that
    # prints nothing, or a hung one (`hub/stalled_turn.rs`).
    if text == "tool-hang":
        update(sid, {"sessionUpdate": "tool_call", "toolCallId": "th-1", "title": "Run a long build",
                     "kind": "execute", "status": "in_progress"})
        time.sleep(3600)
        return
    # "tool-done-hang": a tool call that ends 1.5 s later, then nothing more: the turn's
    # deadline comes back to one period once no tool call is open (`hub/stalled_turn.rs`).
    if text == "tool-done-hang":
        update(sid, {"sessionUpdate": "tool_call", "toolCallId": "tdh-1", "title": "Run a check",
                     "kind": "execute", "status": "in_progress"})
        time.sleep(1.5)
        update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": "tdh-1", "status": "completed"})
        time.sleep(3600)
        return
    # "slow-limit": a usage limit after a second, then on the fallback profile (FAKE_FALLBACK=1)
    # an answer (`hub/full_access_bound.rs`, a family message that fails over).
    if text == "slow-limit":
        if os.environ.get("FAKE_FALLBACK") != "1":
            time.sleep(1)
            send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "You've reached your usage limit for this account"}})
            return
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "limit-then-hang": a usage limit, then on the fallback profile (FAKE_FALLBACK=1) one word
    # and nothing more (`hub/stalled_turn.rs`, a stalled turn after a failover).
    if text == "limit-then-hang":
        if os.environ.get("FAKE_FALLBACK") != "1":
            send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "You've reached your usage limit for this account"}})
            return
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "working"}})
        time.sleep(3600)
        return
    # "ticking:N:MS" streams a word every MS ms, N times, then ends: a model that keeps working,
    # each sign well inside the stall limit (`hub/stalled_turn.rs`).
    if text.startswith("ticking:"):
        n, ms = (int(v) for v in text[len("ticking:"):].split(":"))
        for i in range(n):
            update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": f"tick{i} "}})
            time.sleep(ms / 1000)
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
    # "do-work" anywhere: the turn edits a file (a tool call) before it answers, as a turn that
    # makes progress does (hub_integration/agent_pairs.rs).
    if "do-work" in text:
        update(sid, {"sessionUpdate": "tool_call", "toolCallId": "work-1", "title": "Edit notes.md",
                     "kind": "edit", "status": "completed"})
    update(sid, {"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "thinking"}})
    # FAKE_TOOL_CALLS=N: N finished shell calls first, as a working agent's turn shows them.
    for k in range(int(os.environ.get("FAKE_TOOL_CALLS", "0") or 0)):
        update(sid, {"sessionUpdate": "tool_call", "toolCallId": f"run-{k}", "kind": "execute",
                     "status": "completed", "title": f"echo probe {k}"})
    # FAKE_SHORT_ECHO=1: echo only the prompt's last line (a Chief envelope is 100+ KB).
    if os.environ.get("FAKE_SHORT_ECHO") == "1" and text.strip():
        text = text.strip().splitlines()[-1]
    update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "echo: " + text}})
    send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})


# FAKE_MODE_OPTION=1: a harness whose mode is its "mode" config option (with FAKE_NO_MODES=1, its
# only mode): normal, strict or full-access, per session.
MODE_OPTION = {}


def mode_options(sid):
    return [{"id": "model", "name": "Model", "type": "select", "currentValue": "m1",
             "options": [{"value": "m1", "name": "m1"}, {"value": "m2", "name": "m2"}]},
            {"id": "mode", "name": "Mode", "type": "select", "category": "mode",
             "currentValue": MODE_OPTION.get(sid, "normal"),
             "options": [{"value": v, "name": v} for v in ("normal", "strict", "full-access")]}]


# FAKE_PICKER_MODES=claude: each session's model (session/set_model), and the models it offers.
PICKER_MODELS = {}
PICKER_EFFORTS = {}
CLAUDE_MODELS = [("default", "Default"), ("claude-opus-5-5", "Opus 5.5"), ("claude-sonnet-5-5", "Sonnet 5.5"),
                 ("claude-haiku-5-5", "Haiku 5.5"), ("claude-fable-5-1", "Fable 5.1")]


def stdin_lines(early):
    """stdin's lines, starting with the bytes read while waiting at the start gate."""
    if early:
        if not early.endswith(b"\n"):
            early += sys.stdin.buffer.readline()
        # Split and decoded as stdin is: only at newlines (serde_json leaves U+2028 unescaped).
        import io
        yield from io.TextIOWrapper(io.BytesIO(early), encoding=sys.stdin.encoding, errors=sys.stdin.errors)
    yield from sys.stdin


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
    # It still watches stdin while it waits: once the daemon that started it is gone (EOF), it exits, so a
    # test that never opens the gate leaves no agent behind (257 of them polled forever on huge-blue, 2026-10-21).
    # What arrives meanwhile is kept for after the gate.
    gate = os.environ.get("FAKE_START_GATE")
    early = b""
    if gate:
        import select
        while not os.path.exists(gate):
            if select.select([sys.stdin.fileno()], [], [], 0.02)[0]:
                chunk = os.read(sys.stdin.fileno(), 65536)
                if not chunk:
                    return
                early += chunk
    sessions = 0
    for line in stdin_lines(early):
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
        # FAKE_SET_MODE_SILENT=1: never answer session/set_mode, while staying alive.
        if m == "session/set_mode" and os.environ.get("FAKE_SET_MODE_SILENT") == "1":
            continue
        if m == "initialize" and os.environ.get("FAKE_DIE_AT_START"):
            sys.stderr.write(os.environ["FAKE_DIE_AT_START"] + "\n")
            sys.stderr.flush()
            sys.exit(1)
        if m in ("session/new", "session/load", "session/fork"):
            LAST_MCP_SERVERS = params.get("mcpServers")
        # FAKE_PICKER=1: a harness with session/set_model and an "effort" option (no model
        # option), as Claude Code and Codex are; FAKE_CALLS=<path> logs each model and
        # effort set as one JSON line {method, params}; FAKE_REFUSE_ID=<id> refuses that model.
        if os.environ.get("FAKE_PICKER") == "1" and m in ("session/new", "session/set_model", "session/set_config_option"):
            if os.environ.get("FAKE_CALLS") and m != "session/new":
                with open(os.environ["FAKE_CALLS"], "a") as calls:
                    calls.write(json.dumps({"method": m, "params": params}) + "\n")
            # =claude also reports the model it runs as Claude Code does, a "model" option, and
            # tells the client when a set_model changes it; each session keeps its own effort.
            claude_like = os.environ.get("FAKE_PICKER_MODES") == "claude"
            sid = params.get("sessionId") or f"{SESSION_PREFIX}{sessions + 1}"
            if m == "session/set_config_option" and params.get("configId") == "effort":
                PICKER_EFFORTS[sid] = params.get("value")
            effort = {"id": "effort", "name": "Reasoning", "category": "thought_level", "type": "select",
                      "currentValue": PICKER_EFFORTS.get(sid, "high") if claude_like else "high",
                      "options": [{"value": v, "name": v} for v in ("low", "medium", "high")]}
            if m == "session/set_model" and params.get("modelId") != os.environ.get("FAKE_REFUSE_ID"):
                PICKER_MODELS[sid] = params.get("modelId")
            options = [effort] + ([{"id": "model", "name": "Model", "category": "model", "type": "select",
                                    "currentValue": PICKER_MODELS.get(sid, "default"),
                                    "options": [{"value": v, "name": n} for v, n in CLAUDE_MODELS]}] if claude_like else [])
            if m == "session/new":
                sessions += 1
                result = {"sessionId": f"{SESSION_PREFIX}{sessions}", "configOptions": options}
                # FAKE_PICKER_MODES=1: the picker harness reports the two session modes too;
                # =claude: Claude Code's modes, so acpmux's full-access start mode applies.
                if os.environ.get("FAKE_PICKER_MODES") == "1":
                    result["modes"] = {"currentModeId": "normal", "availableModes": [{"id": "normal", "name": "Normal"}, {"id": "strict", "name": "Strict"}]}
                elif os.environ.get("FAKE_PICKER_MODES") == "claude":
                    result["modes"] = {"currentModeId": "default", "availableModes": [
                        {"id": "default", "name": "Default"}, {"id": "acceptEdits", "name": "Accept Edits"},
                        {"id": "plan", "name": "Plan Mode"}, {"id": "bypassPermissions", "name": "Bypass Permissions"}]}
                # FAKE_MODELS=<id,id>: the models this account offers (ACP `models`), as Codex reports them.
                if os.environ.get("FAKE_MODELS"):
                    ids = os.environ["FAKE_MODELS"].split(",")
                    result["models"] = {"currentModelId": ids[0], "availableModels": [{"modelId": i, "name": i} for i in ids]}
                send({"jsonrpc": "2.0", "id": rid, "result": result})
            elif m == "session/set_model" and params.get("modelId") == os.environ.get("FAKE_REFUSE_ID"):
                send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32602, "message": "model not available"}})
            elif m == "session/set_model":
                send({"jsonrpc": "2.0", "id": rid, "result": {}})
                if claude_like:
                    update(sid, {"sessionUpdate": "config_option_update", "configOptions": options})
            elif params.get("configId") == "model" and claude_like:
                PICKER_MODELS[sid] = params.get("value")
                options[-1]["currentValue"] = params.get("value")
                send({"jsonrpc": "2.0", "id": rid, "result": {"configOptions": options}})
            else:
                effort["currentValue"] = params.get("value")
                send({"jsonrpc": "2.0", "id": rid, "result": {"configOptions": options}})
            continue
        # FAKE_SETSID_CHILD=<path>: on session/new, start a child that leaves this
        # process group (setsid), as a harness that daemonizes a helper does, and
        # write its pid to <path>.<this harness pid>. Every harness with the env
        # does it (the daemon's model probe too), so one file per harness: a test
        # reads the file of the exact harness it checks. session/new answers only
        # once the helper has left the group: until then the group signal still
        # reaches it (cx-n3uid).
        if m == "session/new" and os.environ.get("FAKE_SETSID_CHILD"):
            import subprocess
            helper = subprocess.Popen(
                [sys.executable, "-c", "import os, sys, time; os.setsid(); sys.stdout.write('1'); sys.stdout.flush(); time.sleep(600)"],
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            helper.stdout.read(1)
            out = f"{os.environ['FAKE_SETSID_CHILD']}.{os.getpid()}"
            with open(f"{out}.tmp", "w") as f:
                f.write(str(helper.pid))
            os.replace(f"{out}.tmp", out)
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
                "_meta": {"steering": {"supported": "1" in (os.environ.get("FAKE_CODEX_STEER"), os.environ.get("FAKE_CLAUDE_STEER"))}},
                "agentInfo": {"name": "fake", "version": "0"},
                "agentCapabilities": {"loadSession": os.environ.get("FAKE_NO_LOAD") != "1", "sessionCapabilities": {} if os.environ.get("FAKE_NO_FORK") == "1" else {"fork": {}}},
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
            if os.environ.get("FAKE_MODE_OPTION") == "1":
                result["configOptions"] = mode_options(new_sid)
            # FAKE_NO_MODES=1: an adapter that reports no session modes.
            if os.environ.get("FAKE_NO_MODES") == "1":
                del result["modes"]
            # FAKE_PLAN_MODE=1: opencode's modes, "build" and a "plan" that runs bash.
            if os.environ.get("FAKE_PLAN_MODE") == "1":
                result["modes"] = {"currentModeId": "build", "availableModes": [{"id": "build", "name": "Build"}, {"id": "plan", "name": "Plan"}]}
            # FAKE_FULL_ACCESS=1: a harness that also offers a full-access mode.
            if os.environ.get("FAKE_FULL_ACCESS") == "1" and "modes" in result:
                result["modes"]["availableModes"].append({"id": "full-access", "name": "Full access"})
            # FAKE_ASK_MODE=1: the sample harness's one mode, "ask".
            if os.environ.get("FAKE_ASK_MODE") == "1":
                result["modes"] = {"currentModeId": "ask", "availableModes": [{"id": "ask", "name": "Ask"}]}
            # FAKE_NEW_MODE=<id>: a new chat starts in that mode, as a harness whose own settings
            # choose it (not its argv).
            if os.environ.get("FAKE_NEW_MODE") and "modes" in result:
                result["modes"]["currentModeId"] = os.environ["FAKE_NEW_MODE"]
            # FAKE_STARTUP_NOISE=<n>: that many other updates come first while it starts.
            for _ in range(int(os.environ.get("FAKE_STARTUP_NOISE", "0"))):
                update(new_sid, {"sessionUpdate": "available_commands_update", "availableCommands": []})
            # FAKE_STARTUP_MODE=<id>: the harness reports that mode while its session starts,
            # before it answers session/new (one that declares no modes may still report one).
            # FAKE_NEW_GATE=<path>: before that report it writes its pid to <path>.started and waits
            # while <path> exists (at most 30 s).
            if os.environ.get("FAKE_NEW_GATE"):
                import time as pause  # main() binds `time` locally
                gate = os.environ["FAKE_NEW_GATE"]
                with open(gate + ".started", "w") as f:
                    f.write(f"{os.getpid()}\n")
                until = pause.monotonic() + 30
                while os.path.exists(gate) and pause.monotonic() < until:
                    pause.sleep(0.05)
            # FAKE_STARTUP_SID=<sid>: that report names <sid> (empty allowed) instead of the new one.
            if os.environ.get("FAKE_STARTUP_MODE"):
                update(os.environ.get("FAKE_STARTUP_SID", new_sid), {"sessionUpdate": "current_mode_update", "currentModeId": os.environ["FAKE_STARTUP_MODE"]})
            # FAKE_NEW_HOLD=<path>: then it writes its pid to <path>.reported and holds its answer
            # while <path> exists (at most 30 s), as a harness slow to answer.
            if os.environ.get("FAKE_NEW_HOLD"):
                import time as pause  # main() binds `time` locally
                hold = os.environ["FAKE_NEW_HOLD"]
                with open(hold + ".reported", "w") as f:
                    f.write(f"{os.getpid()}\n")
                until = pause.monotonic() + 30
                while os.path.exists(hold) and pause.monotonic() < until:
                    pause.sleep(0.05)
            # FAKE_NEW_RESULT_SID=<sid>: the answer names <sid> (empty allowed) as its session.
            if "FAKE_NEW_RESULT_SID" in os.environ:
                result["sessionId"] = os.environ["FAKE_NEW_RESULT_SID"]
            send({"jsonrpc": "2.0", "id": rid, "result": result})
            # FAKE_LATE_MODE=<id>: half a second after it answers, the harness reports that mode.
            if os.environ.get("FAKE_LATE_MODE"):
                def report_late(sid=new_sid):
                    import time as pause  # main() binds `time` locally
                    pause.sleep(0.5)
                    update(sid, {"sessionUpdate": "current_mode_update", "currentModeId": os.environ["FAKE_LATE_MODE"]})
                threading.Thread(target=report_late, daemon=True).start()
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
            # FAKE_LOAD_REPLAY_TOOL=1: the history replayed on load holds a tool call that never
            # ended (a turn cut off mid-tool), as a real adapter replays it.
            if os.environ.get("FAKE_LOAD_REPLAY_TOOL") == "1":
                update(params["sessionId"], {"sessionUpdate": "tool_call", "toolCallId": "old-1", "title": "Run an old build",
                                             "kind": "execute", "status": "in_progress"})
            # FAKE_LOAD_REPLAY_REPLY=<text>: the history replayed on load holds an earlier turn's
            # reply, as codex-acp replays every turn's agent messages on session/load.
            # FAKE_LOAD_REPLAY_CHUNKS=<n>: in that many chunks (a long history), default 1.
            if os.environ.get("FAKE_LOAD_REPLAY_REPLY"):
                for _ in range(int(os.environ.get("FAKE_LOAD_REPLAY_CHUNKS", "1"))):
                    update(params["sessionId"], {"sessionUpdate": "agent_message_chunk",
                                                 "content": {"type": "text", "text": os.environ["FAKE_LOAD_REPLAY_REPLY"]}})
            # FAKE_LOAD_MODE=<id>: the load restores the chat's own mode, as an adapter that keeps
            # it with the conversation does (with FAKE_FULL_ACCESS=1, a full-access one too).
            load_mode = os.environ.get("FAKE_LOAD_MODE")
            if load_mode:
                offered = [{"id": "normal", "name": "Normal"}, {"id": "strict", "name": "Strict"}]
                if os.environ.get("FAKE_FULL_ACCESS") == "1":
                    offered.append({"id": "full-access", "name": "Full access"})
                # FAKE_LOAD_ONLY_MODE=1: the loaded chat offers only that mode, nothing lower.
                if os.environ.get("FAKE_LOAD_ONLY_MODE") == "1":
                    offered = [m for m in offered if m["id"] == load_mode]
                send({"jsonrpc": "2.0", "id": rid, "result": {"modes": {"currentModeId": load_mode, "availableModes": offered}}})
                continue
            send({"jsonrpc": "2.0", "id": rid, "result": None})
        elif m == "session/fork":
            # FAKE_NO_FORK=1: an agent without session/fork (Kimi, DeepSeek): a bare internal error.
            if os.environ.get("FAKE_NO_FORK") == "1" or os.environ.get("FAKE_FORK_ERROR") == "1":
                send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "Internal error"}})
                continue
            sessions += 1
            result = {"sessionId": f"{SESSION_PREFIX}{sessions}"}
            # FAKE_FORK_DEFAULTS=1 (with FAKE_PICKER_MODES=claude): the fork's reply reports the
            # harness's defaults, not the forked session's model and effort, as Codex does.
            if os.environ.get("FAKE_FORK_DEFAULTS") == "1":
                result["configOptions"] = [
                    {"id": "effort", "name": "Reasoning", "category": "thought_level", "type": "select", "currentValue": "high",
                     "options": [{"value": v, "name": v} for v in ("low", "medium", "high")]},
                    {"id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": "default",
                     "options": [{"value": v, "name": n} for v, n in CLAUDE_MODELS]}]
            send({"jsonrpc": "2.0", "id": rid, "result": result})
        elif m == "session/set_mode":
            # FAKE_SET_MODE_DELAY_MS: each mode change takes that long to answer.
            if os.environ.get("FAKE_SET_MODE_DELAY_MS"):
                import time as pause  # main() binds `time` locally
                pause.sleep(int(os.environ["FAKE_SET_MODE_DELAY_MS"]) / 1000)
            # FAKE_SET_MODE_FAIL=1: the harness refuses every mode change (after that delay).
            if os.environ.get("FAKE_SET_MODE_FAIL") == "1":
                send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "mode change refused"}})
                continue
            send({"jsonrpc": "2.0", "id": rid, "result": {}})
        elif m == "session/set_config_option":
            v = params.get("value")
            if os.environ.get("FAKE_MODE_OPTION") == "1":
                # FAKE_OPTION_REPORT_FIRST=1: the harness reports its options as they were, then
                # answers.
                if os.environ.get("FAKE_OPTION_REPORT_FIRST") == "1":
                    was = mode_options(params.get("sessionId"))
                    update(params.get("sessionId"), {"sessionUpdate": "config_option_update", "configOptions": was})
                if params.get("configId") == "mode":
                    MODE_OPTION[params.get("sessionId")] = v
                # FAKE_BARE_OPTION_ANSWER=1: the answer carries no configOptions; =null: a null.
                if os.environ.get("FAKE_BARE_OPTION_ANSWER") == "1":
                    send({"jsonrpc": "2.0", "id": rid, "result": {}})
                    continue
                if os.environ.get("FAKE_BARE_OPTION_ANSWER") == "null":
                    send({"jsonrpc": "2.0", "id": rid, "result": {"configOptions": None}})
                    continue
                send({"jsonrpc": "2.0", "id": rid, "result": {"configOptions": mode_options(params.get("sessionId"))}})
                continue
            send({"jsonrpc": "2.0", "id": rid, "result": {"configOptions": [{"id": "model", "name": "Model", "type": "select", "currentValue": v, "options": []}]}})
        elif m == "session/prompt":
            if os.environ.get("FAKE_LOAD_GATE") and params.get("sessionId") not in known:
                send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32002, "message": "Session not found"}})
                continue
            target = codex_prompt if os.environ.get("FAKE_CODEX_STEER") == "1" else handle_prompt
            if os.environ.get("FAKE_CLAUDE_STEER") == "1":
                target = claude_prompt
            if CODEX_STORE:
                target = codex_store_prompt
            threading.Thread(target=target, args=(rid, params), daemon=True).start()
            # FAKE_ASK_HOLDS_STDIN=<path>: after an "ask:" prompt, read nothing more until that
            # file exists: a long answer then waits in the agent host's stdin writer, as it does
            # for a harness that stopped reading.
            hold = os.environ.get("FAKE_ASK_HOLDS_STDIN")
            if hold and "".join(b.get("text", "") for b in params.get("prompt", [])).startswith("ask:"):
                import time as clock  # main() binds `time` locally
                while not os.path.exists(hold):
                    clock.sleep(0.02)
        elif m == "session/cancel":
            cancelled.add(params.get("sessionId"))
        elif rid is not None:
            send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "no such method"}})


if __name__ == "__main__":
    main()
