#!/usr/bin/env python3
"""Live check that the Chief's cmux calls reach its own tagged app (cmux-lawrence-2 only).

hmchief7: the Chief's `cmux workspace create` landed in the user's release app
(session cmux-app) and the tagged sidebar stayed empty. This drives the real
Chief through the Home composer (`debug.home.drive` type/send) with the
requests a user makes, waits for each reply, then checks the tagged daemon
(through scripts/cmux-debug-cli.sh, as a user would) and the default sessions
(cmux-app, main: where a misrouted call lands, read only). Prints one table
row per flow: flow | expected | observed | pass/fail.

Launches the tagged app itself (no-activate, scratch config), and on exit
quits it with quitEndSessions, shuts down the tag's acpmux daemon, stops the
tag's cmux-tui session and the Chief host, by exact PID only.

Usage: chief-cmux-flows-e2e.py --tag <tag> --app PATH --debug-cli PATH [--out DIR] [--only N,M]
"""
import argparse, json, os, re, signal, socket, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--debug-cli", required=True, help="scripts/cmux-debug-cli.sh")
parser.add_argument("--derived-data", required=True, help="CMUX_DERIVED_DATA for cmux-debug-cli.sh")
parser.add_argument("--out", default="/tmp")
parser.add_argument("--turn-timeout", type=float, default=420)
parser.add_argument("--only", default="")
parser.add_argument("--keep", action="store_true", help="leave the app running (debugging)")
parser.add_argument("--attach", action="store_true", help="use the tagged app this script left running (--keep)")
parser.add_argument("--start-timeout", type=float, default=600, help="seconds for the app's control socket")
opts = parser.parse_args()

