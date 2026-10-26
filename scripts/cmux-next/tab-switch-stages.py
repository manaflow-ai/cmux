#!/usr/bin/env python3
"""Per-stage time of a warm tab switch inside one pane, on a tagged cmux-next build (tab-switch-fast).

Launches the tagged app itself (no activation, scratch config, empty Ghostty config), makes one pane
with a terminal, a Chromium page, a WebKit page, a Markdown file and a second terminal, visits each
once (warm), then switches between them with Ctrl-Tab / Ctrl-Shift-Tab (`debug.key`, the key router's
real path) and with clicks on the tab strip (`debug.mouse`, AppKit events into the strip), one switch
every --interval ms. Per switch `debug.tab_switch` reports, in ms since the intent began:
  input    the key or click event's age when the intent began (event -> PaneController.select)
  focus    select -> applySelection (focus coordinator and the focus reducer)
  strip    the strip shows the selection
  withdraw the old tab concealed;  content  the new tab's content looked up
  reveal   the new tab presented (its rendering resumed);  view  its view swapped into the pane
  present  presentSelection returned;  record  window-record save requested (async)
  apply    the selection is shown (the switch's main-thread cost)
  commit   the Core Animation commit that carries it; late_vsyncs: frames it missed (0 = first frame)
plus confirm_ms: the daemon stored the selection (window record write), asynchronous.
The budget: a warm switch commits in the first frame (late_vsyncs 0) and apply p90 <= 8 ms.

Usage: tab-switch-stages.py --tag <tag> --app PATH [--rounds 12] [--interval 0.25] [--out DIR] [--json PATH]
"""
import argparse, glob, json, os, re, signal, socket, statistics, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_launch import BenchApp, bundle_id  # noqa: E402

# `--matrix`: every tab kind at 2/10/30/60 tabs with CPU and memory (tab-switch-matrix.py), through the
# same fleet entry (scripts/measure/tab-switch.sh passes its arguments here).
if "--matrix" in sys.argv:
    os.execv(sys.executable, [sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "tab-switch-matrix.py"), *sys.argv[1:]])

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True, help="the tagged .app bundle")
parser.add_argument("--rounds", type=int, default=12, help="passes over the tabs per input kind and direction")
parser.add_argument("--interval", type=float, default=0.25, help="seconds between switches")
parser.add_argument("--apply-budget-ms", type=float, default=8.0)
parser.add_argument("--out", default="/tmp")
parser.add_argument("--json", help="write the samples here")
opts = parser.parse_args()
TAG, APP = opts.tag, os.path.abspath(opts.app.rstrip("/"))
BUNDLE_ID = bundle_id(APP) or f"com.cmuxterm.app.debug.{TAG}"
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
BINARY = next((p for p in sorted(glob.glob(os.path.join(APP, "Contents/MacOS/*"))) if not p.endswith(".dylib")), None)
SCRATCH = tempfile.mkdtemp(prefix=f"tabswitch-{TAG}-")
open(os.path.join(SCRATCH, "ghostty"), "w").close()
CONFIG = os.path.join(SCRATCH, "cmux.json")
open(CONFIG, "w").write("{}\n")
ENV = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1"}
STAGES = ["input", "focus", "strip", "withdraw", "content", "reveal", "stripSync", "view", "present", "record", "apply", "commit"]
ROWS, LAUNCHED = [], []
app = None


def run(*args, timeout=30):
    env = {**ENV, "CMUX_TAG": TAG, "CMUX_BUNDLE_ID": BUNDLE_ID, "CMUX_BUNDLED_CLI_PATH": CLI}
    return subprocess.run([CLI, *args], capture_output=True, text=True, timeout=timeout, env=env)


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


def action(name, args=None, timeout=60):
    return rpc("action.run", {"action": name, "args": args or {}, "focus": True, "origin": "script"}, timeout=timeout)


def wait(check, seconds, step=0.25):
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


def panes():
    return [p for w in ((rpc("debug.surfaces") or {}).get("windows") or []) for p in w.get("panes", [])]


def focused_pane():
    return next((p for p in panes() if p.get("focused")), None)


def row(check, expected, observed, ok):
    ROWS.append((check, expected, observed, ok))
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


def strip_tabs(minimum=1):
    """The focused strip's tabs as (id-or-label, center point in window coordinates): the first strip with at least
    `minimum` tabs. Setup waits for each new tab with the default; it needed 5 before, so it never saw tab 2."""
    for strip in (rpc("debug.tab_drag") or {}).get("strips") or []:
        tabs = strip.get("tabs") or []
        if len(tabs) >= minimum:
            out = []
            for tab in tabs:
                f = tab["frame"]
                f = [f["x"], f["y"], f["width"], f["height"]] if isinstance(f, dict) else list(f)
                out.append((tab.get("id") or tab.get("label"), [f[0] + f[2] * 0.4, f[1] + f[3] / 2]))
            return out
    return []


