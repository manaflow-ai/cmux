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

--case in-flight: a Chromium browser's creation is still under way when quit stops Chromium.
`CEFRuntime.shutdown` calls `cmux_shim_close_all`, which closes only the browsers that exist; a
browser whose `cmux_shim_create_window` ran but whose OnAfterCreated had not arrived reaches
AFTER_CREATED during the shutdown wait. Before the fix the runtime registered it and never closed it,
so the wait ran out (3 s, `CEFEngine.shutdown`): "CEF shutdown timed out; exiting without
CefShutdown" and a slower quit. Each run:

  1. one workspace of three panes, each with a front Chromium tab (made and shown, its page in the
     default profile), so quit has browsers and windows to close;
  2. --profiles fresh browser profiles (`cmux browser profile create`). A profile's first browser
     makes its request context, and Chromium builds the browser only once that context initialized
     (a profile load), so its creation stays under way for 0.2 s to 2 s (more under load) instead
     of one pump turn;
  3. the burst: every --open-interval-ms, on its own thread, a front Chromium tab of the next fresh
     profile (`openBrowser {engine: cef, profile}`), cycling over the panes. The Quit Apple event
     (aevt/quit, built ahead and sent with AESendMessage, so the send is a moment on the clock; the
     same event `osascript -e 'tell application id ... to quit'` sends, from which it took about
     350 ms to reach the app) goes after --quit-after-opens of them, and the burst goes on until
     quit's close of every browser reached a live page, so creations start all through the quit's
     steps before Chromium stops (saving windows, sidebar and browser records: 1 to 3 s here). Only
     a creation started within its own creation time before close_all lands; the steady burst makes
     one do.

