#!/usr/bin/env python3
"""A tiny ACP agent for tests.

Behaviour per prompt text:
  "ask: <x>"   -> requests permission, then replies with the chosen optionId
  "plan-ask: <plan>" -> a plan approval as Claude Code's ExitPlanMode asks it, then as "ask:";
                 an allow carrying an edited plan (`_meta.updatedInput.plan`) says "building: <plan>"
  "plan-ask-on: <plan>" -> the same; a rejected plan plans on until session/cancel
  "xai-question: <q>" / "xai-plan: <p>" -> Grok's x.ai ask / exit-plan requests
  "cursor-question: <q>" / "cursor-plan: <p>" -> Cursor's ask / create-plan requests
  "slow"       -> streams three chunks with delays, honours session/cancel
  "ticking:N:MS" -> a word every MS ms, N times; honours session/cancel
  "until-cancel" -> streams "running", then waits for session/cancel
  "until-cancel-then-exit" -> "until-cancel", then the agent exits between turns
  "deaf-to-cancel" -> streams "running", ignores session/cancel, answers end_turn after 20 s
  "cancel-ends-turn" -> streams "running", then answers session/cancel with end_turn, not cancelled
  "cancel-errors" -> streams "running", then answers session/cancel with an error
  "works-through-cancel" -> a tool call every 100 ms, titled "step N pid P", through every
                 session/cancel; answers end_turn after 60 s
  "stuck-loop" -> three identical failed cargo test calls, then a ready marker while the
                 turn stays open for at most 90 s; cancel ends it early, otherwise one
                 successful call clears the episode before end_turn
  "works-through-cancel-beside-background" -> the same after starting background subagent bg-1
  "answer-then-exit" -> answers, then the agent exits between turns
  "delta-chunks: N L" -> N reply chunks of exactly L bytes each, then end_turn
  "gate: <p>"  -> streams before-gate, waits for a write to FIFO <p>, then after-gate
  "goal: <objective>" -> a Codex goal as session_info_update _meta.goal (running 32 min), then a short reply
  "/goal pause|resume|clear|<text>" -> that goal paused, running again, gone, or set to <text>
  "work-gate: <p>" -> a plan step in progress and a running tool call, then as "gate:"
  "plan-json: <entries>" -> a plan update with the JSON list of entries, then "planned" and end_turn
  "wrap-up: <json>" -> a reply, then a completed mcp__acpmux__wrap_up call with <json> as its input
  "steps"      -> a finished tool call every 150 ms until session/cancel (see FAKE_STEPS_IN)
  "work-for: S" -> a finished tool call each second for S seconds of wall clock, titled "tick N at
                 <unix ms>", then "worked S s" and end_turn; a session/cancel ends it cancelled
  "tool-then-cancel: <p>" -> a running tool call tc-1 until a write to FIFO <p>, its result, then
                 as "until-cancel" (a turn a move may stop between its tool calls)
  "elapsed-tour:" -> a finished shell, a shell gone on in the background, then a shell
                 held running in the foreground (until session/cancel, else 300 s)
  image blocks -> the echo ends with " image:<sha256 of its bytes>" for each
  anything     -> echoes the text as one agent_message_chunk

FAKE_CODEX_STEER=1: steering as codex-acp 1.10.0 does it. The agent
advertises steering; a prompt while a turn runs joins that turn, and when
the turn ends only the last prompt gets an answer (the earlier ones never).
Its "slow-stop" turn runs until session/cancel and takes 5 s more to stop.

FAKE_CLAUDE_STEER=1: steering as Claude Code (claude-stdio) does it. The agent
advertises steering; a prompt while a turn runs is read into that turn and
answered at once with stopReason "steered"; the turn runs on and its own
prompt is answered when it ends. With FAKE_STEER_STEP=<fifo> a steer is
answered only once the test writes to that FIFO (the agent's next tool step).
With FAKE_STEER_NO_TURN_AT_END=1 a steer is never read: the turn ends first, and the
steer is answered "steer: no turn is running" after the turn's own answer, as
Claude Code's translator answers a message it held for a tool step that never came.

FAKE_REVIEW_CMUX=<cmux-tui binary> with FAKE_REVIEW_SOCKET=<daemon socket>: a prompt that
starts "Code review of " (a threaded diff.comments.send) is answered in each of its threads,
as a real agent follows the prompt: for every "## Thread <id>:" section that does not say it
"needs no answer", the agent runs `<bin> git comments reply <id> --root <root> --text
"answered <id>"` against that socket, then echoes the prompt as any other.

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

FAKE_CLAUDE_STORE=1: a session file where Claude Code keeps its own, with the
prompts answered as without it: each session is
~/.claude/projects/<cwd, every character but a letter or digit a dash>/<uuid>.jsonl,
a first line, then one line per prompt. session/load of an id with no file in
its cwd's project folder fails, as a resume of a conversation Claude does not
have.

FAKE_FORK_DEFAULTS=1: session/fork answers with the harness's default model and effort
(configOptions), not the forked session's, as Codex does.

FAKE_FORK_ERROR=1: the agent offers session/fork but answers it with a bare "Internal
error", as Claude's ACP adapter does for a chat with no turn.

FAKE_FORK_SILENT=1: the agent never answers session/fork, and goes on answering everything else.

FAKE_FORK_DELAY_MS=<ms>: the agent answers session/fork that long after it read it, and goes on
answering everything else meanwhile.

FAKE_FORK_REPLAY=1: before it answers session/fork, the agent replays the forked conversation as
session/updates under the NEW session's id (a prompt, a thought, a tool call, a reply, its
commands), as OpenCode 1.19's forkSession does (its replayMessages).

FAKE_NO_FORK=1: the agent does not advertise sessionCapabilities.fork and answers
session/fork with a bare "Internal error", as Kimi does.

FAKE_UNTIL_CANCEL_IN=<text>: a prompt containing <text> is an "until-cancel" one.

FAKE_STEPS_IN=<text>: a prompt containing <text> is a "steps" one. FAKE_STEP_LOG=<path>: each
finished step's tool call id, one per line, written after its result is sent. FAKE_STEPS_END=<path>:
once that file exists a "steps" turn ends by itself.

FAKE_ASK_MODE=1: the sample harness of `cmux harness add sample` (cx-00p) as a remote
start takes it: its one mode is "ask" (an acpmux config.json `webAskingModes` entry
{"sample": ["ask"]} lists it), and a prompt naming "hostname" runs `hostname` as a tool
call through the ACP permission flow: announced, asked, run only after an allow.

CPU class (macOS, tests/cpu_class.rs; `ps -o pri=` is 4 at background class):
FAKE_CLASS_LOG=<path>: on session/new, append {"pid", "pri", "nice"} (its own, as it starts) to <path>.
"class-probe: <path>": start `sleep 120` (a tool its turn runs) and write {"sleeper": pid, "diskio": n}
to <path>: n is its own process's disk I/O policy (`getiopolicy_np`, macOS; the tool inherits it),
None elsewhere.
"class-wait: <path>": the same, then nothing until the test writes the FIFO <path>.gate; then its
first token, and the turn ends at the next write.
FAKE_BG_ONCE=<path>: the first agent to get `initialize` (<path> does not exist yet) creates <path>,
has another process put it in background class (an outside cause, not its own call), answers that
`initialize` with an error and stays alive, as a harness that fails its start at background class.

Auto mode (tests/auto_session.rs):
"auto-shell: <path>": a running tool call whose shell, in a session of its own, appends a line to
<path> every 50 ms (its pid in <path>.pid); the turn waits for session/cancel (bounded at 120 s).
"auto-run: <path>" (tests/auto_journey.rs): the same, with a shell that appends "start" to <path>,
works for ten minutes, then appends "end".

Start under load (tests/start_under_load_bench.rs):
FAKE_BOOT_CPU_MS=<ms>: before it reads its first line, the agent spends that much CPU time (not
wall time), as a real harness spends CPU loading its code: on a busy machine a harness that gets
little of the CPU takes much longer to start.

Exactly-once across restarts (tests/durable_agents/restart_exactly_once.rs):
FAKE_WIRE_LOG=<path>: append one JSON line {"pid", "id", "method", "session"} for every line the
agent reads (a response has "method": null), so a test counts what reached the agent itself.

A rate-limit storm (tests/hub_integration/auto_resume_429_storm.rs):
FAKE_RATE_LIMIT_FILE=<path>: while <path> exists, every prompt fails with the account's 429, naming
no reset, as a model endpoint that refuses every request on a spent account limit.
FAKE_UPSTREAM_URL=<url>: every prompt is a model call to a fake Anthropic upstream at <url> (the
529-storm chaos test's, tests/hub_integration/auto_resume_529_chaos.rs); see `upstream_turn`.
FAKE_CAPACITY_FILE=<path>: while <path> exists, every prompt, `/compact` too, fails with a capacity
error, in turn the provider's 529 overloaded, the SR2 gateway's 503 "no non-exhausted accounts"
and the worker gateway's 502 "at its call limit": an overload storm. Each prompt's text is appended
to <path>.seen, one JSON string per line, so a test sees what reached the model.
FAKE_QUIT_429_FILE=<path>: while <path> exists, an agent started on a chat's conversation
(session/load) answers the load, then, idle, prints <path>'s line on stderr and exits 0 on its own,
as a CLI does that quits on its account's 429 between turns (`quit-after:` once, this at every start).

An agent that starts itself again (tests/durable_agents/credential_restart.rs):
FAKE_REEXEC_WITHOUT=<A,B>: before it reads a line, the process execs itself again without the
variables A and B, so /proc/PID/environ, which shows the env of its last exec, has neither. It
works the same afterward, as a harness launched through a wrapper that cleans its env does.
"""
import base64
import hashlib
import json
import sys
import os
import threading
import time

if os.environ.get("FAKE_REEXEC_WITHOUT"):
    _drop = set(os.environ["FAKE_REEXEC_WITHOUT"].split(",")) | {"FAKE_REEXEC_WITHOUT"}
    os.execve(sys.executable, [sys.executable] + sys.argv,
              {k: v for k, v in os.environ.items() if k not in _drop})

lock = threading.Lock()
# FAKE_CAPACITY_FILE: how many prompts the storm refused, to rotate its errors.
capacity_storm = [0]
cancelled = set()
failed_once = set()
# "goal:" and "/goal": each session's goal as Codex reports it (session_info_update _meta.goal).
goals = {}
cap_failures = {}
capacity_inner_loops = set()
failed_digest = set()
# Sessions whose "net-down" prompt cut the connection for good (auto-resume tests).
net_down = set()
# "rate-fail-n:N:ERROR" fails the session's turns with ERROR until N of them failed, whatever
# their text (acpmux's continuations included); the next one runs.
rate_failures = {}
# Sessions whose "net-flaky" prompt left one more prompt to fail (auto-resume tests).
net_flaky = set()
next_id = 100
pending = {}
# Sessions this process created or finished loading.
known = set()


