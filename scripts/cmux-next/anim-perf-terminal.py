#!/usr/bin/env python3
"""App animation frame times, measured in a real window (anim-perf, Lawrence 2026-10-21: "we need to fix all
animation lag as well. for new tabs, making splits, etc.").

The pane motion of bonsplit and columns (split, close, New Column, zoom, divider drag at 2 to 30 panes) is
pane-perf-terminal.py's (a421). This bench covers every other animation, and one split/column pass in a small
layout so a single table compares builds:

  tab-new / tab-close           newTab (the New Tab page) and closeTab, in a pane with 3 tabs
  tab-move-right / -left        moveSurfaceRight / moveSurfaceLeft (the tab strip reorder)
  tab-to-pane / tab-back        moveSurfaceToPaneRight / moveSurfaceToPaneLeft (a tab moves between two panes)
  split-right / split-down      splitRight / splitDown, each closed again (split-close)
  column / column-close         newColumn, then its closePane
  ws-switch / ws-back           goToWorkspace to a 4-pane workspace and back
  sidebar-hide / sidebar-show   toggleSidebar twice
  right-open / right-close      toggleRightSidebar twice
  group-collapse / -expand      toggleFocusedWorkspaceGroupCollapsed twice (a sidebar group of 3 workspaces)
  home-show / home-leave        home.show, then goToWorkspace back
  chat-open / -next / -prev     home.openConversation of the first of 4 seeded chats (the bench's own Chief home),
                                then home.nextConversation / home.previousConversation
  palette-open / palette-close  commandPalette twice

Per animation (median over --rounds): display frame intervals p50/p95/max, dropped frames (an interval over 1.5
refresh periods), frames over 8.33 ms (a 120 Hz frame), main-thread CPU per frame p95/max and in total
(`debug.frames`), and hangs (`debug.hangs`). The budgets (scripts/perf-bench/budgets.json `animations`) are a 120 Hz
frame: no dropped frame, no frame and no main-thread slice over 8.33 ms. Each starts advisory; --gate fails on the
enforced ones.

Usage: anim-perf-terminal.py --tag <tag> --app PATH [--anims a,b] [--rounds 3] [--json PATH] [--out DIR] [--gate]
Fleet: scripts/measure/split-spring.sh --arg=--suite=anim-perf (scripts/measure/anim-perf.sh once allowlisted).
"""
import argparse, glob, json, os, signal, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "../.."))
BUDGETS = os.path.join(ROOT, "scripts/perf-bench/budgets.json")

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--anims", default="")
parser.add_argument("--rounds", type=int, default=3)
parser.add_argument("--json")
parser.add_argument("--out", default="/tmp")
parser.add_argument("--gate", action="store_true", help="fail on the enforced budgets")
parser.add_argument("--reduce-motion", action="store_true", help="cmux animations off: every change must land in one frame")
parser.add_argument("--sample", default="", help="ANIM[,...]: `sample` the app while it repeats ANIM")
parser.add_argument("--sample-repeats", type=int, default=8)
opts, _unknown = parser.parse_known_args()
TAG, APP = opts.tag, os.path.abspath(opts.app.rstrip("/"))
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
BINARY = next((p for p in sorted(glob.glob(os.path.join(APP, "Contents/MacOS/*"))) if not p.endswith(".dylib")), None)
SCRATCH = tempfile.mkdtemp(prefix=f"anim-perf-{TAG}-")
open(os.path.join(SCRATCH, "ghostty"), "w").close()
CONFIG = os.path.join(SCRATCH, "cmux.json")
open(CONFIG, "w").write(json.dumps({"ui": {"animationSpeed": "off"}}) + "\n" if opts.reduce_motion else "{}\n")
WINDOW = (80, 80, 1600, 1000)
ROWS = []
app = None
state = {}


def rpc(method, params=None, timeout=30):
    import socket
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCKET)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 22)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def action(name, args=None, settle=0.0, timeout=60):
    reply = rpc("action.run", {"action": name, "args": args or {}, "focus": True, "origin": "script"}, timeout=timeout)
    if settle:
        time.sleep(settle)  # test harness: the layout settles before the next step
    return reply


def error_of(reply):
    return str(reply.get("error")) if isinstance(reply, dict) and reply.get("error") else None


