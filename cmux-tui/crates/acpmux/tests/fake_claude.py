#!/usr/bin/env python3
"""A tiny stand-in for Claude Code's stream-json protocol, for tests.

It answers every control_request with success, reports system/init after
initialize, and replies to every user message with its own arguments as
JSON (spawn-time checks of the Claude command line).

With FAKE_CLAUDE_STORE set it keeps Claude Code's own session store there:
the init reports the `--session-id`/`--resume` id, a conversation exists
once a user message reached it, and `--resume` of one that does not exist
fails the first prompt with Claude's own "No conversation found" line.
FAKE_CLAUDE_DIE=1 dies on the first prompt before anything is stored (a
launcher whose proxy is down); FAKE_CLAUDE_DIE_IF=<path> does so while that
file exists. With CLAUDE_CONFIG_DIR set (and no FAKE_CLAUDE_STORE), the store
is Claude Code's own layout: <CLAUDE_CONFIG_DIR>/projects/p/<id>.jsonl, with
a user and an assistant line per prompt; "history-probe" replies with the
prompts the conversation holds (a resumed or forked transcript's included).
"hold: PATH" answers once PATH exists, so a test can act while a turn runs;
"tool-hold: PATH" does so inside a running Bash call, after "partial words"
(history-probe's "unresolved" lists tool calls stored with no result).
A prompt ending in "settings-probe" replies with the prompt text as Claude
read it, every `apply_flag_settings` it got, and its argv.
"slow-stop" runs until the interrupt, then echoes the next prompt line it
reads before the stopped turn's result (a Stop Claude Code answers late).
"compact-stop" reports a compaction, ignores its interrupt until the
compaction finishes, then emits the late result (the Stop path must settle
before that result arrives).
"long-step" is one step (a long tool call) that runs until the interrupt, as
Claude Code 2.1 does it: user lines written during the step wait; at the
interrupt the step's result comes first, then each waiting line is echoed and
answered ("read: TEXT") as one more turn (cosmic-gray, 2026-10-20); a
cancel_async_message drops a waiting line by its uuid.
A stop_task control request ends its task killed (task_updated);
FAKE_CLAUDE_STOP_NOTIFY=1 sends the task's task_notification too.
"fg-shell" runs a foreground Bash call until a background_tasks control
request (Ctrl-B) moves it to the background, then ends the turn with the
shell still running; FAKE_CLAUDE_BACKGROUND_ERROR=<text> refuses that
request with the text instead. FAKE_CLAUDE_BACKGROUND_SILENT_MS=<ms> never
answers it: <ms> later Claude Code moves the shell by itself, then ends the
turn (with FAKE_CLAUDE_BACKGROUND_SILENT_END=1 the turn ends at once and the
shell moves <ms> after). FAKE_CLAUDE_BACKGROUND_TWICE waits for two requests,
answers the first `backgrounded: true` and the second false, and moves the
shell before the second answer ("moved") or after it ("answered"); the
shell's tool result then names its output file. FAKE_CLAUDE_FG_WAIT_S (20
by default) is how long the shell waits for a control request before the
turn ends by itself. With FAKE_CLAUDE_FLOOD_GATE=<fifo>, the shell first
says "before-flood", reads the fifo, then streams FAKE_CLAUDE_FLOOD (8000)
text deltas and writes <fifo>.done: output the agent's host buffers while no
daemon reads it; once <fifo>.done exists it floods no more. "flood" is that
backlog alone, then the turn ends.
FAKE_CLAUDE_AUTH=1 looks for a sign-in the way Claude Code does (the
environment, then `env` and `apiKeyHelper` in <Claude home>/settings.json,
then <Claude home>/.credentials.json; the home is CLAUDE_CONFIG_DIR or
~/.claude) and replies with what it found as JSON, or fails the turn with
Claude Code's own "Not logged in · Please run /login".
FAKE_CLAUDE_SKILLS=1 has one skill installed and sends system/init every turn.
FAKE_CLAUDE_INIT (a JSON object) adds its fields to system/init (`mcp_servers`,
`skills`, ...); with FAKE_CLAUDE_CONTROL_LOG set, the subtype of every
control request is appended to that file, one per line.
FAKE_CLAUDE_CONTEXT=1 answers get_context_usage with a /context breakdown
(=error refuses it). FAKE_CLAUDE_LATE_CONTEXT=<path> makes a FAKE_CLAUDE_DIE_IF prompt a
usage limit instead (the process lives on, and answers no more get_context_usage), and leaves a
process outside its own (forked twice, so a kill of its group and descendants misses it) that 1 s
later writes a /context answer and a rate_limit_event, then a `system/late_probe` line, then creates <path>: a replaced
Claude Code's answer that arrives after the failover. FAKE_CLAUDE_MCP_DOWN=<name> fails mcp_reconnect of that
server, and every other reconnect succeeds. "env: NAME"
replies with that environment variable. Any plain prompt
replies with the process's argv (spawn flags such as `--disallowedTools`).
"agent-503" starts a background agent (agent id A503) whose task fails on SR2's 503 after the
turn; Claude Code then runs a turn of its own for the notification ("agent-503-held: PATH"
holds that turn until PATH exists; "agent-400" fails on a bad request instead, "agent-reset" on
a dropped connection). A prompt naming SendMessage to that agent resumes it: its task starts
again under the SendMessage call (with FAKE_CLAUDE_RESUME_FAILS=1 it fails on the 503 again; with
FAKE_CLAUDE_FORGET_AGENTS=1, 64 other agents fail first; with FAKE_CLAUDE_RESUME_COMPLETES=1 it
completes).
"cost-probe" ends its turn the way Claude Code reports spend: the turn's own
token usage, and `total_cost_usd` as the process's running total (0.25 more
per cost-probe turn, from 0 at each start). "cost-restore X" first restores
the running total X, as a resumed Claude Code does; "cost-zero" reports a
zeroed total, as a crashed one's last result can.
"rate-limits-probe" sends two rate_limit_event lines as Claude Code 2.1.307 does
(`utilization` a 0-1 fraction): the session and weekly windows, then the
session window alone, moved. FAKE_CLAUDE_LIMITS=1 sends them on every prompt.
"""
import json
import os
import sys
import threading


SEND_LOCK = threading.Lock()


def send(obj):
    with SEND_LOCK:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()


# Like Claude Code, init reports the mode `--permission-mode` pinned.
MODE = "default"
if "--permission-mode" in sys.argv[:-1]:
    MODE = sys.argv[sys.argv.index("--permission-mode") + 1]

STORE = os.environ.get("FAKE_CLAUDE_STORE")
LAYOUT = None
if not STORE and os.environ.get("CLAUDE_CONFIG_DIR"):
    STORE = os.path.join(os.environ["CLAUDE_CONFIG_DIR"], "projects", "p")
    LAYOUT = ".jsonl"
    os.makedirs(STORE, exist_ok=True)


def stored(sid):
    return os.path.join(STORE, sid + (LAYOUT or ""))
SESSION = "fake-claude-session"
RESUME = None
FLAG_SETTINGS = []
if STORE:
    for flag in ("--session-id", "--resume"):
        if flag in sys.argv[:-1]:
            SESSION = sys.argv[sys.argv.index(flag) + 1]
            if flag == "--resume":
                RESUME = SESSION

SESSION_RULES = []
DESTINATIONS = []
COST = 0.0

