#!/usr/bin/env python3
"""Key-down to first painted frame of the Command Palette (Cmd-Shift-P) and Go to Workspace (Cmd-P), per focused
surface, on a tagged cmux-next build (palette-open-latency).

Launches the tagged app itself (no activation, scratch config, empty Ghostty config), makes one pane with a
terminal, a Chromium page, a WebKit page, a Markdown file and Home, then for each tab (selected by a click on the
tab strip) presses Cmd-Shift-P and Cmd-P through `debug.key` (the key router's real path; for Chromium also with
the page window as the key window, `target: page`), and closes the palette with Escape. Per open,
`debug.timings` reports (ms):
  input    the key-down's age when the palette began to open (key router, action dispatch)
  model    the page's items and first results;  panel  creating the panel (zero once made)
  present  placing, ordering in and focusing the panel;  commit  layout, display and the Core Animation commit
  key      input + model + panel + present + commit: key-down to the committed first frame
plus rpc_ms, the synchronous `debug.key` round trip (the main thread's whole key handling), and the longest
main-thread stall during the open (`debug.hangs`). Builds without the input stage report key = ms + 0.

The budget: a warm open commits within one 60 Hz frame (key p90 <= 16 ms).

Usage: palette-open-stages.py --tag <tag> --app PATH [--rounds 10] [--interval 0.35] [--out DIR] [--json PATH]
"""
import argparse, glob, json, os, re, signal, socket, statistics, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_launch import BenchApp, bundle_id  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True, help="the tagged .app bundle")
parser.add_argument("--rounds", type=int, default=10, help="opens per surface and key")
parser.add_argument("--interval", type=float, default=0.35, help="seconds between an open and its close")
parser.add_argument("--budget-ms", type=float, default=16.0)
parser.add_argument("--out", default="/tmp")
parser.add_argument("--json", help="write the samples here")
parser.add_argument("--no-gate", action="store_true", help="report only; exit 0 when every open was timed")
opts = parser.parse_args()
TAG, APP = opts.tag, os.path.abspath(opts.app.rstrip("/"))
BUNDLE_ID = bundle_id(APP) or f"com.cmuxterm.app.debug.{TAG}"
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
BINARY = next((p for p in sorted(glob.glob(os.path.join(APP, "Contents/MacOS/*"))) if not p.endswith(".dylib")), None)
SCRATCH = tempfile.mkdtemp(prefix=f"paletteopen-{TAG}-")
open(os.path.join(SCRATCH, "ghostty"), "w").close()
CONFIG = os.path.join(SCRATCH, "cmux.json")
open(CONFIG, "w").write("{}\n")
ENV = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1"}
STAGES = ["input", "model", "panel", "present", "commit", "key", "rpc"]
KEYS = [("Cmd-Shift-P", {"key": "p", "modifiers": ["command", "shift"]}), ("Cmd-P", {"key": "p", "modifiers": ["command"]})]
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
    # origin script: the control socket refuses origin user (dc82dca5497), so every setup open failed.
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


def strip_tabs(minimum):
    """The focused strip's tabs as (id-or-label, center point in window coordinates)."""
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


def one_open(params):
    """One open and close: the open's timing row, or None when the palette did not report an open."""
    rpc("debug.timings", {"clear": True})
    rpc("debug.hangs", {"clear": True})
    started = time.monotonic()
    reply = rpc("debug.key", params)
    rpc_ms = (time.monotonic() - started) * 1000
    time.sleep(opts.interval)  # test harness: the open's commit lands
    opens = (rpc("debug.timings") or {}).get("palette_opens") or []
    hangs = rpc("debug.hangs") or {}
    closed = rpc("debug.key", {"key": "escape", "target": "palette"})
    if isinstance(closed, dict) and closed.get("error"):
        rpc("debug.key", {"key": "escape"})
    time.sleep(0.25)  # test harness: the close animation ends before the next open
    if not opens:
        return None, reply
    o = opens[-1]
    sample = {s: o.get(f"{s}_ms") for s in ["input", "model", "panel", "present", "commit"]}
    sample["input"] = sample["input"] or 0.0
    sample["key"] = o.get("key_to_frame_ms") or (o.get("ms", 0) + sample["input"])
    sample["rpc"] = round(rpc_ms, 2)
    sample["created_panel"] = o.get("created_panel")
    sample["stall_max_ms"] = hangs.get("max_ms")
    sample["stalls"] = [{"ms": r.get("duration_ms"), "frames": [f for f in r.get("frames", []) if "Cmux" in f or "cmux" in f][:14]}
                        for r in (hangs.get("records") or [])[-2:]]
    return sample, reply


