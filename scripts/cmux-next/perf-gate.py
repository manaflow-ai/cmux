#!/usr/bin/env python3
"""cmux-next perf gate (invariant I8, plans/cmux-next/perf-speed-of-light.md, cx-8w027.7).

One launch of a Debug cmux DEV app, every scenario, a work budget per action read from the
app's own debug counters (debug.layout_counters, debug.sidebar_perf, debug.surfaces). Counter
budgets are host-independent, so they BLOCK. Timing values (op latency, frame intervals) are
warnings only.

  source guard   no CATransaction.flush and no window capture outside the capture helpers, the screenshot
                 actions and the debug tools in
                 Packages/macOS/CmuxNext/Sources (I5: a theme change captures no window and
                 forces no commit). A reviewed exception carries `// perf-gate-ok: <reason>`
                 on the line or the line above it.
  workspaces     20 workspaces, each shown once, then every one again by id (goToWorkspace):
                 per switch 0 applies, at most 1 topology send, 0 pane snapshots, 0 sidebar
                 list reloads, 1 sidebar selection patch; 0 blank panes at the end (I6).
  theme          two of them with different themes, switched back and forth: the workspace
                 budget per switch, and the backdrop blend (debug.themes presentation value)
                 moves toward the target only, shows a color in between, ends on the target,
                 and a reversal starts from the color on screen (I5).
  drag           a terminal split right, its divider dragged one debug.mouse event per 60 Hz
                 frame: the grid each terminal renders follows the grid its frame fits within
                 --lag steps (I7). Frame p99 over 16.7 ms is a warning.
  tabs           16 panes x 3 tabs, Next Tab 40 times: 0 applies, 0 topology sends, 0 pane
                 snapshots, 0 sidebar list reloads (I6); each switch's Core Animation commit is in
                 the first frame after it shows (debug.tab_switch late_vsyncs 0; a frame check), a
                 main-thread apply over 4 ms is a warning. The socket reply also waits for the
                 daemon's confirm: reported, not gated. --hang-ms N prints main-thread stalls.
  split          split right + close pane 10 times in the 16 panes: per pair at most 2 applies,
                 2 topology sends, 4 pane snapshots (sources name the snapshot fields that changed).
  relaunch       the app quits and starts again on the same tag, so it restores the grid with
                 its hidden New Tab pages (state an earlier launch left, as a person's app has);
                 then tabs and split again in that grid, with the tabs and split budgets (I2,
                 cx-8w027.20: each restored page re-ran its pane on every split or close anywhere).
  new_workspaces 50 new workspaces, one newTab (Cmd-N's create path) at a time: each one's sidebar row is
                 drawn from the press, before the daemon creates it, with no rows pass walking every
                 workspace between its create and that draw (debug.new_workspace walks 0;
                 host-independent, blocks; the window's own later rows pass is not timed), and commits
                 in the first frame after it is drawn (late_vsyncs 0; a frame check). Press to drawn over
                 one frame is a warning; the reply (the daemon's confirm) is reported.
  pane_focus     16 panes x 3 tabs, focus moved 40 times each by Focus Next Pane, Focus Pane Left/Right
                 and a click (debug.mouse) into another pane, on page tabs then on terminal tabs: a move
                 touches the two panes only (0 applies, 0 topology sends, 0 sidebar list reloads or row
                 configures, at most 2 pane snapshots and 2 pane chrome updates per move; I6;
                 host-independent, blocks), and no window record save or location-trail encode runs on
                 the main thread between a move and its commit (debug.pane_focus work_before_commit 0;
                 blocks where moves are timed), and no Chromium page window encodes its restorable
                 state (debug.pane_focus chromium_restorable_encodes 0: a WindowServer round trip on the
                 main thread per encode; blocks). Intent to settled p95 over 2 ms of main-thread work
                 (PANE_FOCUS_BUDGET_MS, speed-of-sound-DESIGN.md 3.2) and a commit later than the
                 first frame after the move settles (debug.pane_focus late_vsyncs) are warnings: on a
                 shared GUI host both follow the host's load.
                 PERF_GATE_SAMPLE=1 also records a /usr/bin/sample call tree of 200 more moves;
                 PERF_GATE_PANE_FOCUS_WORKSPACES=N adds N workspaces first (a heavy session).
  activation     Cmd-Tab back in a heavy session (activation-perf.py): 150 workspaces, 100 Chromium
                 tabs (50 hibernated), 100 chat tabs; 20 resign/become pairs through debug.app_activation
                 with the main window's key and main notices. Per activation at most
                 ACTIVATION_MAX_RESYNCS status indicators re-checked (the ones a window shows, never every
                 row and tab of the session; host-independent, blocks); the main-thread time of the
                 become notices over ACTIVATION_BUDGET_MS p95 is a warning.
  status         4 background workspaces print OSC 7501 progress 4 times a second for 5 s:
                 0 applies, 0 topology sends, 0 pane snapshots, 0 sidebar list reloads (I1-I3).

The drag lag, the theme blend and the tab switch and new workspace timings (the app times them
per frame) need a window that draws. On a console without a lit display (fleet minis, CI VMs)
the window is occluded and the display link does not tick: with
--frames auto (the CI default) the script then reports those checks as skipped (a warning);
with --frames required (the GUI host) no frames is a failure. A budget breach names its callers
(debug.layout_counters `sources`).

Usage:
  perf-gate.py --source-guard-only
  perf-gate.py --app "<dir>/cmux DEV <tag>.app" --out DIR [--frames auto|required] [--only a,b]
CI: the cmux-scheme-compile job of .github/workflows/cmux-next.yml, on the app it compiled.
GUI host, before a landing that touches panes, tabs, workspaces, the sidebar or themes:
  nx-remote --needs gui --priority gate --gate-head SHA --ref SHA --app-from-fleet cmux --tag T -- \\
    python3 scripts/cmux-next/perf-gate.py --app "$NX_APP" --out "$NX_ARTIFACTS" --frames required
The script launches the app itself (no activation, automation socket, scratch config, empty
Ghostty config, isolated Chief home), quits it and ends the tag's daemons (tag_teardown). The
app must not be running. Exit 1 on any blocking failure.
"""
import argparse, importlib.util, json, os, re, socket, subprocess, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from tag_teardown import TagTeardown  # noqa: E402

