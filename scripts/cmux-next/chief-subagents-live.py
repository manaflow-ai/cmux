#!/usr/bin/env python3
"""Live proof of the Chief's subagent orchestration in a real tagged app (cmux-lawrence-2 only).

Launches the tagged app (no-activate, scratch config, an isolated Chief home),
drives the real Chief through the Home composer (`debug.home.drive`) and its
tools socket (`optchat/tools.sock`: spawn, zoom, engine, stop, the same calls
its harness makes), and checks each flow against the Chief's memory
(`optchat/memory.sqlite3`), its trace (`optchat/traces`), acpmux (`acpmux ls`,
`acpmux cancel`) and the process table. Prints one row per flow:
flow | expected | observed | pass/fail. While it runs it records the app
window (`debug.window_snapshot` about once a second) into OUT/frames, and
makes OUT/recording.mp4 when ffmpeg is on PATH.

Flows: three parallel subagents on a real task and the Chief's combined
answer; the Chief answering while they run (and its "at work" line); zoom of
a subagent's chat; stopping one subagent (quiet report, no Chief turn); a
failed subagent (a failure report, no hang); the cap of 16 (a 17th queues and
starts when one finishes); chief.stop (every subagent stops: session state
and processes); a Chief host restart mid-run (each report once); subagents on
the Chief's harness (claude and codex).

On exit it quits the app with quitEndSessions, shuts down the tag's acpmux
daemon and stops the tag's cmux-tui session; leftovers of this tag's bundle
are ended by exact PID.

Usage: chief-subagents-live.py --tag <tag> --app PATH --debug-cli PATH --derived-data DIR [--out DIR] [--only a,b]
"""
import argparse, glob, json, os, re, shutil, signal, socket, sqlite3, subprocess, sys, tempfile, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--debug-cli", required=True)
parser.add_argument("--derived-data", required=True)
parser.add_argument("--out", default="/tmp")
parser.add_argument("--turn-timeout", type=float, default=600)
parser.add_argument("--only", default="", help="comma-separated flow names")
parser.add_argument("--keep", action="store_true")
parser.add_argument("--cloud", action="store_true", help="also prove a server brain's subagent (staging pairing, cleaned up)")
parser.add_argument("--creds", default="", help="the cloud flow signs the app in with this credentials file (never read here)")
parser.add_argument("--account", default="lawrence@manaflow.ai")
parser.add_argument("--no-home-workarounds", action="store_true",
                    help="no Home cache removal and no resend after 90 s: a lost first send fails its row (cx-ebm.55 fix)")
parser.add_argument("--cli-first", action="store_true",
                    help="before the app: `cmux chief -p` (no app) spawns a subagent; the app must then show its live chat")
opts = parser.parse_args()

TAG = opts.tag
APP = opts.app
BINARY = os.path.join(APP, "Contents/MacOS/cmux DEV")
ACPMUX = os.path.join(APP, "Contents/Resources/bin/acpmux")
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
MUX_HOME = os.path.expanduser(f"~/.cmux/chief/isolated/{TAG}")
OPTCHAT = os.path.join(MUX_HOME, "optchat")
ACPMUX_HOME = os.path.join(MUX_HOME, "acpmux")
SCRATCH = tempfile.mkdtemp(prefix=f"chief-subagents-{TAG}-")


def fnv1a32(text):
    """optchat-chief `paths::home_id`: FNV-1a 32 of the home's path, 8 lowercase hex digits."""
    h = 0x811C9DC5
    for b in text.encode():
        h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF
    return f"{h:08x}"


HOME_ID = fnv1a32(MUX_HOME)
WORK = os.path.join(SCRATCH, "work")
FRAMES = os.path.join(opts.out, "frames")
os.makedirs(FRAMES, exist_ok=True)
ROWS = []
STOP_RECORDING = threading.Event()


# --- plumbing -----------------------------------------------------------------

def rpc(method, params=None, timeout=30):
    """One request on the tagged app's control socket."""
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCKET)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def tools(request, timeout=300):
    """One request on the Chief's tools socket (what its harness calls)."""
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(os.path.join(OPTCHAT, "tools.sock"))
        conn.sendall((json.dumps(request) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        conn.close()
        return json.loads(buf)
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def acpmux(*args, timeout=60):
    env = {**os.environ, "ACPMUX_HOME": ACPMUX_HOME, "ACPMUX_SOCKET": os.path.join(ACPMUX_HOME, "acpmux.sock")}
    out = subprocess.run([ACPMUX, *args], env=env, capture_output=True, text=True, timeout=timeout)
    return out.stdout + out.stderr


def acpmux_rpc(method, params, timeout=30):
    """One JSON-RPC request on the tag's acpmux socket (newline framed)."""
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(os.path.join(ACPMUX_HOME, "acpmux.sock"))
        conn.sendall((json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}) + "\n").encode())
        buf = b""
        while True:
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
            for line in buf.split(b"\n"):
                if not line.strip():
                    continue
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                if msg.get("id") == 1:
                    conn.close()
                    return msg.get("result") or {"error": msg.get("error")}
        conn.close()
    except OSError as error:
        return {"error": str(error)}
    return {"error": "no answer"}


def session_status(session_id):
    found = acpmux_rpc("_acpmux/sessions", {}) or {}
    for s in found.get("sessions", []) if isinstance(found, dict) else []:
        if s.get("sessionId") == session_id:
            return s.get("status")
    return None


def tagged(*args):
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
    env.update(CMUX_TAG=TAG, CMUX_DERIVED_DATA=opts.derived_data)
    out = subprocess.run([opts.debug_cli, "--json", *args], env=env, capture_output=True, text=True, timeout=60)
    try:
        return json.loads(out.stdout)
    except ValueError:
        return {"error": (out.stdout + out.stderr).strip()[:400]}


def workspaces():
    """Every workspace the app shows, on every machine row (the Chief's owner daemon included):
    the app's topology (`snapshot.get`). `workspace list` names only the app's own session."""
    return ((rpc("snapshot.get") or {}).get("topology") or {}).get("workspaces", []) or app_workspaces()


def app_workspaces():
    value = tagged("workspace", "list")
    if isinstance(value, dict):
        value = value.get("value", value)
    if isinstance(value, dict):
        value = value.get("workspaces", value.get("items", []))
    return value if isinstance(value, list) else []


def ws_name(ws):
    return ws.get("name") or ws.get("title") or ""


def app_ws(ws_id):
    snap = rpc("snapshot.get") or {}
    for ws in (snap.get("topology") or {}).get("workspaces", []):
        if ws.get("id") == ws_id:
            return json.dumps(ws)
    return ""


def wait(predicate, seconds, step=1.0):
    end = time.time() + seconds
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # test harness wait, not app code
    return None


def memory(query, args=()):
    path = os.path.join(OPTCHAT, "memory.sqlite3")
    if not os.path.exists(path):
        return []
    try:
        db = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=5)
        try:
            return db.execute(query, args).fetchall()
        finally:
            db.close()
    except sqlite3.Error:
        return []


def log_items():
    return [{"kind": k, "text": t} for k, t in memory("SELECT kind, text FROM messages ORDER BY id")]


def host_state():
    """The host state rows (`host/<key>`) as one dict."""
    out = {}
    for key, value in memory("SELECT key, value FROM state WHERE key LIKE 'host/%'"):
        try:
            out[key[len("host/"):]] = json.loads(value)
        except ValueError:
            pass
    return out


def subs():
    """Every subagent record by id, with its spawn."""
    spawns = host_state().get("spawns") or {}
    found = {}
    for spawn, record in spawns.items():
        for sub in record.get("subs", []):
            found[sub["id"]] = {**sub, "spawn": spawn}
    return found


def trace():
    events = []
    for path in sorted(glob.glob(os.path.join(OPTCHAT, "traces", "*.jsonl"))):
        for line in open(path, errors="replace"):
            try:
                events.append(json.loads(line))
            except ValueError:
                pass
    return events


def reports(ids=None):
    """The `[aN] ...` report items in the log, oldest first."""
    out = []
    for item in log_items():
        m = re.match(r"\[(a\d+)\] ", item["text"]) if item["kind"] == "user" else None
        if m and (ids is None or m.group(1) in ids):
            out.append((m.group(1), item["text"]))
    return out