LAST_MCP_SERVERS = None
# The additionalDirectories of the last session/new, load or fork ("dirs" replies with them).
LAST_DIRS = None
RUNNING_MCP = []
# Whether the client asked for native subagent sessions the way codex-acp 1.10.0
# reads it: the JetBrains AIR capability in clientCapabilities._meta (its ACP
# schema strips the draft `subagents` field, so that one does not count).
NATIVE_SUBAGENTS = False
SESSION_PREFIX = os.environ.get("FAKE_SESSION_PREFIX", "fake-")


def boot_work():
    """FAKE_BOOT_CPU_MS: this process's CPU time, spent before it reads anything."""
    budget = int(os.environ.get("FAKE_BOOT_CPU_MS", "0")) / 1000
    until = time.process_time() + budget
    while time.process_time() < until:
        pass


boot_work()


def send(obj):
    send_all([obj])


# FAKE_USAGE=<json>: every prompt answer that ends a turn carries it as its ACP `usage` (a
# harness's token counts and cost). FAKE_SENT_LOG=<path>: append the wall clock (Unix
# microseconds) each such answer is written at, one per line (the cost-per-task bench).
FAKE_USAGE = json.loads(os.environ["FAKE_USAGE"]) if os.environ.get("FAKE_USAGE") else None
FAKE_SENT_LOG = os.environ.get("FAKE_SENT_LOG")
# FAKE_USAGE_UPDATES=<json list of USD>: before a prompt's answer that ends its turn, one ACP
# `usage_update` per entry, each carrying the session's cumulative `cost` (the turn's own spend so
# far, the entry, on top of what earlier turns spent): the spend burn-rate warnings' bench
# (hub/spend_burn.rs).
FAKE_USAGE_UPDATES = json.loads(os.environ["FAKE_USAGE_UPDATES"]) if os.environ.get("FAKE_USAGE_UPDATES") else None
# FAKE_USAGE_UPDATES: each prompt request's session, and each session's cumulative cost.
prompt_sessions = {}
session_spent = {}


def usage_updates(objs):
    """`objs` with FAKE_USAGE_UPDATES' usage updates before each prompt answer that ends a turn."""
    out = []
    for o in objs:
        sid = prompt_sessions.pop(o.get("id"), None) if "stopReason" in (o.get("result") or {}) else None
        if sid is not None:
            base = session_spent.get(sid, 0.0)
            for amount in FAKE_USAGE_UPDATES:
                out.append({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {
                    "sessionUpdate": "usage_update", "used": 1000, "size": 200000,
                    "cost": {"amount": round(base + amount, 6), "currency": "USD"}}}})
            session_spent[sid] = base + (FAKE_USAGE_UPDATES[-1] if FAKE_USAGE_UPDATES else 0.0)
        out.append(o)
    return out


def send_all(objs):
    """Write `objs` as one write: a burst the agent sends at once."""
    if FAKE_USAGE_UPDATES is not None:
        objs = usage_updates(objs)
    ends = [o for o in objs if isinstance(o.get("result"), dict) and "stopReason" in o["result"]]
    if FAKE_USAGE is not None:
        for o in ends:
            o["result"].setdefault("usage", FAKE_USAGE)
    with lock:
        if FAKE_SENT_LOG and ends:
            with open(FAKE_SENT_LOG, "a") as f:
                f.write(f"{time.time_ns() // 1000}\n")
        sys.stdout.write("".join(json.dumps(o) + "\n" for o in objs))
        sys.stdout.flush()


def request_start(method, params):
    """Send a request to the client without waiting: its id and the event its answer sets."""
    global next_id
    with lock:
        rid = next_id
        next_id += 1
    ev = threading.Event()
    pending[rid] = [ev, None]
    send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
    return rid, ev


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


CLAUDE_STORE = os.environ.get("FAKE_CLAUDE_STORE") == "1"
# FAKE_CLAUDE_STORE: each session's project file.
claude_files = {}


def claude_file(cwd, sid):
    project = "".join(c if c.isascii() and c.isalnum() else "-" for c in cwd)
    return os.path.join(os.path.expanduser("~"), ".claude", "projects", project, sid + ".jsonl")


def claude_write(sid, record):
    with open(claude_files[sid], "a") as f:
        f.write(json.dumps(record) + "\n")


def claude_new(cwd):
    import uuid
    sid = str(uuid.uuid4())
    claude_files[sid] = claude_file(cwd, sid)
    os.makedirs(os.path.dirname(claude_files[sid]), exist_ok=True)
    # Not Claude Code's own record types: nothing in acpmux reads this file as a transcript.
    claude_write(sid, {"type": "fake-session", "sessionId": sid, "cwd": cwd})
    return sid


def claude_load(cwd, sid):
    path = claude_file(cwd, sid)
    if not os.path.isfile(path):
        return False
    claude_files[sid] = path
    return True


def prompt_text(params):
    """Match fixture commands on the request; opt in to echoing cmux guidance."""
    blocks = params.get("prompt", [])
    if os.environ.get("FAKE_ECHO_GUIDANCE") != "1":
        blocks = [b for b in blocks if not is_cmux_guidance(b)]
    # Who wrote it (hub/prompt_attribution.rs): fixtures match the prompt, opt in to the marks.
    if os.environ.get("FAKE_ECHO_ATTRIBUTION") != "1":
        blocks = [unwrapped(b) for b in blocks if not is_attribution(b)]
    return "".join(b.get("text", "") for b in blocks)


def unwrapped(block):
    """A paste acpmux wrapped in its marks (attributionWrap), as the composer sent it."""
    wrap = ((block.get("_meta") or {}).get("acpmux") or {}).get("attributionWrap") if isinstance(block, dict) else None
    text = block.get("text", "") if isinstance(block, dict) else ""
    if not wrap or not isinstance(text, str):
        return block
    head, tail = wrap.get("open", "") + "\n", "\n" + wrap.get("close", "")
    if text.startswith(head) and text.endswith(tail):
        return {**block, "text": text[len(head):len(text) - len(tail)]}
    return block


def is_attribution(block):
    """A mark of who wrote the prompt, which acpmux adds ahead of or around its blocks."""
    return isinstance(block, dict) and (block.get("_meta") or {}).get("acpmux", {}).get("attribution") is True


# The hidden guidance blocks (`context_inventory::override_block`), and only those: the
# forum's rules, a side question's chat and a message's attachments are cmux-*-context
# blocks too, and the agent must read them, so their tests read them in the echo.
GUIDANCE_TAGS = ("<cmux-default-context>", "<cmux-user-context>", "<cmux-project-context>", "<cmux-guidance-context>")


def guidance_text(text):
    """Recognize a guidance wrapper after an adapter dropped its metadata."""
    return isinstance(text, str) and text.lstrip().startswith(GUIDANCE_TAGS)


def is_cmux_guidance(block):
    """Identify cmux's hidden first-turn guidance after an adapter drops metadata."""
    if not isinstance(block, dict):
        return False
    # The files acpmux prefetched into the prompt (`hub/prefetch.rs`): left out of fixture
    # commands and echoes unless FAKE_ECHO_PREFETCH=1.
    if os.environ.get("FAKE_ECHO_PREFETCH") != "1" and str(block.get("text", "")).lstrip().startswith("<cmux-prefetch-context>"):
        return True
    source = (block.get("_meta") or {}).get("acpmux", {}).get("contextSource")
    if source in {"cmux-default", "cmux-user", "cmux-project", "cmux-guidance"}:
        return True
    return guidance_text(block.get("text", ""))


def codex_transcript_content(params):
    """Keep the harness's raw context blocks while keeping ordinary fixtures compact."""
    blocks = [b for b in params.get("prompt", []) if isinstance(b, dict)]
    if not any(is_cmux_guidance(b) for b in blocks):
        return [{"type": "input_text", "text": prompt_text(params)}]
    return [{"type": "input_text", "text": b.get("text", "")} for b in blocks
            if isinstance(b.get("text"), str)]


def codex_visible_text(payload):
    """Read a fixture rollout like adopt_replay: context is not a person prompt."""
    content = payload.get("content", [])
    return "".join(item.get("text", "") for item in content
                   if isinstance(item, dict) and not guidance_text(item.get("text", "")))


def codex_store_prompt(rid, params):
    sid = params["sessionId"]
    text = prompt_text(params)
    codex_write(sid, "event_msg", {"type": "task_started"})
    codex_write(sid, "response_item", {"type": "message", "role": "user", "content": codex_transcript_content(params)})
    # A turn takes time: it never ends in the millisecond it started.
    time.sleep(0.02)
    reply = "ok: " + text
    if text.strip() == "history-probe":
        with open(rollouts[sid]) as f:
            records = [json.loads(line) for line in f if line.strip()]
        reply = json.dumps({
            "prompts": [codex_visible_text(r["payload"]) for r in records
                        if r["type"] == "response_item" and r["payload"].get("role") == "user"
                        and codex_visible_text(r["payload"]) != "history-probe"],
            "sessions": sorted({r["payload"]["id"] for r in records if r["type"] == "session_meta"}),
        })
    # Native rollouts retain the assistant reply as well as the user's prompt.
    codex_write(sid, "response_item", {"type": "message", "role": "assistant", "phase": "final_answer", "content": [{"type": "output_text", "text": reply}]})
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
    text = prompt_text(params)
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
# FAKE_CLAUDE_STEER with FAKE_STEER_STEP: steers not read yet, by their hub promptId, and those
# taken back (`_acpmux/steer_withdraw`, as Claude Code's cancel_async_message drops one).
claude_unread = set()
claude_withdrawn = set()
# FAKE_STEER_NO_TURN_AT_END: the steers each session's running turn holds unread, by request id.
claude_held = {}


def claude_prompt(rid, params):
    """Claude Code: a prompt during a turn is a steer, answered "steered" at once."""
    sid = params["sessionId"]
    text = prompt_text(params)
    with lock:
        steer = sid in claude_turns
        if not steer:
            claude_turns.add(sid)
    if steer and os.environ.get("FAKE_STEER_NO_TURN_AT_END") == "1":
        with lock:
            claude_held.setdefault(sid, []).append(rid)
        return
    if steer:
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "steer: " + text}})
        # FAKE_STEER_STEP=<fifo>: the steer is read at the agent's next tool step, which the
        # test makes by writing to the FIFO, as Claude Code answers a steer only there.
        step = os.environ.get("FAKE_STEER_STEP")
        prompt_id = (params.get("_meta") or {}).get("promptId")
        if step:
            with lock:
                claude_unread.add(prompt_id)
            with open(step) as gate:
                gate.read()
            with lock:
                claude_unread.discard(prompt_id)
                if prompt_id in claude_withdrawn:
                    send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32000, "message": "steer: withdrawn before the agent read it"}})
                    return
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "steered"}})
        return
    try:
        handle_prompt(rid, params)
    finally:
        with lock:
            claude_turns.discard(sid)
            held = claude_held.pop(sid, [])
        for steer_id in held:
            send({"jsonrpc": "2.0", "id": steer_id, "error": {"code": -32602, "message": "steer: no turn is running"}})


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


