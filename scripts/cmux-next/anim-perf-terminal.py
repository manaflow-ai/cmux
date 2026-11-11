#!/usr/bin/env python3
"""App animation frame times, measured in a real window (anim-perf, Lawrence 2026-10-21: "we need to fix all
animation lag as well. for new tabs, making splits, etc.").

The pane motion of bonsplit and columns (split, close, New Column, zoom, divider drag at 2 to 30 panes) is
pane-perf-terminal.py's (a421). This bench covers every other animation, and one split/column pass in a small
layout so a single table compares builds:

  tab-new / tab-close           newTab (the New Tab page) and closeTab, in a pane with 3 tabs
  tab-move / tab-move-back      moveSurfaceRight (Left at the strip's edge) and back (the tab strip reorder)
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
(`debug.frames`, `debug.main_cpu`), and hangs (`debug.hangs`). The budgets (scripts/perf-bench/budgets.json `animations`) are a 120 Hz
frame: no dropped frame, no frame and no main-thread slice over 8.33 ms. Each starts advisory; --gate fails on the
enforced ones.

Usage: anim-perf-terminal.py --tag <tag> --app PATH [--anims a,b] [--rounds 3] [--json PATH] [--out DIR] [--gate]
Fleet: scripts/measure/split-spring.sh --arg=--suite=anim-perf (scripts/measure/anim-perf.sh once allowlisted).
"""
import argparse, glob, json, os, signal, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_launch import LaunchError, launch_app  # noqa: E402

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

def make_a():
    action("workspace.newAtBottom", settle=1.5)
    action("terminal.sendText", {"text": "seq 1 3000\r"})
    for _ in range(2):
        action("newTab", settle=0.8)
    state["a"] = shown_workspace()


def setup():
    make_a()
    action("workspace.newAtBottom", settle=1.5)
    for verb in ("splitRight", "splitDown", "focusLeft", "splitDown"):
        action(verb, settle=0.6)
    state["b"] = shown_workspace()
    action("workspace.newInNewGroup", settle=1.2)
    state["group_ws"] = shown_workspace()
    for _ in range(2):
        action("workspace.newBelow", settle=1.0)
    state["chats"] = seed_home()
    action("goToWorkspace", {"workspace": state["a"]}, settle=1.0)
    time.sleep(1.5)  # test harness: launch and setup work settles


def go(workspace):
    return error_of(action("goToWorkspace", {"workspace": workspace}))


def panes_of(workspace):
    """[(pane id, tab count)] of `workspace`."""
    for w in topology().get("workspaces") or []:
        if w.get("id") == workspace:
            return [(p.get("id"), len(p.get("tabs") or p.get("surfaces") or [])) for s in w.get("screens") or [] for p in s.get("panes") or []]
    return None


def at_a(panes=1):
    """Shows workspace A with `panes` panes (made again when a close took it), focused on the first pane's middle tab."""
    if panes_of(state.get("a")) is None:
        make_a()
    go(state["a"])
    time.sleep(0.4)  # test harness: the switch lands
    while len(panes_of(state["a"]) or []) > panes:
        action("focusRight", settle=0.2)
        action("closePane", settle=0.8)
    while len(panes_of(state["a"]) or []) < panes:
        action("splitRight", settle=0.8)
    for _ in range(panes):
        action("focusLeft", settle=0.2)
    first = (panes_of(state["a"]) or [(None, 0)])[0]
    for _ in range(max(0, 3 - first[1])):
        action("newTab", settle=0.8)


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


OPPOSITE = {"moveSurfaceRight": "moveSurfaceLeft", "moveSurfaceLeft": "moveSurfaceRight",
            "moveSurfaceToPaneRight": "moveSurfaceToPaneLeft", "moveSurfaceToPaneLeft": "moveSurfaceToPaneRight"}


def either(first, second, key):
    """Runs `first`; when the app refuses it (the tab is at that edge), `second`. Remembers which ran for `undo`.
    A refusal runs no motion and costs no frame, so the timed gesture is the move that ran."""
    reply = action(first)
    if error_of(reply):
        state[key] = second
        return error_of(action(second))
    state[key] = first
    return None


def undo(key):
    return error_of(action(OPPOSITE[state[key]])) if state.get(key) else "nothing to undo"