def turn_starts():
    return [e for e in trace() if e.get("ev") == "turn.start"]


def row(flow, expected, observed, ok):
    ROWS.append((flow, expected, observed, ok))
    print(f"| {flow} | {expected} | {observed} | {'pass' if ok else 'FAIL'} |", flush=True)


def snapshot(name):
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"{len(ROWS) + 1:02d}-{name}.png")})


def recorder():
    k = 0
    while not STOP_RECORDING.is_set():
        rpc("debug.window_snapshot", {"path": os.path.join(FRAMES, f"frame-{k:05d}.png")}, timeout=10)
        k += 1
        STOP_RECORDING.wait(1.0)


def chief_conversation():
    home = rpc("debug.home") or {}
    return next((c for c in home.get("conversations", []) if "agent_mux" in c.get("participants", [])), None)


def host_log():
    try:
        return open(os.path.join(MUX_HOME, "host.log"), errors="replace").read()
    except OSError:
        return ""


def show_home():
    rpc("action.run", {"id": "home.show"})
    wait(lambda: (rpc("debug.home.drive", {"action": "geometry"}) or {}).get("ok"), 20)


def ask(text, wait_reply=True):
    """Sends `text` through the Home composer; with wait_reply, the Chief's final reply of that turn."""
    show_home()
    before = len(log_items())
    for action, extra in (("focus", {}), ("type", {"text": text}), ("send", {})):
        reply = rpc("debug.home.drive", {"action": action, **extra})
        if not (isinstance(reply, dict) and reply.get("ok")):
            return f"(drive {action} failed: {reply})"
    # Its index + 1 (index 0 is a found message, and wait() takes only a truthy value).
    def logged():
        return next((i + 1 for i, m in enumerate(log_items()) if i >= before and m["kind"] == "user"
                     and text[:40] in m["text"]), None)
    found = wait(logged, opts.turn_timeout if opts.no_home_workarounds else 90)
    if found is None and opts.no_home_workarounds:
        print(f"home send lost: {text[:60]!r} not logged ({json.dumps(rpc('debug.home') or {})[:400]})", flush=True)
    elif found is None:
        # A send before Home's owner connection took it stays a draft: show Home and send again.
        print(f"ask: not logged after 90 s ({json.dumps(rpc('debug.home') or {})[:300]}); sending again", flush=True)
        show_home()
        for action, extra in (("focus", {}), ("type", {"text": text}), ("send", {})):
            rpc("debug.home.drive", {"action": action, **extra})
        found = wait(logged, opts.turn_timeout)
    mine = None if found is None else found - 1
    if mine is None:
        return "(my message never reached the Chief's log)"
    if not wait_reply:
        return ""

    def done():
        items = log_items()
        talks = [m for m in items[mine + 1:] if m["kind"] == "talk"]
        return talks[-1]["text"] if talks and items[-1]["kind"] == "talk" else None
    reply = wait(done, opts.turn_timeout, step=3)
    time.sleep(4)  # a turn that goes on after a talk item logs more
    return (done() or reply) or "(no reply)"


def agent_tab(ws_id):
    """The id of the agent chat tab in the app's tree of workspace `ws_id` (snapshot.get)."""
    found = []

    def walk(node):
        if isinstance(node, dict):
            # A tab (it has a surface) that is not the workspace's terminal: the agent chat.
            if isinstance(node.get("id"), str) and "surface" in node and node.get("kind") not in ("terminal", "pty", None):
                found.append(node["id"])
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)
    tree_text = app_ws(ws_id)
    walk(json.loads(tree_text) if tree_text else {})
    return found[0] if found else None


def focus_workspace(ws_id, name):
    """Shows the subagent's agent tab in the window (`tab.focus`, as `cmux tab <id> focus`)."""
    tab = wait(lambda: agent_tab(ws_id), 30)
    shown = rpc("tab.focus", {"tab": tab}) if tab else {"error": "no agent tab in the app tree"}
    print(f"focus {name}: tab {tab} -> {json.dumps(shown)[:160]}", flush=True)
    wait(lambda: not (rpc("debug.agent_pane", {"action": "chat_state"}) or {}).get("error"), 30)
    time.sleep(3)  # test harness: let the agent pane render its transcript
    snapshot(name)


def host_pid(session_id):
    """The agent host acpmux started for this run's subagent session (its host_started event)."""
    if not session_id:
        return None
    events = (acpmux_rpc("_acpmux/events", {"sessionId": session_id, "afterSeq": 0, "limit": 10000}) or {}).get("events", [])
    pids = [e.get("msg", {}).get("hostPid") for e in events if e.get("kind") == "host_started"]
    return int(pids[-1]) if pids and pids[-1] else None


def tree(roots):
    """The live processes under this run's own agent hosts (roots included), as 'pid command' lines."""
    rows = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,command="], capture_output=True, text=True).stdout
    children, command = {}, {}
    for line in rows.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3:
            children.setdefault(int(parts[1]), []).append(int(parts[0]))
            command[int(parts[0])] = parts[2]
    out, todo = [], [r for r in roots if r in command]
    while todo:
        pid = todo.pop()
        out.append(f"{pid} {command.get(pid, '')}")
        todo.extend(children.get(pid, []))
    return out


def processes(pattern, ids=None):
    """Lines of `pattern` processes under the agent hosts of these subagents (default: all of this run's)."""
    found = subs()
    roots = [host_pid(found[i].get("session_id")) for i in (ids or found) if i in found]
    return [line for line in tree([r for r in roots if r]) if pattern in line]


def type_in_pane(text):
    """Types `text` into the shown agent pane; a first send in an untrusted folder asks to trust it,
    and the proof clicks Trust as the user does."""
    sent = rpc("debug.agent_pane", {"action": "send_prompt", "text": text})
    if "trust.pending" in json.dumps(sent):
        # The ask renders after the refusal comes back.
        clicked = wait(lambda: (lambda r: r if not r.get("error") else None)(
            rpc("debug.agent_pane", {"action": "click", "text": "Trust"}) or {"error": "none"}), 30)
        print("trust:", json.dumps(clicked)[:200], flush=True)
        # The refused prompt never went (acpmux trust_gate: it goes back to the composer), so
        # the user sends it again after Trust, as the proof does.
        again = wait(lambda: (lambda r: r if "trust.pending" not in json.dumps(r) else None)(
            rpc("debug.agent_pane", {"action": "send_prompt", "text": text})), 30)
        sent = {"first": sent, "trusted": clicked, "again": again}
    return sent


def pane_text(state):
    """The chat text the shown agent pane renders (chat_state `transcript`), one string."""
    rows = (state or {}).get("transcript") if isinstance(state, dict) else None
    return "\n".join(f"{r.get('kind')}: {r.get('text')}" for r in rows or [])


def engine(**fields):
    request = {"tool": "engine", "action": "set" if fields else "show"}
    request.update({k: v for k, v in fields.items() if v is not None})
    return tools(request)


def spawn(tasks, cwd=None):
    request = {"tool": "spawn", "tasks": tasks}
    if cwd:
        request["cwd"] = cwd
    return tools(request, timeout=600)


def ids_in(answer):
    return re.findall(r"- (a\d+):", json.dumps(answer).replace("\\n", "\n"))


def wait_done(ids, seconds):
    return wait(lambda: all(subs().get(i, {}).get("status") in ("done", "reported") for i in ids), seconds, step=3)


# --- flows --------------------------------------------------------------------

FLOWS = []


def flow(fn):
    FLOWS.append(fn)
    return fn