def run_stuck_loop(rid, sid):
    """Keep a detected loop visible long enough for a real-app capture, without running a command."""
    for number in range(3):
        if sid in cancelled:
            cancelled.discard(sid)
            send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "cancelled"}})
            return
        call_id = f"stuck-cargo-{number}"
        update(sid, {"sessionUpdate": "tool_call", "toolCallId": call_id, "title": "cargo test",
                     "kind": "execute", "status": "in_progress", "rawInput": {"command": "cargo test"}})
        update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": call_id, "status": "failed",
                     "rawOutput": {"exit_code": 1, "stderr": "auth.rs:88: assertion failed"}})
    update(sid, {"sessionUpdate": "agent_message_chunk", "content": {
        "type": "text", "text": "STUCK LOOP READY"}})
    # Starting the next tool finalizes that assistant segment for the DEV capture's
    # chat_state untilReplyContains wait, without clearing the still-running episode.
    update(sid, {"sessionUpdate": "tool_call", "toolCallId": "stuck-progress", "title": "Check progress",
                 "kind": "execute", "status": "in_progress", "rawInput": {"command": "true"}})
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        if sid in cancelled:
            cancelled.discard(sid)
            send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "cancelled"}})
            return
        time.sleep(min(0.1, max(0, deadline - time.monotonic())))
    if sid in cancelled:
        cancelled.discard(sid)
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "cancelled"}})
        return
    update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": "stuck-progress", "status": "completed"})
    update(sid, {"sessionUpdate": "agent_message_chunk", "content": {
        "type": "text", "text": " STUCK LOOP CLEARED"}})
    send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})


def run_goal(rid, sid, text):
    now = int(time.time() * 1000)
    goal = goals.get(sid)
    if text.startswith("goal:"):
        goal = {"objective": text[5:].strip(), "status": "active", "provider": "codex",
                "startedAt": now - 32 * 60 * 1000, "updatedAt": now}
        reply = "Goal set."
    else:
        arg = text[6:].strip()
        if goal is None and arg in ("pause", "resume", "clear"):
            reply = "No goal is set."
        elif arg == "pause":
            goal = {**goal, "status": "paused", "updatedAt": now}
            reply = "Goal paused."
        elif arg == "resume":
            goal = {**goal, "status": "active", "updatedAt": now}
            reply = "Goal resumed."
        elif arg == "clear":
            goal = None
            reply = "Goal cleared."
        else:
            goal = {**(goal or {"provider": "codex", "startedAt": now}), "objective": arg, "status": "active",
                    "updatedAt": now}
            reply = "Goal updated."
    if goal is None:
        goals.pop(sid, None)
    else:
        goals[sid] = goal
    update(sid, {"sessionUpdate": "session_info_update", "_meta": {"goal": goal}})
    update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": reply}})
    send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})


def answer_review_threads(text):
    """Answer each thread of a threaded review in that thread, through the cmux CLI."""
    import re
    import shlex
    import subprocess
    root = re.search(r"--root ('(?:[^']|'\\'')*')", text)
    root = shlex.split(root.group(1))[0] if root else ""
    env = dict(os.environ, CMUX_TUI_SOCKET=os.environ.get("FAKE_REVIEW_SOCKET", ""))
    for section in re.split(r"(?m)^## Thread ", text)[1:]:
        thread_id = section.split(":", 1)[0].strip()
        if "needs no answer" in section:
            continue
        subprocess.run(
            [os.environ["FAKE_REVIEW_CMUX"], "git", "comments", "reply", thread_id,
             "--root", root, "--text", "answered " + thread_id, "--json"],
            env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=60, check=False,
        )


def upstream_priority():
    """The X-Subrouter-Priority this process's requests carry, as Claude Code sends it: the line
    in ANTHROPIC_CUSTOM_HEADERS, else the SUBROUTER_PRIORITY acpmux put in its env."""
    for line in os.environ.get("ANTHROPIC_CUSTOM_HEADERS", "").splitlines():
        name, _, value = line.partition(":")
        if name.strip().lower() == "x-subrouter-priority":
            return value.strip()
    return os.environ.get("SUBROUTER_PRIORITY", "")


def upstream_turn(rid, sid, text):
    """FAKE_UPSTREAM_URL=<url>: every prompt is one Anthropic-shaped model call (POST
    <url>/v1/messages), as Claude Code makes one: the session's model (FAKE_PICKER's), its
    X-Subrouter-Priority, and X-Fake-Session=<ACPMUX_SESSION_ID or pid>. A 200 completes the turn;
    a 529 (or any error) is retried FAKE_UPSTREAM_RETRIES times inside the turn, as Claude Code
    retries an overload itself, waiting the answer's Retry-After (seconds, fractions allowed) or
    FAKE_UPSTREAM_BACKOFF_MS doubling; then the turn fails as Claude Code's does, "API Error: 529
    <body>"."""
    import urllib.request, urllib.error
    url = os.environ["FAKE_UPSTREAM_URL"].rstrip("/") + "/v1/messages"
    model = PICKER_MODELS.get(sid, "default")
    who = os.environ.get("ACPMUX_SESSION_ID") or str(os.getpid())
    body = json.dumps({"model": model, "max_tokens": 16,
                       "messages": [{"role": "user", "content": text[:200]}]}).encode()
    headers = {"content-type": "application/json", "anthropic-version": "2023-06-01",
               "x-subrouter-priority": upstream_priority(), "x-fake-session": who}
    retries = int(os.environ.get("FAKE_UPSTREAM_RETRIES", "0") or 0)
    backoff = int(os.environ.get("FAKE_UPSTREAM_BACKOFF_MS", "50") or 50) / 1000
    status, reply = 0, ""
    for attempt in range(retries + 1):
        if sid in cancelled:
            cancelled.discard(sid)
            send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "cancelled"}})
            return
        req = urllib.request.Request(url, data=body, method="POST", headers=headers)
        wait = backoff * (2 ** attempt)
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                status, reply = resp.status, resp.read().decode()
        except urllib.error.HTTPError as e:
            status, reply = e.code, e.read().decode()
            after = e.headers.get("retry-after")
            try:
                wait = max(wait, float(after)) if after else wait
            except ValueError:
                pass
        except Exception as e:  # the upstream gone: a transport error, as Claude Code says one
            status, reply = 0, f"Connection error. {e}"
        if status == 200:
            update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "echo: " + text}})
            send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
            return
        if attempt < retries:
            time.sleep(wait)
    message = f"API Error: {status} {reply}" if status else f"API Error: {reply}"
    send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": message}})