# Budgets: the measured values after the perf lanes (perf-speed-of-light.md Status). Tighten here.
BUDGET = {
    # Per workspace switch (and per theme switch).
    # The sidebar repaints the old and new selected row or tile only: no row configure, no band layout (cx-8w027.17).
    "switch": {"workspace_applies": 0, "topology_sends": 1, "pane_snapshots": 0, "list_reloads": 0, "row_configures": 0,
               "band_updates": 0},
    "switch_selection_patches": 1,
    # Whole phase (40 Next Tab ops at 16 panes x 3 tabs).
    "tabs": {"workspace_applies": 0, "topology_sends": 0, "pane_snapshots": 0, "list_reloads": 0},
    # Per split+close pair (cx-8w027.14, measured 2 / 2 / 1.9-2.5): one apply and one topology each
    # for the split and the close (the new tab is named by its client-minted id; topologies carry no
    # surfaces, so the daemon's confirm sends none); snapshots: the new pane's mount and the shell's
    # titles (0-1.5, the shell's timing); the confirm re-runs only that tab's strip item.
    "split": {"workspace_applies": 2, "topology_sends": 2, "pane_snapshots": 3},
    # Whole status window (4 tickers x 4 ticks/s x 5 s).
    "status": {"workspace_applies": 0, "topology_sends": 0, "pane_snapshots": 0, "list_reloads": 0},
    # Per pane focus move (16 panes x 3 tabs): the old pane loses its ring, the new pane gets it; nothing
    # else re-runs (speed-of-sound-DESIGN.md 3.2: O(what changed on screen)).
    "pane_focus": {"workspace_applies": 0, "topology_sends": 0, "pane_snapshots": 2, "list_reloads": 0,
                   "row_configures": 0, "band_updates": 0, "pane_chrome_updates": 2},
    # Per restored pane, from the relaunched app's first answer until the restore settled: one
    # snapshot when the pane mounts on its restored tabs, no re-run as the restore goes on (cx-8w027.23).
    "restore": {"pane_snapshots": 1},
}
# Known breaches of a budget above: (scenario, counter) -> (the value measured today, the bead that
# removes it). A breach up to that value is a warning that names the bead; above it, a failure. A
# ratchet: when a full run (no --only) no longer shows the breach, the gate fails until its line here
# is removed, so the fixing lane tightens the gate in its own landing.
KNOWN = {
    # 3-6 of 50 new workspace rows commit a frame late on the mini (commit p99 34-39 ms at 33-70
    # workspaces; feat-cmux-next runs 39292677937, 39296303954, 39300730843). The row is drawn
    # from the press (walks 0); the list's commit of the insert is what runs long.
    ("new_workspaces", "late_rows"): (8, "cx-zf6um"),
}
FRAME_BUDGET_MS = 1000 / 60
# Main-thread work of one tab switch (intent to shown); MainActorWorkQueue's frame budget.
TAB_APPLY_BUDGET_MS = 4
# Main-thread work of one pane focus move (intent to settled): a fraction of a 120 Hz frame.
PANE_FOCUS_BUDGET_MS = 2
# New workspace rows: press to drawn (main-thread work and hops), one 60 Hz frame.
NEW_ROW_BUDGET_MS = FRAME_BUDGET_MS
# App activation (Cmd-Tab back) in the heavy session: indicators re-checked per activation (blocks)
# and the become notices' main-thread time p95 (warning). Before the fix: every indicator of the
# session per activation (user 2026-10-21, msg 9674/9682).
ACTIVATION_MAX_RESYNCS = 64
ACTIVATION_BUDGET_MS = 8
SCENARIOS = ["workspaces", "theme", "drag", "tabs", "pane_focus", "split", "relaunch", "new_workspaces", "activation", "status"]

ROOT = os.path.abspath(os.path.join(HERE, "../.."))
# The source guard's rule lives in check-perf-source-guard.py, which CI and the pre-push gate run alone.
_spec = importlib.util.spec_from_file_location("perf_source_guard", os.path.join(HERE, "check-perf-source-guard.py"))
perf_source_guard = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(perf_source_guard)

failures, warnings, report = [], [], {"checks": [], "phases": {}}


def check(ok, what, scenario):
    print(("ok   " if ok else "FAIL ") + f"[{scenario}] {what}", flush=True)
    report["checks"].append({"scenario": scenario, "ok": bool(ok), "what": what})
    if not ok:
        failures.append(f"[{scenario}] {what}")
    return ok


def warn(what, scenario):
    print(f"WARN [{scenario}] {what}", flush=True)
    warnings.append(f"[{scenario}] {what}")
    if os.environ.get("GITHUB_ACTIONS"):
        print(f"::warning title=perf gate {scenario}::{what}", flush=True)


# -- source guard ------------------------------------------------------------

def source_guard():
    hits, count = perf_source_guard.scan(ROOT)
    for hit in hits:
        print("  " + hit, flush=True)
    check(not hits, f"no CATransaction.flush and no window capture outside the capture helpers, screenshot actions and debug tools ({count} files, "
                    f"{len(hits)} hits; a reviewed exception carries `// perf-gate-ok: <reason>`)", "source guard")


# -- the app -----------------------------------------------------------------

class App:
    def __init__(self, bundle, out):
        name = os.path.basename(bundle.rstrip("/"))
        match = re.fullmatch(r"cmux DEV (.+)\.app", name)
        if not match:
            raise SystemExit(f"perf-gate: expected a `cmux DEV <tag>.app` bundle, got {name}")
        self.bundle, self.tag, self.out = bundle, match.group(1), out
        self.socket = f"/tmp/cmux-debug-{self.tag}.sock"
        self.cli_path = os.path.join(bundle, "Contents/Resources/bin/cmux")
        self.scratch = tempfile.mkdtemp(prefix=f"perf-gate-{self.tag}-")
        self.config = os.path.join(self.scratch, "cmux.json")
        self.process = None
        self.teardown = TagTeardown(bundle)

    def launch(self):
        with open(self.config, "w") as f:
            json.dump({"appearance": {"backgroundOpacity": 1,
                                      "colorTransition": {"duration": 400, "curve": "linear", "colorSpace": "oklab"}}}, f)
        ghostty = os.path.join(self.scratch, "ghostty")
        open(ghostty, "w").close()
        if os.path.exists(self.socket):
            os.unlink(self.socket)
        env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
               "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
               "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1440,900",
               "CMUX_NEXT_CONFIG_FILE": self.config, "CMUX_NEXT_GHOSTTY_CONFIG": ghostty,
               "CMUX_NEXT_CHIEF_ISOLATED": "1", "CMUX_NEXT_CHIEF_HOME": os.path.join(self.scratch, "chief")}
        # --hang-ms: the main-thread watchdog samples every stall over N ms (debug.hangs), for a late frame's cause.
        if os.environ.get("PERF_GATE_HANG_MS"):
            env["CMUX_NEXT_HANG_THRESHOLD_MS"] = os.environ["PERF_GATE_HANG_MS"]
        self.teardown.install()
        log = open(os.path.join(self.out, "app.log"), "a")
        self.process = subprocess.Popen([os.path.join(self.bundle, "Contents/MacOS/cmux DEV")], env=env,
                                        stdout=log, stderr=log, stdin=subprocess.DEVNULL)
        print(f"perf-gate: launched {self.tag} pid {self.process.pid}", flush=True)
        if not wait(lambda: os.path.exists(self.socket) and "error" not in (self.rpc("debug.layout_counters") or {"error": 1}), 180):
            raise SystemExit("perf-gate: the app's debug socket never answered (a Debug build is required)")
        if not wait(lambda: self.panes()[0] >= 1, 60):
            raise SystemExit("perf-gate: the first terminal pane never showed")

    def relaunch(self):
        """Quits the app and starts it again on the same tag: it restores what this launch left."""
        self.stop()
        self.teardown = TagTeardown(self.bundle)
        self.launch()

    def stop(self):
        try:
            if self.process and self.process.poll() is None:
                self.rpc("debug.quit", {"fixture_quit": "end-sessions"}, timeout=10)
                try:
                    self.process.wait(30)
                except subprocess.TimeoutExpired:
                    self.process.terminate()
                    try:
                        self.process.wait(15)
                    except subprocess.TimeoutExpired:
                        self.process.kill()
        finally:
            self.teardown.end()

    def rpc(self, method, params=None, timeout=60):
        try:
            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(timeout)
            conn.connect(self.socket)
            conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = conn.recv(1 << 22)
                if not chunk:
                    break
                buf += chunk
            conn.close()
            reply = json.loads(buf)
        except (OSError, ValueError) as error:
            return {"error": str(error)}
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}

    def action(self, name, args=None, target=None):
        params = {"action": name, "args": args or {}, "focus": True, "origin": "script"}
        if target:
            params["target"] = target
        reply = self.rpc("action.run", params, timeout=120)
        if isinstance(reply, dict) and reply.get("error"):
            print(f"  action {name} -> {reply['error']}", flush=True)
        return reply

    def cli(self, *args):
        env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
        env["CMUX_NEXT_CONFIG_FILE"] = self.config
        done = subprocess.run([self.cli_path, "--app-socket", self.socket, *args], env=env, capture_output=True,
                              text=True, timeout=120, stdin=subprocess.DEVNULL)
        if done.returncode != 0:
            print(f"  cli {' '.join(args)[:80]} -> {done.returncode} {(done.stdout + done.stderr).strip()[-240:]}", flush=True)
        return done

    # -- reads --

    def topology(self):
        snap = self.rpc("snapshot.get") or {}
        return snap.get("topology") or {}

    def workspace_ids(self):
        return [w.get("id") for w in self.topology().get("workspaces") or [] if w.get("id")]

    def shown_workspace(self):
        return (self.topology().get("focus") or {}).get("workspace")

    def panes(self):
        """(panes, tabs) of the shown workspace."""
        topo = self.topology()
        focus = (topo.get("focus") or {}).get("workspace")
        panes = tabs = 0
        for workspace in topo.get("workspaces") or []:
            if workspace.get("id") != focus:
                continue
            for screen in workspace.get("screens") or []:
                for pane in screen.get("panes") or []:
                    panes += 1
                    tabs += len(pane.get("tabs") or [])
        return panes, tabs

    def pane_ids(self):
        """Pane ids of the shown workspace, in snapshot order."""
        topo = self.topology()
        focus = (topo.get("focus") or {}).get("workspace")
        return [pane.get("id") for workspace in topo.get("workspaces") or [] if workspace.get("id") == focus
                for screen in workspace.get("screens") or [] for pane in screen.get("panes") or [] if pane.get("id")]

    def themes_window(self):
        windows = (self.rpc("debug.themes") or {}).get("windows") or []
        return windows[0] if windows else {}

    def sheet(self):
        return (self.themes_window().get("backdrop") or {}).get("sheet") or ""

    def counters(self, reset=True):
        """The app's work counters since the last reset, in one flat dict (+ `sources`)."""
        layout = self.rpc("debug.layout_counters", {"reset": reset}) or {}
        sidebar = self.rpc("debug.sidebar_perf", {"reset": reset}) or {}
        out = {k: v for k, v in layout.items() if isinstance(v, (int, float))}
        out.update({k: v for k, v in sidebar.items() if isinstance(v, (int, float)) and "@" not in k and k not in out})
        # The sidebar names the caller of each list reload as "list_reloads@<file>:<line>".
        out["sources"] = {**(layout.get("sources") or {}), **{k: v for k, v in sidebar.items() if "@" in k}}
        return out

    def settle(self):
        """Lets observation work for the last op run before a counter read: one socket round trip
        through the main actor, then a bounded pause for trailing async apply work."""
        self.topology()
        time.sleep(0.5)  # test script: trailing async work after the last reply lands in this read

    QUIET_KEYS = ("workspace_applies", "topology_sends", "pane_snapshots", "list_reloads", "selection_patches")

    def quiet_counters(self, before_reset=None):
        """settle(), then the counters once two reads 0.2 s apart agree on the budget counters (at
        most 3 s), so late work of this op is not counted in the next op's window; then reset.
        `before_reset` runs just before the reset, so its socket reads count in this window."""
        self.settle()
        deadline = time.monotonic() + 3
        last = self.counters(reset=False)
        while time.monotonic() < deadline:  # bounded: the app's own counters stop moving
            time.sleep(0.2)  # test script: the gap between two counter reads
            now = self.counters(reset=False)
            if all(now.get(k) == last.get(k) for k in self.QUIET_KEYS):
                break
            last = now
        if before_reset:
            before_reset()
        return self.counters()

    def draws(self):
        """True when the window's display link ticks (a lit, unoccluded window)."""
        self.rpc("debug.frames", {"action": "start"})
        time.sleep(1.0)  # test script: the frame probe's sampling window
        stats = self.rpc("debug.frames", {"action": "stop"}) or {}
        return (stats.get("frames") or 0) >= 10, stats