@flow
def parallel_three():
    """3 parallel subagents on a real task; the Chief combines their reports."""
    for name, n in (("alpha", 3), ("beta", 5), ("gamma", 7)):
        with open(os.path.join(WORK, f"{name}.txt"), "w") as f:
            f.write("".join(f"{name} line {k}\n" for k in range(n)))
    start = {w.get("id") for w in workspaces()}
    reply = ask(
        f"Use your spawn tool to start exactly three subagents in parallel, with cwd {WORK}: one counts the lines "
        "of alpha.txt, one of beta.txt, one of gamma.txt; each runs `sleep 90` before it replies with only its "
        "count. Do not count them yourself. When all three reports are in, tell me the total.")
    print("chief:", reply[:400], flush=True)
    if reply.startswith("("):
        row("3 workspaces with live agent panes", "the Chief spawns 3 subagents", f"no Chief turn: {reply}", False)
        return
    spawned = wait(lambda: [i for i, s in subs().items() if s.get("session_id")] if len(subs()) >= 3 else None, 120) or []
    # hq-6d 2026-10-09 (parity timing): a spawn in a turn starts its subagents at once with the
    # turn's view; it never waits for the compactor to summarize the turn's own tool call.
    waits = [e.get("settle_ms") for e in trace() if e.get("ev") == "spawn"]
    row("spawn starts its subagents at once", "the spawn tool waits under 1.5 s before its subagents start",
        f"spawn waits (ms) {waits}", bool(waits) and all((w or 0) < 1500 for w in waits))
    # The Chief answers a user message while they run: asked first, inside their `sleep 90`
    # (the pane checks below take minutes, so asked after them nothing ran any more).
    running = wait(lambda: [i for i, s in subs().items() if s.get("status") == "running"] or None, 120) or []
    starts = len(turn_starts())
    answer = ask("While they work: what is 17 times 3? Answer with only the number.")
    still = [i for i, s in subs().items() if s.get("status") == "running"]
    new = wait(lambda: [w for w in workspaces() if w.get("id") not in start and re.match(r"a\d+ · ", ws_name(w))]
               if len([w for w in workspaces() if re.match(r"a\d+ · ", ws_name(w))]) >= 3 else None, 120) or []
    tabs = [w for w in new if agent_tab(w.get("id"))]
    # hq-6d 2026-10-09: subagent workspaces always live in the Chief's owner daemon (its machine
    # row, server-host_chief<home id>), also when the app started the Chief, so they outlive the app.
    rows = {w.get("id"): str(w.get("machine") or "") for w in ((rpc("snapshot.get") or {}).get("topology") or {}).get("workspaces", [])}
    machines = [rows.get(w.get("id"), "") for w in new]
    row("subagent workspaces in the Chief's owner daemon", "each subagent workspace is on the Chief row",
        f"machines {machines}", len(machines) >= 3 and all(m.startswith("server-host_chief") for m in machines))
    # Each pane must show its subagent's own chat: the chat text the pane renders names its file.
    shown = []
    for w in new[:3]:
        focus_workspace(w.get("id"), f"workspace-{ws_name(w).split(' ')[0]}")
        file = next((f for f in ("alpha", "beta", "gamma") if f in ws_name(w)), "lines of")
        state = wait(lambda: (lambda st: st if file in pane_text(st) else None)(
            rpc("debug.agent_pane", {"action": "chat_state"})), 60) or rpc("debug.agent_pane", {"action": "chat_state"})
        shown.append(file in pane_text(state) and not (state or {}).get("missingSession"))
    show_home()
    row("3 workspaces with live agent panes", "3 subagent workspaces; each pane's chat text names its own file",
        f"subagents {sorted(spawned)}, workspaces {[ws_name(w) for w in new]}, with agent tab {len(tabs)}, own transcript shown {shown}",
        len(new) >= 3 and len(tabs) >= 3 and len(shown) == 3 and all(shown))
    row("Chief answers while subagents run", "51 while at least one subagent is running",
        f"reply {answer[:40]!r}; running before {running}, after {still}", "51" in answer and bool(running))
    at_work = [e.get("layout", {}).get("at_work") for e in turn_starts()[starts:]]
    named = [a for a in at_work if a]
    row("at-work line matches", "the turn's line names the running subagents",
        f"lines {named}; running then {running}",
        bool(named) and all(i in named[0] for i in running if i in still))
    ids = sorted(i for i in subs() if i in {s for s in spawned})
    wait_done(ids, 600)
    total = wait(lambda: next((m["text"] for m in reversed(log_items()) if m["kind"] == "talk" and "15" in m["text"]), None),
                 opts.turn_timeout, step=3)
    got = reports(set(ids))
    once = all(sum(1 for i, _ in got if i == x) == 1 for x in ids)
    snapshot("combined")
    row("per-agent reports and combined answer", "3 reports, each once, any order; the Chief says 15",
        f"reports {[i for i, _ in got]}; total reply {(total or '')[:120]!r}", len(got) == 3 and once and bool(total))
    zoom = tools({"tool": "zoom", "id": ids[0]}).get("text", "") if ids else ""
    row("zoom(a<N>) opens the full log", "task, tool calls and reply of the subagent",
        f"{len(zoom)} chars; task={'Your task' in zoom}, tool={'|tool: ' in zoom}, talk={'|talk: ' in zoom}",
        "Your task" in zoom and "|tool: " in zoom and "|talk: " in zoom)


@flow
def type_into_pane():
    """The user types into a subagent's agent pane: it answers, and its new report reaches the Chief."""
    answer = spawn(["Reply with only the word ready."])
    ids = ids_in(answer)
    wait_done(ids, 300)
    ws = wait(lambda: next((w for w in workspaces() if ws_name(w).startswith("✓ " + ids[0] + " ")), None) if ids else None, 60)
    if ws:
        focus_workspace(ws.get("id"), f"pane-{ids[0]}-before")
    state = rpc("debug.agent_pane", {"action": "chat_state"})
    sent = type_in_pane("Reply with only the word banana.")
    got = wait(lambda: [t for i, t in reports({ids[0]}) if "banana" in t.lower()] if ids else None, 300, step=3)
    inputs = [e for e in trace() if e.get("ev") == "subagent.input" and e.get("id") == (ids[0] if ids else None)]
    if ws:
        focus_workspace(ws.get("id"), f"pane-{ids[0]}-after")
    show_home()
    row("type into a subagent pane", "the typed message reaches the subagent; its new report reaches the Chief",
        f"pane state {json.dumps(state)[:120]}; send {json.dumps(sent)[:80]}; user inputs traced {len(inputs)}; "
        f"report {(got or [''])[0][:80]!r}", bool(got) and bool(inputs))


@flow
def stop_one():
    """Stopping one subagent: its report is logged quietly, no Chief turn."""
    answer = spawn([f"Run `sleep 121` in {WORK}, then reply done."])
    ids = ids_in(answer)
    sid = wait(lambda: subs().get(ids[0], {}).get("session_id") if ids else None, 60)
    wait(lambda: processes("sleep 121", ids), 180)
    starts = len(turn_starts())
    out = acpmux("cancel", sid) if sid else "(no session)"
    stopped = wait(lambda: subs().get(ids[0], {}).get("stopped") or subs().get(ids[0], {}).get("status") == "done", 90)
    time.sleep(10)  # test harness: give a wrong wake time to show
    quiet = len(turn_starts()) == starts
    ask("Thanks. Anything new from your subagents?")
    logged = [t for i, t in reports({ids[0]}) if "(stopped by the user)" in t] if ids else []
    row("stop one subagent", "report logged with the next turn, no Chief turn of its own",
        f"cancel {out.strip()[:60]!r}; stopped={bool(stopped)}; no turn={quiet}; logged={logged[:1]}",
        bool(stopped) and quiet and bool(logged))


@flow
def failure():
    """A subagent whose harness dies reports a failure, never hangs."""
    answer = spawn([f"Run `sleep 122` in {WORK}, then reply done."])
    ids = ids_in(answer)
    sid = wait(lambda: subs().get(ids[0], {}).get("session_id") if ids else None, 60)
    wait(lambda: processes("sleep 122", ids), 180)
    pid = host_pid(sid)
    if pid:
        os.kill(int(pid), signal.SIGKILL)  # this run's subagent host, by exact pid
    got = wait(lambda: reports({ids[0]}) if ids else None, 300, step=3) or []
    text = got[-1][1] if got else ""
    row("failed subagent", "a failure report, no hang",
        f"killed host {pid}; report {text[:120]!r}",
        bool(pid) and bool(re.search(r"failed|stopped without a report|gone", text)))