# Each animation: (prepare, perform). prepare runs untimed; perform is the timed gesture.
def anims():
    run = lambda verb: (lambda: error_of(action(verb)))  # noqa: E731
    return [
        ("tab-new", lambda: at_a(1), run("newTab")),
        ("tab-close", None, run("closeTab")),
        ("tab-move", lambda: action("newTab", settle=0.8), lambda: either("moveSurfaceRight", "moveSurfaceLeft", "tab-move")),
        ("tab-move-back", None, lambda: undo("tab-move")),
        ("tab-to-pane", lambda: (at_a(2), action("newTab", settle=0.8)),
         lambda: either("moveSurfaceToPaneRight", "moveSurfaceToPaneLeft", "tab-to-pane")),
        ("tab-back", None, lambda: undo("tab-to-pane")),
        ("split-right", lambda: at_a(1), run("splitRight")),
        ("split-close", None, run("closePane")),
        ("split-down", lambda: at_a(1), run("splitDown")),
        ("split-down-close", None, run("closePane")),
        ("column", lambda: at_a(1), run("newColumn")),
        ("column-close", None, run("closePane")),
        ("ws-switch", lambda: at_a(1), lambda: go(state["b"])),
        ("ws-back", None, lambda: go(state["a"])),
        ("sidebar-hide", lambda: at_a(1), run("toggleSidebar")),
        ("sidebar-show", None, run("toggleSidebar")),
        ("right-open", lambda: at_a(1), run("toggleRightSidebar")),
        ("right-close", None, run("toggleRightSidebar")),
        ("group-collapse", lambda: go(state["group_ws"]), run("toggleFocusedWorkspaceGroupCollapsed")),
        ("group-expand", None, run("toggleFocusedWorkspaceGroupCollapsed")),
        ("home-show", lambda: at_a(1), run("home.show")),
        ("chat-open", None, lambda: error_of(action("home.openConversation", {"conversation": state["chats"][0]}))
         if state.get("chats") else "no seeded chats"),
        ("chat-next", None, run("home.nextConversation")),
        ("chat-prev", None, run("home.previousConversation")),
        ("home-leave", None, lambda: go(state["a"])),
        ("palette-open", lambda: at_a(1), run("commandPalette")),
        ("palette-close", None, run("commandPalette")),
    ]


def measure(name, perform):
    rpc("debug.hangs", {"clear": True})
    rpc("debug.frames", {"action": "start"})
    rpc("debug.main_cpu", {"action": "start"})
    time.sleep(0.1)  # test harness: frames at rest before the gesture, so the first interval is a real one
    error = perform()
    time.sleep(1.0)  # test harness: the springs land (rest is under 0.6 s)
    cpu = rpc("debug.main_cpu", {"action": "stop"}) or {}
    frames = rpc("debug.frames", {"action": "stop"}) or {}
    if isinstance(cpu, dict) and not cpu.get("error"):
        frames = {**frames, **{k: v for k, v in cpu.items() if k != "frames"}}
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
    print(f"== sample {name}: main thread, heaviest non-idle call paths", flush=True)
    for line in main_thread_hot(text):
        print(line, flush=True)


IDLE = ("mach_msg2_trap", "mach_msg_trap", "__CFRunLoopServiceMachPort", "kevent", "__psynch_cvwait", "semaphore_wait")