def wait(predicate, seconds, step=0.25):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the live app's own state
        try:
            value = predicate()
        except Exception:  # noqa: BLE001 - the app may not answer yet
            value = None
        if value:
            return value
        time.sleep(step)
    return None


def over(measured, budget, scale=1):
    """[(counter, value, limit)] of the counters over budget x scale."""
    return [(k, measured.get(k, 0), limit * scale) for k, limit in budget.items() if measured.get(k, 0) > limit * scale]


def breach_text(breaches, sources):
    text = ", ".join(f"{k} {v} > {limit}" for k, v, limit in breaches)
    if breaches and sources:
        text += "; callers: " + ", ".join(f"{k} x{v}" for k, v in sorted(sources.items(), key=lambda kv: -kv[1])[:6])
    return text


# -- OKLab (the blend space) ---------------------------------------------------

def rgb(hexa):
    return tuple(int(hexa[i:i + 2], 16) / 255 for i in (1, 3, 5)) if len(hexa or "") >= 7 else None


def oklab(color):
    def lin(c):
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (lin(c) for c in color)
    l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ** (1 / 3)
    m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ** (1 / 3)
    s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ** (1 / 3)
    return (0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s)


def distance(a, b):
    return sum((x - y) ** 2 for x, y in zip(oklab(rgb(a)), oklab(rgb(b)))) ** 0.5


# -- scenarios -----------------------------------------------------------------