def wait(check, seconds, step=0.1):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            value = check()
        except Exception:  # the app may not answer yet
            value = None
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def topology():
    return (rpc("snapshot.get") or {}).get("topology") or {}


def shown_workspace():
    return (topology().get("focus") or {}).get("workspace")


def workspace_ids():
    return [w.get("id") for w in topology().get("workspaces") or [] if w.get("id")]


def row(check, expected, observed, ok):
    ROWS.append((check, expected, observed, ok))
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


# -- setup: a workspace A of one pane with 3 tabs, a workspace B of 4 panes, a sidebar group of 3 workspaces --

def setup():
    action("workspace.newAtBottom", settle=1.5)
    action("terminal.sendText", {"text": "seq 1 3000\r"})
    for _ in range(2):
        action("newTab", settle=0.8)
    state["a"] = shown_workspace()
    action("workspace.newAtBottom", settle=1.5)
    for verb in ("splitRight", "splitDown", "focusLeft", "splitDown"):
        action(verb, settle=0.6)
    state["b"] = shown_workspace()
    action("workspace.newInNewGroup", settle=1.2)
    state["group_ws"] = shown_workspace()
    for _ in range(2):
        action("workspace.newBelow", settle=1.0)
    action("goToWorkspace", {"workspace": state["group_ws"]}, settle=0.8)
    state["chats"] = seed_home()
    action("goToWorkspace", {"workspace": state["a"]}, settle=1.0)
    time.sleep(1.5)  # test harness: launch and setup work settles


class Owner:
    """A JSON-lines connection to the Chief home's daemon (the v1 protocol, as home-inbox-parity.py)."""

    def __init__(self, path):
        import socket
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(15)
        self.sock.connect(path)
        self.buf, self.next = b"", 1

    def request(self, cmd, **params):
        rid = self.next
        self.next += 1
        self.sock.sendall((json.dumps({"id": rid, "cmd": cmd, **params}) + "\n").encode())
        while True:
            while b"\n" not in self.buf:
                chunk = self.sock.recv(1 << 16)
                if not chunk:
                    raise RuntimeError(f"{cmd}: the daemon closed the connection")
                self.buf += chunk
            line, self.buf = self.buf.split(b"\n", 1)
            value = json.loads(line)
            if value.get("id") == rid and "event" not in value:
                if value.get("ok") is not True:
                    raise RuntimeError(f"{cmd} refused: {value}")
                return value.get("data")


def owner_socket(session):
    darwin = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
    for base in [b for b in (darwin, os.environ.get("TMPDIR", ""), "/tmp", "/private/tmp") if b]:
        path = os.path.join(base, f"cmux-tui-{os.getuid()}", f"{session}.sock")
        try:
            if Owner(path).request("identify").get("session") == session:
                return path
        except (OSError, RuntimeError, ValueError):
            continue
    return None


def seed_home(count=4):
    """Home with `count` chats (each with a few messages) in the isolated Chief home, so chat-next/prev switch
    between real conversations. Returns the conversation ids (empty when the owner never answers)."""
    if not wait(lambda: not error_of(action("home.show")), 120):
        print("  (home.show refused: no Home chats)", flush=True)
        return []
    session = wait(lambda: ((rpc("debug.home") or {}).get("chief_owner") or {}).get("session"), 60)
    path = wait(lambda: owner_socket(session), 120) if session else None
    if not path:
        print(f"  (no Chief owner socket for session {session}: no Home chats)", flush=True)
        return []
    owner = Owner(path)
    me = (owner.request("home-inbox") or {}).get("me") or "user_local"
    person = {"id": me, "kind": "human", "display_name": "Bench"}
    stamp = str(int(time.time()))
    made = []
    for index in range(count):
        key = f"anim-{index}-{stamp}"
        conversation = owner.request("conversation-create", idempotency_key=key, title=f"Bench chat {index + 1}",
                                     participants=[person])["conversation"]["id"]
        for line in range(6):
            owner.request("conversation-op", conversation=conversation, idempotency_key=f"{key}-m{line}",
                          op={"kind": "message.send", "client_msg_id": f"{key}-m{line}",
                              "parts": [{"type": "text", "text": f"message {line + 1} of chat {index + 1}: " + "lorem ipsum " * 12}]})
        made.append(conversation)
    rows = wait(lambda: (lambda ids: ids if set(made) <= ids else None)(
        {r.get("id") for r in (rpc("debug.home") or {}).get("dock", {}).get("messages_list") or []}), 60)
    print(f"  seeded {len(made)} Home chats (listed: {bool(rows)})", flush=True)
    return made