def main_thread_hot(text, limit=40):
    """The main thread's call tree with idle waits removed: the deepest frames under 1 ms samples that hold at
    least 2 % of the busy samples, so a profile names where a slow animation's main-thread time goes."""
    import re
    graph = text.split("Call graph:", 1)
    if len(graph) < 2:
        return ["  (no call graph)"]
    lines = graph[1].splitlines()
    node = re.compile(r"^([ +!:|]*)(\d+) (.*?)(?:  \(in ([^)]*)\).*)?$")
    start = next((i for i, l in enumerate(lines) if "com.apple.main-thread" in l), None)
    if start is None:
        return ["  (no main thread)"]
    head = node.match(lines[start])
    base = len(head.group(1))
    nodes = []  # (depth, count, symbol)
    modules = []
    for line in lines[start + 1:]:
        m = node.match(line)
        if not m:
            continue
        depth = len(m.group(1))
        if depth <= base:
            break
        nodes.append((depth, int(m.group(2)), m.group(3).strip()[:150]))
        modules.append(m.group(4) or "")
    # Each node's busy samples: its own count less the idle waits under it (children by depth).
    parents, busy_of = [], [0] * len(nodes)
    for i, (depth, count, sym) in enumerate(nodes):
        while parents and nodes[parents[-1]][0] >= depth:
            parents.pop()
        busy_of[i] = 0 if any(k in sym for k in IDLE) else count
        nodes[i] = (depth, count, sym, parents[-1] if parents else None)
        parents.append(i)
    def under_idle(i):
        j = nodes[i][3]
        while j is not None:
            if any(k in nodes[j][2] for k in IDLE):
                return True
            j = nodes[j][3]
        return False
    for i in range(len(nodes) - 1, -1, -1):
        parent = nodes[i][3]
        # Only the outermost idle wait counts: a wait nested in another (mach_msg2_trap under
        # __CFRunLoopServiceMachPort) is the same samples, and counting both drove busy below zero.
        if parent is not None and any(k in nodes[i][2] for k in IDLE) and not under_idle(i):
            # the idle wait's samples leave every ancestor
            j = parent
            while j is not None:
                busy_of[j] -= nodes[i][1]
                j = nodes[j][3]
    for i in range(len(nodes)):
        if under_idle(i):
            busy_of[i] = 0  # inside a wait: the waiting thread's own frames, not work
    total = int(head.group(2))
    busy = max(1, sum(b for i, b in enumerate(busy_of) if nodes[i][3] is None))
    out = [f"  main thread samples {total}, busy {busy} (1 ms each)"]
    threshold = max(2, busy // 50)
    for i, (depth, count, sym, _) in enumerate(nodes):
        if busy_of[i] < threshold:
            continue
        kids = [busy_of[j] for j in range(i + 1, len(nodes)) if nodes[j][3] == i]
        if all(k < threshold for k in kids):
            out.append(f"  {busy_of[i]:>6}  {100.0 * busy_of[i] / busy:5.1f}%  {sym}")
    out = out[:limit]
    # Where our own code spends it: the busiest cmux frames, inclusive (each counted once on its path).
    ours = {}
    for i, (depth, count, sym, _) in enumerate(nodes):
        if "cmux" not in modules[i] or busy_of[i] < threshold:
            continue
        j, nested = nodes[i][3], False
        while j is not None:
            if nodes[j][2] == sym:
                nested = True
                break
            j = nodes[j][3]
        if not nested:
            ours[sym] = ours.get(sym, 0) + busy_of[i]
    out.append("  -- our frames, inclusive busy samples --")
    for sym, count in sorted(ours.items(), key=lambda kv: -kv[1])[:40]:
        out.append(f"  {count:>6}  {100.0 * count / busy:5.1f}%  {sym}")
    return out


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
    log_path = os.path.join(opts.out, f"app-{TAG}.log")
    macos = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
    host = subprocess.run(["hostname"], capture_output=True, text=True).stdout.strip()

    def started(process):
        global app
        app = process
    # One launch path (bench_launch.py): socket in the state folder, bench env, the reason (main-thread sample, log
    # tail) when it does not come up.
    try:
        app, SOCKET = launch_app(APP, env, log_path, timeout=120, on_start=started)
    except LaunchError as error:
        if error.reason == "no-gui-session":
            sys.exit(1)
        # macOS 27 minis: a first launch can stall before its socket (NSXPCSharedListener interrupted); one relaunch.
        print("the tagged app did not come up in 120 s; relaunching once", flush=True)
        if app and app.poll() is None:
            app.kill()  # the pid this script started
            app.wait(timeout=30)
        try:
            app, SOCKET = launch_app(APP, env, log_path, timeout=120, on_start=started)
        except LaunchError:
            sys.exit(1)
    print(f"launched pid {app.pid} macOS {macos} host {host}", flush=True)
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
    undo_of = {"tab-new": "tab-close", "tab-move": "tab-move-back", "split-right": "split-close", "column": "column-close",
            "ws-switch": "ws-back", "sidebar-hide": "sidebar-show", "right-open": "right-close", "group-collapse": "group-expand",
            "palette-open": "palette-close", "tab-to-pane": "tab-back", "split-down": "split-down-close"}
    for name in filter(None, opts.sample.split(",")):
        if name in by_name:
            prepare, perform = by_name[name]
            profile(name, prepare, perform, by_name.get(undo_of.get(name), (None, None))[1])

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