Then the same checks as above, and: the pid's `CEF shutdown complete` line, no `CEF shutdown timed
out`, and that the race landed. Quit-to-exit is reported, not checked: the burst slows the quit's
own steps (1 to 4 s on a busy capture mini), so a clean quit took 2.0 to 6.4 s and a timed-out one
(its 3 s wait run out) 4.7 to 7.2 s; only the shutdown lines tell them apart. --quit-bound S makes
it a check where the host is quiet enough for one.

How the landing is seen (closeAll logs nothing; run-N/timeline.json has it all, in ms from the
Apple event's send):
  - the input journal (`debug.journal`, read every 10 ms during the quit; run-N/journal-content.json)
    has each fresh tab's lifecycle trace: `host-present ... created=false` (the shown tab asks for
    its browser: create_window, as no window of its profile exists) and `attach` (AFTER_CREATED
    registered the browser for the tab);
  - when the shutdown wait began: on a timed-out quit its line comes once the 3 s ran out, so the
    wait began at most 3 s before it; the first live page's held request ending (Chromium tore the
    page down) bounds it from above (run-N/quit-log.ndjson, `log stream --level info`, also has the
    quit's `quit origin` line);
  - landed: a fresh browser registered after the wait began (the bug: AFTER_CREATED after
    close_all, kept), or asked for before the last fresh browser registered ahead of the close and
    never registered (with the fix no browser is registered once the wait began, so it was asked
    for before; it was closed at AFTER_CREATED, or never made in time).

--case windowless: the first Chromium browser's creation is under way, and no Chromium window
exists yet, when quit stops Chromium. `CEFRuntime.shutdown` found no window and no browser, so its
sequence was ready at once and it called CefShutdown under the creation (`pendingWindows`). Each run
is a first launch (wipe_state: no saved workspaces, no Chromium profile data or use record) with
its own cmux-next.json (new tabs in WebKit, so the first launch's new-tab page is not Chromium):

  1. the new-tab page's tab is replaced by a terminal workspace: only terminals, Chromium never
     started, no spare window (`debug.cef` state idle, spare_window none);
  2. one fresh browser profile; Chromium starts with no tab (`browser.defaultEngine.chromium` is a
     warm-up signal: CefInitialize at the next idle moment). The warm-up builds the spare window
     (CEFSpareWindow) at the idle moment after that, unless a host has a tab or a page is being
     made, so the open goes as soon as `debug.cef` says ready (spare_window still none);
  3. the Quit Apple event, then (--quit-at before-open) one front Chromium tab of the fresh profile
     --quit-delay-ms after the send. The tab's create_window must land after the quit's decision
     and before its stop of Chromium (about 15 ms wide on a capture mini). Earlier, the open's
     daemon round trip holds up the quit's record flush and Chromium's window build holds the main
     thread, so AFTER_CREATED comes first ("early"); later, the quit already stopped Chromium and
     no create_window runs ("late"). --staircase-ms moves the next run's delay after each miss and
     --until-landed N stops after N landed runs. Opening first and quitting right after
     (--quit-at present, or during CefInitialize: --quit-at initialize) never landed: the Apple
     event waits behind Chromium's window build (about 100 ms) and AFTER_CREATED came first.

Landed: `create_window` is in `debug.cef` start_steps (it runs only before `shutdown` began:
`acceptsNewBrowsers`, #23383) and neither `attach` (journal) nor `first_window` (start_steps) was
recorded while the app still answered (from the shutdown's start AFTER_CREATED goes to its own
branch, which records neither). A missed run is reported, not judged. On a landed run: the common
checks, `CEF shutdown complete`, no `CEF shutdown timed out`. run-N/timeline.json has the ms from the
Apple event's send. Seen on a capture mini (2026-10-21): base dies in CefShutdown (SIGSEGV), the fix
logs `CEF shutdown complete` about 190 ms after create_window and exits 0.

  scripts/cmux-next/quit-hidden-chromium-live.py --app PATH [--case hidden|in-flight|windowless]
      [--runs N] [--windows N] [--tabs N] [--profiles N] [--quit-after-opens N] [--open-interval-ms MS]
      [--quit-bound S] [--chromium running|cold] [--quit-at before-open|open|initialize|present]
      [--quit-delay-ms MS[,MS...]] [--staircase-ms MS] [--until-landed N] [--out DIR]

GUI host only (a leased capture mini; ssh is outside the Aqua session, so the app starts with
`open -n`). Ends the tag's daemons between runs and at the end (tag_teardown.py). Writes
run-N/app.log, run-N/setup.json (and for in-flight and windowless run-N/timeline.json) and
verdict.json to --out. Exit 1 when a check fails (windowless: a landed run's check, or fewer landed
runs than --until-landed).
"""
import argparse, datetime, glob, http.server, json, os, plistlib, re, shutil, socket, subprocess, sys, tempfile, threading, time

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
parser.add_argument("--case", choices=["hidden", "in-flight", "windowless"], default="hidden",
                    help="hidden: never-made tabs in parked workspaces (default); in-flight: creations under way at quit; "
                         "windowless: the first Chromium tab's creation under way at quit, no Chromium window yet")
parser.add_argument("--profiles", type=int, default=24,
                    help="in-flight: fresh profiles, one first tab each in the burst (it stops once quit closed the browsers)")
parser.add_argument("--quit-after-opens", type=int, default=1, help="in-flight: burst opens sent before the Quit Apple event")
parser.add_argument("--open-interval-ms", type=float, default=200, help="in-flight: time between the burst's opens")
parser.add_argument("--quit-delay-ms", default="0",
                    help="windowless: ms between --quit-at's moment and the Quit Apple event (before-open: between the "
                         "Apple event and the open); a comma list is cycled over the runs")
parser.add_argument("--staircase-ms", type=float, default=0,
                    help="windowless before-open: after a run whose open came too early (AFTER_CREATED registered the "
                         "browser before the shutdown) the next open goes this much later; too late (no create_window), "
                         "this much earlier")
parser.add_argument("--until-landed", type=int, default=0,
                    help="windowless: stop after this many runs landed (--runs is then the most attempts)")
parser.add_argument("--chromium", choices=["running", "cold"], default="running",
                    help="windowless: start Chromium before the open with no tab (the warm-up the default-engine "
                         "switch starts; the open goes before it builds the spare window), or leave it to the open")
parser.add_argument("--quit-at", choices=["before-open", "open", "initialize", "present"], default="present",
                    help="windowless: send the Quit Apple event while Chromium's start holds the main thread "
                         "(CefInitialize, before the tab's create_window; default), or once the tab asked for its "
                         "browser (`host-present ... created=false`; AFTER_CREATED came before the shutdown in "
                         "every such run on a capture mini)")
parser.add_argument("--quit-bound", type=float, default=None,
                    help="in-flight: fail a quit-to-exit longer than this many seconds (default: report it only)")
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
staircase = {"delay": None}  # windowless before-open: the next run's open delay (--staircase-ms)
ENGINE_CLOSE_WAIT = 3.0  # CEFEngine.shutdown(timeout:)'s default: how long quit waits for Chromium's windows
streams = []  # LogStream and fallback osascript processes, stopped in the end's `finally` too


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
# In-flight pages (/live-..., /fresh-...) are timed by their requests: a page's first GET says its
# browser exists (Chromium starts the first navigation as it builds the browser), and each holds a
# request open (GET /hold/...) that the server never answers, whose connection ends when Chromium
# tears the page down: the first live page's says quit's close of every browser reached it.
hits = []
HOLD = "<script>fetch('/hold' + location.pathname)</script>"


class Pages(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        hits.append((time.time(), "GET", self.path))
        if self.path.startswith("/hold/"):
            self.connection.settimeout(None)
            try:
                self.rfile.read(1)  # no answer: blocks until the page's connection closes
            except OSError:
                pass
            hits.append((time.time(), "CLOSED", self.path))
            self.close_connection = True
            return
        script = HOLD if self.path.startswith(("/live-", "/fresh-")) else ""
        body = f"<!doctype html><title>{self.path}</title><body>{self.path}{script}</body>".encode()
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


def three_pane_workspace(run, index, layout):
    """Window `index` (a new one past the first) with a shown workspace A of three terminal panes
    (a terminal, split right, the right pane split down). (window, entry, panes), or None."""
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
    return window, entry, panes


def build_window(run, index, layout):
    """One window: workspace A (three panes of Chromium tabs, made, parked, hibernated and never made)
    parked behind a shown workspace B, then in A each pane selects a never-made Chromium tab."""
    made = three_pane_workspace(run, index, layout)
    if not made:
        return
    window, entry, panes = made
    workspace_a = entry["workspace_a"]
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


def cli(*args):
    """The bundled cmux CLI on this tag's socket, --json; its parsed reply or None."""
    try:
        done = subprocess.run([CLI, "--app-socket", SOCKET, "--json", *args], capture_output=True, text=True, timeout=30,
                              env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")})
        return json.loads(done.stdout)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None


def profile_id(reply):
    """The id in a `browser profile create` reply, wherever the envelope puts it."""
    if isinstance(reply, dict):
        record = reply.get("browser_profile")
        if isinstance(record, dict) and record.get("id"):
            return record["id"]
        for value in reply.values():
            found = profile_id(value)
            if found:
                return found
    return None


class LogStream:
    """`log stream --level info` kept across the quit. The quit's `quit origin` line is an info line,
    which `log show` after the exit does not have, and on a busy capture mini RunningBoard's
    `termination reported` line had left `log show`'s memory buffer within minutes."""

    def __init__(self, path, predicate):
        self.path = path
        self.handle = open(path, "w")
        self.process = subprocess.Popen(["/usr/bin/log", "stream", "--level", "info", "--style", "ndjson", "--predicate", predicate],
                                        stdout=self.handle, stderr=subprocess.STDOUT)
        streams.append(self.process)
        # Its first line ("Filtering the log data ...") says the stream is attached.
        self.attached = bool(wait(lambda: os.path.getsize(path) > 0, 10, step=0.05))

    def stop(self):
        time.sleep(1)  # the stream delivers a moment after the line is logged
        self.process.terminate()  # this stream's exact process
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
        self.handle.close()

    def events(self):
        """[(epoch seconds, category, message)] in order (the stream's own header is not one)."""
        found = []
        with open(self.path, errors="replace") as handle:
            for line in handle:
                try:
                    event = json.loads(line)
                    stamp = datetime.datetime.strptime(event["timestamp"], "%Y-%m-%d %H:%M:%S.%f%z").timestamp()
                except (ValueError, KeyError, TypeError):
                    continue
                found.append((stamp, event.get("category"), event.get("eventMessage") or ""))
        return found


class JournalWatch:
    """Reads the app's input journal (`debug.journal`) every few ms from before the burst until the
    socket is gone, keeping every entry by seq. A Chromium tab's lifecycle trace is in it, timed on
    CLOCK_UPTIME_RAW: `host-present ... created=false` (the shown tab asks for its browser:
    `ensureCreated`, create_window for a new window) and `attach ...` (AFTER_CREATED registered the
    browser for the tab). The ring is in memory only, so it is read while the app still runs."""

    def __init__(self, seconds=30):
        self.entries, self.reads, self.stop, self.last_read = {}, 0, False, None
        self.seconds = seconds
        self.thread = threading.Thread(target=self.loop, daemon=True)
        self.thread.start()

    def loop(self):
        misses, deadline = 0, time.monotonic() + self.seconds
        while not self.stop and misses < 3 and time.monotonic() < deadline:  # test harness: bounded read of the app's own ring
            reply = rpc("debug.journal", {"last": 600}, timeout=2) or {}
            if "error" in reply:
                misses += 1
            else:
                misses = 0
                self.reads += 1
                for entry in reply.get("entries") or []:
                    self.entries[entry.get("seq")] = entry
                self.last_read = time.time()  # the ring as of this moment is in `entries`
            time.sleep(0.01)

    def finish(self):
        self.thread.join(timeout=40)
        self.stop = True

    def content(self):
        """[(epoch seconds, tab, event)] of the lifecycle trace, in order."""
        offset = time.time() - time.clock_gettime(time.CLOCK_UPTIME_RAW)
        found = []
        for seq in sorted(k for k in self.entries if k is not None):
            entry = self.entries[seq]
            content = (entry.get("kind") or {}).get("content") if isinstance(entry.get("kind"), dict) else None
            if content:
                found.append((entry.get("uptimeNanos", 0) / 1e9 + offset, content.get("tab"), content.get("event")))
        return found


def app_quit_predicate(pid):
    return f'processID == {pid} AND subsystem == "com.cmuxterm.app.next" AND (category == "cef" OR category == "app.quit")'


def termination_predicate(pid):
    return f'process == "runningboardd" AND eventMessage CONTAINS "termination reported by launchd" AND eventMessage CONTAINS ":{pid}]"'


class QuitEvent:
    """The Quit Apple event (aevt/quit, no kAEQuitReason: an interactive quit, as `osascript -e 'tell
    application id ... to quit'` sends it), built ahead and sent with no reply wait, so the send is a
    moment on the clock; osascript took about 350 ms from its stdin to the app's `quit origin` line."""

    def __init__(self, bundle_id):
        self.bundle_id = bundle_id
        self.event, self.error = None, None
        try:
            import ctypes
            self.ctypes = ctypes
            self.core = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/CoreServices.framework/CoreServices")

            class AEDesc(ctypes.Structure):
                _fields_ = [("descriptorType", ctypes.c_uint32), ("dataHandle", ctypes.c_void_p)]

            code = lambda text: int.from_bytes(text.encode(), "big")
            self.core.AECreateDesc.argtypes = [ctypes.c_uint32, ctypes.c_char_p, ctypes.c_long, ctypes.POINTER(AEDesc)]
            self.core.AECreateAppleEvent.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.POINTER(AEDesc),
                                                     ctypes.c_int16, ctypes.c_int32, ctypes.POINTER(AEDesc)]
            self.core.AESendMessage.argtypes = [ctypes.POINTER(AEDesc), ctypes.POINTER(AEDesc), ctypes.c_int32, ctypes.c_long]
            target, event = AEDesc(), AEDesc()
            name = bundle_id.encode()
            # typeApplicationBundleID 'bund'; kAutoGenerateReturnID -1, kAnyTransactionID 0.
            status = self.core.AECreateDesc(code("bund"), name, len(name), ctypes.byref(target)) or \
                self.core.AECreateAppleEvent(code("aevt"), code("quit"), ctypes.byref(target), -1, 0, ctypes.byref(event))
            if status == 0:
                self.event, self.reply_type = event, AEDesc
            else:
                self.error = f"AE build status {status}"
        except (OSError, AttributeError) as error:
            self.error = str(error)

    def send(self):
        """'AESendMessage' or the osascript fallback, with how it went."""
        if self.event is not None:
            reply = self.reply_type()
            status = self.core.AESendMessage(self.ctypes.byref(self.event), self.ctypes.byref(reply), 0x1, -1)  # kAENoReply
            if status == 0:
                return "AESendMessage aevt/quit, no reply wait"
            fallback = f"AESendMessage status {status}; osascript"
        else:
            fallback = f"{self.error}; osascript"
        done = subprocess.Popen(["osascript", "-e", f'tell application id "{self.bundle_id}" to quit'],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        streams.append(done)
        return fallback


def in_flight_quit(run, pid):
    """--case in-flight: three panes with a made Chromium tab each, then the burst of first tabs of
    fresh profiles with the Quit Apple event inside it. The quit's timing, or None when setup failed."""
    layout = []
    made = three_pane_workspace(run, 0, layout)
    if not made:
        return None
    _, entry, panes = made
    anchors = []
    for number, pane in enumerate(panes):
        terminal = pane.get("selected")
        action("tab.focus", target=f"tab:{terminal}", focus=True)
        reply = action("openBrowser.chromium", target=f"tab:{terminal}", focus=True, url=f"{ORIGIN}/live-r{run.index}-p{number}")
        tab = (created(reply) or [None])[0]
        run.check(tab and wait(lambda: tab in shown_chromium_tabs(), 30), f"pane {number}: a front Chromium tab is made and shown", tab)
        entry["panes"][pane["pane"]] = {"terminal": terminal, "front": [tab]}
        if tab:
            anchors.append(tab)
    if not run.check(anchors, "made Chromium tabs to anchor the burst", anchors):
        return None
    profiles = []
    for k in range(opts.profiles):
        profiles.append(profile_id(cli("browser", "profile", "create", "--name", f"quit-in-flight-{os.getpid()}-{run.index}-{k}")))
    if not run.check(all(profiles), f"{opts.profiles} fresh browser profiles", profiles):
        return None
    time.sleep(2)  # the app's mirror of the profile records follows the daemon's reply
    entry["fresh_profiles"] = profiles
    log = LogStream(os.path.join(run.dir, "quit-log.ndjson"), app_quit_predicate(pid))
    run.check(log.attached, "log stream attached before the quit")
    quit_event = QuitEvent(BUNDLE_ID)
    journal = JournalWatch()
    time.sleep(0.3)
    journal.entries.clear()
    # The burst: one open every --open-interval-ms, each on its own thread (an open's reply waits on
    # the daemon for about 200 ms; waiting for it would leave gaps no creation spans), cycling over
    # the panes; the Quit Apple event goes in its place in the schedule.
    burst = [None] * len(profiles)

    def open_fresh(k, profile):
        sent = time.time()
        # Short timeout: once quit ended the app the socket is gone.
        reply = rpc("action.run", {"action": "openBrowser", "origin": "script", "focus": True,
                                   "target": f"tab:{anchors[k % len(anchors)]}",
                                   "args": {"engine": "cef", "profile": profile, "url": f"{ORIGIN}/fresh-r{run.index}-{k}"}}, timeout=5) or {}
        burst[k] = {"profile": profile, "sent": sent, "reply_ms": round((time.time() - sent) * 1000, 1),
                    "created": created(reply), "error": reply.get("error")}

    threads, quit_at, quit_wall, sent_by = [], None, None, None
    start_at = time.monotonic()
    quit_slot = min(opts.quit_after_opens, len(profiles))
    for k in range(len(profiles) + 1):
        slot = start_at + k * opts.open_interval_ms / 1000
        if k == quit_slot:
            quit_wall, quit_at = time.time(), time.monotonic()
            sent_by = quit_event.send()
        if slot > time.monotonic():
            time.sleep(slot - time.monotonic())
        if any(m == "CLOSED" and path.startswith(f"/hold/live-r{run.index}-") for t, m, path in hits):
            break  # quit closed every browser: a later open can make no browser, only load
        if k < len(profiles):
            thread = threading.Thread(target=open_fresh, args=(k, profiles[k]), daemon=True)
            thread.start()
            threads.append(thread)
    for thread in threads:
        thread.join(timeout=10)
    burst = [b for b in burst if b]  # the opens that ran (the burst stops at quit's close)
    run.note(f"Quit Apple event: {sent_by}")
    for b in burst:
        sent = b.pop("sent")
        b["after_quit"], b["sent_ms"] = sent >= quit_wall, round((sent - quit_wall) * 1000, 1)
    before = [b for b in burst if not b["after_quit"]]
    run.check(before and all(b["created"] for b in before), "the burst's opens before the quit each made a tab",
              [{k: b[k] for k in ("created", "error", "reply_ms")} for b in before])
    with open(os.path.join(run.dir, "setup.json"), "w") as handle:
        json.dump({"pid": pid, "layout": layout, "burst": burst}, handle, indent=1)
    run.note("burst (ms from the quit's send): " + ", ".join(
        f"{b['sent_ms']:+.0f}{'' if b['created'] else ' refused'}" for b in burst))
    return {"quit_at": quit_at, "quit_wall": quit_wall, "log": log, "burst": burst, "journal": journal}


def in_flight_evidence(run, quit, exit_seconds):
    """Times everything against the Apple event's send (see the docstring: how the landing is seen):
    the quit's `quit origin` line, each fresh tab's host-present and attach, its page's first GET,
    the first live page torn down, the `CEF shutdown` line and the exit; then the in-flight checks."""
    log = quit["log"]
    log.stop()
    events = log.events()
    zero = quit["quit_wall"]
    ms = lambda t: round((t - zero) * 1000)
    origin = next((t for t, c, m in events if c == "app.quit" and m.startswith("quit origin")), None)
    shutdown = [(t, m) for t, c, m in events if c == "cef" and m.startswith("CEF shutdown")]
    live_closed = sorted(t for t, method, path in hits if method == "CLOSED" and path.startswith(f"/hold/live-r{run.index}-"))
    first_close = live_closed[0] if live_closed else None
    gets = {}
    for t, method, path in hits:
        if method == "GET" and path.startswith(f"/fresh-r{run.index}-"):
            gets.setdefault(int(path.rsplit("-", 1)[-1]), t)
    journal = quit["journal"]
    journal.finish()
    content = journal.content()
    with open(os.path.join(run.dir, "journal-content.json"), "w") as handle:
        json.dump([(ms(t), tab, event) for t, tab, event in content], handle, indent=0)
    tab_of = {tab: k for k, b in enumerate(quit["burst"]) for tab in b["created"]}
    present, attach = {}, {}
    for t, tab, event in content:
        k = tab_of.get(tab)
        if k is None:
            continue
        if event.startswith("host-present") and "created=false" in event:
            present.setdefault(k, t)
        elif event.startswith("attach"):
            attach.setdefault(k, t)
    # When the shutdown wait began (cmux_shim_close_all): on a timed-out quit, its line is logged once
    # the 3 s wait (CEFEngine.shutdown's) ran out, so the wait began at most 3 s before it. A quit
    # that completes logs nothing there; the first live page torn down bounds it from above.
    timed_out_at = next((t for t, m in shutdown if "timed out" in m), None)
    wait_began = timed_out_at - ENGINE_CLOSE_WAIT if timed_out_at is not None else None
    # Registered after the wait began: AFTER_CREATED arrived after close_all and the runtime kept the
    # browser (the bug).
    registered_late = sorted(k for k, t in attach.items() if wait_began is not None and t > wait_began)
    # Asked for before the last fresh browser was registered ahead of the close, and never registered:
    # its create_window ran before the wait began (with the fix, no browser is registered once it
    # began), and its AFTER_CREATED never registered it (the fix closes such a browser).
    registered_early = [t for t in attach.values() if first_close is not None and t < first_close]
    cutoff = max(registered_early) if registered_early else None
    never_registered = sorted(k for k, t in present.items() if k not in attach and cutoff is not None and t < cutoff)
    fresh = {k: {"present": ms(present[k]) if k in present else None, "attach": ms(attach[k]) if k in attach else None,
                 "get": ms(gets[k]) if k in gets else None} for k in sorted(set(present) | set(attach) | set(gets))}
    timeline = {"quit_origin_ms": ms(origin) if origin else None,
                "wait_began_ms": ms(wait_began) if wait_began is not None else None,
                "first_live_page_torn_down_ms": ms(first_close) if first_close else None,
                "registered_after_wait_began": {k: fresh[k] for k in registered_late},
                "under_way_never_registered": {k: fresh[k] for k in never_registered},
                "shutdown_line": [(ms(t), m) for t, m in shutdown], "exit_ms": round(exit_seconds * 1000),
                "journal_reads": journal.reads}
    with open(os.path.join(run.dir, "timeline.json"), "w") as handle:
        json.dump(dict(timeline, fresh=fresh, live_pages_torn_down_ms=[ms(t) for t in live_closed]), handle, indent=1)
    run.note("quit timeline (ms from the Apple event's send): " + json.dumps(timeline))
    run.check(registered_late or never_registered,
              "the race landed: a fresh browser's creation was under way when quit closed every browser "
              "(registered after the wait began, or asked for before it and never registered)", timeline)
    timed_out = [m for t, m in shutdown if "timed out" in m]
    run.check(not timed_out, "no `CEF shutdown timed out`", timed_out or "none")
    run.check(any(m == "CEF shutdown complete" for t, m in shutdown), "`CEF shutdown complete` logged",
              [m for t, m in shutdown] or "no CEF shutdown line")
    if opts.quit_bound is None:
        run.note(f"quit to exit {exit_seconds:.2f} s")
    else:
        run.check(exit_seconds < opts.quit_bound, f"quit to exit under {opts.quit_bound:g} s", f"{exit_seconds:.2f} s")
    return timeline


class CEFWatch:
    """Reads `debug.cef` every 20 ms from before the open until the socket is gone, keeping each
    change of Chromium's `state` (idle, loading, loaded, ready, shutDown) and of `spare_window`, with
    the time it was first seen, and the last `start_steps` (the first window's `create_window` call
    and its `first_window`, OnAfterCreated through the pane's own path, on CLOCK_UPTIME_RAW)."""

    def __init__(self, seconds=90):
        self.changes, self.steps, self.last_read, self.stop, self.inflight = [], [], None, False, None
        self.seconds = seconds
        self.thread = threading.Thread(target=self.loop, daemon=True)
        self.thread.start()

    def loop(self):
        misses, deadline, last = 0, time.monotonic() + self.seconds, None
        while not self.stop and misses < 3 and time.monotonic() < deadline:  # test harness: bounded read of the app's own report
            self.inflight = time.time()
            reply = rpc("debug.cef", timeout=2) or {}
            self.inflight = None
            if "error" in reply:
                misses += 1
            else:
                misses, self.last_read = 0, time.time()
                now = (reply.get("state"), reply.get("spare_window"))
                if now != last:
                    self.changes.append((self.last_read, *now))
                    last = now
                self.steps = reply.get("start_steps") or self.steps
            time.sleep(0.02)

    def finish(self):
        self.thread.join(timeout=100)
        self.stop = True

    def initializing(self, held=0.04):
        """True while Chromium's start holds the main thread: the framework load began (`loading`)
        and a `debug.cef` request (a main-actor call) has waited over `held` s. CefInitialize is that
        hold: the first tab's create_window follows it."""
        since = self.inflight
        return bool(self.changes and self.changes[-1][1] in ("loading", "loaded") and since and time.time() - since > held)

    def step(self, name):
        """The epoch time of start step `name`, or None."""
        offset = time.time() - time.clock_gettime(time.CLOCK_UPTIME_RAW)
        found = next((s for s in self.steps if s.get("name") == name), None)
        return found["start_uptime_ns"] / 1e9 + offset if found else None


def wipe_state():
    """A first launch of this tag: no saved workspaces (the daemon's state), no Chromium profile data
    and no Chromium use record (`cmux-last-tab-opened.json`: launch would warm Chromium up and build
    the spare window), no saved window state. The Chromium runtime (`<bundle id>/ChromiumRuntime`)
    stays. Runs only between runs, with the tag's processes ended (end_tag)."""
    if ".debug." not in BUNDLE_ID:
        raise SystemExit(f"refusing to wipe the state of non-DEV bundle {BUNDLE_ID}")
    slug = re.sub(r"[^a-z0-9]+", ".", TAG.lower()).strip(".")
    # An empty or foreign tag would name every tag's folder, or another tag's.
    if not slug or "/" in TAG or TAG in (".", "..") or not BUNDLE_ID.endswith("." + slug):
        raise SystemExit(f"refusing to wipe: tag {TAG!r} is not the tag of bundle {BUNDLE_ID}")
    library = os.path.expanduser("~/Library")
    for path in (os.path.join(library, "Application Support", BUNDLE_ID, "Chromium"),
                 os.path.join(library, "Application Support/cmux/tags", TAG),
                 os.path.join(library, "Saved Application State", BUNDLE_ID + ".savedState"),
                 os.path.join(library, "Caches", BUNDLE_ID),
                 os.path.expanduser(f"~/.acpmux/builds/com.cmuxterm.app.debug.{slug}"),
                 os.path.expanduser(f"~/.cmux/mux/tags/{TAG}")):
        shutil.rmtree(path, ignore_errors=True)


def windowless_quit(run, pid):
    """--case windowless: a first launch of only terminals (Chromium not started, no spare window),
    exactly one front Chromium tab of a fresh profile, and the Quit Apple event (--quit-at). The
    quit's timing, or None when setup failed."""
    window = wait(lambda: next((w.get("id") for w in windows()), None), 30)
    if not window:
        action("newWindow", focus=True)
        window = wait(lambda: next((w.get("id") for w in windows()), None), 30)
    if not run.check(window, "a window", window):
        return None
    # A first launch shows the new-tab page (a WebKit page, content kind browser): a terminal
    # workspace takes its place, and the page's tab closes.
    first = [(p["pane"], t) for p in panes_of(window) for t in pane_tabs(p["pane"])]
    if any(t.get("content_kind") != "terminal" for _, t in first):
        shown = next((w.get("selected") for w in windows() if w.get("id") == window), None)
        action("newTab", target=f"workspace:{shown}" if shown else None, focus=True)
        wait(lambda: (lambda w: w if w and w.get("workspace") != shown and len(w.get("topology") or []) == 1 else None)(focus_window(window)), 20)
        for _, tab in first:
            if tab.get("content_kind") != "terminal":
                action("closeTab", target=f"tab:{tab.get('id')}", focus=False, confirm=True)
        time.sleep(1)
    panes = panes_of(window)
    every = [t for w in windows() for p in panes_of(w.get("id")) for t in pane_tabs(p["pane"])]
    kinds = sorted({t.get("content_kind") for t in every})
    terminal = (panes or [{}])[0].get("selected")
    cef = rpc("debug.cef") or {}
    before = {k: cef.get(k) for k in ("state", "spare_window", "likely", "trigger", "default_engine")}
    run.note(f"before the open: Chromium {json.dumps(before)}; tab kinds {kinds}; replaced first-launch tabs "
             f"{[t.get('content_kind') + ':' + str(t.get('id')) for _, t in first if t.get('content_kind') != 'terminal']}")
    if not run.check(terminal and kinds == ["terminal"] and not shown_chromium_tabs(),
                     "only terminals, no Chromium tab ever opened", kinds):
        return None
    # The spare window (CEFSpareWindow) is built only by the warm-up (ChromiumWarmup) after Chromium
    # started: at launch for a recent Chromium user (the use record, wiped), or on a Chromium-likely
    # signal (a Chromium tab, the "+" menu, the palette). None of them fired, so Chromium is not
    # running and no spare exists.
    run.check(cef.get("state") in ("idle", "loading", "loaded") and cef.get("spare_window") == "none",
              "Chromium not started and no spare window before the open", before)
    profile = profile_id(cli("browser", "profile", "create", "--name", f"quit-windowless-{os.getpid()}-{run.index}"))
    if not run.check(profile, "a fresh browser profile", profile):
        return None
    time.sleep(2)  # the app's mirror of the profile record follows the daemon's reply
    log = LogStream(os.path.join(run.dir, "quit-log.ndjson"), app_quit_predicate(pid))
    run.check(log.attached, "log stream attached before the quit")
    quit_event = QuitEvent(BUNDLE_ID)
    journal, watch = JournalWatch(seconds=120), CEFWatch(seconds=120)
    time.sleep(0.3)
    journal.entries.clear()
    opened = {}

    def open_tab():
        opened["sent"] = time.time()
        # Short timeout once the quit went: the socket is gone when the app ends.
        reply = rpc("action.run", {"action": "openBrowser", "origin": "script", "focus": True, "target": f"tab:{terminal}",
                                   "args": {"engine": "cef", "profile": profile, "url": f"{ORIGIN}/fresh-r{run.index}-0"}},
                    timeout=60) or {}
        opened.update(reply_ms=round((time.time() - opened["sent"]) * 1000, 1), created=created(reply), error=reply.get("error"))

    def asked():
        """The first `host-present ... created=false` in the ring: (tab, epoch seconds)."""
        for t, tab, event in journal.content():
            if event.startswith("host-present") and "created=false" in event:
                return tab, t
        return None

    opener = threading.Thread(target=open_tab, daemon=True)
    if opts.chromium == "running":
        # Chromium starts with no tab: the default-engine switch is a warm-up signal (ChromiumWarmup:
        # CefInitialize at the next idle moment). The warm-up builds the spare window at the idle
        # moment after that (750 ms with no input), unless a Chromium page is being made then
        # (`pagesPending`) or a host has a tab: the open goes as soon as Chromium runs.
        action("browser.defaultEngine.chromium", focus=False)
        ready = wait(lambda: watch.changes and watch.changes[-1][1] == "ready", 60, step=0.002)
        run.check(ready and watch.changes[-1][2] == "none", "Chromium runs with no tab and no spare window before the open",
                  watch.changes[-1][1:] if watch.changes else None)
    trigger = True
    delays = [float(d) for d in str(opts.quit_delay_ms).split(",") if d.strip()] or [0.0]
    delay_ms = staircase["delay"] if staircase["delay"] is not None else delays[(run.index - 1) % len(delays)]
    run.delay_ms = delay_ms
    run.note(f"--quit-at {opts.quit_at}, delay {delay_ms:g} ms")
    if opts.quit_at == "before-open":
        # The open goes --quit-delay-ms after the Apple event's send, timed from the send itself
        # (AESendMessage takes some ms to return), between the quit's decision and its stop of
        # Chromium (about 15 ms on a capture mini: the quit reads facts, saves, then stops Chromium).
        gate = threading.Event()

        def open_later():
            gate.wait(5)
            due = quit_moment[0] + delay_ms / 1000
            while time.time() < due:  # test harness: a bounded wait for the open's moment
                time.sleep(max(0.0, min(0.001, due - time.time())))
            open_tab()

        quit_moment = [None]
        opener = threading.Thread(target=open_later, daemon=True)
        opener.start()
    else:
        opener.start()
        if opts.quit_at != "open":
            trigger = wait(watch.initializing if opts.quit_at == "initialize" else asked, 60, step=0.002)
        if delay_ms:
            time.sleep(delay_ms / 1000)
    quit_wall, quit_at = time.time(), time.monotonic()
    if opts.quit_at == "before-open":
        quit_moment[0] = quit_wall
        gate.set()
    sent_by = quit_event.send()
    run.note(f"Quit Apple event: {sent_by}; sent at {opts.quit_at} ({'seen' if trigger else 'NOT seen in 60 s'})")
    opener.join(timeout=15)
    with open(os.path.join(run.dir, "setup.json"), "w") as handle:
        json.dump({"pid": pid, "window": window, "terminal": terminal, "profile": profile, "before": before,
                   "open": opened, "replaced": first}, handle, indent=1)
    return {"quit_at": quit_at, "quit_wall": quit_wall, "log": log, "journal": journal, "watch": watch,
            "asked": asked, "opened": opened}


def windowless_evidence(run, quit, exit_seconds):
    """Times the windowless quit against the Apple event's send: the open, the tab's host-present
    (its create_window), Chromium's `create_window` step, AFTER_CREATED through the pane's own path
    (`attach`, `first_window`: only while quit had not begun stopping Chromium), the page's first GET
    (the browser exists), its held request ending (Chromium tore it down), the quit's lines and the
    exit."""
    log = quit["log"]
    log.stop()
    events = log.events()
    zero = quit["quit_wall"]
    ms = lambda t: round((t - zero) * 1000) if t is not None else None
    journal, watch = quit["journal"], quit["watch"]
    journal.finish()
    watch.finish()
    content = journal.content()
    with open(os.path.join(run.dir, "journal-content.json"), "w") as handle:
        json.dump([(ms(t), tab, event) for t, tab, event in content], handle, indent=0)
    tab, present = quit["asked"]() or (None, None)  # read once the journal watch ended
    attach = next((t for t, which, event in content if which == tab and event.startswith("attach")), None)
    origin = next((t for t, c, m in events if c == "app.quit" and m.startswith("quit origin")), None)
    choice = next((t for t, c, m in events if c == "app.quit" and m.startswith("quit choice")), None)
    shutdown = [(t, m) for t, c, m in events if c == "cef" and m.startswith("CEF shutdown")]
    path = f"/fresh-r{run.index}-0"
    get = next((t for t, method, p in hits if method == "GET" and p == path), None)
    torn_down = next((t for t, method, p in hits if method == "CLOSED" and p == "/hold" + path), None)
    shutdown_at = shutdown[0][0] if shutdown else None
    timeline = {
        "open_sent_ms": ms(quit["opened"].get("sent")), "open_reply_ms": quit["opened"].get("reply_ms"),
        "host_present_ms": ms(present), "create_window_ms": ms(watch.step("create_window")),
        "initialize_ms": ms(watch.step("initialize")),
        "initialize_took_ms": next((round(m.get("ms", 0)) for m in watch.steps if m.get("name") == "initialize"), None),
        "first_window_ms": ms(watch.step("first_window")),
        "attach_ms": ms(attach), "quit_origin_ms": ms(origin), "quit_choice_ms": ms(choice),
        "page_get_ms": ms(get), "page_torn_down_ms": ms(torn_down),
        "shutdown_line": [(ms(t), m) for t, m in shutdown],
        "cef_state": [(ms(t), state, spare) for t, state, spare in watch.changes],
        "last_journal_read_ms": ms(journal.last_read), "last_cef_read_ms": ms(watch.last_read),
        "exit_ms": round(exit_seconds * 1000), "journal_reads": journal.reads}
    with open(os.path.join(run.dir, "timeline.json"), "w") as handle:
        json.dump(timeline, handle, indent=1)
    run.note("quit timeline (ms from the Apple event's send): " + json.dumps(timeline))
    # The landing. `create_window` (start_steps) runs only while quit has not begun stopping Chromium
    # (`ensureCreated` checks `acceptsNewBrowsers`, false from `shutdown`'s first line, #23383), so a
    # recorded `create_window` started before the shutdown began. AFTER_CREATED through the pane's
    # own path (`attach`, `first_window`) comes only before it too: from then on AFTER_CREATED goes
    # to the shutdown branch, which records neither. So `create_window` without them, read while the
    # app still answered, is a creation under way when the shutdown began.
    covered = journal.last_read is not None and (shutdown_at is None or journal.last_read >= shutdown_at)
    run.landing = ("late" if watch.step("create_window") is None else
                   "early" if attach is not None or watch.step("first_window") is not None else
                   "landed" if covered else "unknown")
    timeline["landing"] = run.landing
    if opts.staircase_ms and opts.quit_at == "before-open" and run.landing in ("early", "late"):
        staircase["delay"] = run.delay_ms + (opts.staircase_ms if run.landing == "early" else -opts.staircase_ms)
    run.check(run.landing == "landed",
              "the timing landed: create_window ran before quit began stopping Chromium, and AFTER_CREATED had "
              "not registered the browser when it began", {k: timeline[k] for k in
              ("open_sent_ms", "host_present_ms", "create_window_ms", "attach_ms", "first_window_ms", "last_journal_read_ms")})
    if run.landing == "landed":
        # Seen on a capture mini (2026-10-21): base calls CefShutdown at once under the creation and
        # dies in it (SIGSEGV, KERN_INVALID_ADDRESS 0xefefefefefefefef, CefShutdown <-
        # CEFRuntime.shutdown), with no `CEF shutdown` line; the fix closes the browser when Chromium
        # makes it and logs `CEF shutdown complete` about 190 ms after create_window. The late
        # AFTER_CREATED itself shows nowhere (the shutdown branch records nothing, and its page never
        # loads), so only the line and the clean exit tell them apart.
        complete = [t for t, m in shutdown if m == "CEF shutdown complete"]
        run.check(complete, "`CEF shutdown complete` logged (CefShutdown ran and returned)", [m for t, m in shutdown] or "no CEF shutdown line")
        run.check(not any("timed out" in m for t, m in shutdown), "no `CEF shutdown timed out`", [m for t, m in shutdown] or "none")
        if complete and watch.step("create_window") is not None:
            run.note(f"CEF shutdown complete {round((complete[0] - watch.step('create_window')) * 1000)} ms after create_window")
    run.note(f"journal read {'past' if covered else 'NOT past'} the first CEF shutdown line")
    run.note(f"quit to exit {exit_seconds:.2f} s")
    return timeline


def one_run(index):
    run = Run(index)
    runs.append(run)
    end_tag()  # a clean start: no app, daemon or terminal host of this tag left
    if opts.case == "windowless":
        wipe_state()  # a first launch: nothing restored, Chromium never used
    app_log = os.path.join(run.dir, "app.log")
    reports_before = set(glob.glob(os.path.join(REPORTS, "*.ips")))
    print(f"run {index}: launching {os.path.basename(APP)} ({BUNDLE_ID})", flush=True)
    extra = []
    if opts.case == "windowless":
        # Its own cmux-next.json, which the default-engine switch writes (never the account's file).
        # New tabs start in WebKit: with Chromium the default, the first launch's new-tab page is a
        # Chromium tab.
        config = os.path.join(run.dir, "cmux-next.json")
        with open(config, "w") as handle:
            json.dump({"browser": {"defaultEngine": "webkit"}}, handle)
        extra = ["--env", f"CMUX_NEXT_CONFIG_FILE={config}"]
    subprocess.run(["open", "-n", "-g", "--stdout", app_log, "--stderr", app_log,
                    "--env", "CMUX_NEXT_SOCKET_MODE=automation", "--env", "CMUX_NEXT_NO_ACTIVATE=1",
                    "--env", "ACPMUX_AGENT_LAUNCH=deny", "--env", "CMUX_NEXT_TEST_WINDOW_FRAME=60,60,1280,820",
                    *extra, APP], check=False, timeout=60)
    pid = wait(lambda: (app_pids() or [None])[0], 60)
    if not run.check(pid, "the app starts", pid):
        return run
    if not run.check(wait(lambda: "error" not in (rpc("debug.focus") or {"error": 1}), 180), "the app answers its socket"):
        return run
    # A relaunch restores the last run's windows and workspaces; start from none.
    restored = windows() if opts.case != "windowless" else []
    if restored:
        run.note(f"restored {len(restored)} windows with {sum(len(w.get('workspaces') or []) for w in restored)} workspaces; closing them")
        action("workspace.closeAllInAllWindows", focus=True, confirm=True)
        time.sleep(2)
        if len(windows()) > 1:
            action("window.closeOthers", focus=True, confirm=True)
            wait(lambda: len(windows()) <= 1, 15)
    start = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(time.time() - 2))
    # RunningBoard's exit line, streamed from before the quit (see LogStream).
    rb_stream = LogStream(os.path.join(run.dir, "termination.ndjson"), termination_predicate(pid))
    in_flight = in_flight_quit(run, pid) if opts.case == "in-flight" else \
        windowless_quit(run, pid) if opts.case == "windowless" else None
    if in_flight:
        quit_at = in_flight["quit_at"]
    else:
        if opts.case == "hidden":
            layout = []
            for w in range(opts.windows):
                build_window(run, w, layout)
            with open(os.path.join(run.dir, "setup.json"), "w") as handle:
                json.dump({"pid": pid, "layout": layout, "windows": windows()}, handle, indent=1)
            run.note(f"{len(windows())} windows; {sum(len(e['panes']) for e in layout)} panes in parked workspaces; "
                     f"{sum(len(r['background']) for e in layout for r in e['panes'].values())} never-made Chromium tabs; "
                     f"{sum(1 for e in layout for r in e['panes'].values() if r['hibernated'])} hibernated")
        # Quit as Leo did: the Quit Apple event (also ends an in-flight run whose setup failed).
        start = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(time.time() - 2))
        quit_at = time.monotonic()
        osa = subprocess.run(["osascript", "-e", f'tell application id "{BUNDLE_ID}" to quit'],
                             capture_output=True, text=True, timeout=120)
        run.note(f"osascript quit -> exit {osa.returncode} {(osa.stdout + osa.stderr).strip()[:200]}")
    # A quit sheet (running terminals) is answered with keep; the socket is gone once quit ends.
    sheet = wait(lambda: (lambda r: r if "error" in r or r.get("asking") else None)(rpc("debug.quit", timeout=3) or {"error": 1}), 5)
    if sheet and sheet.get("asking"):
        buttons = [b.get("id") for b in sheet.get("buttons") or []]
        # The default (Keep Sessions Running, id "keep"), never another id that merely contains "keep".
        choice = (sheet.get("prompt") or {}).get("default") or ("keep" if "keep" in buttons else (buttons[0] if buttons else None))
        run.note(f"quit sheet asked ({buttons}); pressing {choice}")
        rpc("debug.quit", {"press": choice}, timeout=5)
    exited = wait(lambda: not alive(pid), 60, step=0.01)
    exit_seconds = time.monotonic() - quit_at
    run.check(exited, "the process exits after the Quit Apple event", f"pid {pid}, {exit_seconds:.2f} s")
    if not exited:
        os.kill(pid, 9)  # this run's exact PID, never a pattern
        wait(lambda: not alive(pid), 10)

    # Exit status: RunningBoard's line for the pid ((domain, code, wait status)).
    termination = []
    for _ in range(3):  # the log can lag the exit by a moment
        # The app's own line, not its WebContent helpers' (their names embed the app's pid too).
        termination = [l for l in [m for t, c, m in rb_stream.events()] + unified_log(start, termination_predicate(pid))
                       if re.search(r"\[app<application\.%s\.[^>]*>:%d\] termination reported" % (re.escape(BUNDLE_ID), pid), l)]
        if termination:
            break
        time.sleep(2)
    rb_stream.stop()
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
    if opts.case == "hidden":
        run.note("refusals of ensureCreated/create_window are not logged by the fix; not observable after exit")
    timeline = None
    if in_flight and opts.case == "windowless":
        timeline = windowless_evidence(run, in_flight, exit_seconds)
    elif in_flight:
        timeline = in_flight_evidence(run, in_flight, exit_seconds)
    elif opts.case in ("in-flight", "windowless"):
        run.check(False, f"the {opts.case} setup ran (see the failures above)")
    run.result = {"pid": pid, "wait_status": status, "signal": signal_number or None, "exit_code": exit_code,
                  "crash_reports": ips, "fatal": fatal[:2], "stack": stack[:8], "cef_log": shutdown,
                  "termination": termination[-1:], "quit_to_exit_s": round(exit_seconds, 3), "timeline": timeline}
    end_tag()
    return run