TAG = opts.tag
APP = opts.app
BINARY = os.path.join(APP, "Contents/MacOS/cmux DEV")
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
ACPMUX = os.path.join(APP, "Contents/Resources/bin/acpmux")
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
# A no-activate launch is an isolated Chief home (ChiefHome.swift).
MUX_HOME = os.path.expanduser(f"~/.cmux/chief/isolated/{TAG}")
ACPMUX_HOME = os.path.join(MUX_HOME, "acpmux")
SCRATCH = tempfile.mkdtemp(prefix=f"chief-flows-{TAG}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
open(CONFIG, "w").write("{}")
open(os.path.join(SCRATCH, "ghostty"), "w").write("")
os.makedirs(opts.out, exist_ok=True)
ROWS = []


def rpc(method, params=None, timeout=30):
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


def tagged(*args):
    """The tagged app's CLI through cmux-debug-cli.sh (its daemon, its app)."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
    env.update(CMUX_TAG=TAG, CMUX_DERIVED_DATA=opts.derived_data)
    out = subprocess.run([opts.debug_cli, "--json", *args], env=env, capture_output=True, text=True, timeout=60)
    try:
        return json.loads(out.stdout)
    except ValueError:
        return {"error": (out.stdout + out.stderr).strip()[:400]}


def session_list(session):
    """Read-only workspace list of a default session, or None when it is not running."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
    out = subprocess.run([CLI, "--session", session, "--json", "workspace", "list"], env=env,
                         capture_output=True, text=True, timeout=30)
    try:
        value = json.loads(out.stdout)
    except ValueError:
        return None
    return workspaces_of(value)


def workspaces_of(value):
    if isinstance(value, dict):
        value = value.get("value", value)
    if isinstance(value, dict):
        value = value.get("workspaces", value.get("items", []))
    return value if isinstance(value, list) else []


def workspaces():
    return workspaces_of(tagged("workspace", "list"))


def ws_name(ws):
    return ws.get("name") or ws.get("title") or ""


def app_ws(name):
    """The workspace named `name` (by its daemon id) in the tagged app's own tree (snapshot.get), as JSON text."""
    ws_id = (find_ws(name) or {}).get("id")
    snap = rpc("snapshot.get") or {}
    for ws in (snap.get("topology") or {}).get("workspaces", []):
        if ws_id and ws.get("id") == ws_id:
            return json.dumps(ws)
    return ""


def find_ws(name):
    return next((w for w in workspaces() if ws_name(w) == name), None)


def focused():
    """The workspace the tagged app shows (snapshot.get topology.focus)."""
    snap = rpc("snapshot.get") or {}
    return ((snap.get("topology") or {}).get("focus") or {}).get("workspace")


def wait(predicate, seconds, step=1.0):
    end = time.time() + seconds
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # test harness wait, not app code
    return None


def chief_conversation():
    home = rpc("debug.home") or {}
    return next((c for c in home.get("conversations", []) if "agent_mux" in c.get("participants", [])), None)


def memory(query, args=()):
    """Read-only rows of the Chief's memory database (optchat/memory.sqlite3)."""
    import sqlite3
    path = os.path.join(MUX_HOME, "optchat", "memory.sqlite3")
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
    """The Chief's OptChat log (user, talk, tool, echo, work items), oldest first."""
    return [{"kind": kind, "text": text} for kind, text in memory("SELECT kind, text FROM messages ORDER BY id")]


def host_state(key):
    rows = memory("SELECT value FROM state WHERE key = ?", (f"host/{key}",))
    try:
        return json.loads(rows[0][0]) if rows else None
    except ValueError:
        return None


def ask(text):
    """Sends `text` through the Home composer; returns the Chief's final reply of that turn."""
    before = len(log_items())
    for action, extra in (("focus", {}), ("type", {"text": text}), ("send", {})):
        reply = rpc("debug.home.drive", {"action": action, **extra})
        if not (isinstance(reply, dict) and reply.get("ok")):
            return f"(drive {action} failed: {reply})"
    mine = wait(lambda: next((i for i, m in enumerate(log_items()) if i >= before and m.get("kind") == "user"
                              and text in m.get("text", "")), None), 60)
    if mine is None:
        return "(my message never reached the Chief's log)"
    # The turn ends with its final reply posted to the conversation (last_seq
    # moves past the user's message); the log's last talk is that reply.
    def done():
        items = log_items()
        talks = [m for m in items[mine + 1:] if m.get("kind") == "talk"]
        conv = chief_conversation() or {}
        if talks and int(conv.get("last_seq", 0)) > 0 and items[-1].get("kind") == "talk":
            return talks[-1]["text"]
        return None
    reply = wait(done, opts.turn_timeout, step=3)
    if reply is None:
        return "(no reply)"
    time.sleep(4)  # a turn that goes on after a talk item logs more
    return done() or reply


DEFAULTS = {}


def defaults_snapshot():
    return {s: sorted(json.dumps(w, sort_keys=True) for w in (session_list(s) or [])) for s in ("cmux-app", "main")}


def defaults_unchanged():
    now = defaults_snapshot()
    changed = [s for s in now if now[s] != DEFAULTS.get(s)]
    return (not changed, "default sessions unchanged" if not changed else f"CHANGED: {changed}")


def row(flow, expected, observed, ok):
    ROWS.append((flow, expected, observed, ok))
    print(f"| {flow} | {expected} | {observed} | {'pass' if ok else 'FAIL'} |", flush=True)


def show_home():
    rpc("action.run", {"id": "home.show"})
    wait(lambda: (rpc("debug.home.drive", {"action": "geometry"}) or {}).get("ok"), 20)


def tail():
    """The conversation's messages as the log has them (user and talk items)."""
    return [{"author": "agent_mux" if m.get("kind") in ("talk", "work") else "user_local", "text": m.get("text", "")}
            for m in log_items() if m.get("kind") in ("user", "talk", "work")]


def check(flow, expected, prompt, verify):
    # Home shows the Chief's composer; the user is on Home when they ask.
    show_home()
    focus_before = focused()
    reply = ask(prompt)
    print(f"--- {flow}\nchief: {reply[:600]}", flush=True)
    try:
        ok, observed = verify(reply, focus_before)
    except Exception as error:  # report, keep going
        ok, observed = False, f"verify raised {error!r}"
    clean, note = defaults_unchanged()
    # The CLI's `focused` must name what the app window shows (app_focus).
    cli_focused = [w.get("id") for w in workspaces() if w.get("focused")]
    agrees = cli_focused == [focused()]
    note += f"; CLI focused agrees with the window={agrees}"
    clean = clean and agrees
    # Closing the workspace the window shows moves it to a neighbour.
    closed_shown = flow == "close a workspace" and focus_before not in {w.get("id") for w in workspaces()}
    if flow != "focus a workspace" and not closed_shown:
        kept = focused() == focus_before
        note += f"; focus kept={kept}"
        clean = clean and kept
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"{len(ROWS) + 1:02d}-{flow.replace(' ', '-')}.png")})
    row(flow, expected, f"{observed}; {note}", ok and clean)
    return reply


app = None