def pct(values, q):
    values = sorted(values)
    return values[min(len(values) - 1, int(len(values) * q))] if values else None


def summarize(label, switches):
    print(f"\n== {label}: {len(switches)} switches", flush=True)
    by_kind = {}
    for s in switches:
        by_kind.setdefault(s.get("kind", "?"), []).append(s)
    table = {}
    for kind, rows in sorted(by_kind.items()):
        line = {}
        for stage in STAGES:
            values = [r[stage + "_ms"] for r in rows if stage + "_ms" in r]
            if values:
                line[stage] = {"p50": round(pct(values, 0.5), 2), "p90": round(pct(values, 0.9), 2), "max": round(max(values), 2)}
        late = [r.get("late_vsyncs", 0) for r in rows]
        line["late_vsyncs"] = {"mean": round(statistics.mean(late), 2), "max": max(late), "late_switches": sum(1 for v in late if v > 0)}
        table[kind] = line
        cells = " ".join(f"{st}={line[st]['p50']}/{line[st]['p90']}" for st in STAGES if st in line)
        print(f"  {kind:<10} n={len(rows):<3} p50/p90 ms: {cells}  late={line['late_vsyncs']}", flush=True)
    return table


def measure(label, step, count):
    rpc("debug.frames", {"action": "start"})  # keeps the display link ticking: a commit's frame is the next vsync
    rpc("debug.tab_switch", {"action": "start"})
    rpc("debug.hangs", {"clear": True})
    for index in range(count):
        step(index)
        time.sleep(opts.interval)  # test harness pacing: one switch per frame window
    time.sleep(1.0)  # test harness: the last commit and the daemon confirms land
    own = rpc("debug.tab_switch", {"action": "stop"}) or {}
    rpc("debug.frames", {"action": "stop"})
    hangs = rpc("debug.hangs") or {}
    switches = own.get("switches") or []
    confirms = own.get("confirms_ms") or []
    table = summarize(label, switches)
    if confirms:
        print(f"  daemon confirm (async) p50 {pct(confirms, 0.5):.1f} p90 {pct(confirms, 0.9):.1f} max {max(confirms):.1f} ms "
              f"({len(confirms)} switches)", flush=True)
    print(f"  main-thread stalls: count={hangs.get('count')} max={hangs.get('max_ms')}", flush=True)
    for record in (hangs.get("records") or [])[-4:]:
        frames = [f for f in record.get("frames", []) if "CmuxNext" in f or "Ghostty" in f or "cef" in f.lower()][:10]
        print(f"  stall {record.get('duration_ms', 0):.1f} ms: " + " < ".join(str(f)[:80] for f in frames), flush=True)
    timed = len(switches)
    row(f"{label}: timed", f"{count} switches timed", f"{timed}", timed >= count * 0.9)
    for kind, line in table.items():
        if kind == "cold":
            continue
        apply_p90 = line.get("apply", {}).get("p90", 0)
        late = line["late_vsyncs"]["late_switches"]
        row(f"{label}: {kind}", f"apply p90 <= {opts.apply_budget_ms} ms, every switch in its first frame",
            f"apply p90 {apply_p90} ms, late {late}", apply_p90 <= opts.apply_budget_ms and late == 0)
    return {"switches": switches, "confirms_ms": confirms, "table": table, "hangs": {k: v for k, v in hangs.items() if k != "records"}}


def cleanup():
    print("cleanup", flush=True)
    if os.environ.get("TABSWITCH_KEEP") or not LAUNCHED:
        return
    rpc("action.run", {"action": "quitEndSessions"}, timeout=10)
    if app:
        try:
            app.wait(timeout=20)
        except subprocess.TimeoutExpired:
            os.kill(app.pid, signal.SIGKILL)
    subprocess.run([CLI, "server", "stop", "--session", f"cmux-app-{TAG}", "--end-terminals"],
                   env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)
    for _ in range(2):
        ps = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True).stdout
        for line in ps.splitlines():
            parts = line.split(None, 2)
            if len(parts) == 3 and parts[2].startswith(APP + "/") and int(parts[0]) != os.getpid():
                print("leftover", line[:160], flush=True)
                try:
                    os.kill(int(parts[0]), signal.SIGTERM)
                except OSError:
                    pass
        time.sleep(3)  # test harness: let them exit
    if os.path.exists(SOCKET):
        os.remove(SOCKET)