@flow
def cap_queue_and_chief_stop():
    """16 at work, a 17th queues and starts when one finishes; chief.stop stops them all."""
    long = [f"Run `sleep 93` in {WORK}, then reply ok {k}." for k in range(8)]
    a = spawn(long)
    b = spawn(long)
    c = spawn([f"Run `sleep 93` in {WORK}, then reply seventeen."])
    queued = "queued" in json.dumps(c)
    seventeenth = ids_in(c)
    # One of the 16 is stopped (acpmux cancel, as the pane's stop): its slot frees, the 17th starts.
    first = (ids_in(a) or [None])[0]
    wait(lambda: subs().get(first, {}).get("session_id"), 120)
    acpmux("cancel", subs().get(first, {}).get("session_id") or "")
    started = wait(lambda: subs().get(seventeenth[0], {}).get("session_id") if seventeenth else None, 300)
    row("17th spawn queues under the cap of 16", "queued, then starts when one finishes",
        f"answer queued={queued}; started session={started}", queued and bool(started))
    wait(lambda: len(processes("sleep 93")) >= 8, 180)
    live = [i for i, s in subs().items() if s.get("status") in ("running", "starting")]
    sleeps = len(processes("sleep 93"))
    stop = tools({"tool": "stop"})
    gone = wait(lambda: not processes("sleep 93"), 120)
    statuses = {i: session_status(subs()[i].get("session_id")) for i in live if subs().get(i, {}).get("session_id")}
    idle = all(s not in ("running", "waiting") for s in statuses.values())
    row("chief.stop stops every subagent", "all at work stop: sessions idle, their sleep processes gone",
        f"stop {json.dumps(stop)[:160]}; sleep 93 under their hosts before {sleeps}, after {len(processes('sleep 93'))}; "
        f"sessions {sorted(set(statuses.values()))}",
        bool(stop.get("stopped")) and sleeps > 0 and bool(gone) and idle)


@flow
def restart_mid_run():
    """A Chief host restart while subagents run: each report arrives once."""
    answer = spawn([f"Run `sleep 40` in {WORK}, then reply one.", f"Run `sleep 40` in {WORK}, then reply two."])
    ids = ids_in(answer)
    wait(lambda: all(subs().get(i, {}).get("session_id") for i in ids), 60)
    lock = os.path.join(MUX_HOME, "state", "host.lock")
    pid = int(open(lock).read().split()[0])
    os.kill(pid, signal.SIGTERM)  # the Chief host this run's app started, by exact pid
    # The app restarts too, keeping sessions (acpmux and the subagents run on); its launch starts a new host.
    rpc("action.run", {"action": "quitKeepSessions"}, timeout=10)
    try:
        app.wait(timeout=60)
    except subprocess.TimeoutExpired:
        pass
    launch_app()
    show_home()
    back = wait(lambda: os.path.exists(lock) and open(lock).read().split()[:1] not in ([str(pid)], [])
                and os.path.exists(os.path.join(OPTCHAT, "tools.sock")), 300)
    wait_done(ids, 300)
    wait(lambda: len(reports(set(ids))) >= len(ids), 300, step=3)
    time.sleep(20)  # test harness: a duplicate would come now
    got = reports(set(ids))
    counts = {i: sum(1 for x, _ in got if x == i) for i in ids}
    row("host restart mid-run", "the host comes back; each report once",
        f"host {pid} -> back={bool(back)}; report counts {counts}", bool(back) and all(v == 1 for v in counts.values()))


@flow
def subagent_link_opens_its_chat():
    """Lawrence 2026-10-09: "you need to be able to link to a subagent so I can just click here to
    get to it". The Chief names its new subagent as a link, Home renders it as a link, and a click
    (Home's own click path) shows that subagent's workspace with its chat tab."""
    reply = ask(f"Use spawn to start exactly one subagent with cwd {WORK} whose task is: reply with only the "
                "word link-probe. Then tell me its name, written as its link from the spawn answer.")
    print("chief:", reply[:300], flush=True)
    sub = wait(lambda: next((i for i, v in subs().items() if v.get("session_id") and "link-probe" in (v.get("title") or "")), None), 120)
    session = (subs().get(sub) or {}).get("session_id")
    show_home()
    snapshot("link-home")
    # This subagent's own link (earlier replies link other subagents).
    clicked = rpc("debug.home.drive", {"action": "link", "prefix": f"cmux://chief/{HOME_ID}/session/{session}"}) or {}
    print("link click:", json.dumps(clicked)[:300], flush=True)
    state = wait(lambda: (lambda st: st if st.get("sessionId") == session else None)(
        rpc("debug.agent_pane", {"action": "chat_state"}) or {}), 30) or rpc("debug.agent_pane", {"action": "chat_state"}) or {}
    time.sleep(3)  # test harness: let the agent pane render its transcript
    snapshot("link-opened")
    url = clicked.get("url") or ""
    row("subagent link opens its chat", "Home shows the subagent as a link; a click shows its workspace and chat",
        f"sub {sub}; model wrote a link={'](cmux://chief/' in reply}; clicked {url[:90]!r}; pane session {state.get('sessionId')} "
        f"(want {session}); task in pane={'link-probe' in pane_text(state)}",
        # The model writes the plain id (the memory keeps no URL); the posted reply carries the
        # link (link_subagents), so the click on this subagent's own link is the proof.
        bool(session) and url.endswith("/session/" + session)
        and state.get("sessionId") == session and "link-probe" in pane_text(state))
    show_home()


@flow
def subagent_mentions_are_links():
    """Lawrence 2026-10-10: "it should be able to link to subagents in general too". A later Chief
    reply that names its subagents, with no link written by the model, shows each one as a link;
    a click on a2's opens a2's workspace and chat."""
    answer = spawn(["Reply with only the word mention-one.", "Reply with only the word mention-two."])
    ids = ids_in(answer)
    print("spawn:", json.dumps(answer)[:400], flush=True)
    wait_done(ids, 300)
    reply = ask(f"In one plain sentence with no links and no markdown, say what {' and '.join(ids)} did.")
    if reply.startswith("(my message"):  # the composer was not shown yet after the last flow's tab
        reply = ask(f"In one plain sentence with no links and no markdown, say what {' and '.join(ids)} did.")
    print("chief:", reply[:300], flush=True)
    second = ids[1] if len(ids) > 1 else None
    session = (subs().get(second) or {}).get("session_id") if second else None
    last = next((m["text"] for m in reversed(log_items()) if m["kind"] == "talk"), "")
    show_home()
    snapshot("mentions-home")
    clicked = rpc("debug.home.drive", {"action": "link", "prefix": "cmux://chief/"} if not session else
                  {"action": "link", "prefix": f"cmux://chief/{HOME_ID}/session/{session}"}) or {}
    print("mention click:", json.dumps(clicked)[:300], flush=True)
    state = wait(lambda: (lambda st: st if session and st.get("sessionId") == session else None)(
        rpc("debug.agent_pane", {"action": "chat_state"}) or {}), 30) or rpc("debug.agent_pane", {"action": "chat_state"}) or {}
    time.sleep(3)  # test harness: let the agent pane render its transcript
    snapshot("mentions-opened")
    row("subagent mentions are links", "the reply names a2 as a link; a click opens a2's workspace and chat",
        f"ids {ids}; model wrote a link={'](cmux://' in last}; clicked {(clicked.get('url') or '')[:90]!r}; "
        f"pane session {state.get('sessionId')} (want {session})",
        bool(session) and (clicked.get("url") or "").endswith(f"/session/{session}")
        and state.get("sessionId") == session and "mention-two" in pane_text(state))
    show_home()


def pane_grid(pane):
    """The terminal pane's viewport text and grid (`debug.surfaces`): cell size and grid origin in
    window points from the top-left, as `debug.mouse` takes them."""
    report = rpc("debug.surfaces", {"text": True}) or {}
    for window in report.get("windows", []):
        for p in window.get("panes", []):
            if p.get("pane") == pane:
                return p.get("text") or "", p.get("grid")
    return "", None