teardown = TagTeardown(APP)
teardown.install()
try:
    for n in range(1, opts.runs + 1):
        one_run(n)
        if opts.until_landed and sum(1 for r in runs if getattr(r, "landing", None) == "landed") >= opts.until_landed:
            break
finally:
    for stream in streams:
        if stream.poll() is None:
            stream.terminate()  # that process's exact PID
    teardown.end()
    end_tag()
    server.shutdown()
    verdict = [{"run": r.index, "ok": not r.failures, "landing": getattr(r, "landing", None), "failures": r.failures, "notes": r.notes,
                "result": getattr(r, "result", None), "checks": r.checks} for r in runs]
    with open(os.path.join(opts.out, "verdict.json"), "w") as handle:
        json.dump({"app": os.path.basename(APP), "bundle_id": BUNDLE_ID, "runs": verdict}, handle, indent=1)

def died(r):
    return bool(getattr(r, "result", {}) and (r.result.get("signal") or r.result.get("crash_reports") or r.result.get("fatal")))


aborted = sum(1 for r in runs if died(r))
if opts.case == "windowless":
    # A run whose timing missed (the open too early or too late) tested nothing: it is reported, not judged.
    landed = [r for r in runs if getattr(r, "landing", None) == "landed"]
    clean = sum(1 for r in landed if not r.failures)
    missed = {k: sum(1 for r in runs if getattr(r, "landing", None) == k) for k in ("early", "late", "unknown", None)}
    print(f"verdict: {clean}/{len(landed)} landed runs clean, {sum(1 for r in landed if died(r))} aborted; "
          f"missed {json.dumps({str(k): v for k, v in missed.items() if v})} of {len(runs)} attempts; artifacts in {opts.out}", flush=True)
    sys.exit(1 if clean != len(landed) or not landed or len(landed) < opts.until_landed else 0)
clean = sum(1 for r in runs if not r.failures)
print(f"verdict: {clean}/{len(runs)} runs clean, {aborted} aborted; artifacts in {opts.out}", flush=True)
sys.exit(1 if clean != len(runs) else 0)