def main():
    global app, SOCKET
    # No socket check here: BenchApp.launch() refuses a live same-tag app (any bundle path) and unlinks only a
    # socket nothing accepts on.
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG,
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"), "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1400,900"}
    # One launch path (bench_launch.py): socket in the state folder, bench env, a clear reason when it does not come up.
    launcher = BenchApp(APP, out=opts.out, log_name=f"app-{TAG}.log", window=None, screen=None, teardown=False, env=env)
    try:
        launcher.launch(timeout=120, on_start=lambda process: LAUNCHED.append(process.pid))
    finally:
        app = launcher.process
    SOCKET = launcher.socket
    ENV["CMUX_SOCKET_PATH"] = SOCKET
    print(f"launched pid {app.pid}", flush=True)
    for old in set(re.findall(r"(ws_[0-9a-f]+)\s+tabswitch-e2e", run("workspace", "list").stdout)):
        run("workspace", old, "close")
    made = run("workspace", "create", "--name", "tabswitch-e2e")
    tab = re.search(r"value\.tab_id\s+(tab_\S+)", made.stdout)
    workspace = re.search(r"value\.workspace_id\s+(\S+)", made.stdout)
    if workspace:
        run("workspace", workspace.group(1), "focus")
    for index in range(1, 10):
        rpc("action.run", {"action": "selectWorkspaceByNumber", "args": {"index": index}})
        if wait(lambda: any(tab and p.get("selected_tab") == tab.group(1) for p in panes()), 3):
            break
    if not wait(lambda: (focused_pane() or {}).get("kind") == "terminal", 30):
        row("setup", "a focused terminal", json.dumps(panes())[:400], False)
        return
    time.sleep(2)  # test harness: shell prompt
    page = os.path.join(SCRATCH, "page.html")
    open(page, "w").write("<!doctype html><title>switch page</title><body style='background:#2980b9;color:white;font:40px "
                          "-apple-system'>" + "<p>switch page row</p>" * 60)
    markdown = os.path.join(SCRATCH, "notes.md")
    open(markdown, "w").write("# Tab switch\n\n" + "\n".join(f"- item {i} with `code` and **bold**" for i in range(200)) + "\n")
    steps = [("chromium", lambda: action("openBrowser.chromium", {"url": "file://" + page}, timeout=120)),
             ("webkit", lambda: action("openBrowser.webkit", {"url": "file://" + page})),
             ("markdown", lambda: action("openMarkdownFile", {"path": markdown})),
             ("terminal 2", lambda: action("newSurface"))]
    for index, (name, make) in enumerate(steps, start=2):
        reply = make()
        print(f"open {name}: {json.dumps(reply)[:200]}", flush=True)
        if not wait(lambda: len(strip_tabs()) >= index, 60):
            row(f"setup: {name}", f"{index} tabs", f"{len(strip_tabs())}", False)
            return
        time.sleep(1.5)  # test harness: the page loads before the next tab
    tabs = strip_tabs(5)
    print("tabs:", [t[0] for t in tabs], flush=True)
    # Warm: visit every tab once, slowly.
    for _ in range(len(tabs)):
        rpc("debug.key", {"key": "tab", "modifiers": ["control"]})
        time.sleep(0.6)  # test harness: slow warm-up visit
    time.sleep(2)  # test harness: pages settle
    n = len(tabs)
    report = {"tag": TAG, "tabs": [t[0] for t in tabs]}
    report["keys_forward"] = measure("Ctrl-Tab", lambda i: rpc("debug.key", {"key": "tab", "modifiers": ["control"]}), n * opts.rounds)
    report["keys_back"] = measure("Ctrl-Shift-Tab", lambda i: rpc("debug.key", {"key": "tab", "modifiers": ["control", "shift"]}),
                                  n * opts.rounds)
    tabs = strip_tabs(5)  # frames after the warm-up (a strip may relayout)
    report["clicks"] = measure("click", lambda i: rpc("debug.mouse", {"action": "click", "x": tabs[i % n][1][0], "y": tabs[i % n][1][1]}),
                               n * opts.rounds)
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "tabswitch-final.png")})
    if opts.json:
        with open(opts.json, "w") as handle:
            json.dump(report, handle, indent=1)
        print("wrote", opts.json, flush=True)


try:
    main()
finally:
    cleanup()
    print("\nRESULT", "PASS" if ROWS and all(r[3] for r in ROWS) else "FAIL", f"({sum(r[3] for r in ROWS)}/{len(ROWS)})")
    sys.exit(0 if ROWS and all(r[3] for r in ROWS) else 1)