@flow
def cli_osc8_link_opens_the_subagent():
    """Lawrence 2026-10-10: a Cmd-click on a subagent's name in any terminal opens it. `cmux chief
    -p` in a cmux terminal spawns a subagent and prints its name as an OSC 8 hyperlink; a REAL
    Cmd-click (`debug.mouse`) on that cell goes through Ghostty's own hyperlink hit path and the
    app's link.open, and shows the subagent's workspace and chat."""
    os.makedirs(WORK, exist_ok=True)
    def terminals():
        return [p for w in (rpc("debug.surfaces") or {}).get("windows", []) for p in w.get("panes", [])
                if p.get("kind") == "terminal" and p.get("selected_tab")]
    before = {p.get("pane") for p in terminals()}
    made = rpc("action.run", {"action": "newTab"})  # New Workspace: one terminal pane
    print("new workspace:", json.dumps(made)[:200], flush=True)
    # The new workspace may not be the shown one (Home is): show its terminal tab (`tab.focus`).
    ws_id = ((made or {}).get("created") or [None])[0]
    def terminal_tab():
        found = []
        def walk(node):
            if isinstance(node, dict):
                if isinstance(node.get("id"), str) and "surface" in node and node.get("kind") in ("terminal", "pty"):
                    found.append(node["id"])
                for v in node.values():
                    walk(v)
            elif isinstance(node, list):
                for v in node:
                    walk(v)
        text = app_ws(ws_id) if ws_id else ""
        walk(json.loads(text) if text else {})
        return found[0] if found else None
    tab = wait(terminal_tab, 30)
    print("terminal tab:", tab, json.dumps(rpc("tab.focus", {"tab": tab}) if tab else {})[:160], flush=True)
    term = wait(lambda: next((p for p in terminals() if p.get("pane") not in before), None), 60)
    if not term:
        row("terminal OSC 8 link opens the subagent", "a new workspace's terminal", f"made {json.dumps(made)[:120]}; terminals {len(terminals())}", False)
        return
    prompt = (f"Use spawn to start exactly one subagent with cwd {WORK} whose task is: reply with only the word "
              "osc8-probe. Then name it in one short sentence.")
    command = f"CMUX_NEXT_CHIEF_ISOLATED=1 CMUX_TAG={TAG} {CLI!r} chief -p {json.dumps(prompt)}\r"
    sent = rpc("action.run", {"action": "terminal.sendText", "target": f"tab:{term['selected_tab']}", "args": {"text": command}})
    print("send-text:", json.dumps(sent)[:200], flush=True)
    sub = wait(lambda: next((i for i, v in subs().items() if v.get("session_id") and "osc8-probe" in (v.get("title") or "")), None), 300)
    session = (subs().get(sub) or {}).get("session_id")
    # The reply printed: the id's label in the viewport, after the command line.
    def label_cell():
        text, grid = pane_grid(term["pane"])
        lines = text.split("\n")
        for r in range(len(lines) - 1, -1, -1):
            m = re.search(rf"(?<![\w/]){sub}(?!\w)", lines[r]) if sub else None
            if m and "chief -p" not in lines[r] and grid:
                return r, m.start(), grid, text
        return None
    found = wait(label_cell, 300)
    snapshot("osc8-terminal")
    if not (session and found):
        row("terminal OSC 8 link opens the subagent", "the reply names the subagent in the terminal",
            f"sub {sub}; session {session}; grid {pane_grid(term['pane'])[1]}", False)
        return
    r, c, grid, text = found
    # The viewport text is logical lines; the grid wraps each at its column count.
    cols = max(1, int((grid["frame_width"] - 2 * (grid["origin_x"] - grid["frame_x"])) // grid["cell_width"]))
    lines = text.split("\n")
    r = sum(max(1, -(-len(line) // cols)) for line in lines[:r]) + c // cols
    c = c % cols
    x = grid["origin_x"] + (c + 0.5) * grid["cell_width"]
    y = grid["origin_y"] + (r + 0.5) * grid["cell_height"]
    clicked = rpc("debug.mouse", {"window": grid["window"], "x": x, "y": y, "action": "click", "modifiers": ["cmd"]})
    print("cmd-click:", json.dumps(clicked)[:200], f"cell r{r} c{c}", flush=True)
    state = wait(lambda: (lambda st: st if st.get("sessionId") == session else None)(
        rpc("debug.agent_pane", {"action": "chat_state"}) or {}), 30) or rpc("debug.agent_pane", {"action": "chat_state"}) or {}
    topo = (rpc("snapshot.get") or {}).get("topology") or {}
    time.sleep(3)  # test harness: let the agent pane render its transcript
    snapshot("osc8-opened")
    json.dump({"sub": sub, "session": session, "cell": [r, c], "grid": grid, "click": clicked, "chat_state": state,
               "topology": topo, "viewport": text}, open(os.path.join(opts.out, "osc8-proof.json"), "w"), indent=1)
    shown = {w.get("workspace") for w in topo.get("windows", [])}
    opened = [w.get("name") or "" for w in topo.get("workspaces", []) if w.get("id") in shown]
    row("terminal OSC 8 link opens the subagent", "a Cmd-click on the subagent's name in the terminal shows its workspace and chat",
        f"sub {sub} at r{r} c{c}; window shows {opened}; pane session {state.get('sessionId')} (want {session})",
        state.get("sessionId") == session and any(n.lstrip("✓ ").startswith(f"{sub} ") for n in opened))
    show_home()


@flow
def group_move_stays_in_its_row():
    """A workspace group holds workspaces of one machine row (hq-6d 2026-10-09). A drag refuses a
    Chief-row subagent workspace into a This Mac group; the palette/CLI move (moveWorkspaceToGroup,
    `cmux workspace-group add-workspace`) refuses it with the same rule, and writes nothing."""
    answer = spawn(["Reply with only the word group-probe."])
    ids = ids_in(answer)
    wait_done(ids, 300)

    def topo():
        return (rpc("snapshot.get") or {}).get("topology") or {}
    chief = wait(lambda: next((w for w in topo().get("workspaces", []) if ids
                               and str(w.get("machine") or "").startswith("server-host_chief")
                               and (w.get("name") or "").lstrip("✓ ").startswith(ids[0] + " ")), None), 120)
    local = next((w for w in topo().get("workspaces", [])
                  if not str(w.get("machine") or "").startswith("server-host_chief")), None)
    if not (chief and local):
        row("group move stays in its row", "a Chief-row and a This Mac workspace", f"chief {chief}; local {local}", False)
        return
    made = rpc("action.run", {"action": "newWorkspaceGroup", "target": f"workspace:{local['id']}", "args": {"name": "row-probe"}})
    group = wait(lambda: next((g.get("id") for g in topo().get("workspace_groups", []) if g.get("name") == "row-probe"), None), 30)
    moved = rpc("action.run", {"action": "moveWorkspaceToGroup", "target": f"workspace:{chief['id']}",
                               "args": {"group": f"workspace-group:{group}"}}) if group else {"error": "no group"}
    time.sleep(3)  # test harness: a write that went through would show now
    after = next((w for w in topo().get("workspaces", []) if w.get("id") == chief["id"]), {})
    snapshot("group-move-refused")
    refused = isinstance(moved, dict) and bool(moved.get("error"))
    row("group move stays in its row", "the move is refused with a reason; the Chief workspace stays out of the group",
        f"group {group} (made {json.dumps(made)[:80]}); move {json.dumps(moved)[:160]}; group after {after.get('group')}",
        bool(group) and refused and after.get("group") != group)


@flow
def harness_follows_chief():
    """Subagents run on the Chief's harness: claude, then codex."""
    seen = {}
    for harness in ("codex", "claude-sr"):
        set_ = engine(harness=harness)
        reply = ask(f"Use spawn to start one subagent with cwd {WORK} that replies with only the word {harness}-ok.")
        last = [e for e in trace() if e.get("ev") == "subagent.start"][-1:]
        seen[harness] = (last[0].get("harness"), last[0].get("harness_profile")) if last else None
        print("chief:", reply[:200], "engine:", json.dumps(set_)[:200], flush=True)
    ok = all(v and harness.split("-")[0] in (v[0] or "") + (v[1] or "") for harness, v in seen.items())
    row("subagents use the Chief's harness", "codex turn -> codex subagent; claude turn -> claude subagent",
        f"{seen}", ok)


@flow
def stale_tab_never_shows_another_session():
    """P1 2026-10-09: a subagent tab whose session is gone, while the Chief home's acpmux has a
    new session of the same name, says "This chat isn't available" and never shows that session:
    live (the session is deleted while its tab shows) and after an app restart (the handshake)."""
    answer = spawn(["Reply with only the word stale-probe."])
    ids = ids_in(answer)
    wait_done(ids, 300)
    sub = subs().get(ids[0], {}) if ids else {}
    old = sub.get("session_id")
    ws = wait(lambda: next((w for w in workspaces() if ws_name(w).lstrip("✓ ").startswith(ids[0] + " ")), None) if ids else None, 60)
    if not (old and ws):
        row("stale subagent tab", "a subagent with a session and a workspace", f"session {old}; ws {ws}", False)
        return
    focus_workspace(ws.get("id"), f"stale-{ids[0]}-before")
    before = rpc("debug.agent_pane", {"action": "chat_state"}) or {}
    # The recreated home: the old session goes, a new one takes its name (a compactor's in the bug).
    name = next((r.get("name") for r in (acpmux_rpc("_acpmux/sessions", {}) or {}).get("sessions", [])
                 if r.get("sessionId") == old), f"optchat-sub-x-{ids[0]}")
    deleted = acpmux_rpc("session/delete", {"sessionId": old})
    made = acpmux_rpc("session/new", {"cwd": WORK, "mcpServers": [],
                                      "_meta": {"acpmux": {"name": name, "harness": os.environ.get("MUX_HARNESS", "claude-sr")}}})
    new = (made or {}).get("sessionId")
    live = wait(lambda: (lambda st: st if st.get("missingSession") else None)(
        rpc("debug.agent_pane", {"action": "chat_state"}) or {}), 30) or rpc("debug.agent_pane", {"action": "chat_state"}) or {}
    snapshot(f"stale-{ids[0]}-live")
    row("stale subagent tab, live", "the pane says the chat is gone; it never attaches the new same-named session",
        f"old {old} ({'stale-probe' in pane_text(before)}); name {name}; delete {json.dumps(deleted)[:60]}; new {new}; "
        f"pane session {live.get('sessionId')}, missing {live.get('missingSession')}",
        live.get("missingSession") == old and live.get("sessionId") in (None, old) and new is not None
        and live.get("sessionId") != new and "stale-probe" in pane_text(before))
    rpc("action.run", {"action": "quitKeepSessions"}, timeout=10)
    try:
        app.wait(timeout=60)
    except subprocess.TimeoutExpired:
        pass
    launch_app()
    show_home()
    ws = wait(lambda: next((w for w in workspaces() if ws_name(w).lstrip("✓ ").startswith(ids[0] + " ")), None), 120)
    if ws:
        focus_workspace(ws.get("id"), f"stale-{ids[0]}-restored")
    restored = wait(lambda: (lambda st: st if st.get("missingSession") else None)(
        rpc("debug.agent_pane", {"action": "chat_state"}) or {}), 60) or rpc("debug.agent_pane", {"action": "chat_state"}) or {}
    row("stale subagent tab, after restart", "the restored tab says the chat is gone; never the new same-named session",
        f"ws {ws_name(ws or {})!r}; pane session {restored.get('sessionId')}, missing {restored.get('missingSession')}; "
        f"text {pane_text(restored)[:60]!r}",
        bool(ws) and restored.get("missingSession") == old and restored.get("sessionId") != new and not pane_text(restored))
    if new:
        acpmux_rpc("session/delete", {"sessionId": new})
    show_home()


@flow
def relaunch_keep_sessions_keeps_the_chief():
    """cx-ebm.54 (P1 2026-10-10): opening a subagent tab, then Quit Keep Sessions and a relaunch, keep
    the Chief home's acpmux, the Chief host and the subagent's session: the host never logs
    "acpmux daemon ended", the restored tab shows the same session, the Chief answers, and a new
    spawn works (no connection refused)."""
    log_from = len(host_log())
    answer = spawn(["Reply with only the word keep-probe."], cwd=WORK)
    ids = ids_in(answer)
    wait_done(ids, 300)
    session = subs().get(ids[0], {}).get("session_id") if ids else None
    ws = wait(lambda: next((w for w in workspaces() if ws_name(w).lstrip("✓ ").startswith(ids[0] + " ")), None) if ids else None, 60)
    if not (session and ws):
        row("relaunch keeps the Chief", "a subagent with a session and a workspace", f"answer {json.dumps(answer)[:200]}; ws {ws}", False)
        return
    # The first open of a subagent tab in this launch (the first handoff in the bug).
    focus_workspace(ws.get("id"), f"keep-{ids[0]}-before")
    before = rpc("debug.agent_pane", {"action": "chat_state"}) or {}
    rpc("action.run", {"action": "quitKeepSessions"}, timeout=10)
    try:
        app.wait(timeout=60)
    except subprocess.TimeoutExpired:
        pass
    launch_app()
    show_home()
    ws = wait(lambda: next((w for w in workspaces() if ws_name(w).lstrip("✓ ").startswith(ids[0] + " ")), None), 120)
    if ws:
        focus_workspace(ws.get("id"), f"keep-{ids[0]}-restored")
    after = wait(lambda: (lambda st: st if st.get("sessionId") == session else None)(
        rpc("debug.agent_pane", {"action": "chat_state"}) or {}), 60) or rpc("debug.agent_pane", {"action": "chat_state"}) or {}
    reply = ask("Reply with only the word keep-pong.")
    again = spawn(["Reply with only the word keep-probe-2."], cwd=WORK)
    log = host_log()[log_from:]
    ended = [line for line in log.splitlines() if "acpmux daemon ended" in line or "the host stops" in line]
    row("relaunch keeps the Chief", "the host lives; the restored tab shows its session; the Chief answers; a new spawn works",
        f"session {session}; before {before.get('sessionId')}; after {after.get('sessionId')} missing {after.get('missingSession')}; "
        f"reply {reply[:60]!r}; spawn again {json.dumps(again)[:120]}; host ended {ended[:2]}",
        not ended and before.get("sessionId") == session and after.get("sessionId") == session
        and not after.get("missingSession") and "keep-pong" in reply.lower() and bool(ids_in(again)))
    show_home()


def unix_call(path, request, timeout=30):
    """One JSON line request on a Unix socket (a cmux-tui daemon or a tools socket)."""
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(path)
        conn.sendall((json.dumps(request) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        conn.close()
        return json.loads(buf)
    except (OSError, ValueError) as error:
        return {"error": str(error)}


@flow
def cloud_chief():
    """A server brain (cloud Chief) spawns a subagent; the paired app opens, watches and types into it."""
    if not opts.cloud:
        return
    brain = os.path.expanduser("~/.cmux/brains/chief")
    if os.path.exists(brain) and os.listdir(brain):
        row("cloud Chief subagent", "a free ~/.cmux/brains/chief", "it exists and is not this run's: not touched", False)
        return
    # The cloud flow needs the app signed in (staging pairing). The local flows ran signed out on purpose,
    # so the Home composer never reached a real account's Chief; this flow never uses the composer.
    if opts.creds:
        rpc("action.run", {"action": "quitEndSessions"}, timeout=10)
        try:
            app.wait(timeout=60)
        except subprocess.TimeoutExpired:
            pass
        APP_ENV.update({"CMUX_AUTH_CREDENTIALS_FILE": opts.creds, "CMUX_DEV_AUTH_ACCOUNT": opts.account,
                        "CMUX_DEV_AUTH_PROFILE": "personal"})
        launch_app()
        wait(lambda: (rpc("auth.status") or {}).get("signed_in"), 120)
    auth = rpc("auth.status") or {}
    if not auth.get("signed_in"):
        row("cloud Chief subagent", "the tagged app signed in", f"auth {json.dumps(auth)[:120]}", False)
        return
    bins = os.path.join(brain, "bin")
    for d in ("bin", "mux", "acpmux", "daemon", "cloud", "logs"):
        os.makedirs(os.path.join(brain, d), mode=0o700, exist_ok=True)
    res = os.path.join(APP, "Contents/Resources/bin")
    for name, src in (("optchat-chief", "optchat-chief"), ("acpmux", "acpmux"), ("cmux-tui", "cmux")):
        shutil.copy(os.path.join(res, src), os.path.join(bins, name))
    sock = os.path.join(brain, "daemon", "cmux.sock")
    mux = os.path.join(brain, "mux")
    base = {**os.environ, "PATH": f"{os.environ['HOME']}/bin:{os.environ['HOME']}/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"}
    base.pop("CMUX_SOCKET_PATH", None)
    acp = {"ACPMUX_HOME": os.path.join(brain, "acpmux")}
    procs = []
    host = install = chief = None

    def start(argv, env, log):
        p = subprocess.Popen(argv, env={**base, **env}, stdout=open(os.path.join(brain, "logs", log), "a"),
                             stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        procs.append(p)
        return p
    try:
        start([os.path.join(bins, "cmux-tui"), "--headless", "--socket", sock],
              {**acp, "CMUX_TUI_CHIEF_TOOLS_SOCKET": os.path.join(mux, "optchat", "tools.sock")}, "daemon.log")
        start([os.path.join(bins, "acpmux"), "daemon", "run"], acp, "acpmux.log")
        wait(lambda: os.path.exists(sock), 60)
        caps = (unix_call(sock, {"id": 1, "cmd": "identify"}).get("data") or {}).get("capabilities") or []
        name = subprocess.run(["/bin/hostname", "-s"], capture_output=True, text=True).stdout.strip()
        install_file = os.path.join(brain, "cloud", "install.json")
        pair_log = os.path.join(brain, "logs", "pair.log")
        start([os.path.join(bins, "optchat-chief"), "cloud", "pair", "--install", install_file, "--api-base",
               "https://cloud-api-staging.cmux.dev", "--name", name, "--wait-chief", "900"], {}, "pair.log")
        code = wait(lambda: (re.search(r"pairing code: (\S+)", open(pair_log).read()) or [None, None])[1], 120)
        approved = rpc("action.run", {"action": "server.addServer", "args": {"code": code, "name": name, "chief": False},
                                      "wait": True}, timeout=120)
        paired = wait(lambda: re.search(r"paired: host (\S+) \(install (\S+)\)", open(pair_log).read()), 180)
        host, install = (paired.group(1), paired.group(2)) if paired else (None, None)
        made = rpc("debug.server_reach.test_chief", {"host": host, "install": install,
                                                     "display_name": f"Subagent proof {TAG}"}, timeout=90) if host else {}
        chief = (made or {}).get("id") or ((made or {}).get("chief") or {}).get("id")
        wait(lambda: procs[2].poll() is not None, 300)
        start([os.path.join(bins, "optchat-chief"), "host", "--conversation-source", "cloud", "--cloud-install", install_file,
               "--daemon-socket", sock, "--mux-home", mux],
              {"MUX_HOME": mux, **acp, "ACPMUX_SOCKET": os.path.join(brain, "acpmux", "acpmux.sock"),
               "ACPMUX_BIN": os.path.join(bins, "acpmux"), "CMUX_DAEMON_SOCKET": sock, "OPTCHAT_ACPMUX_SUPERVISED": "1",
               "MUX_HARNESS": "claude-sr"}, "host.log")
        tools_sock = os.path.join(mux, "optchat", "tools.sock")
        wait(lambda: os.path.exists(tools_sock), 180)
        time.sleep(10)  # test harness: the host's start-up
        answer = unix_call(tools_sock, {"tool": "spawn", "tasks": ["Run `sleep 20`, then reply with only the word cloud-ok."]},
                           timeout=600)
        sub = (re.findall(r"- (a\d+):", answer.get("text", "")) or [None])[0]
        reach = rpc("debug.server_reach", {"refresh": True}, timeout=60)
        seen = sub and sub in json.dumps(reach)
        def brain_key():
            for path in glob.glob(os.path.join(mux, "optchat", "traces", "*.jsonl")):
                for line in open(path, errors="replace"):
                    if '"subagent.workspace"' in line and f'"id":"{sub}"' in line.replace(" ", ""):
                        return json.loads(line).get("workspace")
            return None
        key = wait(brain_key, 60)

        def server_ws():
            snap = rpc("snapshot.get") or {}
            return next((w for w in (snap.get("topology") or {}).get("workspaces", [])
                         if key and (w.get("key") == key or w.get("id") == key)), None)
        ws = wait(server_ws, 120)
        print("cloud ws:", json.dumps({k: (ws or {}).get(k) for k in ("id", "key", "name", "machine", "session")}), flush=True)
        if ws:
            focus_workspace(ws.get("id"), f"cloud-{sub}-watch")
        state = rpc("debug.agent_pane", {"action": "chat_state"})
        sent = type_in_pane("Reply with only the word typed-ok.")
        brain_db = os.path.join(mux, "optchat", "memory.sqlite3")

        def brain_reports():
            try:
                db = sqlite3.connect(f"file:{brain_db}?mode=ro", uri=True, timeout=5)
                rows = db.execute("SELECT text FROM messages WHERE kind = 'user' ORDER BY id").fetchall()
                db.close()
                return [r[0] for r in rows if sub and r[0].startswith(f"[{sub}] ")]
            except sqlite3.Error:
                return []
        typed = wait(lambda: [t for t in brain_reports() if "typed-ok" in t], 300, step=3)
        if ws:
            focus_workspace(ws.get("id"), f"cloud-{sub}-typed")
        show_home()
        row("cloud Chief subagent", "server brain workspace shown in the app; its pane attaches; typing reaches it",
            f"attach cap={'agent-session-attach-v1' in caps}; approve {json.dumps(approved)[:60]}; host {host}; chief {chief}; "
            f"sub {sub}; in server_reach={bool(seen)}; app ws={bool(ws)}; pane {json.dumps(state)[:100]}; "
            f"send {json.dumps(sent)[:60]}; reports {brain_reports()[-2:]}",
            bool(seen) and bool(ws) and bool(typed) and "agent-session-attach-v1" in caps)
    finally:
        if host:
            print("cloud cleanup:", json.dumps(rpc("debug.server_reach.cleanup", {"host": host, **({"chief": chief} if chief else {})},
                                                  timeout=90))[:300], flush=True)
        for p in reversed(procs):
            if p.poll() is None:
                p.terminate()
                try:
                    p.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    p.kill()
        subprocess.run([os.path.join(bins, "acpmux"), "daemon", "shutdown"], env={**base, **acp}, capture_output=True, timeout=30)
        shutil.copytree(os.path.join(brain, "logs"), os.path.join(opts.out, "brain-logs"), dirs_exist_ok=True)
        try:
            shutil.copy(os.path.join(mux, "host.log"), os.path.join(opts.out, "brain-host.log"))
        except OSError:
            pass
        shutil.rmtree(brain, ignore_errors=True)


CLI_TASK = "Run `wc -l cli.txt` in your folder, then `sleep 60`, then reply with only the line count."


def cli_first():
    """A Chief that `cmux chief` started without the app spawns a subagent (its workspace goes to the
    Chief's owner daemon); returns its id once its session runs."""
    os.makedirs(WORK, exist_ok=True)
    open(os.path.join(WORK, "cli.txt"), "w").write("one\ntwo\nthree\nfour\n")
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
           "CMUX_NEXT_CHIEF_ISOLATED": "1", "CMUX_TAG": TAG, "MUX_HARNESS": os.environ.get("MUX_HARNESS", "claude-sr")}
    prompt = f"Use your spawn tool to start exactly one subagent with cwd {WORK} and this task: {CLI_TASK}"
    shell = f"cd {WORK} && {CLI!r} chief -p {json.dumps(prompt)}"
    out = subprocess.run(["/bin/zsh", "-lic", shell], env=env, capture_output=True, text=True, timeout=900)
    print("cmux chief -p:", (out.stdout + out.stderr)[-600:], flush=True)
    sub = wait(lambda: next((i for i, v in subs().items() if v.get("session_id")), None), 120)
    log = host_log()
    print("cli brain workspace lines:", [l[:200] for l in log.splitlines() if "workspace" in l][-4:], flush=True)
    return sub


def cli_shown(sub):
    """After the app opened: the CLI subagent's workspace, its pane's live chat, and typing into it."""
    # The CLI Chief's subagent lives in the Chief owner daemon: the row named after the Chief
    # (machine server-host_chief<home id>), never a same-named workspace of the app's own session.
    def chief_row_ws():
        snap = rpc("snapshot.get") or {}
        return next((w for w in (snap.get("topology") or {}).get("workspaces", [])
                     if str(w.get("machine") or "").startswith("server-host_chief")
                     and (w.get("name") or "").lstrip("✓ ").startswith(f"{sub} ")), None)
    ws = wait(chief_row_ws, 180)
    if ws:
        focus_workspace(ws.get("id"), f"cli-{sub}-pane")
    state = pane_text(wait(lambda: (lambda st: st if "cli.txt" in pane_text(st) else None)(
        rpc("debug.agent_pane", {"action": "chat_state"})), 90) or rpc("debug.agent_pane", {"action": "chat_state"}))
    # The tool call shows as a tool line in zoom; the pane's assistant text names the count.
    tool = "|tool: " in tools({"tool": "zoom", "id": sub}).get("text", "")
    sent = type_in_pane("Reply with only the word cli-typed.")
    typed = wait(lambda: [t for i, t in reports({sub}) if "cli-typed" in t.lower()], 300, step=3)
    if ws:
        focus_workspace(ws.get("id"), f"cli-{sub}-typed")
    show_home()
    row("CLI-started Chief: subagent pane in the app", "workspace shown; pane has its task and a tool call; typing reaches it",
        f"sub {sub}; ws {ws_name(ws or {})!r} on {(ws or {}).get('machine')}; task in pane={'cli.txt' in state}; tool={tool}; send {json.dumps(sent)[:80]}; "
        f"typed report {(typed or [''])[0][:60]!r}", bool(ws) and "cli.txt" in state and tool and bool(typed))


# --- run ----------------------------------------------------------------------

app = None
APP_ENV = {}


def launch_app():
    """Starts the tagged app (again); True once its control socket answers."""
    global app
    log = open(os.path.join(opts.out, f"app-{TAG}.log"), "a")
    app = subprocess.Popen([BINARY], env=APP_ENV, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    print(f"launched pid {app.pid}", flush=True)
    return bool(wait(lambda: (rpc("debug.windows") or {}).get("windows"), 600))


def cleanup():
    STOP_RECORDING.set()
    if opts.keep:
        return
    rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
    if app:
        try:
            app.wait(timeout=20)
        except subprocess.TimeoutExpired:
            os.kill(app.pid, signal.SIGKILL)
    acpmux("daemon", "shutdown", timeout=30)
    stop_sessions()
    for _ in range(2):
        ps = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
        for line in ps.splitlines():
            parts = line.split(None, 1)
            if len(parts) == 2 and parts[1].startswith(APP + "/") and int(parts[0]) != os.getpid():
                print("leftover", line[:160], flush=True)
                try:
                    os.kill(int(parts[0]), signal.SIGTERM)
                except OSError:
                    pass
        time.sleep(3)  # test harness: let them exit


def stop_sessions():
    """Stops this tag's app session and its Chief owner session (`cmux-chief-<home id>`) by exact
    name. A Chief owner left by an earlier run of the same tag kept its conversation after the
    home was deleted, and the new Chief host never saw a Home message (cx-ebm.55 class)."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
    for session in (f"cmux-app-{TAG}", f"cmux-chief-{HOME_ID}"):
        out = subprocess.run([CLI, "server", "stop", "--session", session, "--end-terminals"],
                             env=env, capture_output=True, text=True, timeout=30)
        print(f"server stop {session}: exit {out.returncode} {(out.stdout + out.stderr).strip()[:160]}", flush=True)


def make_video():
    frames = sorted(glob.glob(os.path.join(FRAMES, "frame-*.png")))
    if not frames or not shutil.which("ffmpeg"):
        print(f"frames: {len(frames)} (no ffmpeg: no mp4)", flush=True)
        return
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "4", "-i", os.path.join(FRAMES, "frame-%05d.png"),
                    "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-pix_fmt", "yuv420p",
                    os.path.join(opts.out, "recording.mp4")], timeout=600)
    print(f"recording: {os.path.join(opts.out, 'recording.mp4')} from {len(frames)} frames", flush=True)


def main():
    if os.path.exists(SOCKET):
        sys.exit(f"{SOCKET} exists: another {TAG} app runs; pick a fresh tag")
    stop_sessions()  # an earlier run's Chief owner of this tag must not answer this run's Home
    # The app's Home cache of this Chief home (`cmux-home/cmux-chief-<home id>/home.json`) keeps
    # an earlier run's conversation: the run deletes the home, the new host makes a new
    # conversation, and Home sent to the old one (no turn ever came; cx-ebm.55).
    cache = os.path.expanduser(f"~/Library/Caches/cmux-home/cmux-chief-{HOME_ID}")
    if os.path.isdir(cache) and not opts.no_home_workarounds:
        print(f"removing the stale Home cache {cache}", flush=True)
        shutil.rmtree(cache)
    os.makedirs(WORK, exist_ok=True)
    config = os.path.join(SCRATCH, "cmux.json")
    open(config, "w").write("{}")
    open(os.path.join(SCRATCH, "ghostty"), "w").write("")
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": config,
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"),
           "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1400,900",
           # Model traffic only through the team subrouter (claude-sr).
           "MUX_HARNESS": os.environ.get("MUX_HARNESS", "claude-sr")}
    # The subrouter route of this host's login shell (run the script under `zsh -lic`), so the
    # app's Chief and its compactor sign in; values pass through, never printed.
    for name in ("ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "SUBROUTER_URL"):
        if os.environ.get(name):
            env[name] = os.environ[name]
    print("route env:", sorted(k for k in env if k.startswith(("ANTHROPIC_", "SUBROUTER_"))), flush=True)
    APP_ENV.update(env)
    cli_sub = cli_first() if opts.cli_first else None
    if opts.cli_first and not cli_sub:
        row("CLI-started Chief: subagent pane in the app", "the CLI Chief spawns a subagent", "no subagent session", False)
    if not launch_app():
        sys.exit("the tagged app did not come up")
    show_home()
    if not wait(chief_conversation, 180):
        sys.exit(f"no Chief conversation: {json.dumps(rpc('debug.home'))[:1000]}")
    if not wait(lambda: "daemon connected" in host_log() and os.path.exists(os.path.join(OPTCHAT, "tools.sock")), 180):
        sys.exit("the Chief host did not connect (no tools socket)")
    time.sleep(10)  # test harness: the compactor start-up probe
    threading.Thread(target=recorder, daemon=True).start()
    print("engine:", json.dumps(engine())[:400], flush=True)
    if cli_sub:
        try:
            cli_shown(cli_sub)
        except Exception as error:  # report, keep going
            row("CLI-started Chief: subagent pane in the app", "no error", f"raised {error!r}", False)
    only = {n for n in opts.only.split(",") if n}
    for fn in FLOWS:
        if only and fn.__name__ not in only:
            continue
        print(f"=== {fn.__name__}: {fn.__doc__}", flush=True)
        try:
            fn()
        except Exception as error:  # report, keep going
            row(fn.__name__, "no error", f"raised {error!r}", False)
    STOP_RECORDING.set()
    json.dump([{"flow": f, "expected": e, "observed": o, "ok": k} for f, e, o, k in ROWS],
              open(os.path.join(opts.out, "rows.json"), "w"), indent=1)
    for name in ("host.log",):
        try:
            shutil.copy(os.path.join(MUX_HOME, name), os.path.join(opts.out, name))
        except OSError:
            pass
    shutil.copytree(os.path.join(OPTCHAT, "traces"), os.path.join(opts.out, "traces"), dirs_exist_ok=True)


if __name__ == "__main__":
    try:
        main()
    finally:
        cleanup()
        make_video()
    print(f"{sum(1 for r in ROWS if r[3])}/{len(ROWS)} pass", flush=True)
    sys.exit(0 if ROWS and all(r[3] for r in ROWS) else 1)