def cleanup():
    if opts.keep:
        return
    print("cleanup", flush=True)
    rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
    if app:
        try:
            app.wait(timeout=20)
        except subprocess.TimeoutExpired:
            os.kill(app.pid, signal.SIGKILL)
    subprocess.run([ACPMUX, "daemon", "shutdown"], env={**os.environ, "ACPMUX_HOME": ACPMUX_HOME,
                                                        "ACPMUX_SOCKET": os.path.join(ACPMUX_HOME, "acpmux.sock")},
                   capture_output=True, timeout=30)
    subprocess.run([CLI, "server", "stop", "--session", f"cmux-app-{TAG}", "--end-terminals"],
                   env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)
    # Every process left from this tag's bundle (its own path), by exact pid;
    # twice, as terminal hosts outlive their session owner.
    for _ in range(2):
        ps = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
        for line in ps.splitlines():
            parts = line.split(None, 1)
            # The bundle's own executables only (this script's argv names the bundle too).
            if len(parts) == 2 and parts[1].startswith(APP + "/") and int(parts[0]) != os.getpid():
                print("leftover", line[:160], flush=True)
                try:
                    os.kill(int(parts[0]), signal.SIGTERM)
                except OSError:
                    pass
        time.sleep(3)  # test harness: let them exit


def host_log():
    try:
        return open(os.path.join(MUX_HOME, "host.log")).read()
    except OSError:
        return ""