def summarize(label, samples):
    line = {}
    for stage in STAGES:
        values = [s[stage] for s in samples if s.get(stage) is not None]
        if values:
            line[stage] = {"p50": round(pct(values, 0.5), 2), "p90": round(pct(values, 0.9), 2), "max": round(max(values), 2)}
    cells = " ".join(f"{st}={line[st]['p50']}/{line[st]['p90']}" for st in STAGES if st in line)
    print(f"  {label:<26} n={len(samples):<3} p50/p90 ms: {cells}", flush=True)
    worst = max(samples, key=lambda s: s.get("key") or 0, default=None)
    if worst and worst.get("stalls"):
        for stall in worst["stalls"]:
            print(f"    stall {stall['ms']} ms: " + " < ".join(str(f)[:70] for f in stall["frames"]), flush=True)
    return line


def cleanup():
    print("cleanup", flush=True)
    if os.environ.get("PALETTEOPEN_KEEP") or not LAUNCHED:
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
    made = run("workspace", "create", "--name", "paletteopen-e2e")
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
    open(page, "w").write("<!doctype html><title>palette page</title><body style='background:#2980b9;color:white;font:40px "
                          "-apple-system'><input autofocus>" + "<p>palette page row</p>" * 60)
    markdown = os.path.join(SCRATCH, "notes.md")
    open(markdown, "w").write("# Palette open\n\n" + "\n".join(f"- item {i} with `code` and **bold**" for i in range(200)) + "\n")
    kinds = ["terminal"]
    steps = [("chromium", lambda: action("openBrowser.chromium", {"url": "file://" + page}, timeout=120)),
             ("webkit", lambda: action("openBrowser.webkit", {"url": "file://" + page})),
             ("markdown", lambda: action("openMarkdownFile", {"path": markdown})),
             ("home", lambda: action("home.tab"))]
    for name, make in steps:
        before = len(strip_tabs(1))
        reply = make()
        print(f"open {name}: {json.dumps(reply)[:200]}", flush=True)
        if not wait(lambda: len(strip_tabs(1)) > before, 60):
            row(f"setup: {name}", f"{before + 1} tabs", f"{len(strip_tabs(1))}", False)
            continue
        kinds.append(name)
        time.sleep(1.5)  # test harness: the page loads before the next tab
    tabs = strip_tabs(len(kinds))
    print("tabs:", [t[0] for t in tabs], "kinds:", kinds, flush=True)
    # Warm: one open and close of each palette, as after launch idle.
    for _, params in KEYS:
        one_open(params)
    report = {"tag": TAG, "kinds": kinds, "surfaces": {}}
    print("\n== palette opens", flush=True)
    for index, kind in enumerate(kinds):
        if index >= len(tabs):
            break
        rpc("debug.mouse", {"action": "click", "x": tabs[index][1][0], "y": tabs[index][1][1]})
        time.sleep(1.0)  # test harness: the tab shows and takes focus
        if kind in ("chromium", "webkit"):
            # The page has the keyboard, as after a click into it.
            rpc("debug.key", {"key": "tab"}, timeout=10)
            time.sleep(0.3)  # test harness: focus moves into the page
        targets = [(kind, {})] + ([("chromium page window", {"target": "page"})] if kind == "chromium" else [])
        for label, extra in targets:
            for key_label, params in KEYS:
                samples, missed, last_reply = [], 0, None
                for _ in range(opts.rounds):
                    sample, reply = one_open({**params, **extra})
                    if sample is None:
                        missed += 1
                        last_reply = reply
                    else:
                        samples.append(sample)
                name = f"{label} {key_label}"
                if not samples:
                    row(name, "palette opened", f"no open timed: {json.dumps(last_reply)[:200]}", False)
                    continue
                line = summarize(name, samples)
                report["surfaces"][name] = {"table": line, "samples": samples, "missed": missed}
                key_p90 = line.get("key", {}).get("p90", 1e9)
                row(name, f"key-down to frame p90 <= {opts.budget_ms} ms, {opts.rounds} opens",
                    f"p90 {key_p90} ms, {len(samples)} timed", (opts.no_gate or key_p90 <= opts.budget_ms) and missed == 0)
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