# FAKE_CLAUDE_SKILLS=1: Claude Code with one skill installed, as Claude Code
# 2.1.299 reports it: the initialize answer lists every slash command (a
# skill's description ends "(user)"), and system/init, sent at the start of
# every turn, names the skills (`skills`, names without "/").
SKILLS = os.environ.get("FAKE_CLAUDE_SKILLS") == "1"
COMMANDS = [
    {"name": "demo-skill", "description": "A demo skill (user)", "argumentHint": ""},
    {"name": "compact", "description": "Clear conversation history but keep a summary in context",
     "argumentHint": "<optional custom summarization instructions>"},
]


# Claude Code's get_context_usage answer (detail "summary"), with what acpmux leaves out.
# Set once a FAKE_CLAUDE_LATE_CONTEXT prompt hit its usage limit.
LIMITED = False
CONTEXT_USAGE = {
    "categories": [
        {"id": "system_prompt", "name": "System prompt", "tokens": 3000, "color": "promptBorder", "kind": "used"},
        {"name": "MCP tools (deferred)", "tokens": 900, "color": "inactive", "isDeferred": True, "kind": "deferred"},
        {"id": "messages", "name": "Messages", "tokens": 1500, "color": "purple", "kind": "used"},
        {"id": "free_space", "name": "Free space", "tokens": 195500, "color": "promptBorder", "kind": "free"},
    ],
    "totalTokens": 4500, "maxTokens": 200000, "rawMaxTokens": 200000, "percentage": 2,
    "gridRows": [[{"color": "purple", "isFilled": True, "categoryName": "Messages", "tokens": 1500,
                   "percentage": 1, "squareFullness": 1}]],
    "model": "fake",
    "memoryFiles": [{"path": "/repo/CLAUDE.md", "type": "Project", "tokens": 120}],
    "mcpTools": [{"name": "mcp__cmux__a", "serverName": "cmux", "tokens": 40, "isLoaded": True},
                 {"name": "mcp__cmux__b", "serverName": "cmux", "tokens": 60, "isLoaded": False}],
    "agents": [],
    "skills": {"totalSkills": 1, "includedSkills": 1, "tokens": 30,
               "skillFrontmatter": [{"name": "demo-skill", "source": "user", "tokens": 30}]},
    "isAutoCompactEnabled": True,
}


def init():
    line = {"type": "system", "subtype": "init", "session_id": SESSION, "model": "fake",
            "permissionMode": MODE, "tools": [], "mcp_servers": []}
    if SKILLS:
        line["slash_commands"] = [c["name"] for c in COMMANDS]
        line["skills"] = ["demo-skill"]
    line.update(json.loads(os.environ.get("FAKE_CLAUDE_INIT") or "{}"))
    return line


AGENT_503 = "a503a503a503a503"
RESUMES = [0]  # SendMessage resumes so far
AGENT_ERRORS = {
    "agent-503": "API Error: 503 no non-exhausted claude accounts available. This is a server-side issue, "
                 "usually temporary (error type server_error, HTTP 503)",
    "agent-400": "API Error: 400 invalid_request_error: prompt is too long",
    "agent-reset": "API Error: Connection error.",
}


def agent_failure(tool, kind="agent-503"):
    send({"type": "system", "subtype": "task_notification", "task_id": AGENT_503, "tool_use_id": tool,
          "status": "failed", "output_file": "",
          "summary": "Agent terminated early due to an API error: " + AGENT_ERRORS[kind]})


def extra_agents():
    """FAKE_CLAUDE_EXTRA_503=N: "agent-503" starts N more agents, which fail on the 503 too."""
    n = int(os.environ.get("FAKE_CLAUDE_EXTRA_503") or "0")
    return [("toolu_c%d" % i, "c%015d" % i) for i in range(n)]


def agent_failed(said):
    """The end of "agent-503"'s agent, after its turn, and Claude Code's own turn for it."""
    agent_failure("toolu_a503", next(k for k in AGENT_ERRORS if said.startswith(k)))
    for tool, task in extra_agents():
        send({"type": "system", "subtype": "task_notification", "task_id": task, "tool_use_id": tool,
              "status": "failed", "output_file": "", "summary": AGENT_ERRORS["agent-503"]})
    send(init())
    if said.startswith("agent-503-held: "):
        import time
        path = said[len("agent-503-held: "):].split("<", 1)[0].split()[0]
        while not os.path.exists(path):
            time.sleep(0.02)
    send({"type": "result", "subtype": "success", "result": "noted", "num_turns": 1, "duration_api_ms": 1,
          "usage": {"input_tokens": 1, "output_tokens": 1}})


def ask(rid, tool):
    """A Bash permission ask with the rule Claude Code suggests for it."""
    return {"type": "control_request", "request_id": rid, "request": {
        "subtype": "can_use_tool", "tool_name": "Bash", "tool_use_id": tool,
        "input": {"command": "npm test", "description": "Run the tests"},
        "permission_suggestions": [{"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent": "npm test:*"}],
                                    "behavior": "allow", "destination": "localSettings"}]}}


# stdin, read by a thread so a turn can wait for a line with a timeout ("slow-stop").
import queue
import threading
LINES = queue.Queue()
AGAIN = []


def _read_stdin():
    for got in sys.stdin:
        LINES.put(got)
    LINES.put(None)


threading.Thread(target=_read_stdin, daemon=True).start()


def slow_stop():
    """The "slow-stop" turn: one Claude Code is slow to stop. It runs until the
    interrupt, acks it, then waits (up to 12 s) for the next prompt line. That
    line is echoed before this turn's interrupted result, then runs as its own
    turn (the line goes back to the main loop)."""
    import time
    send({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0,
                                             "delta": {"type": "text_delta", "text": "working"}}})
    deadline = None
    while True:
        wait = None if deadline is None else max(0.0, deadline - time.monotonic())
        try:
            got = LINES.get(timeout=wait)
        except queue.Empty:
            break
        if got is None:
            sys.exit(0)
        try:
            msg = json.loads(got)
        except ValueError:
            continue
        if msg.get("type") == "control_request":
            send({"type": "control_response", "response": {"subtype": "success",
                  "request_id": msg.get("request_id"), "response": {}}})
            if (msg.get("request") or {}).get("subtype") == "interrupt" and deadline is None:
                deadline = time.monotonic() + 12
            continue
        if msg.get("type") == "user":
            send({"type": "user", "isReplay": True, "uuid": msg.get("uuid"), "message": msg.get("message")})
            AGAIN.append(got)
            break
    send({"type": "result", "subtype": "error_during_execution", "is_error": True, "result": None,
          "num_turns": 1, "duration_api_ms": 5})


def compact_stop():
    """A compaction that ignores interrupt until its late result."""
    import time
    send({"type": "system", "subtype": "status", "status": "compacting", "session_id": SESSION})
    deadline = time.monotonic() + 0.8
    while time.monotonic() < deadline:
        try:
            got = LINES.get(timeout=0.02)
        except queue.Empty:
            continue
        if got is None:
            sys.exit(0)
        try:
            control = json.loads(got)
        except ValueError:
            continue
        if control.get("type") == "control_request":
            # Claude acknowledges the interrupt but remains in compaction.
            send({"type": "control_response", "response": {"subtype": "success",
                  "request_id": control.get("request_id"), "response": {}}})
    send({"type": "system", "subtype": "status", "status": None, "compact_result": "success",
          "session_id": SESSION})
    send({"type": "system", "subtype": "compact_boundary", "session_id": SESSION,
          "compact_metadata": {"trigger": "manual", "pre_tokens": 27183, "post_tokens": 2047}})
    send({"type": "user", "session_id": SESSION, "isReplay": False, "isSynthetic": True,
          "message": {"role": "user", "content": "Summary: compacted late."}})
    send({"type": "result", "subtype": "success", "result": "", "num_turns": 0,
          "duration_api_ms": 0, "local_command": True, "usage": {"input_tokens": 0, "output_tokens": 0}})


