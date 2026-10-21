#!/usr/bin/env python3
"""Live check: quitting with hidden, never-made Chromium tabs exits cleanly (no CEF FATAL, no SIGABRT).

NIGHTLY 1.0.0-nightly.3953614980201 crashed on quit. The Quit Apple event ran
`NSApplication terminate:`; CefShutdown ran in applicationShouldTerminate; then AppKit closed the
windows (`_closeForTermination`), `WindowController.teardown` -> `PaneContentView.detachContent`
called `removeFromSuperview` on a pane's content in a hidden (parked) workspace, and AppKit's
`_recursiveLostHiddenAncestorBySwitchingWindow:` sent `viewDidUnhide` to a Chromium tab's
`CEFTabContentView` whose browser was never made. `CEFTab.contentDidAppear` -> `CEFPaneHost.present`
-> `ensureCreated` -> `cmux_shim_create_window` after CefShutdown: CEF FATAL
("Check failed: !IsCefShutdown()"), SIGABRT.

Each run builds that state through the app's own paths, in --windows windows:

  1. workspace A: a terminal, split right, then the right pane split down (three panes);
  2. per pane: one Chromium tab opened in front (made and shown), then --tabs Chromium tabs opened
     in the background (`openBrowser.chromium`, origin script, no focus: unselected, never made);
     in the first pane a second front tab parks the first (made, hidden) and that one hibernates;
  3. a new workspace B is shown: A is parked (its view hides in place, still in the window);
  4. in parked A, per pane: one more background Chromium tab, then the pane's shown tab closes, so
     the pane selects a Chromium tab that was never made while its workspace is hidden.

Then it quits through the Quit Apple event, as Leo did
(`osascript -e 'tell application id "<bundle id>" to quit'`), answers a quit sheet if one shows,
and checks:

  - the process exits;
  - its exit status is 0, not a signal (RunningBoard's `termination reported by launchd (a, b, s)`
    line for the pid: `s` is the wait status, 6 = SIGABRT, 0 = exit 0; `open -n` launches the app,
    so the script is not its parent and cannot waitpid);
  - no new `cmux DEV-*.ips` for that pid in ~/Library/Logs/DiagnosticReports (waits --ips-wait s:
    ReportCrash wrote one about 12 s after the abort);
  - no `FATAL` in the app's stdout/stderr (`open --stdout/--stderr`) or in the pid's unified log;
  - and reports the pid's `CEF shutdown complete` line (CefShutdown ran before the windows closed).

The fix's refusal (`CEFRuntime.acceptsNewBrowsers` in `ensureCreated`, the shim's `stopping()`) logs
nothing, and the content lifecycle trace (`host-present ...`) goes to the in-memory input journal,
which is gone once the process ends; so the run proves the gate only by the clean exit of the
same scenario that aborts on the base.

  scripts/cmux-next/quit-hidden-chromium-live.py --app PATH [--runs N] [--windows N] [--tabs N] [--out DIR]

GUI host only (a leased capture mini; ssh is outside the Aqua session, so the app starts with
`open -n`). Ends the tag's daemons between runs and at the end (tag_teardown.py). Writes
run-N/app.log, run-N/setup.json and verdict.json to --out. Exit 1 when a check fails.
"""
import argparse, glob, http.server, json, os, plistlib, re, socket, subprocess, sys, tempfile, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True, help="the tagged cmux DEV .app")
parser.add_argument("--tag", help="default: from the app name (cmux DEV <tag>.app)")
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="quit-hidden-chromium-"))
parser.add_argument("--runs", type=int, default=3)
parser.add_argument("--windows", type=int, default=2)
parser.add_argument("--tabs", type=int, default=2, help="background Chromium tabs per pane before the park")
parser.add_argument("--ips-wait", type=float, default=45, help="seconds to wait for a crash report")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)

APP = os.path.realpath(opts.app).rstrip("/")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    INFO = plistlib.load(f)
BINARY = os.path.join(APP, "Contents/MacOS", INFO["CFBundleExecutable"])
BUNDLE_ID = INFO["CFBundleIdentifier"]
TAG = opts.tag or os.path.basename(APP).removeprefix("cmux DEV ").removesuffix(".app")
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
REPORTS = os.path.expanduser("~/Library/Logs/DiagnosticReports")
runs = []