def go(workspace):
    return error_of(action("goToWorkspace", {"workspace": workspace}))


# Each animation: (prepare, perform). prepare runs untimed; perform is the timed gesture.
def anims():
    a = lambda: go(state["a"])  # noqa: E731
    two_panes = lambda: (go(state["a"]), action("splitRight", settle=0.8), action("focusLeft", settle=0.3))  # noqa: E731
    one_pane = lambda: (go(state["a"]), action("focusRight", settle=0.2), action("closePane", settle=0.8))  # noqa: E731
    return [
        ("tab-new", a, lambda: error_of(action("newTab"))),
        ("tab-close", None, lambda: error_of(action("closeTab"))),
        ("tab-move-right", a, lambda: error_of(action("moveSurfaceRight"))),
        ("tab-move-left", None, lambda: error_of(action("moveSurfaceLeft"))),
        ("tab-to-pane", two_panes, lambda: error_of(action("moveSurfaceToPaneRight"))),
        ("tab-back", None, lambda: error_of(action("moveSurfaceToPaneLeft"))),
        ("split-right", one_pane, lambda: error_of(action("splitRight"))),
        ("split-close", None, lambda: error_of(action("closePane"))),
        ("split-down", a, lambda: error_of(action("splitDown"))),
        ("split-down-close", None, lambda: error_of(action("closePane"))),
        ("column", a, lambda: error_of(action("newColumn"))),
        ("column-close", None, lambda: error_of(action("closePane"))),
        ("ws-switch", a, lambda: go(state["b"])),
        ("ws-back", None, lambda: go(state["a"])),
        ("sidebar-hide", a, lambda: error_of(action("toggleSidebar"))),
        ("sidebar-show", None, lambda: error_of(action("toggleSidebar"))),
        ("right-open", a, lambda: error_of(action("toggleRightSidebar"))),
        ("right-close", None, lambda: error_of(action("toggleRightSidebar"))),
        ("group-collapse", lambda: go(state["group_ws"]), lambda: error_of(action("toggleFocusedWorkspaceGroupCollapsed"))),
        ("group-expand", None, lambda: error_of(action("toggleFocusedWorkspaceGroupCollapsed"))),
        ("home-show", a, lambda: error_of(action("home.show"))),
        ("chat-open", None, lambda: error_of(action("home.openConversation", {"conversation": state["chats"][0]}))
         if state.get("chats") else "no seeded chats"),
        ("chat-next", None, lambda: error_of(action("home.nextConversation"))),
        ("chat-prev", None, lambda: error_of(action("home.previousConversation"))),
        ("home-leave", None, lambda: go(state["a"])),
        ("palette-open", a, lambda: error_of(action("commandPalette"))),
        ("palette-close", None, lambda: error_of(action("commandPalette"))),
    ]


def measure(name, perform):
    rpc("debug.hangs", {"clear": True})
    rpc("debug.frames", {"action": "start"})
    time.sleep(0.1)  # test harness: frames at rest before the gesture, so the first interval is a real one
    error = perform()
    time.sleep(1.0)  # test harness: the springs land (rest is under 0.6 s)
    frames = rpc("debug.frames", {"action": "stop"}) or {}
    hangs = rpc("debug.hangs") or {}
    hang_list = hangs.get("hangs") if isinstance(hangs, dict) else None
    result = {"anim": name, "error": error, "frames": frames.get("frames"), "refresh_ms": frames.get("refresh_ms"),
              "dropped": frames.get("missed"), "p50_ms": frames.get("p50_ms"), "p95_ms": frames.get("p95_ms"),
              "max_ms": frames.get("max_ms"), "over_8_33": frames.get("over_8_33_ms"),
              "main_ms_total": frames.get("main_ms_total"), "main_ms_p95": frames.get("main_ms_p95"),
              "main_ms_max": frames.get("main_ms_max"), "main_over_8_33": frames.get("main_over_8_33_ms"),
              "missed_at_ms": frames.get("missed_at_ms"),
              "hangs": len(hang_list) if isinstance(hang_list, list) else hangs.get("count")}
    print(f"  {name:<17} frame p50 {fmt(result['p50_ms'])} p95 {fmt(result['p95_ms'])} max {fmt(result['max_ms'])} ms "
          f"dropped {result['dropped']} >8.3 {result['over_8_33']} (refresh {fmt(result['refresh_ms'])})  main p95 "
          f"{fmt(result['main_ms_p95'])} max {fmt(result['main_ms_max'])} total {fmt(result['main_ms_total'])} ms  "
          f"hangs {result['hangs']}  err {error}", flush=True)
    return result