def long_step(prompt):
    """The "long-step" turn (module doc)."""
    send({"type": "user", "isReplay": True, "uuid": prompt.get("uuid"), "message": prompt.get("message")})
    send({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0,
                                             "delta": {"type": "text_delta", "text": "stepping"}}})
    waiting = []
    while True:
        try:
            got = LINES.get(timeout=20)
        except queue.Empty:
            break
        if got is None:
            sys.exit(0)
        msg = json.loads(got)
        if msg.get("type") == "user":
            waiting.append(msg)
        elif (msg.get("request") or {}).get("subtype") == "cancel_async_message":
            # Drops a waiting line by its uuid, as Claude Code does; a no-op once it was read.
            uuid = msg["request"].get("message_uuid")
            kept = [m for m in waiting if m.get("uuid") != uuid]
            send({"type": "control_response", "response": {"subtype": "success",
                  "request_id": msg.get("request_id"), "response": {"cancelled": len(kept) < len(waiting)}}})
            waiting = kept
        elif msg.get("type") == "control_request":
            send({"type": "control_response", "response": {"subtype": "success",
                  "request_id": msg.get("request_id"), "response": {}}})
            if (msg.get("request") or {}).get("subtype") == "interrupt":
                break
    send({"type": "result", "subtype": "error_during_execution", "is_error": True, "result": None,
          "num_turns": 1, "duration_api_ms": 5})
    for msg in waiting:
        said = "".join(b.get("text", "") for b in (msg.get("message") or {}).get("content") or []
                       if isinstance(b, dict))
        send({"type": "user", "isReplay": True, "uuid": msg.get("uuid"), "message": msg.get("message")})
        send({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0,
                                                 "delta": {"type": "text_delta", "text": "read: " + said}}})
        send({"type": "result", "subtype": "success", "result": "read: " + said, "num_turns": 1,
              "duration_api_ms": 5, "usage": {"input_tokens": 1, "output_tokens": 1}})


def flood():
    """FAKE_CLAUDE_FLOOD_GATE's backlog (module doc), once."""
    gate = os.environ.get("FAKE_CLAUDE_FLOOD_GATE")
    if not gate or os.path.exists(gate + ".done"):
        return
    send({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0,
                                             "delta": {"type": "text_delta", "text": "before-flood"}}})
    with open(gate) as f:
        f.read()
    for i in range(int(os.environ.get("FAKE_CLAUDE_FLOOD", "8000"))):
        send({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0,
                                                 "delta": {"type": "text_delta", "text": f"line {i}\n"}}})
    with open(gate + ".done", "w") as f:
        f.write("done")


def fg_shell():
    """The "fg-shell" turn (module doc). Like Claude Code 2.1.305, background_tasks
    answers `backgrounded`: false when its tool_use_id names no foreground task."""
    send({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "toolu_fg", "name": "Bash",
          "input": {"command": "npm run build", "description": "Build"}}]}})
    send({"type": "system", "subtype": "task_started", "task_id": "f1", "tool_use_id": "toolu_fg",
          "description": "Build", "task_type": "local_bash", "is_backgrounded": False})
    flood()

    def answer(rid, moved):
        send({"type": "control_response", "response": {"subtype": "success", "request_id": rid,
              "response": {"backgrounded": moved}}})

    def move():
        send({"type": "system", "subtype": "task_updated", "task_id": "f1", "patch": {"is_backgrounded": True}})

    def done():
        send({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0,
                                                 "delta": {"type": "text_delta", "text": "building in the background"}}})
        send({"type": "result", "subtype": "success", "result": "building in the background", "num_turns": 1,
              "duration_api_ms": 5, "usage": {"input_tokens": 1, "output_tokens": 1}})

    silent = os.environ.get("FAKE_CLAUDE_BACKGROUND_SILENT_MS")
    twice = os.environ.get("FAKE_CLAUDE_BACKGROUND_TWICE")
    asks = []
    stopped = False
    while True:
        try:
            got = LINES.get(timeout=float(os.environ.get("FAKE_CLAUDE_FG_WAIT_S", "20")))
        except queue.Empty:
            break
        if got is None:
            sys.exit(0)
        msg = json.loads(got)
        if msg.get("type") != "control_request":
            continue
        request = msg.get("request") or {}
        rid = msg.get("request_id")
        if request.get("subtype") == "background_tasks":
            refused = os.environ.get("FAKE_CLAUDE_BACKGROUND_ERROR")
            if refused:
                send({"type": "control_response", "response": {"subtype": "error", "request_id": rid,
                      "error": refused}})
                continue
            if silent:
                import time
                if os.environ.get("FAKE_CLAUDE_BACKGROUND_SILENT_END"):
                    done()
                    time.sleep(int(silent) / 1000)
                    move()
                    return
                time.sleep(int(silent) / 1000)
                move()
                send({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "toolu_fg",
                      "content": "Command was moved to the background with ID: f1"}]}})
                break
            if twice:
                asks.append(rid)
                if len(asks) < 2:
                    continue
                answer(asks[0], True)
                if twice == "moved":
                    move()
                answer(asks[1], False)
                if twice != "moved":
                    move()
                output = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR", "/tmp"), "f1.output")
                send({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "toolu_fg",
                      "content": "Command running in background with ID: f1. Output is being written to: "
                                 + output}]}})
                break
            moved = request.get("tool_use_id") in (None, "toolu_fg")
            answer(rid, moved)
            if moved:
                move()
                send({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "toolu_fg",
                      "content": "Command was manually backgrounded by user with ID: f1"}]}})
                break
            continue
        send({"type": "control_response", "response": {"subtype": "success", "request_id": rid, "response": {}}})
        if request.get("subtype") == "interrupt":
            stopped = True
            break
    if stopped:
        send({"type": "result", "subtype": "error_during_execution", "is_error": True, "result": None,
              "num_turns": 1, "duration_api_ms": 5})
        return
    done()