def main():
    global app
    if os.path.exists(SOCKET) and not opts.attach:
        sys.exit(f"{SOCKET} exists: another {TAG} app runs; pick a fresh tag")
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG,
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"),
           "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,900"}
    log = open(os.path.join(opts.out, f"app-{TAG}.log"), "a")
    DEFAULTS.update(defaults_snapshot())
    print("default sessions before:", {k: len(v) for k, v in DEFAULTS.items()}, flush=True)
    connected = 0 if opts.attach else host_log().count("daemon connected")
    if not opts.attach:
        app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
        print(f"launched pid {app.pid}", flush=True)
    if not wait(lambda: os.path.exists(SOCKET) and (rpc("debug.windows") or {}).get("windows"), opts.start_timeout):
        sys.exit("the tagged app did not come up")
    show_home()
    conv = wait(chief_conversation, 120)
    # The Chief host attaches to the conversation after Home opens.
    if not wait(lambda: host_log().count("daemon connected") > connected, 120):
        sys.exit("the Chief host did not connect")
    time.sleep(10)  # test harness: its compactor start-up probe
    if not conv:
        sys.exit(f"no Chief conversation: {json.dumps(rpc('debug.home'))[:2000]}")
    print("identify:", json.dumps(tagged("app", "identify"))[:600], flush=True)
    start = {w.get("id") for w in workspaces()}
    print("tagged workspaces before:", [ws_name(w) or w.get("id") for w in workspaces()], flush=True)
    only = {int(n) for n in opts.only.split(",") if n}
    flows = []

    def flow(fn):
        flows.append(fn)
        return fn

    @flow
    def create():
        def verify(reply, focus):
            new = [w for w in workspaces() if w.get("id") not in start]
            return (len(new) >= 1 and focused() == focus,
                    f"{len(new)} new in tagged tree; focus kept={focused() == focus}")
        check("create a workspace", "a new workspace in the tagged tree only; focus unchanged",
              "Create a new workspace for me.", verify)

    @flow
    def create_named():
        def verify(reply, focus):
            ws = find_ws("chief-e2e-alpha")
            return (ws is not None and focused() == focus, f"chief-e2e-alpha in tagged tree={ws is not None}")
        check("create a named workspace", "chief-e2e-alpha in the tagged tree only",
              "Create a workspace named chief-e2e-alpha.", verify)

    @flow
    def rename():
        def verify(reply, focus):
            return (find_ws("chief-e2e-beta") is not None and find_ws("chief-e2e-alpha") is None,
                    f"beta={find_ws('chief-e2e-beta') is not None} alpha={find_ws('chief-e2e-alpha') is not None}")
        check("rename it", "chief-e2e-alpha renamed to chief-e2e-beta",
              "Rename the workspace chief-e2e-alpha to chief-e2e-beta.", verify)

    @flow
    def run_command():
        def verify(reply, focus):
            terms = sorted(set(re.findall(r"term_[0-9a-f]+", app_ws("chief-e2e-beta"))))
            screens = " ".join(json.dumps(tagged("terminal", t, "screen", "read")) for t in terms)
            on_screen = "chief-e2e-marker-4242" in screens
            return (on_screen and "chief-e2e-marker-4242" in reply,
                    f"marker on a beta terminal={on_screen} ({len(terms)} terminals), in reply={'chief-e2e-marker-4242' in reply}")
        check("run a command and read output", "marker on the beta terminal and quoted in the reply",
              "In the workspace chief-e2e-beta, run `echo chief-e2e-marker-$((4000+242))` in its terminal, "
              "then read the terminal's output and tell me exactly what it printed.", verify)

    @flow
    def split():
        def verify(reply, focus):
            panes = len(set(re.findall(r"pane_[0-9a-f]+", app_ws("chief-e2e-beta"))))
            return (panes >= 2, f"panes in beta (app tree)={panes}")
        check("split a pane", "beta has two panes in the app tree",
              "Split the pane in workspace chief-e2e-beta to the right.", verify)

    @flow
    def browser():
        def verify(reply, focus):
            text = app_ws("chief-e2e-beta")
            browser = '"kind": "browser"' in text
            return (browser and "example.com" in text,
                    f"browser tab in beta (app tree)={browser}, its url example.com={'example.com' in text}")
        check("open a browser tab", "a browser tab on https://example.com in beta",
              "Open a browser tab in workspace chief-e2e-beta at https://example.com.", verify)

    @flow
    def focus():
        def verify(reply, before):
            ws = find_ws("chief-e2e-beta") or {}
            now = focused()
            return (now == ws.get("id"), f"focused={now} beta={ws.get('id')}")
        check("focus a workspace", "the app shows chief-e2e-beta", "Focus the workspace chief-e2e-beta.", verify)

    @flow
    def list_ws():
        def verify(reply, focus):
            return ("chief-e2e-beta" in reply, f"beta named in reply={'chief-e2e-beta' in reply}")
        check("list workspaces", "the reply names chief-e2e-beta", "List my workspaces.", verify)

    @flow
    def close():
        def verify(reply, focus):
            return (find_ws("chief-e2e-beta") is None, f"beta gone={find_ws('chief-e2e-beta') is None}")
        check("close a workspace", "chief-e2e-beta closed", "Close the workspace chief-e2e-beta.", verify)

    @flow
    def subagent():
        def subs():
            spawns = host_state("spawns") or {}
            return [sub for run in spawns.values() for sub in run.get("subs", [])]

        def chat_tab(sub):
            """The agent chat tab bound to the subagent's session in its workspace (app tree)."""
            snap = rpc("snapshot.get") or {}
            for ws in (snap.get("topology") or {}).get("workspaces", []):
                if ws.get("key") != sub.get("workspace"):
                    continue
                for screen in ws.get("screens", []):
                    for pane in screen.get("panes", []):
                        for tab in pane.get("tabs", []):
                            if tab.get("kind") == "conversation" and tab.get("agent_session") == sub.get("session_id"):
                                return ws.get("name") or ws.get("id")
            return None

        before = {sub.get("id") for sub in subs()}

        def verify(reply, focus):
            got = wait(lambda: next((m for m in tail() if m["author"] == "agent_mux" and "PONG" in m["text"]), None),
                       opts.turn_timeout, step=3)
            new = [sub for sub in subs() if sub.get("id") not in before]
            tabs = {sub.get("id"): wait(lambda: chat_tab(sub), 30) for sub in new}
            ok = bool(got) and bool(new) and all(tabs.values())
            return (ok, f"report with PONG={bool(got)}; new subagents={[s.get('id') for s in new]}; "
                        f"chat tab bound to its session in its workspace={tabs}")
        check("start a subagent", "the agent reports PONG; its workspace holds the agent chat tab bound to its session",
              f"Start a subagent named e2e-kid in {SCRATCH} whose task is to reply with the single word PONG.", verify)

    @flow
    def what_did_you_do():
        def verify(reply, focus):
            hits = [w for w in ("chief-e2e-beta", "e2e-kid", "browser") if w in reply]
            return (len(hits) >= 2, f"reply mentions {hits}")
        check("ask what it did", "the reply recounts this session's actions", "What did you do in this chat so far?",
              verify)

    for index, fn in enumerate(flows, 1):
        if not only or index in only:
            fn()
    print("\n| flow | expected | observed | result |\n|---|---|---|---|")
    for flow_, expected, observed, ok in ROWS:
        print(f"| {flow_} | {expected} | {observed} | {'pass' if ok else 'FAIL'} |")
    json.dump(ROWS, open(os.path.join(opts.out, "rows.json"), "w"), indent=1)
    json.dump(rpc("debug.home"), open(os.path.join(opts.out, "home.json"), "w"), indent=1)


try:
    main()
finally:
    cleanup()