def fmt(v):
    return "-" if v is None else (f"{v:.1f}" if isinstance(v, float) else str(v))


def profile(name, prepare, perform, undo):
    """Samples the app (`/usr/bin/sample`, 1 ms) while it repeats `name` and its undo; keeps the report."""
    path = os.path.join(opts.out, f"sample-{name}.txt")
    seconds = max(3, int(opts.sample_repeats * 1.2) + 1)
    if prepare:
        prepare()
    sampler = subprocess.Popen(["/usr/bin/sample", str(app.pid), str(seconds), "1", "-mayDie", "-file", path],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.5)  # test harness: the sampler attaches
    for _ in range(opts.sample_repeats):
        perform()
        time.sleep(0.55)  # test harness: each spring lands before the next press
        if undo:
            undo()
            time.sleep(0.55)  # test harness: the same for the undo
    sampler.wait(timeout=seconds + 60)
    try:
        text = open(path, errors="replace").read()
    except OSError:
        print(f"  (no sample for {name})", flush=True)
        return
    top = text.split("Sort by top of stack")
    if len(top) > 1:
        print(f"== sample {name}: heaviest frames (all threads, top of stack)", flush=True)
        print("\n".join(top[1].splitlines()[:30]), flush=True)


def budgets():
    try:
        return json.load(open(BUDGETS)).get("animations") or []
    except (OSError, ValueError):
        return []


def cleanup():
    if os.environ.get("ANIM_PERF_KEEP") or not app:
        return
    rpc("action.run", {"action": "quitEndSessions"}, timeout=10)
    try:
        app.wait(timeout=20)
    except subprocess.TimeoutExpired:
        os.kill(app.pid, signal.SIGKILL)
    subprocess.run([CLI, "server", "stop", "--session", f"cmux-app-{TAG}", "--end-terminals"],
                   env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)
    if os.path.exists(SOCKET):
        os.remove(SOCKET)