while True:
    line = AGAIN.pop(0) if AGAIN else LINES.get()
    if line is None:
        break
    try:
        msg = json.loads(line)
    except ValueError:
        continue
    kind = msg.get("type")
    # The answer to the late subagent's ask: the subagent says what it was answered.
    if kind == "control_response" and (msg.get("response") or {}).get("request_id") == "late-1":
        behavior = ((msg.get("response") or {}).get("response") or {}).get("behavior", "none")
        send({"type": "stream_event", "parent_tool_use_id": "toolu_lateag", "event": {"type": "content_block_delta",
              "index": 0, "delta": {"type": "text_delta", "text": "late " + behavior}}})
        continue
    # The answer to "answer-shape" (below), checked like Claude Code's permission reply schema:
    # an allow must carry updatedInput (Claude Code runs the tool with it), a deny a message.
    if kind == "control_response" and (msg.get("response") or {}).get("request_id") == "shape-1":
        answer = msg["response"].get("response") or {}
        sent = ask("shape-1", "toolu_shape1")["request"]["input"]
        if answer.get("behavior") == "allow":
            said = "allow input ok" if answer.get("updatedInput") == sent else "allow input bad " + json.dumps(answer)
        elif answer.get("behavior") == "deny":
            ok = isinstance(answer.get("message"), str) and answer["message"] != ""
            said = "deny message ok" if ok else "deny message bad " + json.dumps(answer)
        else:
            said = "invalid " + json.dumps(answer)
        send({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0,
                                                 "delta": {"type": "text_delta", "text": said}}})
        send({"type": "result", "subtype": "success", "result": said, "num_turns": 1, "duration_api_ms": 1,
              "usage": {"input_tokens": 1, "output_tokens": 1}})
        continue
    # The answers to "always-ask" (below): like Claude Code, an allow's updatedPermissions with
    # destination "session" become rules this process keeps, and a covered call is not asked again.
    if kind == "control_response" and (msg.get("response") or {}).get("request_id") in ("ask-1", "ask-2"):
        rid = msg["response"]["request_id"]
        answer = msg["response"].get("response") or {}
        # Like Claude Code: an allow without the input it runs with is refused.
        if answer.get("updatedInput") != ask(rid, "toolu_check")["request"]["input"]:
            DESTINATIONS.append("no-updatedInput")
        updates = answer.get("updatedPermissions") or []
        for update in updates:
            if update.get("destination") == "session" and update.get("behavior") == "allow":
                SESSION_RULES.extend(r.get("ruleContent") for r in update.get("rules") or [])
        DESTINATIONS.extend(u.get("destination") for u in updates)
        if rid == "ask-1" and "npm test:*" not in SESSION_RULES:
            send(ask("ask-2", "toolu_ask2"))
            continue
        said = "asked once" if rid == "ask-1" else "asked twice"
        said += " " + json.dumps(DESTINATIONS)
        send({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0,
                                                 "delta": {"type": "text_delta", "text": said}}})
        send({"type": "result", "subtype": "success", "result": said, "num_turns": 1, "duration_api_ms": 1,
              "usage": {"input_tokens": 1, "output_tokens": 1}})
        continue
    if kind == "control_request":
        request = msg.get("request") or {}
        # Like Claude Code: bypassPermissions only for a process launched with a skip flag.
        if (request.get("subtype") == "set_permission_mode" and request.get("mode") == "bypassPermissions"
                and not {"--allow-dangerously-skip-permissions", "--dangerously-skip-permissions"} & set(sys.argv)):
            send({"type": "control_response", "response": {"subtype": "error", "request_id": msg.get("request_id"),
                  "error": "Cannot set permission mode to bypassPermissions because the session was not launched with --dangerously-skip-permissions"}})
            continue
        if os.environ.get("FAKE_CLAUDE_CONTROL_LOG"):
            with open(os.environ["FAKE_CLAUDE_CONTROL_LOG"], "a") as f:
                f.write(str(request.get("subtype")) + "\n")
        # Like Claude Code, the next init reports the mode the session was switched to.
        if request.get("subtype") == "set_permission_mode" and isinstance(request.get("mode"), str):
            MODE = request["mode"]
        # FAKE_CLAUDE_CONTEXT=1 answers get_context_usage as Claude Code 2.1.305 does (grid and
        # colors included); =error refuses it as a Claude Code that cannot answer. A reconnect of
        # the MCP server FAKE_CLAUDE_MCP_DOWN names fails as Claude Code's does.
        refusal = None
        if request.get("subtype") == "get_context_usage" and os.environ.get("FAKE_CLAUDE_CONTEXT") == "error":
            refusal = "get_context_usage is not supported in this context (onGetContextUsage callback not registered)"
        if (request.get("subtype") == "mcp_reconnect"
                and request.get("serverName") == os.environ.get("FAKE_CLAUDE_MCP_DOWN")):
            refusal = "Server status: failed"
        if refusal:
            send({"type": "control_response", "response": {"subtype": "error", "request_id": msg.get("request_id"),
                  "error": refusal}})
            continue
        # FAKE_CLAUDE_INIT_DELAY_MS: the initialize answer takes that long (a slow start).
        if request.get("subtype") == "initialize" and os.environ.get("FAKE_CLAUDE_INIT_DELAY_MS"):
            import time
            time.sleep(int(os.environ["FAKE_CLAUDE_INIT_DELAY_MS"]) / 1000)
        if request.get("subtype") == "set_permission_mode" and os.environ.get("FAKE_CLAUDE_MODE_DELAY_MS"):
            import time
            time.sleep(int(os.environ["FAKE_CLAUDE_MODE_DELAY_MS"]) / 1000)
        # FAKE_CLAUDE_IDLE_CHILDREN=<file>: the harness starts a worker in its group, one that left
        # it (setsid) and an MCP server (`sleep 3599`), and writes their pids there.
        if request.get("subtype") == "initialize" and os.environ.get("FAKE_CLAUDE_IDLE_CHILDREN"):
            import subprocess
            pids = {name: subprocess.Popen(["sleep", secs], start_new_session=escape, stdin=subprocess.DEVNULL,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).pid
                    for name, secs, escape in (("worker", "3601", False), ("escaped", "3602", True),
                                               ("sidecar", "3599", False))}
            with open(os.environ["FAKE_CLAUDE_IDLE_CHILDREN"], "w") as f:
                f.write(json.dumps(pids))
        answer = {}
        if request.get("subtype") == "initialize" and SKILLS:
            answer = {"commands": COMMANDS}
        if (request.get("subtype") == "get_context_usage" and os.environ.get("FAKE_CLAUDE_CONTEXT") == "1"
                and not LIMITED):
            answer = CONTEXT_USAGE
        send({"type": "control_response", "response": {"subtype": "success", "request_id": msg.get("request_id"), "response": answer}})
        if request.get("subtype") == "apply_flag_settings":
            FLAG_SETTINGS.append(request.get("settings"))
        # Like Claude Code, a stopped task ends killed (task_updated); FAKE_CLAUDE_STOP_NOTIFY=1 also
        # sends its task_notification, as a Claude Code that does not suppress it would.
        if request.get("subtype") == "stop_task":
            task = request.get("task_id")
            send({"type": "system", "subtype": "task_updated", "task_id": task, "patch": {"status": "killed"}})
            if os.environ.get("FAKE_CLAUDE_STOP_NOTIFY") == "1":
                send({"type": "system", "subtype": "task_notification", "task_id": task, "status": "stopped",
                      "output_file": "", "summary": ""})
        # FAKE_CLAUDE_INIT_ON_TURN=1: system/init only when a turn starts, as Claude Code sends it.
        if request.get("subtype") == "initialize" and os.environ.get("FAKE_CLAUDE_INIT_ON_TURN") != "1":
            send(init())
    elif kind == "user" and os.environ.get("FAKE_CLAUDE_AUTH") == "1":
        import subprocess
        home = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
        env = dict(os.environ)
        settings = {}
        try:
            with open(os.path.join(home, "settings.json")) as f:
                settings = json.load(f)
        except (OSError, ValueError):
            pass
        for k, v in (settings.get("env") or {}).items():
            env.setdefault(k, str(v))
        found = [k for k in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN") if env.get(k)]
        if env.get("CLAUDE_CODE_USE_VERTEX") == "1":
            found.append("vertex")
        if env.get("CLAUDE_CODE_USE_BEDROCK") == "1":
            found.append("bedrock")
        helper = settings.get("apiKeyHelper")
        if helper:
            run = subprocess.run(["/bin/sh", "-c", helper], capture_output=True, text=True)
            if run.returncode == 0 and run.stdout.strip():
                found.append("apiKeyHelper")
        if os.path.isfile(os.path.join(home, ".credentials.json")):
            found.append("credentials")
        if found:
            text = json.dumps({"auth": found, "home": home, "base": env.get("ANTHROPIC_BASE_URL"),
                               "awsProfile": env.get("AWS_PROFILE"), "via": env.get("FAKE_CLAUDE_VIA"),
                               "loginOnly": sorted(k for k in ("GITHUB_TOKEN", "GH_TOKEN", "NPM_TOKEN", "MISE_GITHUB_TOKEN",
                                                               "NVM_AUTH_HEADER") if os.environ.get(k)),
                               "miseDataDir": os.environ.get("MISE_DATA_DIR"), "proxy": os.environ.get("HTTPS_PROXY"),
                               "cloudMlRegion": os.environ.get("CLOUD_ML_REGION"),
                               "vertexRegions": sorted(k for k in os.environ if k.startswith("VERTEX_REGION_")),
                               "awsKeys": sorted(k for k in os.environ if k.startswith("AWS_")),
                               "promptCache": {k: v for k, v in os.environ.items()
                                               if k.startswith(("DISABLE_PROMPT_CACHING", "ENABLE_PROMPT_CACHING_1H"))
                                               or k == "FORCE_PROMPT_CACHING_5M"},
                               "turnScoped": {k: os.environ[k] for k in ("SUBROUTER_SESSION_KEY", "CODEX_PROMPT_CACHE_KEY",
                                                                         "OPTCHAT_TURN_SEAL", "OPTCHAT_SUBAGENT", "AI_AGENT")
                                              if k in os.environ},
                               "customHeaders": os.environ.get("ANTHROPIC_CUSTOM_HEADERS")})
            send({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0,
                                                     "delta": {"type": "text_delta", "text": text}}})
            send({"type": "result", "subtype": "success", "result": text, "num_turns": 1, "duration_api_ms": 1,
                  "usage": {"input_tokens": 1, "output_tokens": 1}})
        else:
            said = "Not logged in \u00b7 Please run /login"
            send({"type": "assistant", "error": "authentication_failed", "message": {"model": "<synthetic>",
                  "content": [{"type": "text", "text": said}]}})
            send({"type": "result", "subtype": "success", "is_error": True, "result": said, "num_turns": 1,
                  "duration_api_ms": 0, "usage": {"input_tokens": 0, "output_tokens": 0}})
    elif kind == "user":
        die_if = os.environ.get("FAKE_CLAUDE_DIE_IF")
        late = os.environ.get("FAKE_CLAUDE_LATE_CONTEXT")
        if late and die_if and os.path.exists(die_if):
            LIMITED = True
            first = os.fork()
            if first == 0:
                # Forked twice and in its own session: no longer this process's descendant or in its
                # group by the time the failover kills those.
                os.setsid()
                if os.fork() != 0:
                    os._exit(0)
                import time
                time.sleep(1.0)
                send({"type": "control_response", "response": {"subtype": "success", "request_id": "ctx-late",
                      "response": CONTEXT_USAGE}})
                send({"type": "rate_limit_event", "uuid": "rl-late", "session_id": SESSION, "rate_limit_info": {
                      "status": "rejected", "rateLimitType": "five_hour", "utilization": 1.0, "resetsAt": 1}})
                send({"type": "system", "subtype": "late_probe"})
                open(late, "w").close()
                os._exit(0)
            os.waitpid(first, 0)
            said = "You've hit your usage limit"
            send({"type": "assistant", "error": "rate_limit", "message": {"model": "<synthetic>",
                  "content": [{"type": "text", "text": said}]}})
            send({"type": "result", "subtype": "success", "is_error": True, "result": said, "num_turns": 1,
                  "duration_api_ms": 0, "usage": {"input_tokens": 0, "output_tokens": 0}})
            continue
        if os.environ.get("FAKE_CLAUDE_DIE") == "1" or (die_if and os.path.exists(die_if)):
            sys.stderr.write("proxy down\n")
            sys.stderr.flush()
            sys.exit(1)
        if STORE and RESUME and not os.path.exists(stored(RESUME)):
            sys.stderr.write("No conversation found with session ID: %s\n" % RESUME)
            sys.stderr.flush()
            sys.exit(1)
        if SKILLS or os.environ.get("FAKE_CLAUDE_INIT_ON_TURN") == "1":
            send(init())
        content = (msg.get("message") or {}).get("content") or []
        said = "".join(b.get("text", "") for b in content if isinstance(b, dict))
        # FAKE_CLAUDE_ECHO=1: each prompt line echoed back first, as `--replay-user-messages` does.
        if os.environ.get("FAKE_CLAUDE_ECHO") == "1":
            send({"type": "user", "isReplay": True, "uuid": msg.get("uuid"), "message": msg.get("message")})
        if STORE and LAYOUT:
            # Claude Code stamps each line with its UTC time to the millisecond.
            import datetime
            at = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
            with open(stored(SESSION), "a") as f:
                f.write(json.dumps({"type": "user", "sessionId": SESSION, "timestamp": at, "message": {"role": "user", "content": said}}) + "\n")
                f.write(json.dumps({"type": "assistant", "sessionId": SESSION, "timestamp": at, "message": {"role": "assistant", "content": [{"type": "text", "text": "ok"}]}}) + "\n")
            # The model's reply takes time: a turn's prompt is never stored in
            # the millisecond its turn ends.
            import time
            time.sleep(0.02)
        elif STORE:
            open(stored(SESSION), "w").close()
        # "always-ask": the turn runs `npm test` twice; each run asks unless the first answer's
        # session rule covers it. The turn ends at the last answer (above).
        if said.strip() == "always-ask":
            send(ask("ask-1", "toolu_ask1"))
            continue
        # "answer-shape": one permission ask; the answer is checked (above).
        if said.strip() == "answer-shape":
            send(ask("shape-1", "toolu_shape1"))
            continue
        if said.strip() == "slow-stop":
            slow_stop()
            continue
        if said.strip() == "compact-stop":
            compact_stop()
            continue
        if said.strip() == "long-step":
            long_step(msg)
            continue
        if said.strip() == "fg-shell":
            fg_shell()
            continue
        if said.strip() == "flood":
            flood()
            send({"type": "result", "subtype": "success", "result": "flooded", "num_turns": 1,
                  "duration_api_ms": 5, "usage": {"input_tokens": 1, "output_tokens": 1}})
            continue
        # "/compact" runs Claude Code 2.1.303's compaction: the compacting status, the
        # boundary, the summary as a synthetic user line, the command's stdout, a result.
        if said.strip() == "/compact":
            send({"type": "system", "subtype": "status", "status": "compacting", "session_id": SESSION})
            send({"type": "system", "subtype": "status", "status": None, "compact_result": "success",
                  "session_id": SESSION})
            send({"type": "system", "subtype": "compact_boundary", "session_id": SESSION,
                  "compact_metadata": {"trigger": "manual", "pre_tokens": 27183, "post_tokens": 2047,
                                       **json.loads(os.environ.get("FAKE_CLAUDE_COMPACT_META") or "{}")}})
            send({"type": "user", "session_id": SESSION, "isReplay": False, "isSynthetic": True,
                  "message": {"role": "user", "content": "This session is being continued from a previous "
                              "conversation. Summary: the codeword is PLUM-42."}})
            send({"type": "user", "session_id": SESSION, "isReplay": False,
                  "message": {"role": "user", "content": "<local-command-stdout>Compacted </local-command-stdout>"}})
            send({"type": "result", "subtype": "success", "result": "", "num_turns": 0, "duration_api_ms": 0,
                  "local_command": True, "usage": {"input_tokens": 0, "output_tokens": 0}})
            continue
        # "tool-hold: PATH": the turn says "partial words", then runs a Bash call (stored as a
        # tool_use with no result yet, as Claude Code does) until PATH exists.
        if said.startswith("tool-hold: "):
            import time
            gate = said[len("tool-hold: "):]
            send({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0,
                                                     "delta": {"type": "text_delta", "text": "partial words"}}})
            use = {"type": "tool_use", "id": "toolu_hold", "name": "Bash", "input": {"command": "sleep 600", "description": "Wait"}}
            send({"type": "assistant", "message": {"content": [use]}})
            if STORE and LAYOUT:
                with open(stored(SESSION), "a") as f:
                    f.write(json.dumps({"type": "assistant", "sessionId": SESSION, "timestamp": at,
                                        "message": {"role": "assistant", "content": [use]}}) + "\n")
            while not os.path.exists(gate):
                time.sleep(0.02)
            if STORE and LAYOUT:
                with open(stored(SESSION), "a") as f:
                    f.write(json.dumps({"type": "user", "sessionId": SESSION, "timestamp": at, "message": {"role": "user",
                                        "content": [{"type": "tool_result", "tool_use_id": "toolu_hold", "content": "waited"}]}}) + "\n")
            send({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "toolu_hold", "content": "waited"}]}})
        # "hold: PATH" keeps the turn running until PATH exists.
        if said.startswith("hold: "):
            import time
            while not os.path.exists(said[len("hold: "):]):
                time.sleep(0.02)
        text = json.dumps(sys.argv[1:])
        # "env: NAME" replies with that environment variable, for spawn-time checks.
        if said.startswith("env:"):
            name = said[4:].strip()
            text = f"{name}={os.environ.get(name, '')}"
        if said.startswith("envs:"):
            names = [name.strip() for name in said[5:].split(",") if name.strip()]
            text = json.dumps({name: os.environ.get(name, "") for name in names}, sort_keys=True)
        if said.endswith("settings-probe"):
            text = json.dumps({"said": said, "settings": FLAG_SETTINGS, "argv": sys.argv[1:]})
        if said.strip() == "history-probe" and STORE and LAYOUT:
            with open(stored(SESSION)) as f:
                records = [json.loads(line) for line in f if line.strip()]
            blocks = [b for r in records for b in (r["message"]["content"] if isinstance(r["message"]["content"], list) else [])
                      if isinstance(b, dict)]
            used = [b["id"] for b in blocks if b.get("type") == "tool_use"]
            answered = {b["tool_use_id"] for b in blocks if b.get("type") == "tool_result"}
            text = json.dumps({"prompts": [r["message"]["content"] for r in records
                                           if r.get("type") == "user" and isinstance(r["message"]["content"], str)
                                           and r["message"]["content"] != "history-probe"],
                               "sessions": sorted({r["sessionId"] for r in records}),
                               # Tool calls the conversation holds with no result: Claude's API refuses those.
                               "unresolved": [i for i in used if i not in answered]})
        documents = [b for b in content if isinstance(b, dict) and b.get("type") == "document"]
        if said.strip() == "document-probe":
            text = json.dumps({
                "documents": [
                    {
                        "type": b.get("type"),
                        "title": b.get("title"),
                        "media_type": (b.get("source") or {}).get("media_type"),
                        "data": (b.get("source") or {}).get("data"),
                    }
                    for b in documents
                ]
            }, sort_keys=True)
        # "resource-probe": the text blocks this prompt arrived as, as JSON.
        if said.startswith("resource-probe"):
            text = json.dumps({"texts": [b.get("text") for b in content
                                         if isinstance(b, dict) and b.get("type") == "text"]})
        # "sandbox-probe OUTSIDE PORT": what this process may do, as JSON:
        # write a file at OUTSIDE, connect to 127.0.0.1:PORT, write in its cwd.
        # "keychain-probe": whether this process can retrieve a synthetic
        # generic-password item from the test's temporary keychain.
        if said.strip() == "keychain-probe":
            import subprocess
            rc = subprocess.run(
                [
                    "/usr/bin/security",
                    "find-generic-password",
                    "-a", "synthetic-account",
                    "-s", "synthetic-service",
                    "-w", os.environ["FAKE_KEYCHAIN_PATH"],
                ],
                capture_output=True,
            ).returncode
            text = json.dumps({"keychain": "allowed" if rc == 0 else "denied"})
        if said.startswith("sandbox-probe "):
            import os
            import socket
            # The path may hold spaces (a home under Application Support): the port is the last word.
            outside, port = said[len("sandbox-probe "):].rstrip().rsplit(" ", 1)
            port = int(port)
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
        # G2: exercise the actual child boundary, including its HTTP proxy.
        if said.startswith("linux-sandbox-probe "):
            import socket
            import urllib.parse
            outside, port = said[len("linux-sandbox-probe "):].rstrip().rsplit(" ", 1)
            result = {}
            for key, path in [("outside", outside), ("git", ".git/hooks/x"),
                              ("claude", "CLAUDE.md"), ("cwd", "ok")]:
                try:
                    with open(path, "w") as f:
                        f.write("x")
                    result[key] = "allowed"
                except OSError:
                    result[key] = "denied"
            try:
                socket.create_connection(("127.0.0.1", int(port)), timeout=2).close()
                result["loopback"] = "allowed"
            except OSError:
                result["loopback"] = "denied"
            proxy = urllib.parse.urlsplit(os.environ.get("HTTPS_PROXY", ""))
            result["proxy"] = "missing"
            if proxy.hostname and proxy.port:
                with socket.create_connection((proxy.hostname, proxy.port), timeout=3) as conn:
                    conn.sendall(b"CONNECT 127.0.0.1:22 HTTP/1.1\r\nHost: 127.0.0.1:22\r\n\r\n")
                    result["proxy"] = conn.recv(1024).split(b"\r\n")[0].decode()
            text = json.dumps(result)
        # "usage-probe": the token usage Claude Code streams and the context window its result
        # reports for each model the turn used (the chat's own and a smaller subagent model).
        usage = said.strip() in ("usage-probe", "switched-probe", "compact-probe")
        # "switched-probe": the chat moved to another model mid-session: the main loop's messages
        # name it, and the cumulative modelUsage still holds the earlier, larger model.
        if said.strip() == "switched-probe":
            send({"type": "stream_event", "event": {"type": "message_start", "message": {"model": "claude-sonnet-x"}}})
        if usage:
            send({"type": "stream_event", "event": {"type": "message_delta", "usage": {
                "input_tokens": 1200, "cache_read_input_tokens": 3000, "cache_creation_input_tokens": 0,
                "output_tokens": 300}}})
        # "compact-probe": /compact ran after the turn's message: its context is smaller now.
        if said.strip() == "compact-probe":
            send({"type": "system", "subtype": "compact_boundary",
                  "compact_metadata": {"trigger": "manual", "pre_tokens": 4500}})
        # "rate-limits-probe": the account's plan usage limits, then a later event for one window.
        if said.strip() == "rate-limits-probe" or os.environ.get("FAKE_CLAUDE_LIMITS") == "1":
            send({"type": "rate_limit_event", "uuid": "rl-1", "session_id": SESSION, "rate_limit_info": {
                "status": "allowed", "isUsingOverage": False, "unifiedWindows": {
                    "five_hour": {"utilization": 0.12, "resetsAt": 1790000000},
                    "seven_day": {"utilization": 0.4, "resetsAt": 1790500000}}}})
            send({"type": "rate_limit_event", "uuid": "rl-2", "session_id": SESSION, "rate_limit_info": {
                "status": "allowed_warning", "rateLimitType": "five_hour", "utilization": 0.9,
                "resetsAt": 1790000000}})
        # "bg-probe": the turn starts two shells in the background (Bash run_in_background); Claude
        # Code reports each as a local_bash task, and one is killed while the other finishes.
        if said.strip() == "bg-probe":
            for tid, tool, command, status in (("b1", "toolu_bg1", "npm run dev", "killed"),
                                                ("b2", "toolu_bg2", "cargo test", "completed")):
                send({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": tool, "name": "Bash",
                      "input": {"command": command, "run_in_background": True, "description": "Run " + command}}]}})
                send({"type": "system", "subtype": "task_started", "task_id": tid, "tool_use_id": tool,
                      "description": "Run " + command, "task_type": "local_bash"})
            send({"type": "system", "subtype": "task_notification", "task_id": "b1", "tool_use_id": "toolu_bg1",
                  "status": "killed", "reason": "Stopped by the agent", "output_file": "", "summary": ""})
            send({"type": "system", "subtype": "task_notification", "task_id": "b2", "tool_use_id": "toolu_bg2",
                  "status": "completed", "output_file": "", "summary": "Tests passed"})
        # "agent-probe": the turn starts an Explore subagent (the Agent tool): its own read and
        # reply carry its tool_use id as parent_tool_use_id, then the tool's result ends it.
        if said.strip() == "agent-probe":
            send({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "toolu_ag1", "name": "Agent",
                  "input": {"description": "Find the tests", "prompt": "List the test files", "subagent_type": "Explore", "model": "haiku", "effort": "high"}}]}})
            send({"type": "assistant", "parent_tool_use_id": "toolu_ag1", "message": {"content": [
                  {"type": "tool_use", "id": "toolu_ag2", "name": "Read", "input": {"file_path": "/a/tests.rs"}}]}})
            send({"type": "user", "parent_tool_use_id": "toolu_ag1", "message": {"content": [
                  {"type": "tool_result", "tool_use_id": "toolu_ag2", "content": "fn t() {}"}]}})
            send({"type": "assistant", "parent_tool_use_id": "toolu_ag1", "message": {"id": "child-final", "content": [
                  {"type": "text", "text": "Found one test file"}]}})
            send({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "toolu_ag1", "content": "one test file"}]}})
        if said.strip().startswith(tuple(AGENT_ERRORS)):
            send({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "toolu_a503", "name": "Agent",
                  "input": {"description": "Push relay", "prompt": "Push the relay", "run_in_background": True}}]}})
            send({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "toolu_a503",
                  "content": "Async agent launched"}]}})
            send({"type": "system", "subtype": "task_started", "task_id": AGENT_503, "tool_use_id": "toolu_a503",
                  "description": "Push relay", "task_type": "local_agent", "is_backgrounded": True})
            for i, (tool, task) in enumerate(extra_agents()):
                send({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": tool, "name": "Agent",
                      "input": {"description": "Extra %d" % i, "prompt": "Extra", "run_in_background": True}}]}})
                send({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": tool,
                      "content": "Async agent launched"}]}})
                send({"type": "system", "subtype": "task_started", "task_id": task, "tool_use_id": tool,
                      "description": "Extra %d" % i, "task_type": "local_agent", "is_backgrounded": True})
        if 'SendMessage to "%s"' % AGENT_503 in said:
            send({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "toolu_send", "name": "SendMessage",
                  "input": {"to": AGENT_503, "message": "Continue where you stopped."}}]}})
            # FAKE_CLAUDE_FORGET_AGENTS=1: 64 other agents fail first (a bad request each), so the
            # translator forgot A503 by its resume.
            RESUMES[0] += 1
            for i in range(64 if os.environ.get("FAKE_CLAUDE_FORGET_AGENTS") == "1" else 0):
                tool, task = "toolu_other%d_%d" % (RESUMES[0], i), "b%02d%013d" % (RESUMES[0], i)
                send({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": tool, "name": "Agent",
                      "input": {"description": "Other %d" % i, "prompt": "Other", "run_in_background": True}}]}})
                send({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": tool,
                      "content": "Async agent launched"}]}})
                send({"type": "system", "subtype": "task_started", "task_id": task, "tool_use_id": tool,
                      "description": "Other %d" % i, "task_type": "local_agent", "is_backgrounded": True})
                send({"type": "system", "subtype": "task_notification", "task_id": task, "tool_use_id": tool,
                      "status": "failed", "output_file": "", "summary": AGENT_ERRORS["agent-400"]})
            send({"type": "system", "subtype": "task_started", "task_id": AGENT_503, "tool_use_id": "toolu_send",
                  "description": "Push relay", "task_type": "local_agent", "is_backgrounded": True})
            send({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "toolu_send",
                  "content": '{"success":true,"resumedAgentId":"%s"}' % AGENT_503}]}})
            if os.environ.get("FAKE_CLAUDE_RESUME_FAILS") == "1":
                agent_failure("toolu_send")
            if os.environ.get("FAKE_CLAUDE_RESUME_COMPLETES") == "1":
                send({"type": "system", "subtype": "task_notification", "task_id": AGENT_503,
                      "tool_use_id": "toolu_send", "status": "completed", "output_file": "",
                      "summary": "Pushed the relay"})
        # "late-agent-ask": a background subagent (Agent with run_in_background) that is still
        # running when the turn ends, and asks for permission after it (cx-jo8yo, below).
        if said.strip() == "late-agent-ask":
            send({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "toolu_lateag", "name": "Agent",
                  "input": {"description": "Late writer", "prompt": "Write late.txt", "run_in_background": True}}]}})
            send({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "toolu_lateag",
                  "content": "Async agent launched"}]}})
        # "bg-agent-gate: FIFO": a background subagent still running when the turn ends; it ends
        # with its task_notification once the test writes FIFO, while the chat is idle
        # (manaflow-ai/cmux#25230: the chat works until it does). "bg-agent-fail": a background
        # subagent whose launch fails, so it never runs.
        if said.strip().startswith("bg-agent-gate:") or said.strip() == "bg-agent-fail":
            send({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "toolu_bgag", "name": "Agent",
                  "input": {"description": "Long review", "prompt": "Review it", "run_in_background": True}}]}})
            failed = said.strip() == "bg-agent-fail"
            send({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "toolu_bgag",
                  "is_error": failed, "content": "Agent type not found" if failed else "Async agent launched"}]}})
        # "fg-probe": a foreground Bash is a local_bash task too (not backgrounded), and a
        # notification can name a call acpmux never saw run in the background.
        if said.strip() == "fg-probe":
            send({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "toolu_fg", "name": "Bash",
                  "input": {"command": "ls", "description": "List files"}}]}})
            send({"type": "system", "subtype": "task_started", "task_id": "f1", "tool_use_id": "toolu_fg",
                  "description": "List files", "task_type": "local_bash", "is_backgrounded": False})
            for tid, tool in (("f1", "toolu_fg"), ("x1", "toolu_unknown")):
                send({"type": "system", "subtype": "task_notification", "task_id": tid, "tool_use_id": tool,
                      "status": "completed", "output_file": "", "summary": ""})
        # "bg-left": a shell starts in the background and is still running when the turn ends.
        if said.strip() == "bg-left":
            send({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "toolu_left", "name": "Bash",
                  "input": {"command": "npm run dev", "run_in_background": True}}]}})
            # A launch that failed (denied, or a bad input) never ran, so nothing stops at exit.
            send({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "toolu_err", "name": "Bash",
                  "input": {"command": "rm -rf build", "run_in_background": True}}]}})
            send({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "toolu_err",
                  "is_error": True, "content": "Permission denied"}]}})
        # "bg-running": a dev server starts in the background and is still running when the turn ends.
        if said.strip() == "bg-running":
            send({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "toolu_run", "name": "Bash",
                  "input": {"command": "npm run dev", "run_in_background": True}}]}})
            send({"type": "system", "subtype": "task_started", "task_id": "r1", "tool_use_id": "toolu_run",
                  "description": "npm run dev", "task_type": "local_bash"})
        # "bg-done-twice": a background shell that finishes is reported twice: its task_updated
        # says completed, then its task_notification carries the summary.
        if said.strip() == "bg-done-twice":
            send({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "toolu_dn", "name": "Bash",
                  "input": {"command": "cargo test", "run_in_background": True}}]}})
            send({"type": "system", "subtype": "task_started", "task_id": "d1", "tool_use_id": "toolu_dn",
                  "description": "cargo test", "task_type": "local_bash"})
            send({"type": "system", "subtype": "task_updated", "task_id": "d1", "patch": {"status": "completed"}})
            send({"type": "system", "subtype": "task_notification", "task_id": "d1", "tool_use_id": "toolu_dn",
                  "status": "completed", "output_file": "", "summary": "Tests passed"})
        # "agent-bg-running": a background subagent starts a dev server in the background, which
        # is still running when the turn ends.
        if said.strip() == "agent-bg-running":
            send({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "toolu_agbg", "name": "Agent",
                  "input": {"description": "Serve", "prompt": "Start the dev server", "run_in_background": True}}]}})
            send({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "toolu_agbg",
                  "content": "Async agent launched"}]}})
            send({"type": "assistant", "parent_tool_use_id": "toolu_agbg", "message": {"content": [
                  {"type": "tool_use", "id": "toolu_agrun", "name": "Bash",
                   "input": {"command": "npm run dev", "run_in_background": True}}]}})
            send({"type": "system", "subtype": "task_started", "task_id": "r2", "tool_use_id": "toolu_agrun",
                  "description": "npm run dev", "task_type": "local_bash"})
        # "limits-probe": the turn says the limit knobs this Claude Code started with.
        if said.strip() == "limits-probe":
            text = json.dumps({k: os.environ.get(k) for k in (
                "CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS", "CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION",
                "CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH", "CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY",
                "BASH_MAX_TIMEOUT_MS", "BASH_DEFAULT_TIMEOUT_MS")}, sort_keys=True)
        # "bg-moved": a foreground shell moved to the background while it ran (a task_updated
        # patch), then ended; its notification names only the task.
        if said.strip() == "bg-moved":
            send({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "toolu_mv", "name": "Bash",
                  "input": {"command": "npm run build", "description": "Build"}}]}})
            send({"type": "system", "subtype": "task_started", "task_id": "m1", "tool_use_id": "toolu_mv",
                  "description": "Build", "task_type": "local_bash", "is_backgrounded": False})
            send({"type": "system", "subtype": "task_updated", "task_id": "m1", "patch": {"is_backgrounded": True}})
            send({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "toolu_mv",
                  "content": "Command moved to the background with ID: m1"}]}})
            send({"type": "system", "subtype": "task_notification", "task_id": "m1", "status": "completed",
                  "output_file": "", "summary": "Build finished"})
        # "bg-output: PATH": a background shell whose output Claude Code writes to PATH (its
        # output_file), unless PATH is already there (a test's FIFO); "bg-output-end: PATH"
        # writes its last line there and ends it.
        if said.startswith("bg-output: "):
            path = said[len("bg-output: "):]
            if not os.path.exists(path):
                with open(path, "w") as f:
                    f.write("".join("line %d\n" % i for i in range(100)))
            send({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "toolu_out", "name": "Bash",
                  "input": {"command": "npm run dev", "run_in_background": True}}]}})
            send({"type": "system", "subtype": "task_started", "task_id": "o1", "tool_use_id": "toolu_out",
                  "description": "npm run dev", "task_type": "local_bash", "output_file": path})
        if said.startswith("bg-output-end: "):
            path = said[len("bg-output-end: "):]
            with open(path, "a") as f:
                f.write("done\n")
            send({"type": "system", "subtype": "task_notification", "task_id": "o1", "tool_use_id": "toolu_out",
                  "status": "completed", "output_file": path, "summary": "Server stopped"})
        # "timing-probe": two model requests, each a message_start and three text deltas (the
        # reply's own delta below makes the second request's fourth), with a subagent's
        # message_start and delta between each start and its first delta.
        if said.strip() == "timing-probe":
            for req in ("msg_t1", "msg_t2"):
                send({"type": "stream_event", "event": {"type": "message_start",
                      "message": {"id": req, "model": "fake"}}})
                # A background subagent streams between the request's start and its first token.
                send({"type": "stream_event", "parent_tool_use_id": "toolu_timing_bg", "event": {
                      "type": "message_start", "message": {"id": req + "_sub", "model": "fake"}}})
                send({"type": "stream_event", "parent_tool_use_id": "toolu_timing_bg", "event": {
                      "type": "content_block_delta", "index": 0,
                      "delta": {"type": "text_delta", "text": req + " subagent "}}})
                for word in ("one ", "two ", "three "):
                    send({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0,
                          "delta": {"type": "text_delta", "text": req + " " + word}}})
        # "todo-probe": the turn writes its todo list with Claude Code's TodoWrite tool.
        if said.strip() == "todo-probe":
            send({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "toolu_todo", "name": "TodoWrite",
                  "input": {"todos": [
                      {"content": "Add retry", "status": "completed", "activeForm": "Adding retry"},
                      {"content": "Cover it", "status": "in_progress", "activeForm": "Covering it"},
                      {"content": "Update docs", "status": "pending", "activeForm": "Updating docs"}]}}]}})
        send({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0,
                                                 "delta": {"type": "text_delta", "text": text}}})
        result = {"type": "result", "subtype": "success", "result": text, "num_turns": 1, "duration_api_ms": 1,
                  "usage": {"input_tokens": 1, "output_tokens": 1}}
        if said.strip() in ("usage-probe", "compact-probe"):
            result["modelUsage"] = {"claude-haiku": {"inputTokens": 50, "contextWindow": 100000},
                                    "fake": {"inputTokens": 1200, "contextWindow": 200000}}
        # "cost-restore X": a process that restored its running total X first.
        if said.strip().startswith("cost-restore "):
            COST = float(said.split()[1])
            said = "cost-probe"
        if said.strip() == "cost-zero":
            result["total_cost_usd"] = 0.0
            result["usage"] = {"input_tokens": 100, "output_tokens": 20}
        if said.strip() == "cost-probe":
            COST += 0.25
            result["total_cost_usd"] = COST
            result["usage"] = {"input_tokens": 100, "output_tokens": 20,
                               "cache_read_input_tokens": 300, "cache_creation_input_tokens": 40}
        if said.strip() == "switched-probe":
            result["modelUsage"] = {"claude-opus-1m": {"inputTokens": 90000, "contextWindow": 1000000},
                                    "claude-sonnet-x": {"inputTokens": 1200, "contextWindow": 200000}}
        send(result)
        if said.strip().startswith(tuple(AGENT_ERRORS)):
            agent_failed(said.strip())
        if said.strip().startswith("bg-agent-gate:"):
            gate = said.strip()[len("bg-agent-gate:"):].strip()

            def end_background_agent():
                with open(gate) as g:
                    g.read()
                send({"type": "system", "subtype": "task_notification", "task_id": "bgag1",
                      "tool_use_id": "toolu_bgag", "status": "completed", "output_file": "", "summary": "Reviewed"})

            threading.Thread(target=end_background_agent, daemon=True).start()
        if said.strip() == "late-agent-ask":
            send({"type": "control_request", "request_id": "late-1", "request": {"subtype": "can_use_tool",
                  "tool_name": "Write", "tool_use_id": "toolu_late_w", "input": {"file_path": "late.txt", "content": "x"}}})