class Gate:
    def __init__(self, app, opts):
        self.app, self.opts = app, opts
        self.frames = None  # (draws, stats), read once
        self.warned = set()
        self.full = not opts.only or set(opts.only.split(",")) == set(SCENARIOS)

    def frames_ok(self, scenario):
        """Whether frame-dependent checks run; reports the skip (auto) or the failure (required)."""
        if self.frames is None:
            self.frames = self.app.draws()
            report["frames_probe"] = self.frames[1]
        if self.frames[0]:
            return True
        skipped = report.setdefault("frames_skipped", [])
        if scenario not in skipped:
            skipped.append(scenario)
            skipped.sort()
        what = f"the window draws no frames (debug.frames {self.frames[1].get('frames')} in 1 s: an occluded or unlit console)"
        if self.opts.frames == "required":
            check(False, what, scenario)
        else:
            warn(what + "; the frame-dependent checks are skipped here and run on the GUI host (--frames required)", scenario)
        return False

    def timed_count(self, rows, expected, what, scenario):
        """Whether the app timed every one of `expected` (`what`, e.g. "debug.tab_switch timed {n} of 40
        switches"). The app times them against the display link's frames: a window that draws none
        times none, which is the frame probe's skip (or its failure with --frames required)."""
        if not rows and not self.frames_ok(scenario):
            return False
        return check(len(rows) == expected, what.format(n=len(rows)), scenario)

    def switch_steps(self, targets, scenario):
        """goToWorkspace each target; per switch the counters must fit BUDGET['switch']."""
        app, worst, patches, rows = self.app, {}, 0, []
        app.quiet_counters()
        for target in targets:
            start = time.monotonic()
            app.action("goToWorkspace", {"workspace": target})
            latency = (time.monotonic() - start) * 1000
            landed = {}
            measured = app.quiet_counters(lambda: landed.setdefault("shown", app.shown_workspace()))
            shown = landed.get("shown")
            if shown != target:
                check(False, f"switch to {target} landed (shown {shown})", scenario)
            reloads = {k: v for k, v in measured["sources"].items() if k.startswith("list_reloads@")}
            rows.append({"to": target, "latency_ms": round(latency, 1),
                         **{k: v for k, v in measured.items() if k != "sources"},
                         **({"list_reload_callers": reloads} if reloads else {})})
            patches += measured.get("selection_patches", 0)
            breaches = self.unknown(over(measured, BUDGET["switch"]), scenario)
            if breaches:
                check(False, f"switch to {target}: {breach_text(breaches, measured['sources'])}", scenario)
                if "sidebar_rows" not in report:
                    report["sidebar_rows"] = app.rpc("debug.sidebar_rows")
            for k in BUDGET["switch"]:
                worst[k] = max(worst.get(k, 0), measured.get(k, 0))
        report["phases"][scenario] = {"switches": rows, "worst": worst}
        # The ratchet needs the full run's workspaces (no --only) and a clean scenario.
        if self.full and not any(f.startswith(f"[{scenario}]") for f in failures):
            self.ratchet(scenario, worst, BUDGET["switch"])
        return rows, worst, patches

    def unknown(self, breaches, scenario):
        """The breaches that KNOWN does not name; a known one is a warning (once per scenario)."""
        out = []
        for k, value, limit in breaches:
            known = KNOWN.get((scenario, k))
            if not known or value > known[0]:
                out.append((k, value, limit))
            elif (scenario, k) not in self.warned:
                self.warned.add((scenario, k))
                warn(f"known breach {k} {value} > {limit} (known up to {known[0]}: {known[1]})", scenario)
        return out

    def ratchet(self, scenario, measured, budget):
        for (name, k), (_, bead) in KNOWN.items():
            if name == scenario and k in budget and measured.get(k, 0) <= budget[k]:
                check(False, f"the known breach of {k} no longer happens ({bead}): remove its KNOWN line", scenario)

    def workspaces(self):
        app = self.app
        want = 20
        for i in range(max(0, want - len(app.workspace_ids()))):
            app.cli("workspace", "create", "--name", f"perf {i}")
        ids = wait(lambda: (lambda w: w if len(w) >= want else None)(app.workspace_ids()), 60) or app.workspace_ids()
        check(len(ids) >= want, f"{len(ids)} workspaces open (want {want})", "workspaces")
        ids = ids[:want]
        for target in ids:  # round 1: every workspace shows once (each mounts once)
            app.action("goToWorkspace", {"workspace": target})
        wait(lambda: app.shown_workspace() == ids[-1], 10)
        rows, worst, patches = self.switch_steps(ids + ids[:4], "workspaces")
        check(not self.unknown(over(worst, BUDGET["switch"]), "workspaces"),
              f"{len(rows)} switches at {len(ids)} workspaces, worst per switch {worst} (budget {BUDGET['switch']})", "workspaces")
        want_patches = len(rows) * BUDGET["switch_selection_patches"]
        check(patches == want_patches, f"{patches} sidebar selection patches for {len(rows)} switches (want {want_patches})",
              "workspaces")
        surfaces = app.rpc("debug.surfaces") or {}
        check(surfaces.get("blank_panes") == 0, f"blank_panes {surfaces.get('blank_panes')} after the switches "
              f"(live terminals {surfaces.get('live_terminals')}, warm capacity {surfaces.get('warm_terminal_capacity')})",
              "workspaces")
        latencies = sorted(r["latency_ms"] for r in rows)
        p99 = latencies[min(len(latencies) - 1, int(len(latencies) * 0.99))] if latencies else 0
        report["phases"]["workspaces"]["latency_p99_ms"] = p99
        if p99 > 100:
            warn(f"workspace switch reply p99 {p99} ms (over 100 ms)", "workspaces")
        self.ids = ids

    def theme(self):
        app = self.app
        ids = getattr(self, "ids", None) or app.workspace_ids()
        if len(ids) < 2:
            app.cli("workspace", "create", "--name", "perf theme")
            ids = wait(lambda: (lambda w: w if len(w) >= 2 else None)(app.workspace_ids()), 30) or []
        if not check(len(ids) >= 2, "two workspaces for the theme switch", "theme"):
            return
        a, b = ids[0], ids[1]
        for target, theme in ((a, "Rose Pine"), (b, "Catppuccin Mocha")):
            app.action("goToWorkspace", {"workspace": target})
            app.action("workspace.setTheme", {"theme": theme}, target=f"workspace:{target}")
        # Counters: six theme switches, the workspace switch budget each.
        rows, worst, patches = self.switch_steps([a, b] * 3, "theme")
        check(not self.unknown(over(worst, BUDGET["switch"]), "theme"),
              f"{len(rows)} theme switches, worst per switch {worst} (budget {BUDGET['switch']})", "theme")
        if not self.frames_ok("theme"):
            return

        def at_rest():
            backdrop = app.themes_window().get("backdrop") or {}
            return backdrop.get("sheet") if backdrop.get("blending") == "false" and backdrop.get("sheet") else None

        def sample(seconds, first, then=None):
            samples, start = [], time.monotonic()
            threading.Thread(target=app.action, args=("goToWorkspace", {"workspace": first}), daemon=True).start()
            fired = then is None
            while time.monotonic() - start < seconds:  # bounded sampling window
                if not fired and time.monotonic() - start >= 0.25:
                    samples.append("RETARGET")
                    threading.Thread(target=app.action, args=("goToWorkspace", {"workspace": then}), daemon=True).start()
                    fired = True
                samples.append(app.sheet())
            return samples

        app.action("goToWorkspace", {"workspace": a})
        light = wait(at_rest, 5, 0.05)
        app.action("goToWorkspace", {"workspace": b})
        dark = wait(at_rest, 5, 0.05)
        if not check(bool(light and dark) and distance(light, dark) > 0.02,
                     f"the two workspaces have different backdrops ({light} vs {dark})", "theme"):
            return
        span = distance(light, dark)
        app.action("goToWorkspace", {"workspace": a})
        wait(lambda: (at_rest() or "")[:7] == light[:7], 5, 0.05)
        seen = [c for c in sample(0.8, b) if c]
        while len(seen) > 1 and seen[0][:7] == light[:7] and seen[1][:7] == light[:7]:
            seen = seen[1:]  # the switch had not landed yet
        distinct = list(dict.fromkeys(c[:7] for c in seen))
        remaining = [distance(c, dark) for c in distinct]
        steps = [round(y - x, 4) for x, y in zip(remaining, remaining[1:])]
        report["phases"]["theme"]["blend"] = {"light": light, "dark": dark, "distinct": distinct}
        check(len(distinct) >= 3, f"the blend shows a color between the two ({len(distinct)} distinct samples)", "theme")
        if len(distinct) < 4:
            warn(f"the blend showed {len(distinct)} distinct samples (4 or more on a fast host)", "theme")
        check(all(s <= 0.004 for s in steps), f"every sample is nearer the target than the last (OKLab steps {steps[:12]})", "theme")
        check(bool(seen) and seen[-1][:7] == dark[:7], f"the blend ends on the target ({seen[-1] if seen else None} vs {dark})", "theme")
        wait(lambda: (at_rest() or "")[:7] == dark[:7], 5, 0.05)
        turn = sample(1.1, a, b)
        marker = turn.index("RETARGET") if "RETARGET" in turn else None
        before = [c for c in turn[:marker] if c] if marker is not None else []
        after = [c for c in turn[marker + 1:] if c] if marker is not None else []
        if check(bool(before and after), "samples on both sides of a reversal", "theme"):
            jump = distance(after[0], before[-1])
            check(jump < 0.35 * span, f"the reversal starts from the color on screen (jump {jump:.3f} of span {span:.3f})", "theme")
            check(after[-1][:7] == dark[:7], f"the reversal ends on the target ({after[-1]} vs {dark})", "theme")

    def drag(self):
        app = self.app
        before_ws = app.shown_workspace()
        app.action("workspace.newAtBottom")
        wait(lambda: app.shown_workspace() not in (None, before_ws) and app.panes()[0] >= 1, 30)
        app.action("splitRight", {})
        if not check(bool(wait(lambda: app.panes()[0] >= 2 and self.dividers(), 30)), "a split shows two terminals and a divider", "drag"):
            return
        app.cli("--json", "terminal", "current", "write", "--text", "clear; seq -s. 900\r")
        time.sleep(1.0)  # test script: the long line prints before the drag
        x0, y0 = self.dividers()[0]
        n, step = 40, 6.0
        path = [-step] * n + [step] * (2 * n) + [-step] * n

        def run(sample):
            rows = []
            app.rpc("debug.mouse", {"action": "down", "x": x0, "y": y0})
            x = x0
            for delta in path:
                app.rpc("debug.mouse", {"action": "drag", "x": x, "y": y0, "to_x": x + delta, "to_y": y0, "steps": 1,
                                        "press": False, "release": False})
                x += delta
                time.sleep(1 / 60)  # test script: one pointer event per 60 Hz frame
                if sample:
                    panes = self.terminals()
                    rows.append({"fit": [p[1] for p in panes], "grid": [p[2] for p in panes]})
            app.rpc("debug.mouse", {"action": "up", "x": x, "y": y0})
            time.sleep(0.8)  # test script: the drag's last layout lands
            return rows

        # Pass A: counters and frame intervals of the drag alone.
        app.quiet_counters()
        app.rpc("debug.frames", {"action": "start"})
        run(sample=False)
        frames = app.rpc("debug.frames", {"action": "stop"}) or {}
        measured = app.quiet_counters()
        report["phases"]["drag"] = {"events": len(path), "frames": frames,
                                    "counters": {k: v for k, v in measured.items() if k != "sources"},
                                    "sources": measured["sources"]}
        print(f"  drag counters for {len(path)} events: " + json.dumps(report["phases"]["drag"]["counters"]), flush=True)
        if not self.frames_ok("drag"):
            return
        if (frames.get("p99_ms") or 0) > FRAME_BUDGET_MS:
            warn(f"divider drag frame p99 {frames.get('p99_ms'):.1f} ms (budget {FRAME_BUDGET_MS:.1f} ms; "
                 f"max {frames.get('max_ms') or 0:.1f} ms, missed {frames.get('missed')})", "drag")
        # Pass B: the grid each terminal renders against what its frame fits, per step.
        rows = run(sample=True)
        misses, distinct = [], []
        for pane in range(min((len(r["fit"]) for r in rows), default=0)):
            fits = [r["fit"][pane] for r in rows]
            grids = [r["grid"][pane] for r in rows]
            for i, grid in enumerate(grids):
                recent = fits[max(0, i - self.opts.lag):i + 1]
                if not min(recent) <= grid <= max(recent):
                    misses.append({"pane": pane, "step": i, "grid": grid, "recent_fits": recent})
            distinct.append(len(set(grids)))
        report["phases"]["drag"].update({"misses": misses[:20], "distinct_grids": distinct})
        check(bool(distinct) and min(distinct) > 5, f"the rendered grid follows the drag ({distinct} distinct grids per terminal)", "drag")
        check(not misses, f"every step's rendered columns are within {self.opts.lag} steps of the fitted columns "
                          f"({len(misses)} misses{', first ' + json.dumps(misses[0]) if misses else ''})", "drag")

    def dividers(self):
        windows = (self.app.rpc("debug.layers") or {}).get("windows") or [{}]
        window = windows[0] if windows else {}
        height = (window.get("frame") or [0, 0, 0, 900])[3]
        return sorted((x + w / 2, height - (y + h / 2)) for x, y, w, h in window.get("divider_areas_in_window") or [] if h > w)

    def terminals(self):
        rows = []
        for window in (self.app.rpc("debug.surfaces") or {}).get("windows") or []:
            for pane in window.get("panes") or []:
                surface, grid = pane.get("surface") or {}, pane.get("grid") or {}
                if surface.get("fit_grid"):
                    rows.append((grid.get("frame_x", 0), cols(surface.get("fit_grid")), cols(surface.get("grid"))))
        return sorted(rows)

    def build_grid(self, columns=4, rows=4, tabs=3):
        """A new workspace with columns x rows terminals on one screen (equal splits), each pane
        with `tabs` tabs (New Tab Page tabs: hidden, no PTY)."""
        app = self.app
        before_ws = app.shown_workspace()
        app.action("workspace.newAtBottom")
        wait(lambda: app.shown_workspace() not in (None, before_ws) and app.panes()[0] >= 1, 30)

        def split(action, pane):
            known = set(app.pane_ids())
            app.action(action, {}, target=f"pane:{pane}")
            new = wait(lambda: [p for p in app.pane_ids() if p not in known], 30)
            app.action("equalizeSplits", {}, target=f"pane:{pane}")
            return new[0] if new else None

        column = app.pane_ids()[:1]
        for _ in range(columns - 1):
            if column[-1]:
                column.append(split("splitRight", column[-1]))
        for top in [c for c in column if c]:
            cell = top
            for _ in range(rows - 1):
                cell = split("splitDown", cell) if cell else None
        for pane in app.pane_ids():
            for _ in range(tabs - 1):
                app.action("newTab.page", {}, target=f"pane:{pane}")
        want = columns * rows
        shown = wait(lambda: (lambda p: p if p[0] >= want and p[1] >= want * tabs else None)(app.panes()), 30) or app.panes()
        self.grid_workspace = app.shown_workspace()
        print(f"  grid: {shown[0]} panes, {shown[1]} tabs in {self.grid_workspace}", flush=True)
        self.grid = shown
        return shown

    def tabs(self, scenario="tabs"):
        app = self.app
        panes, tabs = getattr(self, "grid", None) or self.build_grid()
        if not check(panes >= 16 and tabs >= 48, f"16 panes x 3 tabs shown ({panes} panes, {tabs} tabs)", scenario):
            return
        # Next Tab really moves the selection (outside the measured window: the reads cost nothing there).
        seen = []
        for _ in range(3):
            app.action("nextSurface")
            seen.append((app.topology().get("focus") or {}).get("tab"))
        if not check(len(set(seen)) == 3, f"Next Tab selects each of the pane's 3 tabs ({seen})", scenario):
            return
        ops = 40
        app.quiet_counters()
        # The frame probe keeps the display link ticking, so debug.tab_switch's first tick after a switch is the
        # next vsync, not a link that starts from idle.
        app.rpc("debug.frames", {"action": "start"})
        app.rpc("debug.tab_switch", {"action": "start"})
        app.rpc("debug.hangs", {"clear": True})
        latencies = []
        for _ in range(ops):
            start = time.monotonic()
            app.action("nextSurface")
            latencies.append((time.monotonic() - start) * 1000)
        measured = app.quiet_counters()
        own = app.rpc("debug.tab_switch", {"action": "stop"}) or {}
        switch_frames = app.rpc("debug.frames", {"action": "stop"}) or {}
        report["phases"][scenario] = {"ops": ops, "counters": {k: v for k, v in measured.items() if k != "sources"},
                                      "sources": measured["sources"], "latency_p99_ms": sorted(latencies)[int(ops * 0.99) - 1],
                                      "latencies_ms": [round(v, 1) for v in latencies]}
        check(not over(measured, BUDGET["tabs"]),
              f"{ops} tab switches at {panes} panes x 3 tabs: {breach_text(over(measured, BUDGET['tabs']), measured['sources']) or 'all 0'}"
              f" (budget {BUDGET['tabs']})", scenario)
        # The reply also waits for the daemon to confirm the selection and for a frame-paced snapshot publish, so
        # it is not the switch's cost (cx-8w027.21): the same switch without waiting, and a bare round trip.
        def timed(call):
            start = time.monotonic()
            call()
            return round((time.monotonic() - start) * 1000, 1)
        phase = report["phases"][scenario]
        phase["frames"] = switch_frames
        phase["hangs"] = (app.rpc("debug.hangs") or {}).get("records") or []
        for record in phase["hangs"][:8]:
            print(f"  main-thread stall {record.get('duration_ms', 0):.1f} ms ({record.get('kind')}): "
                  + " < ".join(str(f)[:70] for f in (record.get("frames") or [])[:40]), flush=True)
        if scenario == "tabs":
            phase["no_wait_ms"] = [timed(lambda: app.rpc("action.run", {"action": "nextSurface", "args": {}, "focus": True,
                                                                         "origin": "script", "wait": False})) for _ in range(20)]
            app.settle()
            phase["ping_ms"] = [timed(lambda: app.rpc("system.ping")) for _ in range(20)]
        # The gated timing: the app's own time per switch (debug.tab_switch): intent to shown (apply), to the Core
        # Animation commit that carries it (after AppKit's layout and display), and the frames it missed (0: the
        # first frame it could); the commit's end (an upper bound) is reported.
        switches = own.get("switches") or []
        # A row carries its kind ("terminal", "browser") next to its timings.
        phase["switches"] = [{k: round(v, 2) if isinstance(v, (int, float)) else v for k, v in row.items()} for row in switches]
        if not self.timed_count(switches, ops, f"debug.tab_switch timed {{n}} of {ops} switches", scenario):
            return
        col = lambda name: sorted(row[name] for row in switches)
        p99 = lambda values: values[max(0, int(len(values) * 0.99) - 1)]
        applies, commits, ends = col("apply_ms"), col("commit_ms"), col("commit_end_ms")
        print(f"  tab switch: apply p50 {applies[ops // 2]:.2f} / p99 {p99(applies):.2f} ms, commit p50 {commits[ops // 2]:.2f} / "
              f"p99 {p99(commits):.2f} ms, commit end p99 {p99(ends):.2f} ms (refresh {switches[0]['refresh_ms']:.1f} ms); "
              f"reply p99 {phase['latency_p99_ms']:.1f} ms (daemon confirm included)", flush=True)
        if p99(applies) > TAB_APPLY_BUDGET_MS:
            warn(f"tab switch apply p99 {p99(applies):.2f} ms (over {TAB_APPLY_BUDGET_MS} ms of main-thread work)", scenario)
        if self.frames_ok(scenario):
            late = [row for row in switches if row["late_vsyncs"] > 0]
            check(not late, f"every tab switch commits in the first frame after it shows ({len(late)} later"
                            + (f": {[(round(r['apply_ms'], 1), round(r['commit_ms'], 1), int(r['late_vsyncs'])) for r in late][:6]} "
                               "(apply ms, commit ms, frames missed)" if late else "") + ")", scenario)
            # The commit's own end (the encode and AppKit's window-server transaction) past the next vsync: reported.
            overrun = [row for row in switches if row["late_end_vsyncs"] > 0]
            if overrun:
                warn(f"{len(overrun)} of {ops} tab switch commits ended a frame late: "
                     f"{[(round(r['commit_ms'], 1), round(r['commit_end_ms'], 1)) for r in overrun][:6]} (commit ms, end ms)", scenario)

    def pane_focus(self, scenario="pane_focus"):
        app = self.app
        panes, tabs = getattr(self, "grid", None) or self.build_grid()
        if not check(panes >= 16, f"16 panes shown ({panes} panes, {tabs} tabs)", scenario):
            return
        ids = app.pane_ids()
        focused = lambda: (app.topology().get("focus") or {}).get("pane")
        # The modes really move focus (outside the measured window).
        start_pane = focused()
        app.action("focusNextPane")
        if not check(focused() != start_pane, f"Focus Next Pane moves focus ({start_pane} -> {focused()})", scenario):
            return
        per_mode = 40
        clicks = [ids[(i * 5) % len(ids)] for i in range(per_mode)]
        modes = [("next", lambda i: app.action("focusNextPane")),
                 ("left_right", lambda i: app.action("focusRight" if i % 2 == 0 else "focusLeft")),
                 ("click", lambda i: app.rpc("debug.mouse", {"action": "click", "pane": clicks[i]})),
                 # Every pane on its terminal tab (the grid's first tab), then Next Pane again.
                 ("terminals", None),
                 ("next_terminal", lambda i: app.action("focusNextPane")),
                 ("click_terminal", lambda i: app.rpc("debug.mouse", {"action": "click", "pane": clicks[i]}))]
        phase = report["phases"][scenario] = {"modes": {}}
        # PERF_GATE_PANE_FOCUS_WORKSPACES=N: N more workspaces exist (a heavy session); the grid stays shown.
        extra = int(os.environ.get("PERF_GATE_PANE_FOCUS_WORKSPACES") or 0)
        if extra:
            grid = app.shown_workspace()
            for _ in range(extra):
                app.rpc("action.run", {"action": "workspace.newAtBottom", "args": {}, "focus": False, "origin": "script"}, timeout=120)
            app.action("goToWorkspace", {"workspace": grid})
            wait(lambda: app.shown_workspace() == grid, 30)
            phase["workspaces"] = len(app.workspace_ids())
            print(f"  heavy: {phase['workspaces']} workspaces", flush=True)
        app.rpc("debug.frames", {"action": "start"})
        app.rpc("debug.hangs", {"clear": True})
        for name, move in modes:
            if move is None:
                for pane in app.pane_ids():
                    app.action("selectSurfaceByNumber", {"index": 1}, target=f"pane:{pane}")
                app.settle()
                continue
            app.quiet_counters()
            app.rpc("debug.pane_focus", {"action": "start"})
            replies = []
            for i in range(per_mode):
                t0 = time.monotonic()
                move(i)
                replies.append(round((time.monotonic() - t0) * 1000, 1))
            measured = app.quiet_counters()
            own = app.rpc("debug.pane_focus", {"action": "stop"}) or {}
            moves = [{k: round(v, 3) for k, v in row.items() if isinstance(v, (int, float))} for row in own.get("moves") or []]
            phase["modes"][name] = {"reply_ms": replies, "moves": moves,
                                    "counters": {k: v for k, v in measured.items() if k != "sources"}, "sources": measured["sources"]}
            breaches = over(measured, BUDGET["pane_focus"], per_mode)
            per_move = {k: round(measured.get(k, 0) / per_mode, 2) for k in BUDGET["pane_focus"]}
            check(not breaches, f"{per_mode} {name} moves at {panes} panes: per move {per_move} (budget {BUDGET['pane_focus']})"
                                + (f"; {breach_text(breaches, measured['sources'])}" if breaches else ""), scenario)
            # A move that keeps the pane (an edge, a click on the focused pane) is not timed: at least 3 in 4 must be.
            if not moves:
                if not self.frames_ok(scenario):
                    continue
                check(False, f"debug.pane_focus timed 0 of {per_mode} {name} moves", scenario)
                continue
            before_commit = {k: int(v) for k, v in (own.get("work_before_commit") or {}).items() if v}
            phase["modes"][name]["work_before_commit"] = before_commit
            check(not before_commit, f"{name}: no record save or trail encode on the main thread before a move's commit "
                                     f"({before_commit or 'none'} in {len(moves)} moves)", scenario)
            encodes = int(own.get("chromium_restorable_encodes") or 0)
            phase["modes"][name]["chromium_restorable_encodes"] = encodes
            check(encodes == 0, f"{name}: no Chromium page window encodes its restorable state ({encodes} encodes in "
                                f"{per_mode} moves)", scenario)
            col = lambda key: sorted(row.get(key, 0) for row in moves)
            pct = lambda values, q: values[min(len(values) - 1, max(0, int(round(len(values) * q)) - 1))]
            applies, commits = col("apply_ms"), col("commit_ms")
            print(f"  pane focus {name}: {len(moves)} timed; intent to settled p50 {pct(applies, .5):.2f} / p95 {pct(applies, .95):.2f}"
                  f" / max {applies[-1]:.2f} ms; to commit p50 {pct(commits, .5):.2f} / p95 {pct(commits, .95):.2f} ms;"
                  f" reply p50 {sorted(replies)[per_mode // 2]:.1f} ms", flush=True)
            phase["modes"][name].update({"apply_p50_ms": pct(applies, .5), "apply_p95_ms": pct(applies, .95),
                                         "commit_p50_ms": pct(commits, .5), "commit_p95_ms": pct(commits, .95)})
            if pct(applies, .95) > PANE_FOCUS_BUDGET_MS:
                warn(f"{name}: pane focus intent to settled p95 {pct(applies, .95):.2f} ms (budget {PANE_FOCUS_BUDGET_MS} ms)", scenario)
            if self.frames_ok(scenario):
                late = [row for row in moves if row.get("late_vsyncs", 0) > 0]
                phase["modes"][name]["late"] = len(late)
                if late:
                    warn(f"{name}: {len(late)} of {len(moves)} pane focus moves commit after the first frame after they settle: "
                         f"{[(r['apply_ms'], r['commit_ms'], int(r['late_vsyncs'])) for r in late][:6]} (apply ms, commit ms, frames missed)",
                         scenario)
        phase["hangs"] = (app.rpc("debug.hangs") or {}).get("records") or []
        app.rpc("debug.frames", {"action": "stop"})
        if os.environ.get("PERF_GATE_SAMPLE") and app.process:
            # Attribution: the main thread's call tree over 200 more Focus Next Pane moves.
            out = os.path.join(app.out, "pane-focus-sample.txt")
            sampler = subprocess.Popen(["/usr/bin/sample", str(app.process.pid), "8", "1", "-mayDie", "-file", out],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            time.sleep(0.5)  # test script: sample attaches before the moves start
            for i in range(200):
                app.action("focusNextPane")
            sampler.wait(30)
            print(f"  pane focus sample: {out}", flush=True)

    def new_workspaces(self, scenario="new_workspaces"):
        app, creates = self.app, 50
        before = set(app.workspace_ids())
        app.rpc("debug.frames", {"action": "start"})
        app.rpc("debug.new_workspace", {"action": "start"})
        counts, replies = [], []
        for _ in range(creates):
            counts.append(len(app.workspace_ids()))
            start = time.monotonic()
            app.rpc("action.run", {"action": "newTab", "args": {}, "focus": True, "origin": "script"}, timeout=120)
            replies.append(round((time.monotonic() - start) * 1000, 1))
        app.settle()
        own = app.rpc("debug.new_workspace", {"action": "stop"}) or {}
        app.rpc("debug.frames", {"action": "stop"})
        # The later scenarios run with the workspaces they had before this one.
        for workspace in [w for w in app.workspace_ids() if w not in before]:
            app.action("closeWorkspace", {"confirm": True}, target=f"workspace:{workspace}")
        wait(lambda: len(app.workspace_ids()) <= len(before), 60)
        rows = [{k: round(v, 2) if isinstance(v, (int, float)) else v for k, v in row.items()} for row in own.get("creates") or []]
        report["phases"][scenario] = {"workspaces_before": counts, "reply_ms": replies, "creates": rows}
        if not self.timed_count(rows, creates, f"debug.new_workspace timed {{n}} of {creates} new workspace rows", scenario):
            return
        for row, count in zip(rows, counts):
            row["workspaces_before"] = count
        col = lambda name: sorted(row[name] for row in rows)
        p99 = lambda values: values[max(0, int(len(values) * 0.99) - 1)]
        applies, commits = col("apply_ms"), col("commit_ms")
        tail = [row["apply_ms"] for row in rows[-10:]]
        print(f"  new workspace row: press to drawn p50 {applies[creates // 2]:.2f} / p99 {p99(applies):.2f} ms "
              f"(last 10, at {counts[-10]}-{counts[-1]} workspaces: mean {sum(tail) / len(tail):.2f} ms), commit p99 "
              f"{p99(commits):.2f} ms; reply p50 {sorted(replies)[creates // 2]:.1f} ms (daemon confirm included)", flush=True)
        walked = [(row["workspaces_before"], int(row.get("walks", -1))) for row in rows if row.get("walks", -1) != 0]
        check(not walked, f"every new workspace row is drawn from the press with no rows walk of every workspace before it "
                          f"({len(walked)} walked" + (f": {walked[:8]} (workspaces before, walks)" if walked else "") + ")", scenario)
        if p99(applies) > NEW_ROW_BUDGET_MS:
            warn(f"new workspace row press to drawn p99 {p99(applies):.2f} ms (over {NEW_ROW_BUDGET_MS:.1f} ms)", scenario)
        if self.frames_ok(scenario):
            late = [row for row in rows if row["late_vsyncs"] > 0]
            if self.full and not late:
                self.ratchet(scenario, {"late_rows": 0}, {"late_rows": 0})
            # A known count of late rows (KNOWN) is a warning naming its bead; more is a failure.
            check(not late or not self.unknown([("late_rows", len(late), 0)], scenario),
                  f"every new workspace row commits in the first frame after it is drawn ({len(late)} later"
                  + (f": {[(r['workspaces_before'], round(r['apply_ms'], 1), int(r['late_vsyncs'])) for r in late][:6]} "
                     "(workspaces before, apply ms, frames missed)" if late else "") + ")", scenario)

    def split(self, scenario="split"):
        app = self.app
        panes, _ = getattr(self, "grid", None) or self.build_grid()
        pairs = 10
        app.quiet_counters()
        landed = 0
        for _ in range(pairs):
            before = app.panes()[0]
            app.action("splitRight", {})
            split = wait(lambda: app.panes()[0] > before, 30)
            app.action("closePane", {})
            closed = wait(lambda: app.panes()[0] <= before, 30)
            landed += bool(split and closed)
        measured = app.quiet_counters()
        if not check(landed == pairs and app.panes()[0] == panes,
                     f"{landed} of {pairs} split+close pairs landed ({app.panes()[0]} panes after, {panes} before)", scenario):
            return
        per_pair = {k: round(measured.get(k, 0) / pairs, 2) for k in BUDGET["split"]}
        report["phases"][scenario] = {"pairs": pairs, "per_pair": per_pair, "sources": measured["sources"]}
        breaches = over(measured, BUDGET["split"], pairs)
        check(not breaches, f"{pairs} split+close pairs at {panes} panes: per pair {per_pair} (budget {BUDGET['split']})"
                            + (f"; {breach_text(breaches, measured['sources'])}" if breaches else ""), scenario)

    def relaunch(self):
        """tabs and split again after a relaunch on the same tag, in the grid the app restored."""
        app = self.app
        if not getattr(self, "grid", None):
            self.build_grid()
        grid, workspace = self.grid, self.grid_workspace
        app.quiet_counters()  # the grid's last tab creations end before the quit
        pages = self.page_tabs()
        app.relaunch()  # a new process: its counters start at 0, so the window below is the whole restore
        app.action("goToWorkspace", {"workspace": workspace})
        shown = wait(lambda: app.shown_workspace() == workspace and (lambda p: p[0] >= grid[0] and p[1] >= grid[1])(app.panes()), 60)
        if not check(bool(shown), f"the relaunched app restores the grid ({app.panes()} panes and tabs, before {grid})", "relaunch"):
            return
        # The state under test: the grid's New Tab pages came back (most of them hidden, not shown yet).
        restored = pages & self.page_tabs()
        if not check(len(restored) >= grid[0] * 2 and restored == pages,
                     f"the relaunch restores the grid's {len(pages)} New Tab pages ({len(restored)} came back)", "relaunch"):
            return
        # The restore's own work ends before the measured phases: every terminal of the grid runs
        # again (live, with a terminal id), the tab lists stop changing, and the counters stop moving
        # for 3 reads in a row. Its cost is the restore's (a bead of its own), not the phases'.
        start, last, still = time.monotonic(), None, 0
        while time.monotonic() - start < 60:  # bounded: the restored grid settles
            now = (self.grid_tabs(), {k: app.counters(reset=False).get(k) for k in App.QUIET_KEYS})
            live = all(not tab["dead"] and tab["terminal"] for pane in now[0] for tab in pane if tab["kind"] == "terminal")
            still = still + 1 if live and now == last else 0
            if still >= 3:
                break
            last = now
            time.sleep(1.0)  # test script: the gap between two reads while the restore settles
        settled = round(time.monotonic() - start, 1)
        measured = app.counters()
        report["phases"]["relaunch"] = {"settle_s": settled, "settled": still >= 3,
                                        "counters": {k: v for k, v in measured.items() if k != "sources"},
                                        "sources": measured["sources"]}
        if still < 3:
            warn(f"the restored grid did not settle in 60 s (terminals live, tabs and counters still)", "relaunch")
        # Per pane: the budget and its KNOWN line are per restored pane.
        per_pane = {k: round(measured.get(k, 0) / grid[0], 2) for k in BUDGET["restore"]}
        breaches = self.unknown(over(per_pane, BUDGET["restore"]), "relaunch")
        if self.full and still >= 3 and not any(f.startswith("[relaunch]") for f in failures):
            self.ratchet("relaunch", per_pane, BUDGET["restore"])
        check(not breaches, f"the restore of {grid[0]} panes settled in {settled} s: {measured.get('pane_snapshots', 0)} pane snapshots, per pane {per_pane}"
                            f" (budget {BUDGET['restore']} per pane)" + (f"; {breach_text(breaches, measured['sources'])}" if breaches else ""),
              "relaunch")
        self.tabs("relaunch tabs")
        self.split("relaunch split")

    def grid_tabs(self):
        """The shown workspace's tabs per pane: id, kind, dead, terminal id (in order)."""
        topo = self.app.topology()
        focus = (topo.get("focus") or {}).get("workspace")
        return [[{"id": tab.get("id"), "kind": tab.get("kind"), "dead": bool(tab.get("dead")),
                  "terminal": tab.get("terminal")} for tab in pane.get("tabs") or []]
                for workspace in topo.get("workspaces") or [] if workspace.get("id") == focus
                for screen in workspace.get("screens") or [] for pane in screen.get("panes") or []]

    def page_tabs(self):
        """Tab ids of the shown workspace that are not terminals (the grid's New Tab pages)."""
        topo = self.app.topology()
        focus = (topo.get("focus") or {}).get("workspace")
        return {tab.get("id") for workspace in topo.get("workspaces") or [] if workspace.get("id") == focus
                for screen in workspace.get("screens") or [] for pane in screen.get("panes") or []
                for tab in pane.get("tabs") or [] if tab.get("kind") != "terminal" and tab.get("id")}

    def activation(self):
        spec = importlib.util.spec_from_file_location("activation_perf", os.path.join(HERE, "activation-perf.py"))
        bench = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(bench)
        opts = argparse.Namespace(workspaces=150, browser=100, hibernate=50, chats=100, cycles=20,
                                  max_resyncs=ACTIVATION_MAX_RESYNCS, sample=False, out=self.app.out)
        result = bench.run(self.app, opts)
        heavy = result["heavy"]
        report["phases"]["activation"] = {k: result[k] for k in ("light", "session", "heavy_app_only", "heavy")}
        size = result["session"]
        check(not result["failures"], f"activation at {size['workspaces']} workspaces, {size['chromium_tabs']} Chromium "
              f"({size['hibernated']} hibernated), {size['chat_tabs']} chat tabs: worst {heavy['resyncs']['max']} indicators "
              f"re-checked (budget {ACTIVATION_MAX_RESYNCS})", "activation")
        p95 = heavy["observers_ms"]["p95"]
        if p95 is not None and p95 > ACTIVATION_BUDGET_MS:
            warn(f"activation notices p95 {p95} ms (over {ACTIVATION_BUDGET_MS} ms; light session "
                 f"{result['light']['observers_ms']['p95']} ms)", "activation")

    def status(self):
        app = self.app
        if not getattr(self, "grid", None):
            self.build_grid()
        shown = app.shown_workspace()
        loop = ("while :; do for p in 5 15 25 35 45 55 65 75 85 95; do "
                "printf '\\033]7501;state=working:progress=%d\\033\\\\' $p; sleep 0.25; done; done")
        tickers, seconds = 4, 5.0
        for i in range(tickers):
            app.cli("workspace", "create", "--name", f"perf tick {i}", "--shell", loop)
        if app.shown_workspace() != shown:
            app.action("goToWorkspace", {"workspace": shown})
        time.sleep(2.0)  # test script: the tickers start printing before the measured window
        app.quiet_counters()
        time.sleep(seconds)  # test script: the measured window while the tickers print
        measured = app.counters()
        ticks = int(seconds * 4 * tickers)
        report["phases"]["status"] = {"ticks": ticks, "counters": {k: v for k, v in measured.items() if k != "sources"},
                                      "sources": measured["sources"]}
        check(not over(measured, BUDGET["status"]),
              f"{ticks} status ticks: {breach_text(over(measured, BUDGET['status']), measured['sources']) or 'all 0'}"
              f" (budget {BUDGET['status']})", "status")
        check(measured.get("row_patches", 0) > 0, f"the ticks reach the sidebar as row patches ({measured.get('row_patches', 0)})",
              "status")


def cols(value):
    try:
        return int(str(value).split("x")[0])
    except ValueError:
        return 0


def summary(out):
    verdict = "FAIL" if failures else "PASS"
    if report.get("frames_skipped"):
        verdict += f" (frames skipped: {', '.join(report['frames_skipped'])})"
    lines = ["### cmux-next perf gate (I8)", "", f"{verdict}: {len(report['checks'])} checks, "
             f"{len(failures)} failed, {len(warnings)} warnings", ""]
    lines += [f"- FAIL {f}" for f in failures] + [f"- warning {w}" for w in warnings]
    lines += ["", f"Report: `{out}`"]
    text = "\n".join(lines) + "\n"
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write(text)
    print(text, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app", help="a Debug `cmux DEV <tag>.app` (not running)")
    parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or "/tmp/cmux-next-perf-gate")
    parser.add_argument("--frames", choices=["auto", "required"], default="auto",
                        help="auto: skip the frame-dependent checks (warning) when the window draws no frames")
    parser.add_argument("--only", help=f"comma list of scenarios ({','.join(SCENARIOS)})")
    parser.add_argument("--lag", type=int, default=3, help="drag steps the rendered grid may trail the fitted grid")
    parser.add_argument("--source-guard-only", action="store_true")
    parser.add_argument("--hang-ms", type=int, help="sample main-thread stalls over N ms (debug.hangs) and print them")
    opts = parser.parse_args()
    os.makedirs(opts.out, exist_ok=True)
    out = os.path.join(opts.out, "perf-gate.json")
    source_guard()
    if not opts.source_guard_only:
        if not opts.app:
            parser.error("--app is required (or --source-guard-only)")
        asked = opts.only.split(",") if opts.only else SCENARIOS
        unknown = [n for n in asked if n not in SCENARIOS]
        if unknown:
            parser.error(f"unknown scenarios {unknown}")
        names = [n for n in SCENARIOS if n in asked]  # the fixed order: status last (its tickers keep printing)
        if opts.hang_ms:
            os.environ["PERF_GATE_HANG_MS"] = str(opts.hang_ms)
        app = App(os.path.abspath(opts.app), opts.out)
        report.update({"app": app.bundle, "tag": app.tag, "budget": BUDGET, "host": os.uname().nodename})
        gate = Gate(app, opts)
        try:
            try:
                app.launch()
                for name in names:
                    print(f"== {name}", flush=True)
                    start = time.monotonic()
                    try:
                        getattr(gate, name)()
                    except Exception as error:  # noqa: BLE001 - a crashed scenario is a failure; the next one still runs
                        check(False, f"the scenario crashed: {error!r}", name)
                    report.setdefault("seconds", {})[name] = round(time.monotonic() - start, 1)
            except SystemExit as error:
                if isinstance(error.code, int) and error.code >= 128:
                    check(False, f"stopped by signal {error.code - 128}", "signal")
                    raise
                check(False, f"stopped: {error}", "launch")
            finally:
                app.stop()
        finally:
            write_report(out)
    else:
        write_report(out)
    sys.exit(1 if failures else 0)


def write_report(out):
    report.update({"ok": not failures, "failures": failures, "warnings": warnings})
    with open(out, "w") as f:
        json.dump(report, f, indent=1)
    summary(out)


if __name__ == "__main__":
    main()