class Run:
    def __init__(self, index):
        self.index = index
        self.dir = os.path.join(opts.out, f"run-{index}")
        os.makedirs(self.dir, exist_ok=True)
        self.checks, self.failures, self.notes = [], [], []

    def check(self, ok, what, detail=None):
        line = ("ok   " if ok else "FAIL ") + f"[run {self.index}] {what}"
        if detail is not None:
            line += f"  ({detail if isinstance(detail, str) else json.dumps(detail)[:400]})"
        print(line, flush=True)
        self.checks.append({"check": what, "ok": bool(ok), "detail": detail})
        if not ok:
            self.failures.append(what)
        return ok

    def note(self, text):
        print(f"note [run {self.index}] {text}", flush=True)
        self.notes.append(text)


# The pages: a local server, so every tab has a real http page to load once it is made.
class Pages(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = f"<!doctype html><title>{self.path}</title><body>{self.path}</body>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=server.serve_forever, daemon=True).start()
ORIGIN = f"http://127.0.0.1:{server.server_port}"


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
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def action(name, target=None, focus=False, confirm=False, **args):
    params = {"action": name, "origin": "script", "focus": focus, "args": args}
    if target:
        params["target"] = target
    if confirm:
        params["confirm"] = True
        args["confirm"] = True
    reply = rpc("action.run", params, timeout=60) or {}
    if "error" in reply:
        print(f"  action {name} {target or ''} -> {json.dumps(reply)[:300]}", flush=True)
    return reply


def wait(predicate, seconds, step=0.25):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # test harness: bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


def windows():
    return (rpc("debug.windows") or {}).get("windows") or []


def focus_window(window_id):
    """debug.focus's entry for one window: its shown workspace and that workspace's panes."""
    return next((w for w in (rpc("debug.focus") or {}).get("windows") or [] if w.get("id") == window_id), None)


def panes_of(window_id):
    w = focus_window(window_id) or {}
    return w.get("topology") or []


def pane_tabs(pane):
    """The daemon's tabs of a pane, shown workspace or not: [{id, content_kind, focused}]."""
    try:
        done = subprocess.run([CLI, "--app-socket", SOCKET, "--json", "tab", "list", "--pane", pane],
                              capture_output=True, text=True, timeout=30,
                              env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")})
        return json.loads(done.stdout)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return []


def shown_chromium_tabs():
    """Chromium tabs a pane shows now (`debug.cef` devtools lists every shown Chromium tab)."""
    return {d.get("tab") for d in (rpc("debug.cef") or {}).get("devtools") or []}


def created(reply):
    return [c for c in (reply.get("created") or []) if str(c).startswith("tab_")]


def app_pids():
    """PIDs of this bundle's main executable (LaunchServices may report /private/tmp/...)."""
    out = subprocess.run(["ps", "-A", "-o", "pid=,command="], capture_output=True, text=True).stdout
    found = []
    for line in out.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2:
            continue
        command = "/private" + parts[1] if parts[1].startswith(("/var/", "/tmp/")) else parts[1]
        if command == BINARY or command.startswith(BINARY + " "):
            found.append(int(parts[0]))
    return found


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def end_tag():
    """TagTeardown, then this tag's terminal hosts whose daemon is gone. They run as `cmux-tui
    __terminal-host --owner <bundle id>:<tag>@<daemon pid>` (argv[0] is not the bundle path, so
    TagTeardown does not see them) and outlived the forced session shutdown on a capture mini."""
    TagTeardown(APP, log=lambda line: print("  " + line, flush=True)).end()
    out = subprocess.run(["ps", "-A", "-o", "pid=,command="], capture_output=True, text=True).stdout
    owner = re.compile(r"__terminal-host .*--owner %s:%s@(\d+)" % (re.escape(BUNDLE_ID), re.escape(TAG)))
    orphans = [int(line.split(None, 1)[0]) for line in out.splitlines()
               if (m := owner.search(line)) and not alive(int(m.group(1)))]
    for pid in orphans:
        try:
            os.kill(pid, 15)  # an exact PID of this tag's orphaned terminal host, never a pattern
        except ProcessLookupError:
            pass
    if orphans:
        print(f"  teardown: stopped {len(orphans)} orphaned terminal hosts of {TAG}", flush=True)


def unified_log(start, predicate, seconds=30):
    try:
        done = subprocess.run(["/usr/bin/log", "show", "--start", start, "--style", "compact", "--predicate", predicate],
                              capture_output=True, text=True, timeout=seconds + 90)
        return [l for l in done.stdout.splitlines() if l and not l.startswith(("Filtering", "Timestamp"))]
    except subprocess.TimeoutExpired:
        return ["log show timed out"]


def crash_reports_for(pid, before):
    found = []
    for path in sorted(set(glob.glob(os.path.join(REPORTS, "*.ips"))) - before):
        try:
            with open(path, errors="replace") as f:
                text = f.read()
        except OSError:
            continue
        if re.search(r'"pid"\s*:\s*%d\b' % pid, text):
            signal_name = re.search(r'"signal"\s*:\s*"([A-Z]+)"', text)
            found.append({"file": os.path.basename(path), "signal": signal_name.group(1) if signal_name else None})
    return found


def build_window(run, index, layout):
    """One window: workspace A (three panes of Chromium tabs, made, parked, hibernated and never made)
    parked behind a shown workspace B, then in A each pane selects a never-made Chromium tab."""
    before = {w.get("id") for w in windows()}
    if index > 0 or not before:
        action("newWindow", focus=True)
        window = wait(lambda: next((w.get("id") for w in windows() if w.get("id") not in before), None), 30)
    else:
        window = wait(lambda: next((w.get("id") for w in windows()), None), 30)
    if not run.check(window, f"window {index} exists"):
        return
    entry = {"window": window, "workspace_a": None, "panes": {}}
    layout.append(entry)
    # Every action names its target: the app is not active (no activation), so an untargeted
    # action would go to whichever window AppKit considers main.
    def one_pane_workspace(other=None):
        w = focus_window(window)
        return w.get("workspace") if w and w.get("workspace") != other and len(w.get("topology") or []) == 1 else None
    # A new window opens with a workspace of its own (a terminal): that one is A.
    workspace_a = wait(one_pane_workspace, 10) if index > 0 else None
    made = {}
    if not workspace_a:
        shown = next((w.get("selected") for w in windows() if w.get("id") == window), None)
        made = action("newTab", target=f"workspace:{shown}" if shown else None, focus=True)
        workspace_a = wait(lambda: one_pane_workspace(shown), 20)
    run.check(workspace_a, f"window {index}: workspace A with a terminal", workspace_a or made.get("created"))
    if not workspace_a:
        return
    entry["workspace_a"] = workspace_a
    first = (panes_of(window) or [{}])[0].get("pane")
    action("splitRight", target=f"pane:{first}", focus=True)
    two = wait(lambda: (lambda t: t if len(t) == 2 else None)(panes_of(window)), 15) or []
    right = next((p["pane"] for p in two if p["pane"] != first), None)
    action("splitDown", target=f"pane:{right}", focus=True)  # the right pane splits: a hidden tab in a split
    panes = wait(lambda: (lambda t: t if len(t) == 3 else None)(panes_of(window)), 15) or panes_of(window)
    run.check(len(panes) == 3, f"window {index}: three panes in workspace A", [p.get("pane") for p in panes])
    for number, pane in enumerate(panes):
        pane_id = pane["pane"]
        terminal = pane.get("selected")
        record = {"terminal": terminal, "front": [], "background": [], "hibernated": None, "selected_at_quit": None}
        entry["panes"][pane_id] = record
        action("tab.focus", target=f"tab:{terminal}", focus=True)
        fronts = 2 if number == 0 else 1
        for k in range(fronts):
            front_of = record["front"][-1] if record["front"] else terminal
            reply = action("openBrowser.chromium", target=f"tab:{front_of}", focus=True, url=f"{ORIGIN}/w{index}-p{number}-front{k}")
            tab = (created(reply) or [None])[0]
            record["front"].append(tab)
            run.check(tab and wait(lambda: tab in shown_chromium_tabs(), 30),
                      f"window {index} pane {number}: front Chromium tab {k} is made and shown", tab)
        for k in range(opts.tabs):
            reply = action("openBrowser.chromium", target=f"tab:{record['front'][-1]}", focus=False,
                           url=f"{ORIGIN}/w{index}-p{number}-bg{k}")
            record["background"] += created(reply)
        if number == 0 and len(record["front"]) == 2 and record["front"][0]:
            # The first front tab is parked (made, hidden); it hibernates.
            reply = action("hibernateTab", target=f"tab:{record['front'][0]}", focus=False)
            record["hibernated"] = record["front"][0] if "error" not in reply else None
            if record["hibernated"] is None:
                run.note(f"hibernateTab refused: {json.dumps(reply)[:200]}")
    shown_before_park = shown_chromium_tabs()
    reply = action("workspace.newBelow", target=f"workspace:{workspace_a}", focus=True)
    entry["workspace_b"] = next((c for c in reply.get("created") or [] if str(c).startswith("ws_")), None)
    parked = run.check(wait(lambda: (focus_window(window) or {}).get("workspace") not in (None, workspace_a) and
                            {p["pane"] for p in panes_of(window)}.isdisjoint(entry["panes"]), 20),
                       f"window {index}: workspace B shows, A is parked", (focus_window(window) or {}).get("workspace"))
    if not parked:
        return
    for number, (pane_id, record) in enumerate(entry["panes"].items()):
        shown = record["front"][-1]
        reply = action("openBrowser.chromium", target=f"tab:{shown}", focus=False, url=f"{ORIGIN}/w{index}-p{number}-parked")
        record["background"] += created(reply)
        action("closeTab", target=f"tab:{shown}", focus=False)
        tabs = wait(lambda: (lambda t: t if t and all(x.get("id") != shown for x in t) else None)(pane_tabs(pane_id)), 15) or pane_tabs(pane_id)
        selected = next((t for t in tabs if t.get("focused")), {})
        record["selected_at_quit"] = selected.get("id")
        state = ("never made" if selected.get("id") in record["background"]
                 else "hibernated" if selected.get("id") == record["hibernated"] else "made")
        record["selected_state"] = state
        run.check(selected.get("content_kind") == "browser" and state != "made",
                  f"window {index} pane {number}: parked A's pane selects a hidden Chromium tab with no browser",
                  {"selected": selected.get("id"), "kind": selected.get("content_kind"), "state": state})
    entry["shown_chromium_tabs_before_park"] = sorted(t for t in shown_before_park if t)
    entry["shown_chromium_tabs_at_quit"] = sorted(t for t in shown_chromium_tabs() if t)


def one_run(index):
    run = Run(index)
    runs.append(run)
    end_tag()  # a clean start: no app, daemon or terminal host of this tag left
    app_log = os.path.join(run.dir, "app.log")
    reports_before = set(glob.glob(os.path.join(REPORTS, "*.ips")))
    print(f"run {index}: launching {os.path.basename(APP)} ({BUNDLE_ID})", flush=True)
    subprocess.run(["open", "-n", "-g", "--stdout", app_log, "--stderr", app_log,
                    "--env", "CMUX_NEXT_SOCKET_MODE=automation", "--env", "CMUX_NEXT_NO_ACTIVATE=1",
                    "--env", "ACPMUX_AGENT_LAUNCH=deny", "--env", "CMUX_NEXT_TEST_WINDOW_FRAME=60,60,1280,820",
                    APP], check=False, timeout=60)
    pid = wait(lambda: (app_pids() or [None])[0], 60)
    if not run.check(pid, "the app starts", pid):
        return run
    if not run.check(wait(lambda: "error" not in (rpc("debug.focus") or {"error": 1}), 180), "the app answers its socket"):
        return run
    # A relaunch restores the last run's windows and workspaces; start from none.
    restored = windows()
    if restored:
        run.note(f"restored {len(restored)} windows with {sum(len(w.get('workspaces') or []) for w in restored)} workspaces; closing them")
        action("workspace.closeAllInAllWindows", focus=True, confirm=True)
        time.sleep(2)
        if len(windows()) > 1:
            action("window.closeOthers", focus=True, confirm=True)
            wait(lambda: len(windows()) <= 1, 15)
    layout = []
    for w in range(opts.windows):
        build_window(run, w, layout)
    with open(os.path.join(run.dir, "setup.json"), "w") as handle:
        json.dump({"pid": pid, "layout": layout, "windows": windows()}, handle, indent=1)
    run.note(f"{len(windows())} windows; {sum(len(e['panes']) for e in layout)} panes in parked workspaces; "
             f"{sum(len(r['background']) for e in layout for r in e['panes'].values())} never-made Chromium tabs; "
             f"{sum(1 for e in layout for r in e['panes'].values() if r['hibernated'])} hibernated")

    # Quit as Leo did: the Quit Apple event.
    start = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(time.time() - 2))
    quit_at = time.monotonic()
    osa = subprocess.run(["osascript", "-e", f'tell application id "{BUNDLE_ID}" to quit'],
                         capture_output=True, text=True, timeout=120)
    run.note(f"osascript quit -> exit {osa.returncode} {(osa.stdout + osa.stderr).strip()[:200]}")
    # A quit sheet (running terminals) is answered with keep; the socket is gone once quit ends.
    sheet = wait(lambda: (lambda r: r if "error" in r or r.get("asking") else None)(rpc("debug.quit", timeout=3) or {"error": 1}), 5)
    if sheet and sheet.get("asking"):
        buttons = [b.get("id") for b in sheet.get("buttons") or []]
        choice = next((b for b in buttons if "keep" in str(b)), buttons[0] if buttons else None)
        run.note(f"quit sheet asked ({buttons}); pressing {choice}")
        rpc("debug.quit", {"press": choice}, timeout=5)
    exited = wait(lambda: not alive(pid), 60)
    run.check(exited, "the process exits after the Quit Apple event", f"pid {pid}, {time.monotonic() - quit_at:.1f} s")
    if not exited:
        os.kill(pid, 9)  # this run's exact PID, never a pattern
        wait(lambda: not alive(pid), 10)

    # Exit status: RunningBoard's line for the pid ((domain, code, wait status)).
    termination = []
    for _ in range(3):  # the log can lag the exit by a moment
        # The app's own line, not its WebContent helpers' (their names embed the app's pid too).
        termination = [l for l in unified_log(start, f'process == "runningboardd" AND eventMessage CONTAINS "termination reported by launchd" AND eventMessage CONTAINS ":{pid}]"')
                       if re.search(r"\[app<application\.%s\.[^>]*>:%d\] termination reported" % (re.escape(BUNDLE_ID), pid), l)]
        if termination:
            break
        time.sleep(2)
    status = None
    if termination:
        match = re.search(r"termination reported by launchd \((-?\d+), (-?\d+), (-?\d+)\)", termination[-1])
        status = int(match.group(3)) if match else None
    signal_number = status & 0x7F if status is not None else None
    exit_code = status >> 8 if status is not None and signal_number == 0 else None
    run.check(status == 0, "exit status 0, not a signal",
              {"wait_status": status, "signal": signal_number or None, "exit_code": exit_code,
               "line": termination[-1].split("] ", 1)[-1][-160:] if termination else "no RunningBoard line"})

    # Crash report: ReportCrash writes it seconds after the abort.
    ips = wait(lambda: crash_reports_for(pid, reports_before), opts.ips_wait, step=1) or []
    run.check(not ips, f"no crash report for pid {pid} within {opts.ips_wait:.0f} s", ips or "none")
    if signal_number and not ips:
        run.note("the process died of a signal but ReportCrash wrote no new report: it throttles repeat crashes "
                 "of one app (seen on a capture mini: only the first of four base aborts got an .ips)")

    # CEF FATAL: the app's stdout/stderr (CEF logs there) and the pid's unified log.
    with open(app_log, errors="replace") as f:
        lines = f.read().splitlines()
    fatal = [l for l in lines if "FATAL" in l]
    stack = [l.strip() for l in lines if "ensureCreated" in l or "cmux_shim_create_window" in l or "viewDidUnhide" in l
             or "detachContent" in l or "_recursiveLostHiddenAncestor" in l]
    run.check(not fatal, "no CEF FATAL in the app's output", fatal[:2] + stack[:6] if fatal else "none")
    app_lines = unified_log(start, f'processID == {pid} AND subsystem == "com.cmuxterm.app.next" AND (category == "cef" OR category == "app.quit")')
    os_fatal = [l for l in unified_log(start, f'processID == {pid} AND eventMessage CONTAINS "FATAL"')]
    run.check(not os_fatal, "no FATAL in the pid's unified log", os_fatal[:2] or "none")
    shutdown = [l for l in app_lines if "CEF shutdown" in l]
    run.note("CEF quit log: " + (" | ".join(l.split("] ", 1)[-1] for l in shutdown) or "no CEF shutdown line"))
    run.note("refusals of ensureCreated/create_window are not logged by the fix; not observable after exit")
    run.result = {"pid": pid, "wait_status": status, "signal": signal_number or None, "exit_code": exit_code,
                  "crash_reports": ips, "fatal": fatal[:2], "stack": stack[:8], "cef_log": shutdown,
                  "termination": termination[-1:]}
    end_tag()
    return run


teardown = TagTeardown(APP)
teardown.install()
try:
    for n in range(1, opts.runs + 1):
        one_run(n)
finally:
    teardown.end()
    end_tag()
    server.shutdown()
    verdict = [{"run": r.index, "ok": not r.failures, "failures": r.failures, "notes": r.notes,
                "result": getattr(r, "result", None), "checks": r.checks} for r in runs]
    with open(os.path.join(opts.out, "verdict.json"), "w") as handle:
        json.dump({"app": os.path.basename(APP), "bundle_id": BUNDLE_ID, "runs": verdict}, handle, indent=1)

clean = sum(1 for r in runs if not r.failures)
aborted = sum(1 for r in runs if getattr(r, "result", {}) and (r.result.get("signal") or r.result.get("crash_reports") or r.result.get("fatal")))
print(f"verdict: {clean}/{len(runs)} runs clean, {aborted} aborted; artifacts in {opts.out}", flush=True)
sys.exit(1 if clean != len(runs) else 0)