def main():
    global app, SOCKET
    if os.path.exists(SOCKET):
        os.remove(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": CONFIG,
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"),
           "CMUX_NEXT_TEST_WINDOW_FRAME": ",".join(str(v) for v in WINDOW),
           "CMUX_NEXT_CHIEF_ISOLATED": "1", "CMUX_NEXT_CHIEF_HOME": os.path.join(SCRATCH, "chief")}
    os.makedirs(opts.out, exist_ok=True)
    log = open(os.path.join(opts.out, f"app-{TAG}.log"), "a")
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    macos = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
    host = subprocess.run(["hostname"], capture_output=True, text=True).stdout.strip()
    print(f"launched pid {app.pid} macOS {macos} host {host}", flush=True)
    state_socket = os.path.expanduser(f"~/.local/state/cmux/cmux-debug-{TAG}.sock")

    def up():
        global SOCKET
        for path in (f"/tmp/cmux-debug-{TAG}.sock", state_socket):
            if os.path.exists(path):
                SOCKET = path
                if (rpc("debug.windows") or {}).get("windows"):
                    return True
        return False
    if not wait(up, 120):
        log.flush()
        print("the tagged app did not come up", flush=True)
        print(open(os.path.join(opts.out, f"app-{TAG}.log"), errors="replace").read()[-6000:], flush=True)
        sys.exit(1)
    time.sleep(5)  # test harness: launch work settles
    setup()
    wanted = set(filter(None, opts.anims.split(",")))
    plan = [(n, p, f) for n, p, f in anims() if not wanted or n in wanted]
    report = {"tag": TAG, "macos": macos, "host": host, "reduce_motion": opts.reduce_motion, "runs": []}
    for index in range(opts.rounds):
        for name, prepare, perform in plan:
            if prepare:
                prepare()
                time.sleep(0.6)  # test harness: the prepare's own motion lands before the timed gesture
            run = measure(name, perform)
            run["round"] = index
            report["runs"].append(run)
            if opts.json:
                json.dump(report, open(opts.json, "w"), indent=1)
            time.sleep(0.3)  # test harness: idle between runs
    by_name = {n: (p, f) for n, p, f in anims()}
    undo = {"tab-new": "tab-close", "tab-move-right": "tab-move-left", "split-right": "split-close", "column": "column-close",
            "ws-switch": "ws-back", "sidebar-hide": "sidebar-show", "right-open": "right-close", "group-collapse": "group-expand",
            "palette-open": "palette-close", "tab-to-pane": "tab-back", "split-down": "split-down-close"}
    for name in filter(None, opts.sample.split(",")):
        if name in by_name:
            prepare, perform = by_name[name]
            profile(name, prepare, perform, by_name.get(undo.get(name), (None, None))[1])

    def med(runs, key):
        values = sorted(v for v in (r.get(key) for r in runs) if v is not None)
        return values[len(values) // 2] if values else None

    def worst(runs, key):
        values = [v for v in (r.get(key) for r in runs) if v is not None]
        return max(values) if values else None
    print("\n== summary (median over rounds; max is the worst round)")
    print(f"  {'anim':<17} {'p50':>6} {'p95':>6} {'max':>6} {'drop':>5} {'>8.3':>5} {'mainp95':>7} {'mainmx':>7} {'maintot':>7} {'err'}")
    for name, _, _ in plan:
        runs = [r for r in report["runs"] if r["anim"] == name]
        summary = {"anim": name, **{k: med(runs, k) for k in ("p50_ms", "p95_ms", "dropped", "over_8_33", "main_ms_p95",
                                                                "main_ms_total", "frames")},
                   "max_ms": worst(runs, "max_ms"), "main_ms_max": worst(runs, "main_ms_max"),
                   "errors": sorted({r["error"] for r in runs if r["error"]})}
        report.setdefault("summary", []).append(summary)
        print(f"  {name:<17} {fmt(summary['p50_ms']):>6} {fmt(summary['p95_ms']):>6} {fmt(summary['max_ms']):>6} "
              f"{fmt(summary['dropped']):>5} {fmt(summary['over_8_33']):>5} {fmt(summary['main_ms_p95']):>7} "
              f"{fmt(summary['main_ms_max']):>7} {fmt(summary['main_ms_total']):>7} {'; '.join(summary['errors'])[:60]}", flush=True)
        row(f"{name}: ran", "no error", "; ".join(summary["errors"]) or "None", not summary["errors"] or False)
    for budget in budgets():
        anim, key, limit = budget.get("anim"), budget.get("metric"), budget.get("limit")
        summary = next((s for s in report.get("summary", []) if s["anim"] == anim), None)
        if not summary or summary.get(key) is None:
            continue
        ok = summary[key] <= limit or not (opts.gate and budget.get("enforce"))
        row(f"budget {anim} {key}" + ("" if budget.get("enforce") else " (advisory)"), f"<= {limit}", fmt(summary[key]), ok)
    if opts.json:
        json.dump(report, open(opts.json, "w"), indent=1)


try:
    main()
except Exception:  # the step log is stdout only
    import traceback
    traceback.print_exc(file=sys.stdout)
finally:
    cleanup()
    if opts.json and os.path.exists(opts.json):
        # The step log keeps the numbers even when a row failed (no artifact comes back then).
        print("REPORT-JSON " + json.dumps(json.load(open(opts.json)).get("summary") or []), flush=True)
    print("\nRESULT", "PASS" if ROWS and all(r[3] for r in ROWS) else "FAIL", f"({sum(r[3] for r in ROWS)}/{len(ROWS)})")
    sys.exit(0 if ROWS and all(r[3] for r in ROWS) else 1)