def handle_prompt(rid, params):
    sid = params["sessionId"]
    # Model a harness that scopes an interrupt to the prompt it is processing.
    if os.environ.get("FAKE_RESET_CANCEL_ON_PROMPT") == "1":
        cancelled.discard(sid)
    blocks = params.get("prompt", [])
    text = prompt_text(params)
    if os.environ.get("FAKE_REVIEW_CMUX") and text.startswith("Code review of "):
        answer_review_threads(text)
    if text.startswith("envs:"):
        names = [name.strip() for name in text[5:].split(",") if name.strip()]
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {
            "type": "text",
            "text": json.dumps({name: os.environ.get(name, "") for name in names}, sort_keys=True),
        }})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "carrier-fault: TOTAL KILL GATE" (tests/carrier_faults.rs): streams chunks "ev-1 " to
    # "ev-KILL ", asks permission without waiting, waits until the file GATE exists (the test cuts
    # the carrier, then makes it), streams on to "ev-(TOTAL-50) " while the carrier is down, waits
    # for the answer, streams the rest to "ev-TOTAL ", then "chose X" and end_turn.
    if text.startswith("carrier-fault:"):
        total, kill, gate = text[len("carrier-fault:"):].split("<", 1)[0].split()
        total, kill = int(total), int(kill)
        chunk = lambda n: update(sid, {"sessionUpdate": "agent_message_chunk",
                                       "content": {"type": "text", "text": f"ev-{n} "}})
        for n in range(1, kill + 1):
            chunk(n)
        aid, ev = request_start("session/request_permission", {
            "sessionId": sid,
            "toolCall": {"toolCallId": "cf1", "title": "carrier fault", "kind": "execute", "status": "pending"},
            "options": [
                {"optionId": "yes", "name": "Allow", "kind": "allow_once"},
                {"optionId": "no", "name": "Reject", "kind": "reject_once"},
            ],
        })
        while not os.path.exists(gate):
            time.sleep(0.005)
        for n in range(kill + 1, total - 49):
            chunk(n)
        ev.wait()
        res = pending.pop(aid)[1] or {}
        for n in range(max(kill + 1, total - 49), total + 1):
            chunk(n)
        chosen = res.get("outcome", {}).get("optionId", res.get("outcome", {}).get("outcome"))
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": f"chose {chosen}"}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    if os.environ.get("FAKE_UPSTREAM_URL"):
        return upstream_turn(rid, sid, text)
    cap_file = os.environ.get("FAKE_CAPACITY_FILE")
    if cap_file:
        with open(cap_file + ".seen", "a") as seen:
            seen.write(json.dumps(text) + "\n")
    if cap_file and os.path.exists(cap_file):
        storm = [
            "API Error: 529 {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}",
            "API Error: 503 no non-exhausted claude accounts available. (error type server_error, HTTP 503)",
            "API Error: 502 the gateway is at its call limit; retry",
        ]
        n = capacity_storm[0]
        capacity_storm[0] += 1
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": storm[n % len(storm)]}})
        return
    # "/compact": a compaction, as Claude Code reports one (acpmux compacts a chat that outgrew
    # its context before it goes on, hub/auto_resume/compact_first.rs). FAKE_COMPACT=fail
    # reports it failed and ends the prompt as Claude Code does; FAKE_COMPACT=hold runs it until
    # session/cancel.
    if text == "/compact":
        mode = os.environ.get("FAKE_COMPACT", "")
        update(sid, {"sessionUpdate": "compaction", "state": "running"})
        if mode == "hold":
            for _ in range(600):
                if sid in cancelled:
                    cancelled.discard(sid)
                    send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "cancelled"}})
                    return
                time.sleep(0.05)
        if mode == "fail":
            update(sid, {"sessionUpdate": "compaction", "state": "failed", "error": "Prompt is too long"})
        else:
            update(sid, {"sessionUpdate": "compaction", "state": "completed"})
        # Echoed as any other prompt is, so a test can see where the command went in.
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "echo: " + text}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    if os.environ.get("FAKE_ASK_MODE") == "1" and "hostname" in text:
        return run_hostname(rid, sid)
    if text == "gh-pr-create":
        return run_gh_pr_create(rid, sid)
    if text == "stuck-loop":
        return run_stuck_loop(rid, sid)
    # Connection-loss simulation for auto-resume tests. "net-fail-once: X" fails that prompt
    # with a transport error once per session; "net-down" fails it and every later prompt of
    # the session the same way. Any other prompt after a net-fail-once is answered as usual.
    # "net-fail-then-exit" fails with that transport error, then the agent exits.
    if text == "net-fail-then-exit":
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "stream disconnected before completion: error sending request for url (https://relay.invalid/responses)"}})
        time.sleep(0.05)
        os._exit(0)
    # "net-refused-gate: PATH" blocks on the FIFO at PATH (as "gate:"), then fails with a refused
    # connection: the test's open of the FIFO returns once the agent has the prompt, and the
    # answer waits until the test closes it.
    if text.startswith("net-refused-gate:"):
        with open(text[len("net-refused-gate:"):].split("<", 1)[0].strip()) as gate:
            gate.read()
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "connection refused: error sending request for url (https://relay.invalid/responses)"}})
        return
    # A harness-level RPC failure whose wording resembles a dead daemon must
    # remain an agent error; the CLI must not replay the prompt.
    if text == "agent-daemon-closed-error":
        marker = os.environ.get("FAKE_AGENT_DAEMON_CLOSED_MARKER")
        if marker:
            with open(marker, "a") as f:
                f.write("attempt\n")
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "daemon connection closed while the model was running"}})
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
    limit_file = os.environ.get("FAKE_RATE_LIMIT_FILE")
    if limit_file and os.path.exists(limit_file):
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "API Error: Request rejected (429) · This request would exceed your account's rate limit"}})
        return
    # Recovery fixtures: preserve the session, fail the first turn with the supplied
    # provider error, then answer the continuation normally.
    if text.startswith("rate-fail-n:") and sid not in rate_failures:
        _, n, error = text.split(":", 2)
        rate_failures[sid] = [int(n), error]
    if sid in rate_failures and rate_failures[sid][0] > 0:
        rate_failures[sid][0] -= 1
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": rate_failures[sid][1]}})
        return
    # "fail: X" fails the prompt with X and no output; "work-then-fail: X" calls a tool and says
    # something first (cmux#48917: only a conversation whose agent did work stays unstored-awake).
    # "echo-fail: X" streams X as its reply, then fails with X, as a harness that streams its error.
    if text.startswith(("fail: ", "work-then-fail: ", "echo-fail: ")):
        head, error = text.split(": ", 1)
        if head == "work-then-fail":
            update(sid, {"sessionUpdate": "tool_call", "toolCallId": "work-1", "title": "Read file",
                         "kind": "read", "status": "completed"})
            update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Read it."}})
        if head == "echo-fail":
            update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": error}})
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": error}})
        return
    if text.startswith("recover-once: ") and sid not in failed_once:
        failed_once.add(sid)
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": text.removeprefix("recover-once: ")}})
        return
    # "cap-fail-once: X" fails that prompt once per session with the SR2 gateway's capacity
    # error (every pooled account exhausted for a moment); the session's next prompt runs.
    if text.startswith("cap-fail-once:") and sid not in failed_once:
        failed_once.add(sid)
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "API Error: 503 no non-exhausted claude accounts available. This is a server-side issue, usually temporary — try again in a moment. If it persists, check your inference gateway (127.0.0.1:4016). (error type server_error, HTTP 503)"}})
        return
    # "cap-fail-three: X" keeps the SR2 capacity error across the first three
    # turns.  The fourth prompt succeeds so liveness tests can verify that a
    # successful turn clears a session's stuck state.
    if (text.startswith("cap-fail-three:") or sid in cap_failures) and cap_failures.get(sid, 0) < 3:
        cap_failures[sid] = cap_failures.get(sid, 0) + 1
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "API Error: 503 no non-exhausted claude accounts available. This is a server-side issue, usually temporary — try again in a moment. If it persists, check https://user:secret@example.invalid/inference. (error type server_error, HTTP 503)"}})
        return
    # Separate requests in a healthy turn can each briefly meet capacity.
    if text == "capacity-retry-progress":
        for _ in range(2):
            for attempt in range(1, 3):
                update(sid, {"sessionUpdate": "session_info_update", "_meta": {"codex": {"error": {
                    "message": f"Reconnecting... {attempt}", "willRetry": True,
                    "additionalDetails": "Selected model is at capacity."
                }}}})
            update(sid, {"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "working"}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # Older Codex keeps retrying in the turn, with no maximum in its notice.
    # It acknowledges cancel, but never ends the capacity failure on its own.
    if text == "capacity-inner-loop":
        capacity_inner_loops.add(sid)
    if sid in capacity_inner_loops:
        cancelled.discard(sid)
        for attempt in range(1, 251):
            if sid in cancelled:
                break
            update(sid, {"sessionUpdate": "session_info_update", "_meta": {"codex": {"error": {
                "message": f"Reconnecting... {attempt}", "willRetry": True,
                "additionalDetails": "Selected model is at capacity.", "codexErrorInfo": {"serverOverloaded": {}}
            }}}})
            time.sleep(0.02)
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "cancelled"}})
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
    # "elapsed-tour:" (a capture of how long tool calls run, the agent pane's RunningTime.tsx): a
    # shell that finishes after 1.4 s, a shell that goes on in the background as Claude Code reports
    # one (its result names the task, then `background_task_update` running), a short reply, then a
    # shell held running in the foreground until session/cancel or 300 s.
    if text.startswith("elapsed-tour:"):
        def shell(call_id, command):
            update(sid, {"sessionUpdate": "tool_call", "toolCallId": call_id, "title": command, "kind": "execute",
                         "status": "in_progress", "rawInput": {"command": command}})
        def done(call_id, out):
            update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": call_id, "status": "completed",
                         "content": [{"type": "content", "content": {"type": "text", "text": out}}]})
        shell("et-status", "git status --short")
        time.sleep(1.4)
        done("et-status", " M webviews/src/agent-session/acpmux/conversation/RunningTime.tsx")
        waited = "glaeda-gh wait pid 13341 --timeout 1750"
        shell("et-bg", waited)
        done("et-bg", "Command running in background with ID: et-bg-task.")
        update(sid, {"sessionUpdate": "background_task_update", "taskId": "et-bg-task", "toolCallId": "et-bg",
                     "command": waited, "state": "running"})
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {
            "type": "text", "text": "The wait runs in the background; the tests run now."}})
        time.sleep(0.5)
        shell("et-fg", "cargo test --workspace")
        deadline = time.monotonic() + 300
        while time.monotonic() < deadline:
            with lock:
                was_cancelled = sid in cancelled
                cancelled.discard(sid)
            if was_cancelled:
                update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": "et-fg", "status": "failed"})
                send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "cancelled"}})
                return
            time.sleep(0.1)
        done("et-fg", "test result: ok. 412 passed")
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "plan-json: [ENTRIES]" reports a plan with those entries (as Claude's TodoWrite or Codex's
    # update_plan reach acpmux), then answers "planned" and ends the turn.
    if text.startswith("plan-json:"):
        update(sid, {"sessionUpdate": "plan", "entries": json.loads(text[len("plan-json:"):])})
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "planned"}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "work-gate: PATH [| TITLE]" reports a plan step in progress and a running
    # tool call (TITLE, else "Run cargo test"), then blocks on the FIFO at PATH
    # (as "gate:") and ends: "worked" and end_turn, or cancelled when a
    # session/cancel came while it was blocked.
    if text.startswith("tool-then-cancel:"):
        update(sid, {"sessionUpdate": "tool_call", "toolCallId": "tc-1", "title": "Run the build",
                     "kind": "execute", "status": "in_progress"})
        with open(text[len("tool-then-cancel:"):].strip()) as gate:
            gate.read()
        update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": "tc-1", "status": "completed",
                     "rawOutput": "built"})
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "running"}})
        for _ in range(600):
            with lock:
                was_cancelled = sid in cancelled
                cancelled.discard(sid)
            if was_cancelled:
                send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "cancelled"}})
                return
            time.sleep(0.05)
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
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
    # "opencode-task" runs a subagent as OpenCode 1.19 does: only as its `task` tool call, whose
    # end names the child's own session and model (manaflow-ai/cmux#50203).
    if text == "opencode-task":
        call, child = "chatcmpl-tool-oc1", "ses_child_oc1"
        task = {"description": "Reply PONG", "prompt": "Reply PONG.", "subagent_type": "general"}
        update(sid, {"sessionUpdate": "tool_call", "toolCallId": call, "title": "task", "kind": "think",
                     "status": "pending", "rawInput": {}, "locations": []})
        update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": call, "title": "task", "kind": "think",
                     "status": "in_progress", "rawInput": task, "locations": []})
        out = f'<task id="{child}" state="completed">\n<task_result>\nPONG\n</task_result>\n</task>'
        update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": call, "title": "Reply PONG", "kind": "think",
                     "status": "completed", "content": [{"type": "content", "content": {"type": "text", "text": out}}],
                     "rawOutput": {"output": out, "metadata": {"model": {"modelID": "big-pickle", "providerID": "opencode"},
                                                               "parentSessionId": sid, "sessionId": child, "truncated": False}}})
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
    # "notice-gate: PATH" anywhere in the prompt (an inbox notice carries another agent's message
    # after its own lines) works as "gate: PATH".
    if "notice-gate:" in text:
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "before-gate"}})
        with open(text.split("notice-gate:", 1)[1].split()[0].rstrip("\"'`).,;")) as gate:
            gate.read()
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "after-gate"}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "overload-gate: PATH" streams "before-gate", blocks on the FIFO at PATH (as "gate:"), then
    # fails with Claude Code's overload error: a 529 that lands after a daemon restart adopted
    # the turn.
    if text.startswith("overload-gate:"):
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "before-gate"}})
        with open(text[len("overload-gate:"):].split("<", 1)[0].strip()) as gate:
            gate.read()
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "API Error: Repeated 529 Overloaded errors"}})
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
    # "questions: Q1 | Q2 | Q3" asks each Q at once as its own AskUserQuestion (subagents asking
    # side by side), each with the options Yes and No, then streams each outcome as it lands and
    # "all answered" once every one is settled (the composer hat's capture, question/HatQuestions.tsx).
    if text.startswith("questions:"):
        asks, ids = [], []
        for index, question in enumerate(q.strip() for q in text[10:].split("<", 1)[0].split("|")):
            if not question:
                continue
            with lock:
                aid = next_id
                next_id += 1
            ev = threading.Event()
            pending[aid] = [ev, None]
            ids.append((aid, question))
            asks.append({"jsonrpc": "2.0", "id": aid, "method": "session/request_permission", "params": {
                "sessionId": sid,
                "toolCall": {"toolCallId": f"qs{index}", "title": "Question", "kind": "other", "status": "pending",
                             "rawInput": {"questions": [{"question": question, "header": "Check-in",
                                                         "multiSelect": False,
                                                         "options": [{"label": "Yes"}, {"label": "No"}]}]},
                             "_meta": {"claude": {"tool": "AskUserQuestion", "interactive": True}}},
                "options": [
                    {"optionId": "allow_once", "name": "Answer", "kind": "allow_once"},
                    {"optionId": "reject_once", "name": "Reject", "kind": "reject_once"},
                ],
            }})
        if asks:
            send_all(asks)
        for aid, question in ids:
            pending[aid][0].wait()
            res = pending.pop(aid)[1] or {}
            chosen = res.get("outcome", {}).get("optionId", res.get("outcome", {}).get("outcome"))
            answers = res.get("_meta", {}).get("updatedInput", {}).get("answers")
            update(sid, {"sessionUpdate": "agent_message_chunk",
                         "content": {"type": "text", "text": f"{question}: {chosen} {json.dumps(answers, sort_keys=True)}\n"}})
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "all answered"}})
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
    # "plan-ask-on: <plan>": as "plan-ask:", but a rejected plan is a tool denial, as Claude
    # Code's adapter takes it: the turn plans on ("kept planning") unless it is cancelled.
    plan_on = text.startswith("plan-ask-on:")
    if plan_on:
        text = "plan-ask:" + text[len("plan-ask-on:"):]
    if text.startswith("plan-ask:"):
        plan = text[len("plan-ask:"):].strip()
        res = request(
            "session/request_permission",
            {
                "sessionId": sid,
                "toolCall": {"toolCallId": "plan-1", "title": "Approve plan", "kind": "switch_mode",
                             "status": "pending", "rawInput": {"plan": plan},
                             "_meta": {"claude": {"tool": "ExitPlanMode", "interactive": True}}},
                "options": [
                    {"optionId": "yes", "name": "Yes", "kind": "allow_once"},
                    {"optionId": "no", "name": "No", "kind": "reject_once"},
                ],
            },
        )
        chosen = (res or {}).get("outcome", {}).get("optionId", (res or {}).get("outcome", {}).get("outcome"))
        # The plan it builds, as Claude Code takes an allow's `updatedInput`: the person's edit
        # (acpmux lifts the outcome's `_meta` to the result's, hub permissions.rs).
        built = (((res or {}).get("_meta") or {}).get("updatedInput") or {}).get("plan")
        said = f"chose {chosen}" + (f" building: {built}" if built else "")
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": said}})
        if plan_on and chosen == "no":
            for _ in range(100):
                if sid in cancelled:
                    cancelled.discard(sid)
                    send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "cancelled"}})
                    return
                time.sleep(0.05)
            update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": " kept planning"}})
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
    # "auto-shell: <path>": a running tool call whose shell is in a session of its own, as a
    # tool's detached shell is, and appends a line to <path> every 50 ms; its pid goes to
    # <path>.pid. The turn then waits as "until-cancel" (module docs, tests/auto_session.rs).
    # "auto-run: <path>" is the same with a command that runs once: it appends "start" to
    # <path>, works for ten minutes, then appends "end" (tests/auto_journey.rs).
    if text.startswith("auto-shell:") or text.startswith("auto-run:"):
        import subprocess
        once = text.startswith("auto-run:")
        out = text.split(":", 1)[1].strip()
        script = ('echo start >> "$0"; sleep 600; echo end >> "$0"' if once
                  else 'while :; do echo tick >> "$0"; sleep 0.05; done')
        update(sid, {"sessionUpdate": "tool_call", "toolCallId": "tc-auto", "title": "Run the build",
                     "kind": "execute", "status": "in_progress", "rawInput": {"command": "build"}})
        shell = subprocess.Popen(["sh", "-c", script, out],
                                 stdin=subprocess.DEVNULL, start_new_session=True)
        with open(f"{out}.pid.tmp", "w") as f:
            f.write(str(shell.pid))
        os.replace(f"{out}.pid.tmp", f"{out}.pid")
        for _ in range(2400):
            with lock:
                was_cancelled = sid in cancelled
                cancelled.discard(sid)
            if was_cancelled:
                shell.kill()
                send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "cancelled"}})
                return
            time.sleep(0.05)
        shell.kill()
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "class-wait: <path>": as "class-probe", then the turn says nothing until the test writes to
    # the FIFO <path>.gate: a turn the person waits on, before its first token.
    if text.startswith("class-wait:"):
        import subprocess
        sleeper = subprocess.Popen(["sleep", "120"], stdin=subprocess.DEVNULL)
        out = text[len("class-wait:"):].split("<", 1)[0].strip()
        with open(f"{out}.tmp", "w") as f:
            f.write(json.dumps({"sleeper": sleeper.pid, "diskio": own_disk_io()}))
        os.replace(f"{out}.tmp", out)
        with open(f"{out}.gate") as gate:
            gate.read()
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "done"}})
        with open(f"{out}.gate") as gate:
            gate.read()
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "class-probe: <path>": a tool the turn runs, its pid to <path> (module docs).
    if text.startswith("class-probe:"):
        import subprocess
        sleeper = subprocess.Popen(["sleep", "120"], stdin=subprocess.DEVNULL)
        out = text[len("class-probe:"):].strip()
        with open(f"{out}.tmp", "w") as f:
            f.write(json.dumps({"sleeper": sleeper.pid, "diskio": own_disk_io()}))
        os.replace(f"{out}.tmp", out)
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
    # "dirs" replies with the additionalDirectories of the last session/new, load or fork.
    if text == "dirs":
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": json.dumps(LAST_DIRS)}})
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
    # "quit-after: X" answers the turn, then, idle, prints X on stderr and exits 0 on its own, as
    # a CLI that quits after its account's 429 does between turns.
    if text.startswith("quit-after:"):
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "done"}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        line = text[len("quit-after:"):].strip()

        def quit_later():
            time.sleep(0.5)
            sys.stderr.write(line + "\n")
            sys.stderr.flush()
            time.sleep(0.2)
            os._exit(0)

        threading.Thread(target=quit_later, daemon=True).start()
        return
    # "overloaded: X": the provider's overload with no HTTP status in the text.
    # "surfaces-tour": one turn that draws every content surface of the chat (design/chat-surfaces.md,
    # scripts/cmux-next/chat-surfaces-shots.py): a plan, a shell call with its output, a new 55-line
    # PROPOSAL.md (the edited-files card) and a reply with inline code, a code block and a table.
    if text.startswith("surfaces-tour"):
        update(sid, {"sessionUpdate": "plan", "entries": [
            {"content": "Audit the chat's surfaces", "status": "completed", "priority": "high"},
            {"content": "Write the proposal", "status": "completed", "priority": "high"},
            {"content": "Land on the branch", "status": "pending", "priority": "medium"}]})
        update(sid, {"sessionUpdate": "tool_call", "toolCallId": "tour-run", "title": "bun test test/chat-surfaces.test.ts",
                     "kind": "execute", "status": "completed", "rawInput": {"command": "bun test test/chat-surfaces.test.ts"},
                     "content": [{"type": "content", "content": {"type": "text", "text": " 4 pass\n 0 fail\nRan 4 tests across 1 file. [80.00ms]"}}]})
        body = "\n".join(f"- point {k}: one surface level for every card" for k in range(1, 56))
        update(sid, {"sessionUpdate": "tool_call", "toolCallId": "tour-edit", "title": "Write PROPOSAL.md", "kind": "edit",
                     "status": "completed", "locations": [{"path": os.path.join(os.getcwd(), "PROPOSAL.md")}],
                     "content": [{"type": "diff", "path": os.path.join(os.getcwd(), "PROPOSAL.md"), "oldText": None, "newText": body + "\n"}]})
        reply = ("Platform has a red `ci` check. The levels are `--ds-surface-card` and `--ds-surface-inset`.\n\n"
                 "```ts\nconst card = \"color-mix(in srgb, var(--ds-surface-ink) 4%, transparent)\";\n```\n\n"
                 "| Level | Fill | Line |\n|---|---|---|\n| card | 4% | 10% |\n| inset | 8% | none |\n")
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": reply}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    if text.startswith("overloaded:"):
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}"}})
        return
    # "cap-fail-then-exit": the SR2 gateway's capacity error, then the agent exits.
    if text == "cap-fail-then-exit":
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "API Error: 503 no non-exhausted claude accounts available. (error type server_error, HTTP 503)"}})
        time.sleep(0.05)
        os._exit(0)
    # "limit:": a usage limit (a sign-in failure with FAKE_AUTH_FAIL=1, which fails over where a
    # usage limit waits for its reset, #27924).
    if text.startswith("limit:"):
        message = "Not logged in" if os.environ.get("FAKE_AUTH_FAIL") == "1" else "You've reached your usage limit for this account"
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": message}})
        return
    # "big-output:N" answers with one message of N MiB: one update too large for a frame.
    # "compact-summary: TEXT" reports a compaction summary of TEXT, as Claude Code's /compact does
    # (hub/compaction_outline.rs), then answers "ok".
    if text.startswith("compact-summary:"):
        update(sid, {"sessionUpdate": "compaction_summary", "text": text[16:].strip()})
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "ok"}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "tool-turn: N" runs one tool call with an input and a result of N bytes, then answers "done".
    if text.startswith("tool-turn:"):
        n = int(text[10:])
        update(sid, {"sessionUpdate": "tool_call", "toolCallId": "tt1", "title": "Bash", "kind": "execute",
                     "status": "in_progress", "rawInput": {"command": "echo hi"}})
        update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": "tt1", "status": "completed",
                     "content": [{"type": "content", "content": {"type": "text", "text": "r" * n}}]})
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "done"}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "chunks: N" streams N one-word reply chunks, then ends the turn (an ack batch test).
    if text.startswith("chunks:"):
        for n in range(int(text[7:])):
            update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": f"w{n} "}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "delta-chunks: N L" streams N reply chunks of exactly L bytes each, one write per chunk as a
    # harness streams them, then ends the turn (tests/delta_cost.rs: what one text delta costs).
    if text.startswith("delta-chunks:"):
        count, length = (int(x) for x in text[13:].split())
        for _ in range(count):
            update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "d" * length}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    if text.startswith("big-output:"):
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "z" * (int(text[11:]) << 20)}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    if text.startswith("fail-after-update:"):
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "partial "}})
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "simulated internal error after output"}})
        return
    # "goal: X" sets a Codex goal, "/goal pause|resume|clear|<text>" drives it, as codex-acp
    # reports one: session_info_update with _meta.goal (null once cleared).
    if text.startswith("goal:") or text.startswith("/goal "):
        return run_goal(rid, sid, text)
    # "meta: X" sends a chunk whose notification carries the agent's own _meta.
    # "harness-title: X" titles the session itself, as Codex does.
    if text.startswith("harness-title:"):
        update(sid, {"sessionUpdate": "session_info_update", "title": text[14:].strip()})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "wrap-up: JSON" replies, then ends the turn on a completed acpmux wrap_up call whose
    # arguments are JSON ({"recap": ..., "ask": ..., "actions": [...]}), as an agent's last step.
    if text.startswith("wrap-up:"):
        args = json.loads(text[8:].strip())
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Done with the step."}})
        update(sid, {"sessionUpdate": "tool_call", "toolCallId": "wrap-1", "title": "mcp__acpmux__wrap_up", "kind": "other", "status": "in_progress", "rawInput": args})
        update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": "wrap-1", "status": "completed"})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "suggest: TEXT" ends the turn with TEXT as the predicted next prompt.
    if text.startswith("suggest:"):
        update(sid, {"sessionUpdate": "prompt_suggestion", "suggestion": text[8:].strip()})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    if text.startswith("meta:"):
        send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text[5:].strip()}}, "_meta": {"fake": {"n": 1}}}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn", "_meta": {"fake": {"done": True}}}})
        return
    # "reply-segments" streams one message (m1) across what the pane keeps it whole over: a
    # background task's note, a subagent's spawn and update, a plumbing call (ToolSearch) and a
    # usage tick; then a chunk with no messageId, a thought and a tool call the person sees,
    # and another chunk with none. acpmux stamps one segment per message, ended also where the pane
    # cuts the row (hub/stream.rs `cuts_reply`).
    # "reply-checklist" streams one message (m1) across TodoWrite calls and plans, cleared and new:
    # acpmux drops each (todo_tools.rs), so none cuts the row.
    if text == "reply-checklist":
        chunk = lambda t: update(sid, {"sessionUpdate": "agent_message_chunk", "messageId": "m1", "content": {"type": "text", "text": t}})
        todo = lambda n: update(sid, {"sessionUpdate": "tool_call", "toolCallId": f"todo-{n}", "title": "TodoWrite", "kind": "other", "status": "completed", "_meta": {"claude": {"tool": "TodoWrite"}}})
        plan = lambda entries: update(sid, {"sessionUpdate": "plan", "entries": entries})
        step = [{"content": "step", "status": "pending", "priority": "medium"}]
        chunk("a")
        todo(1)
        chunk("b")
        plan(step)
        chunk("c")
        todo(2)
        chunk("d")
        plan(step)
        chunk("e")
        plan([])
        chunk("f")
        plan(step)
        chunk("g")
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "reply-checklist-ticks" sends a plan, then streams one message (m1) across a usage tick, a
    # call's update and another plan: none is a new turn, so the pane keeps the message one row
    # and acpmux one segment (#41540 review F1).
    if text == "reply-checklist-ticks":
        chunk = lambda t: update(sid, {"sessionUpdate": "agent_message_chunk", "messageId": "m1", "content": {"type": "text", "text": t}})
        step = [{"content": "step", "status": "pending", "priority": "medium"}]
        update(sid, {"sessionUpdate": "plan", "entries": step})
        chunk("a")
        update(sid, {"sessionUpdate": "usage_update", "used": 10, "size": 1000})
        update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": "tick-ts", "status": "completed"})
        update(sid, {"sessionUpdate": "plan", "entries": [{**step[0], "status": "in_progress"}]})
        chunk("b")
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "reply-dsh-todo" streams one message (m1) across DeepSeek Harness todo_write calls and their
    # results, which acpmux drops (todo_tools.rs): a | call 1 | b | its result | c | call 2 | d |
    # its result | e (#41540 review F2).
    if text == "reply-dsh-todo":
        chunk = lambda t: update(sid, {"sessionUpdate": "agent_message_chunk", "messageId": "m1", "content": {"type": "text", "text": t}})
        todos = lambda status: {"todos": [{"content": "step", "status": status}]}
        call = lambda n, status: update(sid, {"sessionUpdate": "tool_call", "toolCallId": f"dsh-todo-{n}", "title": "todo_write", "kind": "other", "status": "pending", "rawInput": todos(status)})
        done = lambda n: update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": f"dsh-todo-{n}", "status": "completed"})
        chunk("a")
        call(1, "pending")
        chunk("b")
        done(1)
        chunk("c")
        call(2, "in_progress")
        chunk("d")
        done(2)
        chunk("e")
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "background-subagent" starts background subagent bg-quiet and ends the turn at once, as a
    # coordinator's Claude Agent call with run_in_background outlives its turn;
    # "background-subagent-done" reports it completed.
    if text in ("background-subagent", "background-subagent-done"):
        if text == "background-subagent":
            update(sid, {"sessionUpdate": "subagent_spawned", "subagentSessionId": "bg-quiet", "name": "Background",
                         "task": "Background audit", "background": True, "capabilities": {}})
        else:
            update(sid, {"sessionUpdate": "subagent_state_update", "subagentSessionId": "bg-quiet", "state": "completed"})
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    if text == "reply-segments":
        chunk = lambda t, mid=None: update(sid, {"sessionUpdate": "agent_message_chunk", **({"messageId": mid} if mid else {}), "content": {"type": "text", "text": t}})
        chunk("a", "m1")
        update(sid, {"sessionUpdate": "background_task_update", "taskId": "bg-1", "status": "completed"})
        chunk("b", "m1")
        update(sid, {"sessionUpdate": "subagent_spawned", "subagentSessionId": "seg-child", "name": "Look", "task": "Look", "capabilities": {}})
        update(sid, {"sessionUpdate": "subagent_state_update", "subagentSessionId": "seg-child", "state": "completed"})
        chunk("c", "m1")
        update(sid, {"sessionUpdate": "tool_call", "toolCallId": "seg-ts", "title": "ToolSearch", "kind": "other", "status": "completed", "_meta": {"claudeCode": {"toolName": "ToolSearch"}}})
        chunk("d", "m1")
        update(sid, {"sessionUpdate": "usage_update", "used": 10, "size": 1000})
        chunk("e", "m1")
        chunk("f")
        update(sid, {"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "hm"}})
        update(sid, {"sessionUpdate": "tool_call", "toolCallId": "seg-tc", "title": "ls", "kind": "read", "status": "completed"})
        chunk("g")
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
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
        # A real cumulative total (`totalTokens`); `used` is context occupancy, never tokens.
        update("orch-child", {"sessionUpdate": "usage_update", "totalTokens": 1234, "used": 99, "size": 200000})
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
    # "usage-probe" answers with a Gemini-style ACP usage: its 100K input counts the 90K read from
    # the prompt cache (its total is input plus output).
    if text == "usage-probe":
        usage = {"inputTokens": 100000, "cachedReadTokens": 90000, "outputTokens": 2000, "totalTokens": 102000}
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn", "usage": usage}})
        return
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
    # "steps" (or a prompt containing FAKE_STEPS_IN) is a turn that works until told to stop: a
    # tool call every 150 ms (step-PID-N: 20 ms running, then its result), each finished call's
    # id appended to FAKE_STEP_LOG once its result is sent. A session/cancel between two calls
    # ends it cancelled; once the file FAKE_STEPS_END exists it says "stepped" and ends its turn.
    if text == "steps" or (os.environ.get("FAKE_STEPS_IN") or "\0") in text:
        end, step_log = os.environ.get("FAKE_STEPS_END"), os.environ.get("FAKE_STEP_LOG")
        for n in range(2000):
            with lock:
                was_cancelled = sid in cancelled
                cancelled.discard(sid)
            if was_cancelled:
                send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "cancelled"}})
                return
            if end and os.path.exists(end):
                break
            call = f"step-{os.getpid()}-{n}"
            update(sid, {"sessionUpdate": "tool_call", "toolCallId": call, "title": f"step {n}",
                         "kind": "execute", "status": "in_progress"})
            time.sleep(0.02)
            update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": call, "status": "completed",
                         "rawOutput": f"done {n}"})
            if step_log:
                fd = os.open(step_log, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
                os.write(fd, (call + "\n").encode())
                os.close(fd)
            time.sleep(0.13)
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "stepped"}})
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "work-for: S" is a task that takes S seconds of wall clock (RFD 0135's lid-close gate): one
    # finished tool call a second, each titled with the unix ms it ran at, so a reader can tell
    # whether the work went on through a window or stopped in it. A session/cancel ends it.
    if text.startswith("work-for:"):
        seconds = float(text.split(":", 1)[1].strip() or "0")
        deadline, n = time.monotonic() + seconds, 0
        while time.monotonic() < deadline:
            with lock:
                was_cancelled = sid in cancelled
                cancelled.discard(sid)
            if was_cancelled:
                send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "cancelled"}})
                return
            call = f"tick-{os.getpid()}-{n}"
            at = int(time.time() * 1000)
            update(sid, {"sessionUpdate": "tool_call", "toolCallId": call, "title": f"tick {n} at {at}",
                         "kind": "execute", "status": "in_progress"})
            update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": call, "status": "completed",
                         "rawOutput": f"tick {n} at {at}"})
            n += 1
            time.sleep(max(0.0, min(1.0, deadline - time.monotonic())))
        update(sid, {"sessionUpdate": "agent_message_chunk",
                     "content": {"type": "text", "text": f"worked {seconds:g} s"}})
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
    # "cancel-ends-turn" streams "running" and answers session/cancel with end_turn: an adapter
    # that stops on a cancel but does not say its turn was cancelled (bounded at 30 s).
    if text == "cancel-ends-turn":
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "running"}})
        for _ in range(600):
            if sid in cancelled:
                cancelled.discard(sid)
                break
            time.sleep(0.05)
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "cancel-errors" streams "running" and answers session/cancel with an error, as an adapter
    # whose interrupt fails the turn (bounded at 30 s).
    if text == "cancel-errors":
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "running"}})
        for _ in range(600):
            if sid in cancelled:
                cancelled.discard(sid)
                break
            time.sleep(0.05)
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "turn interrupted: request aborted"}})
        return
    # "works-through-cancel" ignores every session/cancel and keeps calling tools, as a harness
    # that went on working after Stop (2026-10-29): a tool call every 100 ms, each titled with
    # its number and this process's pid, until it ends its turn by itself 60 s later.
    # "works-through-cancel-beside-background" does the same after starting background subagent
    # bg-1, which outlives the turn (a Claude Agent call with run_in_background).
    # The silent variants emit only the initial call, then ignore both cancels.
    if text in ("works-through-cancel", "works-through-cancel-beside-background",
                "silent-through-cancel", "silent-through-cancel-beside-background"):
        if text.endswith("-beside-background"):
            update(sid, {"sessionUpdate": "subagent_spawned", "subagentSessionId": "bg-1", "name": "Background",
                         "task": "Background audit", "background": True, "capabilities": {}})
        for n in range(600):
            if n == 0 or not text.startswith("silent-"):
                update(sid, {"sessionUpdate": "tool_call", "toolCallId": f"work-{os.getpid()}-{n}",
                             "title": f"step {n} pid {os.getpid()}", "kind": "execute", "status": "in_progress"})
            time.sleep(0.1)
        cancelled.discard(sid)
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
    # "slow-limit": a usage limit after a second (a sign-in failure with FAKE_AUTH_FAIL=1, which
    # fails over where a usage limit now waits for its reset), then on the fallback profile
    # (FAKE_FALLBACK=1) an answer (`hub/full_access_bound.rs`, a family message that fails over).
    if text == "slow-limit":
        if os.environ.get("FAKE_FALLBACK") != "1":
            time.sleep(1)
            message = "Not logged in" if os.environ.get("FAKE_AUTH_FAIL") == "1" else "You've reached your usage limit for this account"
            send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": message}})
            return
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "limit-then-hang": a usage limit, then on the fallback profile (FAKE_FALLBACK=1) one word
    # and nothing more (`hub/stalled_turn.rs`, a stalled turn after a failover).
    if text == "limit-then-hang":
        if os.environ.get("FAKE_FALLBACK") != "1":
            message = "Not logged in" if os.environ.get("FAKE_AUTH_FAIL") == "1" else "You've reached your usage limit for this account"
            send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": message}})
            return
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "working"}})
        time.sleep(3600)
        return
    # "tagged:N:MS" streams N rounds of a reply chunk, a thought, a tool call and its end and a
    # plan, every MS ms. Each update carries one tag [[t:ROUND:KIND]] that names it alone, so a
    # client that follows the chat can count each update it got (tests/follower_once.rs).
    if text.startswith("tagged:"):
        n, ms = (int(v) for v in text[len("tagged:"):].split(":"))
        for i in range(n):
            tag = lambda k: f"[[t:{i}:{k}]]"
            send_all([{"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": u}} for u in [
                {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": f"{tag('m')} said "}},
                {"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": f"{tag('th')} thought "}},
                {"sessionUpdate": "tool_call", "toolCallId": f"tg-{i}", "title": tag("tc"), "kind": "execute",
                 "status": "in_progress", "rawInput": {"command": f"echo {tag('tc')}"}},
                {"sessionUpdate": "tool_call_update", "toolCallId": f"tg-{i}", "status": "completed",
                 "content": [{"type": "content", "content": {"type": "text", "text": f"{tag('tu')} out"}}]},
                {"sessionUpdate": "plan", "entries": [{"content": f"{tag('p')} step", "priority": "medium", "status": "in_progress"}]},
            ]])
            time.sleep(ms / 1000)
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    # "ticking:N:MS" streams a word every MS ms, N times, then ends: a model that keeps working,
    # each sign well inside the stall limit (`hub/stalled_turn.rs`).
    if text.startswith("ticking:"):
        n, ms = (int(v) for v in text[len("ticking:"):].split(":"))
        for i in range(n):
            if sid in cancelled:
                send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "cancelled"}})
                cancelled.discard(sid)
                return
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
    if text == "reply-then-thought":
        update(sid, {"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "done"}})
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


HELD = []
HELD_CANCELS = []


def write_atomic(path, text):
    """`text` to `path`, whole or not at all: a reader never sees half of it."""
    with open(path + ".tmp", "w") as f:
        f.write(text)
    os.replace(path + ".tmp", path)


def stdin_lines(early):
    """stdin's lines, starting with the bytes read while waiting at the start gate."""
    if early:
        if not early.endswith(b"\n"):
            early += sys.stdin.buffer.readline()
        # Split and decoded as stdin is: only at newlines (serde_json leaves U+2028 unescaped).
        import io
        yield from io.TextIOWrapper(io.BytesIO(early), encoding=sys.stdin.encoding, errors=sys.stdin.errors)
    yield from sys.stdin


def own_disk_io():
    """This process's disk I/O policy (`getiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS)`)."""
    if sys.platform != "darwin":
        return None
    import ctypes
    return ctypes.CDLL(None).getiopolicy_np(0, 0)


def own_pri():
    """This process's scheduler base priority (`ps -o pri=`): 4 at background class."""
    import subprocess
    out = subprocess.run(["ps", "-o", "pri=", "-p", str(os.getpid())], capture_output=True, text=True)
    return int(out.stdout.strip() or "0")


def wire_log(msg):
    """FAKE_WIRE_LOG: record a line this agent read, one O_APPEND write per line."""
    path = os.environ.get("FAKE_WIRE_LOG")
    if not path:
        return
    params = msg.get("params") if isinstance(msg.get("params"), dict) else {}
    line = json.dumps({"pid": os.getpid(), "id": msg.get("id"), "method": msg.get("method"),
                       "session": params.get("sessionId")}) + "\n"
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        os.write(fd, line.encode())
    finally:
        os.close(fd)


KEY_SIGNED_IN = False


def main():
    global LAST_MCP_SERVERS, LAST_DIRS
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
        wire_log(msg)
        if "method" not in msg:
            p = pending.get(msg.get("id"))
            if p:
                p[1] = msg.get("result") if "error" not in msg else {"error": msg["error"]}
                p[0].set()
            continue
        m = msg["method"]
        rid = msg.get("id")
        params = msg.get("params") or {}
        # FAKE_SET_MODE_HOLD=<dir>: hold every session/set_mode unanswered, writing how many wait
        # to <dir>/held and the ids each `$/cancel_request` names to <dir>/cancels. Once all but one
        # are cancelled, answer every held one, the cancelled ones too: their answers come late
        # and the daemon drops them (tests/cancel_request.rs).
        hold = os.environ.get("FAKE_SET_MODE_HOLD")
        if hold and m == "$/cancel_request":
            HELD_CANCELS.append(params.get("requestId"))
            write_atomic(os.path.join(hold, "cancels"), json.dumps(HELD_CANCELS))
            if len(HELD) > 1 and len(set(map(str, HELD_CANCELS))) >= len(HELD) - 1:
                for held in HELD:
                    send({"jsonrpc": "2.0", "id": held, "result": {}})
                HELD.clear()
            continue
        if hold and m == "session/set_mode":
            HELD.append(rid)
            write_atomic(os.path.join(hold, "held"), str(len(HELD)))
            continue
        # FAKE_SET_MODE_SILENT=1: never answer session/set_mode, while staying alive.
        if m == "session/set_mode" and os.environ.get("FAKE_SET_MODE_SILENT") == "1":
            continue
        bg_once = os.environ.get("FAKE_BG_ONCE")
        if m == "initialize" and bg_once and not os.path.exists(bg_once):
            import subprocess
            open(bg_once, "w").close()
            # PRIO_DARWIN_PROCESS (4), PRIO_DARWIN_BG (0x1000), set from another process.
            lower = "import ctypes, sys; sys.exit(ctypes.CDLL(None).setpriority(4, int(sys.argv[1]), 0x1000))"
            subprocess.run([sys.executable, "-c", lower, str(os.getpid())], check=True)
            send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "start failed at background class"}})
            continue
        if m == "initialize" and os.environ.get("FAKE_DIE_AT_START"):
            sys.stderr.write(os.environ["FAKE_DIE_AT_START"] + "\n")
            sys.stderr.flush()
            sys.exit(1)
        if m in ("session/new", "session/load", "session/fork"):
            LAST_MCP_SERVERS = params.get("mcpServers")
            # FAKE_MCP_OUT=<dir>: each start writes the servers it was given to <dir>/<pid>.json.
            if os.environ.get("FAKE_MCP_OUT"):
                os.makedirs(os.environ["FAKE_MCP_OUT"], exist_ok=True)
                with open(os.path.join(os.environ["FAKE_MCP_OUT"], f"{os.getpid()}.json"), "w") as out:
                    json.dump(LAST_MCP_SERVERS, out)
            LAST_DIRS = params.get("additionalDirectories")
        if m == "session/new" and os.environ.get("FAKE_CLASS_LOG"):
            with open(os.environ["FAKE_CLASS_LOG"], "a") as log:
                nice = os.getpriority(os.PRIO_PROCESS, 0)
                log.write(json.dumps({"pid": os.getpid(), "pri": own_pri(), "nice": nice}) + "\n")
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
        # FAKE_RUN_MCP=<path>: on session/new, run each stdio MCP server the daemon gave, as a
        # harness does (its stdin held open, so it serves until the harness ends), and write
        # their pids to <path>.<this harness pid>.
        if m == "session/new" and os.environ.get("FAKE_RUN_MCP"):
            import subprocess
            pids = []
            for srv in params.get("mcpServers") or []:
                if not srv.get("command"):
                    continue
                env = dict(os.environ)
                env.update({e["name"]: e["value"] for e in srv.get("env") or []})
                proc = subprocess.Popen([srv["command"], *srv.get("args", [])], env=env,
                                        stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL)
                RUNNING_MCP.append(proc)
                pids.append(str(proc.pid))
            out = f"{os.environ['FAKE_RUN_MCP']}.{os.getpid()}"
            with open(f"{out}.tmp", "w") as f:
                f.write("\n".join(pids))
            os.replace(f"{out}.tmp", out)
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
        # FAKE_REQUIRE_KEY_AUTH=1: an agent that signs in with an API key (Antigravity's `agy acp`):
        # it lists "gemini-api-key" and starts, loads or resumes a session only after an
        # authenticate with it, and only when GEMINI_API_KEY is set.
        key_auth = os.environ.get("FAKE_REQUIRE_KEY_AUTH") == "1"
        if m == "authenticate" and key_auth and params.get("methodId") == "gemini-api-key":
            global KEY_SIGNED_IN
            if os.environ.get("GEMINI_API_KEY", "").strip():
                KEY_SIGNED_IN = True
                send({"jsonrpc": "2.0", "id": rid, "result": {}})
            else:
                send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32000, "message": "GEMINI_API_KEY is not set"}})
            continue
        if key_auth and not KEY_SIGNED_IN and m in ("session/new", "session/load", "session/resume"):
            send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32000, "message": "Authentication required"}})
            continue
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
                "agentInfo": {"name": os.environ.get("FAKE_AGENT_NAME", "fake"), "version": "0"},
                "agentCapabilities": {"loadSession": os.environ.get("FAKE_NO_LOAD") != "1", "sessionCapabilities": {} if os.environ.get("FAKE_NO_FORK") == "1" else {"fork": {}},
                                      # FAKE_MCP_HTTP=1: it takes HTTP MCP servers, as Codex
                                      # (cmux-codex-acp) and Claude Code do.
                                      **({"mcpCapabilities": {"http": True, "sse": False}} if os.environ.get("FAKE_MCP_HTTP") == "1" else {}),
                                      # It asks (session/request_permission) before every tool call
                                      # it makes, so it keeps any acpmux policy (acpmux believes it
                                      # only from a harness entry of its config); FAKE_ASK_CLAIM=0
                                      # says nothing, as an agent acpmux cannot trust to ask.
                                      **({} if os.environ.get("FAKE_ASK_CLAIM") == "0" else {"_meta": {"acpmux": {"asksBeforeTools": True}}})},
                "authMethods": [{"id": "gemini-api-key", "name": "Gemini API key"}] if key_auth else [] if not os.environ.get("FAKE_AUTH_FILE") else [
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
            if CLAUDE_STORE:
                new_sid = claude_new(params.get("cwd") or os.getcwd())
            known.add(new_sid)
            result = {
                "sessionId": new_sid,
                "modes": {"currentModeId": "normal", "availableModes": [{"id": "normal", "name": "Normal"}, {"id": "strict", "name": "Strict"}]},
                "configOptions": [{"id": "model", "name": "Model", "type": "select", "currentValue": "m1", "options": [{"value": "m1", "name": "m1"}, {"value": "m2", "name": "m2"}]}],
            }
            if os.environ.get("FAKE_MODE_OPTION") == "1":
                result["configOptions"] = mode_options(new_sid)
            # FAKE_PI_MODES=1: pi-acp 0.0.33's answer: its thinking levels as its `thought_level`
            # option and, for clients older than config options, again as ACP `modes`.
            if os.environ.get("FAKE_PI_MODES") == "1":
                levels = ["off", "minimal", "low", "medium", "high", "xhigh"]
                result["modes"] = {"currentModeId": "medium", "availableModes": [
                    {"id": v, "name": f"Thinking: {v}", "description": None} for v in levels]}
                result["configOptions"].append({"id": "thought_level", "name": "Thinking", "type": "select",
                                                "category": "thought_level", "currentValue": "medium",
                                                "options": [{"value": v, "name": v} for v in levels]})
            # FAKE_NO_MODES=1: an adapter that reports no session modes.
            if os.environ.get("FAKE_NO_MODES") == "1":
                del result["modes"]
            # FAKE_PLAN_MODE=1: opencode's modes, "build" and a "plan" that runs bash.
            if os.environ.get("FAKE_PLAN_MODE") == "1":
                result["modes"] = {"currentModeId": "build", "availableModes": [{"id": "build", "name": "Build"}, {"id": "plan", "name": "Plan"}]}
            # FAKE_PLAN_MODE=claude: Claude's asking modes, "default" and a "plan" that asks.
            if os.environ.get("FAKE_PLAN_MODE") == "claude":
                result["modes"] = {"currentModeId": "default", "availableModes": [{"id": "default", "name": "Default"}, {"id": "plan", "name": "Plan"}]}
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
        elif m == "session/load" and CLAUDE_STORE and not claude_load(params.get("cwd") or os.getcwd(), params["sessionId"]):
            send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "Internal error", "data": {"details": "No conversation found with session ID: " + params["sessionId"]}}})
        elif m == "session/load":
            # FAKE_LOAD_ERROR=<details>: the load fails as codex-acp does while
            # another Codex holds the thread: "Internal error", the reason in data.details.
            if os.environ.get("FAKE_LOAD_ERROR") and not (
                os.environ.get("FAKE_LOAD_RECOVERED") and os.path.exists(os.environ["FAKE_LOAD_RECOVERED"])
            ):
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
            quit_file = os.environ.get("FAKE_QUIT_429_FILE")
            if quit_file and os.path.exists(quit_file):
                with open(quit_file) as f:
                    said = f.read().strip()

                def quit_429(said=said):
                    import time as clock  # main() imports `time` locally
                    clock.sleep(0.3)
                    sys.stderr.write(said + "\n")
                    sys.stderr.flush()
                    clock.sleep(0.2)
                    os._exit(0)

                threading.Thread(target=quit_429, daemon=True).start()
        elif m == "session/fork":
            # FAKE_NO_FORK=1: an agent without session/fork (Kimi, DeepSeek): a bare internal error.
            if os.environ.get("FAKE_NO_FORK") == "1" or os.environ.get("FAKE_FORK_ERROR") == "1":
                send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "Internal error"}})
                continue
            if os.environ.get("FAKE_FORK_SILENT") == "1":
                continue
            sessions += 1
            result = {"sessionId": f"{SESSION_PREFIX}{sessions}"}
            if os.environ.get("FAKE_FORK_REPLAY") == "1":
                new_sid = result["sessionId"]
                update(new_sid, {"sessionUpdate": "available_commands_update", "availableCommands": []})
                update(new_sid, {"sessionUpdate": "user_message_chunk", "messageId": "fork-u1",
                                 "content": {"type": "text", "text": "FORK-REPLAY prompt"}})
                update(new_sid, {"sessionUpdate": "agent_thought_chunk", "messageId": "fork-a1",
                                 "content": {"type": "text", "text": "FORK-REPLAY thought"}})
                update(new_sid, {"sessionUpdate": "tool_call", "toolCallId": "fork-t1", "title": "FORK-REPLAY tool",
                                 "kind": "read", "status": "completed"})
                update(new_sid, {"sessionUpdate": "agent_message_chunk", "messageId": "fork-a1",
                                 "content": {"type": "text", "text": "FORK-REPLAY reply"}})
            # FAKE_FORK_DEFAULTS=1 (with FAKE_PICKER_MODES=claude): the fork's reply reports the
            # harness's defaults, not the forked session's model and effort, as Codex does.
            if os.environ.get("FAKE_FORK_DEFAULTS") == "1":
                result["configOptions"] = [
                    {"id": "effort", "name": "Reasoning", "category": "thought_level", "type": "select", "currentValue": "high",
                     "options": [{"value": v, "name": v} for v in ("low", "medium", "high")]},
                    {"id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": "default",
                     "options": [{"value": v, "name": n} for v, n in CLAUDE_MODELS]}]
            if os.environ.get("FAKE_FORK_DELAY_MS"):
                reply = {"jsonrpc": "2.0", "id": rid, "result": result}
                threading.Timer(int(os.environ["FAKE_FORK_DELAY_MS"]) / 1000, send, args=(reply,)).start()
                continue
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
                    # FAKE_OPTION_HOLD=<path>: a mode option change writes its value to
                    # <path>.held and holds its answer while <path> exists (at most 30 s).
                    hold = os.environ.get("FAKE_OPTION_HOLD")
                    if hold and os.path.exists(hold):
                        import time as pause  # main() binds `time` locally
                        with open(hold + ".held.tmp", "w") as f:
                            f.write(f"{v}\n")
                        os.replace(hold + ".held.tmp", hold + ".held")
                        until = pause.monotonic() + 30
                        while os.path.exists(hold) and pause.monotonic() < until:
                            pause.sleep(0.05)
                # FAKE_BARE_OPTION_ANSWER=1: the answer carries no configOptions; =null: a null;
                # =mode: none for a mode option change only.
                bare = os.environ.get("FAKE_BARE_OPTION_ANSWER")
                bare_mode = bare == "mode" and params.get("configId") == "mode"
                if os.environ.get("FAKE_BARE_OPTION_ANSWER") == "1" or bare_mode:
                    send({"jsonrpc": "2.0", "id": rid, "result": {}})
                    continue
                if os.environ.get("FAKE_BARE_OPTION_ANSWER") == "null":
                    send({"jsonrpc": "2.0", "id": rid, "result": {"configOptions": None}})
                    continue
                send({"jsonrpc": "2.0", "id": rid, "result": {"configOptions": mode_options(params.get("sessionId"))}})
                continue
            send({"jsonrpc": "2.0", "id": rid, "result": {"configOptions": [{"id": "model", "name": "Model", "type": "select", "currentValue": v, "options": []}]}})
        elif m == "session/prompt":
            if FAKE_USAGE_UPDATES is not None:
                prompt_sessions[rid] = params.get("sessionId")
            if os.environ.get("FAKE_LOAD_GATE") and params.get("sessionId") not in known:
                send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32002, "message": "Session not found"}})
                continue
            target = codex_prompt if os.environ.get("FAKE_CODEX_STEER") == "1" else handle_prompt
            if os.environ.get("FAKE_CLAUDE_STEER") == "1":
                target = claude_prompt
            if CODEX_STORE:
                target = codex_store_prompt
            if CLAUDE_STORE and params.get("sessionId") in claude_files:
                claude_write(params["sessionId"], {"type": "fake-prompt", "text": prompt_text(params)})
            threading.Thread(target=target, args=(rid, params), daemon=True).start()
            # FAKE_ASK_HOLDS_STDIN=<path>: after an "ask:" prompt, read nothing more until that
            # file exists: a long answer then waits in the agent host's stdin writer, as it does
            # for a harness that stopped reading.
            hold = os.environ.get("FAKE_ASK_HOLDS_STDIN")
            if hold and prompt_text(params).startswith("ask:"):
                import time as clock  # main() binds `time` locally
                while not os.path.exists(hold):
                    clock.sleep(0.02)
        elif m == "_session/goal":
            # codex-acp's goal control. FAKE_GOAL_LOG=<path>: append its params as one JSON line.
            # Unanswered, as codex-acp answers a `set` only once the goal's turns are over.
            path = os.environ.get("FAKE_GOAL_LOG")
            if path:
                with open(path, "a") as f:
                    f.write(json.dumps(params) + "\n")
        elif m == "session/cancel":
            cancelled.add(params.get("sessionId"))
        elif m == "_acpmux/steer_withdraw" and os.environ.get("FAKE_CLAUDE_STEER") == "1":
            # A steer still unread is dropped; one read already (or none) stays.
            with lock:
                prompt_id = params.get("promptId")
                # FAKE_STEER_KEEP=1: it cannot take one back (codex-acp; a batched line).
                dropped = prompt_id in claude_unread and os.environ.get("FAKE_STEER_KEEP") != "1"
                if dropped:
                    claude_withdrawn.add(prompt_id)
            send({"jsonrpc": "2.0", "id": rid, "result": {"withdrawn": dropped}})
        elif rid is not None:
            send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "no such method"}})


if __name__ == "__main__":
    main()
