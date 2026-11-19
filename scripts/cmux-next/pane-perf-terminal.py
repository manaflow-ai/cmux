#!/usr/bin/env python3
"""Pane layout motion, measured in a real window (panes-perf, Lawrence 2026-10-21: "work purely on the panes
bonsplit + columns performance thing + animations").

Launches a tagged cmux-next app (scratch config, empty Ghostty config). For each --layouts entry (COLSxROWS
terminals, each fed --scrollback lines, optionally streaming) it times every pane action as one gesture until
the panes rest:

  split       Cmd-D on the focused pane (splitRight)
  close       closing the pane that split made (closePane)
  column      New Column (newColumn), then its close (column-close)
  zoom        Cmd-Shift-Enter (toggleSplitZoom) and back (unzoom)
  window      Window > Zoom (the titlebar double-click's resize path) and back (window-unzoom)
  drag        the first vertical divider pressed and dragged 120 pt out and back, one event per 120 Hz frame
              (not applicable to a one-column layout, 1xN: it has no vertical divider; no rows then)
  keys        a held key resize: resizePaneRight pressed 4 times at key-repeat pace (33 ms), then resizePaneLeft
              4 times (Ctrl-Cmd-Right / Left by default, through the action path, which takes the key-resize hold); 4 steps
              of 5% each way stay inside the pane minimums, so the split ends where it started
  scroll      (--browser) the page scrolled 1500 px down and back over about 1 s, one step per page animation frame
  idle        nothing for 1 s: with --browser the page keeps animating, so this is the Chromium pump at rest
  page        a browser page opening on the right (splitBrowserRight, Leo's "opening up a new thing on the
              right"), then its close (page-close)

The bench app activates and its window is key, as for a person: CMUX_NEXT_NO_ACTIVATE is removed from the bench
environment, and once the app that the bench started answers, the bench opens its bundle through LaunchServices
(`open`, which brings that running app to the front and starts no second copy, as a Dock click,
close-flash-bench.py and the film kits' `capture-host launch --activate` do), because macOS does not let an app
that a script started take the front from the app in front. Each layout reads whether the window really is key (`debug.window_list`)
when it starts: a layout measured with a window that is not key is named `<layout>-inactive` (rows
`panes.<action>.<layout>-inactive.*`), so it is never compared with rows of a key window. The window goes on the
main screen at the STRESS size (perf-stress-session.py `place_window`). A layout asked for and not measured (a
STRESS shape refused, a Chromium page that never ran) fails the run, --gate or not.

Per action: display frame intervals p50/p95/p99/max and missed frames (`debug.frames`), the layout's main-thread
work per frame (`debug.motion` clock), each Core Animation commit (`debug.motion` work `ca.commit`: with Chromium
pages it holds the resize wait of fork API 27), frames the springs moved (`moving_frames`: a pane or divider
spring, or the strip camera: New Column moves only the camera), frames a commit motion had a pane in flight
(`commit_frames`: the `layout.commit` samples; 0 on a build without them), grids sent to the PTY owner
(`debug.window_transition`) and hangs (`debug.hangs`). With --record, a second pass records each action with
`debug.window_record` (frames/ in --out; the recording itself costs frames, so it never runs in the timed pass).
The window action also samples its size once per display frame (`debug.motion trace_*`), reports the active
resize's p95/max interval, missed intervals and largest geometry step, and rejects a snap, a no-op or a failed restore even without
--gate. Run this script from the candidate checkout against both the base and candidate app for an A/B.

`missed` is the probe's count of long intervals (each interval above 1.5 refreshes counts one time, however long it
is). Beside it each action keeps `missed_refreshes` (the refreshes those intervals skipped, summed), the probe's
`missed_at_ms`, `missed_split` (main_late, commit_late, presented_late), `main_max_ms` and `missed_frames`: each
long interval with its cause, the refreshes it skipped and `after_action_ms` (when its frame ticked, after the
action was sent; below 0 is the action's own frame). See `late_frames`.

With --pane-motion on,off each round runs its actions one time for each arm, in the same app and layout
(`ui.paneAnimations`, set with `debug.motion` kind): the off arm's rows and summary are named <layout>-motion-off,
and its row `still` passes when no spring and no commit motion moved. Without the option the app's own setting
runs one time and each row keeps its name.

With --window-look see-through the window is a see-through window with a blur instead of the launch's opaque one. The
look is written both ways the app reads it: `appearance.backgroundOpacity` and `appearance.backgroundBlur` in the app
config, and `background-opacity` and `background-blur` (a radius) in the terminal config file. `see-through` alone
takes round values (0.8, frosted, 0.8, 20); each value is an argument (`see-through:opacity=0.5,blur=glass,
terminal-opacity=0.5,terminal-blur=8`; `unset` leaves a key out). The window is over the fixture's desktop, or with
`behind=checker` (or `stripes`) over the app's own patterned panel (`debug.capture_backdrop`). Each row and summary of
such a run is named <layout>-see-through-<opacity>-<blur>-<terminal opacity>-<terminal blur>, so it is never compared
with an opaque window's rows, and the report's conditions hold the look (`window_look`). Without the option, or with
`opaque`, the launch and each row's name stay as they were.

With --browser-engine webkit the probe page and the --pages pages are WebKit pages instead (no `debug.cef` counters
change then; Lawrence 2026-11-05: "resize webviews (both chrome and webkit) more often").

With --browser the top-left pane of each layout shows a Chromium page instead of a fed terminal (a local probe: a
requestAnimationFrame loop counting into window.__frames, a spinner, a tall grid of cards; the first split terminal
takes --stream), and each action pair starts with that pane focused. Per action it adds the change of `debug.cef`'s
pump counters (pump_runs, pump_ms, pump_long, pump_now_req, pump_delayed_req), its tracker counters (trk_clip_reads,
trk_occl_reads, trk_clip_builds, trk_clip_hits, trk_clip_ms, trk_posts, trk_skips; None on builds without them), of the page's own animation
frames (page_frames), of `debug.layers` divider catcher panel updates and child window reorders (catcher_updates, reorders), and
the fork geometry posts per moving frame (posts_per_frame). A layout whose page never runs fails one row and is skipped.

Usage: pane-perf-terminal.py --tag <tag> --app PATH [--layouts 1x2,4x2,6x5] [--browser]
       [--browser-engine chromium|webkit]
       [--actions split,close,column,zoom,window,drag,keys,scroll,idle,page] [--rounds 3] [--scrollback 5000] [--stream]
       [--record] [--json PATH] [--out DIR] [--gate] [--missed-budget N] [--pane-motion on,off]
       [--window-look opaque|see-through[:KEY=VALUE,...]]
"""
import argparse, glob, json, math, os, pathlib, signal, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--layouts", default="1x2,4x2,6x5",
                    help="COLSxROWS terminal grids, and `stress`: the STRESS session (perf-stress-session.py)")
parser.add_argument("--stress-selected", default="terminal", choices=["terminal", "chromium"],
                    help="layout `stress`: what each pane of the measured workspace shows")
parser.add_argument("--actions", default="split,close,column,zoom,drag")
parser.add_argument("--rounds", type=int, default=3)
parser.add_argument("--scrollback", type=int, default=5000)
parser.add_argument("--stream", action="store_true", help="keep output streaming in the first terminal")
parser.add_argument("--record", action="store_true", help="record each action once (a separate, untimed pass)")
parser.add_argument("--browser", action="store_true", help="the top-left pane shows a Chromium page (pump and tracker counters)")
parser.add_argument("--browser-engine", default="chromium", choices=["chromium", "webkit"],
                    help="with --browser: the engine of the probe page and the --pages pages")
parser.add_argument("--sample", default="", help="LAYOUT:ACTION[,...]: `sample` the app while it repeats ACTION")
parser.add_argument("--sample-repeats", type=int, default=8)
parser.add_argument("--content", default="terminal", choices=["terminal", "chromium"],
                    help="what the workspace's first pane shows: a terminal, or a Chromium page (splits start from it)")
parser.add_argument("--pages", type=int, default=0,
                    help="with --browser: this many more panes of each layout (the first ones split) show a Chromium page "
                         "(a static page beside the probe: every page the window holds is re-placed on a motion frame)")
parser.add_argument("--json")
parser.add_argument("--out", default="/tmp")
parser.add_argument("--gate", action="store_true", help="fail on the budget rows")
parser.add_argument("--missed-budget", type=int, default=0)
parser.add_argument("--pane-motion", default=None,
                    help="on, off or on,off: each round runs its actions one time for each arm, in the same app and layout "
                         "(`debug.motion` kind paneAnimations); the off arm's rows are named <layout>-motion-off. "
                         "hide-first is a third arm on a measure branch's build (motion_arms)")
parser.add_argument("--stall-ms", type=int, default=None,
                    help="start the app with its main-thread watchdog at this threshold (CMUX_NEXT_HANG_THRESHOLD_MS, 4 "
                         "at the least): each row then lists the stalls of its action with the stack sampled in each")
parser.add_argument("--window-look", default=None,
                    help="opaque (the default: the launch as it was) or see-through[:opacity=0..1,"
                         "blur=frosted|glass|glass-clear|none,terminal-opacity=0..1,terminal-blur=RADIUS,"
                         "behind=desktop|checker|stripes]: a see-through window with a blur, set in the app config and "
                         "in the terminal config file; its rows are named <layout>-see-through-<each value>")
opts, _unknown = parser.parse_known_args()
TAG, APP = opts.tag, os.path.abspath(opts.app.rstrip("/"))
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_launch import BenchApp, LaunchError  # noqa: E402  the shared GUI launch (session check, failure report)
import bench_background  # noqa: E402  background daemon CPU per round (a reader drops a round over its limit)


def load_stress():
    """perf-stress-session.py as a module: the STRESS builder and the shared window placement."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("perf_stress_session", os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                                                   "perf-stress-session.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


STRESS_MODULE = load_stress()
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ci", "frame-pacing"))
from golden import THRESHOLDS as MOTION_THRESHOLDS, motion as frame_motion, percentile  # noqa: E402  the shared display-frame analysis
# 30 panes in 6 columns leave ~230 pt each: the 200 pt default minimum refused the timed split there
# ("not enough room to split this pane"), so the 30-pane split row measured nothing.
CONFIG = {"layout": {"minimumPaneWidth": 80, "minimumPaneHeight": 32}}
WINDOW = STRESS_MODULE.WINDOW_SIZE  # every layout's window: the STRESS size, placed by `place_window`
PAGE = None  # a local page for a Chromium pane (`serve_page`)


def serve_page():
    """Serves one page with text and layout on 127.0.0.1 for the Chromium pane; returns its URL."""
    import http.server, threading
    body = ("<!doctype html><title>pane</title><h1>pane</h1>" + "<p>" + "lorem ipsum dolor sit amet " * 600 + "</p>").encode()

    class Page(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{server.server_address[1]}/"
ROWS, LAUNCHED = [], []
BENCH = None  # the BenchApp of this run
MEASURED = False  # the app came up and the layouts ran: without it the run fails, --gate or not
UNMEASURED = []  # layouts asked for and not measured: any fails the run, --gate or not
PROBE = {}  # --browser: the probe page's tab id
app = None
PROBE_PAGE = """<!doctype html><meta charset="utf-8"><title>Pane probe</title>
<style>
html,body{margin:0;background:#0b5d3b;color:#fff;font:600 18px -apple-system,sans-serif}
header{position:sticky;top:0;display:flex;align-items:center;gap:12px;height:64px;padding:0 20px;background:#08402a}
#spin{width:24px;height:24px;border-radius:6px;background:#fff}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:12px;padding:20px}
.grid div{height:96px;border-radius:12px;background:#15895a}
</style>
<header><i id="spin"></i><span>Pane probe</span></header>
<div class="grid">""" + "<div></div>" * 240 + """</div>
<script>
window.__frames = 0;
const spin = document.getElementById('spin');
requestAnimationFrame(function frame() {
  window.__frames++;
  spin.style.transform = 'rotate(' + (window.__frames * 6 % 360) + 'deg)';
  requestAnimationFrame(frame);
});
</script>
"""
# 1500 px down and back over about 1 s, one step per page animation frame; returns at once (the measure covers it).
SCROLL_SCRIPT = """(() => { const start = performance.now(); let at = 0;
  requestAnimationFrame(function step(now) {
    const t = Math.max(0, Math.min(1, (now - start) / 1000)), to = Math.round(1500 * (1 - Math.abs(1 - 2 * t)));
    window.scrollBy(0, to - at); at = to;
    if (t < 1) requestAnimationFrame(step);
  });
  return true; })()"""
# --browser: per action, the change of each `debug.cef` counter (result key, object, counter), then the page's frames.
CEF_DELTAS = [("pump_runs", "pump", "work_runs"), ("pump_ms", "pump", "work_ms"), ("pump_long", "pump", "long_work_runs"),
              ("pump_now_req", "pump", "immediate_requests"), ("pump_delayed_req", "pump", "delayed_requests"),
              ("trk_clip_reads", "tracker", "clip_reads"), ("trk_occl_reads", "tracker", "occlusion_reads"),
              ("trk_clip_builds", "tracker", "clip_builds"), ("trk_clip_hits", "tracker", "clip_hits"),
              ("trk_clip_ms", "tracker", "clip_ms"),
              ("trk_posts", "tracker", "geometry_posts"), ("trk_skips", "tracker", "geometry_skips")]
# --browser: per action, the change of `debug.layers` counters of the first window (divider catcher panel moves, child
# window reorders); None on builds without them.
LAYER_DELTAS = [("catcher_updates", "divider_catcher_updates"), ("reorders", "reorders")]
BROWSER_KEYS = [key for key, _, _ in CEF_DELTAS] + ["page_frames"] + [key for key, _ in LAYER_DELTAS] + ["posts_per_frame"]
BROWSER_HEADS = ["pump", "pumpms", "long", "nowreq", "dlyreq", "clipr", "occlr", "clipb", "cliph", "clipms", "posts", "skips",
                 "rAF", "catch", "reord", "post/f"]
WINDOW_ACTIONS = ("window-zoom", "window-unzoom")
STILL = ("drag", "scroll", "idle", *WINDOW_ACTIONS)  # actions that move no layout spring
WINDOW_RESTORE = None  # before each window-zoom, checked after its paired window-unzoom
# Window geometry is sampled from the native display-link trace and cross-checked against the
# action's display-frame probe. Keep this acceptance local to the window rows: other action rows
# retain their existing informational missed-frame semantics. The 15% tolerance matches the
# virtual-display readiness check in split-spring.sh; this proves native geometry pacing, not the
# final composited pixels or absence of a tear (the separate recording/readback remains required).
WINDOW_TARGET_HZ = 120.0
WINDOW_REFRESH_TOLERANCE = 0.15
WINDOW_MAX_STEP = MOTION_THRESHOLDS["window_resize"]["max_step"]
WINDOW_MIN_INTERMEDIATE = MOTION_THRESHOLDS["window_resize"]["min_intermediate"]


def finite_nonnegative(value):
    """Whether a native counter or interval is a real, non-negative number."""
    return (isinstance(value, (int, float)) and not isinstance(value, bool)
            and math.isfinite(value) and value >= 0)


def rpc(method, params=None, timeout=30):
    import socket
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


def action(name, args=None, settle=0.0, timeout=60, focus=True):
    reply = rpc("action.run", {"action": name, "args": args or {}, "focus": focus, "origin": "script"}, timeout=timeout)
    if settle:
        time.sleep(settle)  # test harness: the layout settles before the next step
    return reply


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


def row(check, expected, observed, ok):
    ROWS.append((check, expected, observed, ok))
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


def feed(stream=False):
    text = f"seq 1 {opts.scrollback}\r" if opts.scrollback else ""
    if stream:
        text += "while :; do echo \"$RANDOM $RANDOM $RANDOM streaming output line\"; sleep 0.004; done\r"
    if text:
        action("terminal.sendText", {"text": text})


def page_eval(script):
    """The probe page's value of `script`, None when it did not run."""
    reply = rpc("browser.page.eval", {"script": script, "tab": PROBE["tab"]}, timeout=20) if PROBE.get("tab") else None
    return reply.get("value") if isinstance(reply, dict) and "error" not in reply else None


def open_page():
    """The probe page in a new Chromium tab of the focused pane: a script's openBrowser opens there, selected and
    focused (TabLifecycle.newBrowser, PaneController.newBrowserTab). Returns an error, or None once its loop runs."""
    PROBE.clear()
    path = os.path.join(opts.out, "pane-perf-probe.html")
    open(path, "w").write(PROBE_PAGE)
    # The URL goes under `args` (a top-level `url` opens the New Tab page).
    verb = f"openBrowser.{opts.browser_engine}"
    opened = action(verb, {"url": pathlib.Path(path).resolve().as_uri()}, timeout=120)  # --out may be relative
    if isinstance(opened, dict) and opened.get("error"):
        return f"{verb} refused: {opened['error']}"

    def ready():  # the focused tab: the page's once it lands
        reply = rpc("browser.page.eval", {"script": "document.readyState === 'complete' && window.__frames > 2"}, timeout=20)
        if isinstance(reply, dict) and reply.get("value") is True and reply.get("tab"):
            PROBE["tab"] = reply["tab"]
            return True
        return None
    if not wait(ready, 60, step=0.5):
        cef = rpc("debug.cef")
        cef = cef if isinstance(cef, dict) else {}
        return (f"the probe page never ran in a {opts.browser_engine} tab within 60 s ({verb} {json.dumps(opened)[:160]}; "
                f"debug.cef state {cef.get('state')} unavailable {json.dumps(cef.get('unavailable'))[:160]})")
    time.sleep(1.0)  # test harness: the page's first paints settle
    return None


def focus_page():
    """Focuses the probe page's tab, so the next action acts on its (the Chromium) pane."""
    if PROBE.get("tab"):
        rpc("action.run", {"action": "tab.focus", "target": f"tab:{PROBE['tab']}", "focus": True, "origin": "script"})
        time.sleep(0.3)  # test harness: focus lands before the timed action


def layout(columns, rows):
    """A fresh workspace of columns x rows terminals, each fed; ends focused on the top-left one. With --browser the
    top-left one shows the probe page instead (the first split terminal takes --stream). Returns an error or None."""
    action("workspace.newAtBottom", settle=1.5)
    pending = [opts.stream]  # the first terminal fed streams
    pages = [opts.pages if opts.browser else 0]

    def fed():
        if pages[0] > 0:  # --pages: this pane shows a Chromium page instead of a terminal
            pages[0] -= 1
            global PAGE
            PAGE = PAGE or serve_page()
            action(f"openBrowser.{opts.browser_engine}", {"url": PAGE}, settle=1.5, timeout=120)
            return
        feed(pending.pop() if pending else False)
    if opts.browser:
        problem = open_page()
        if problem:
            return problem
    else:
        fed()
    if opts.content == "chromium":
        global PAGE
        PAGE = PAGE or serve_page()
        reply = action("openBrowser", {"url": PAGE, "engine": "chromium"}, settle=3.0)
        print(f"  (chromium pane: {reply})", flush=True)
    for _ in range(columns - 1):
        action("splitRight", settle=0.6)
        fed()
    for column in range(columns):
        for _ in range(rows - 1):
            action("splitDown", settle=0.6)
            fed()
        for _ in range(rows - 1):
            action("focusUp", settle=0.2)
        if column < columns - 1:
            action("focusLeft", settle=0.2)
    action("equalizeSplits", settle=0.8)
    for _ in range(columns):
        action("focusLeft", settle=0.15)
    focus_page()
    time.sleep(1.5 if opts.scrollback else 0.5)  # test harness: seq fills the scrollback
    return None


STRESS = {}  # layout `stress`: the session's summary (perf-stress-session.py)


def stress_layout():
    """The STRESS session (perf-stress-session.py), ending on its measured workspace's top-left pane."""
    module = STRESS_MODULE
    builder = module.Stress(rpc, selected=opts.stress_selected)
    try:
        STRESS.update(builder.build())
    except module.StressShapeError as error:
        return str(error)  # a wrong shape is a failed row, never measured as STRESS
    finally:
        STRESS["chat_fallbacks"] = builder.chat_fallbacks
    print("STRESS-SESSION " + json.dumps(STRESS), flush=True)
    return None


def window_state():
    """Whether the app is active with its window key now (`debug.window_list`: a main window's `key`; a key
    window means an active app), and the frontmost app."""
    reply = rpc("debug.window_list")
    windows = (reply or {}).get("windows") if isinstance(reply, dict) else None
    key = any(w.get("key") for w in windows if w.get("kind") == "main" and w.get("visible")) if isinstance(windows, list) else None
    return {"window_key": key, "frontmost": frontmost_app()}


def vertical_divider():
    """The leftmost vertical divider's middle, in the window's top-left points."""
    result = rpc("debug.layers")
    window = ((result or {}).get("windows") or [{}])[0] if isinstance(result, dict) else {}
    height = (window.get("frame") or [0, 0, 0, WINDOW[1]])[3]
    areas = sorted((x + w / 2, height - (y + h / 2)) for x, y, w, h in window.get("divider_areas_in_window") or [] if h > w)
    return areas[0] if areas else None


def drag_divider():
    point = vertical_divider()
    if not point:
        return "no vertical divider"
    x0, y0 = point
    rpc("debug.mouse", {"action": "down", "x": x0, "y": y0})
    x = x0
    path = [3.0] * 40 + [-3.0] * 40  # 120 pt out and back
    for delta in path:
        rpc("debug.mouse", {"action": "drag", "x": x, "y": y0, "to_x": x + delta, "to_y": y0, "steps": 1,
                            "press": False, "release": False})
        x += delta
        time.sleep(1 / 120)  # test harness: one pointer event per 120 Hz frame
    rpc("debug.mouse", {"action": "up", "x": x, "y": y0})
    return None


def key_resize():
    """A held resizePaneRight, then a held resizePaneLeft, on the focused pane: one press per key repeat (33 ms), 4 each
    way, so the split comes back to where it started for the next round."""
    for verb in ["resizePaneRight"] * 4 + ["resizePaneLeft"] * 4:
        reply = action(verb)
        if isinstance(reply, dict) and reply.get("error"):
            return f"{verb}: {reply['error']}"
        time.sleep(0.033)  # test harness: the system's key repeat interval
    return None


def perform(name):
    """Runs one action; returns an error string or None."""
    verbs = {"split": "splitRight", "split-down": "splitDown", "close": "closePane", "close-down": "closePane",
             "column": "newColumn", "column-close": "closePane", "zoom": "toggleSplitZoom", "unzoom": "toggleSplitZoom",
             "window-zoom": "zoomWindow", "window-unzoom": "zoomWindow",
             "page": "splitBrowserRight", "page-close": "closePane"}
    if name == "drag":
        return drag_divider()
    if name == "keys":
        return key_resize()
    if name == "idle":
        time.sleep(1.0)  # test harness: nothing happens but the page's own animation
        return None
    if name == "scroll":
        if not PROBE.get("tab"):
            return "scroll needs --browser"
        return None if page_eval(SCROLL_SCRIPT) is True else "the page did not start its scroll"
    reply = action(verbs[name], focus=True)
    return str(reply.get("error")) if isinstance(reply, dict) and reply.get("error") else None


def moving_frames(samples):
    """Display frames the layout moved: per frame a screen steps, its `layout.travel` sample (the points its pane and
    divider springs have left) and the `layout.camera` sample right after it (the strip camera's points left). New
    Column moves only the camera (a new column never resizes the columns there, column-scroll.md R3b), so a count of
    `layout.travel` alone read 0 for every New Column. A build without `layout.camera` counts the springs alone."""
    samples = samples if isinstance(samples, list) else []
    count = 0
    for index, sample in enumerate(samples):
        if not isinstance(sample, dict) or sample.get("name") != "layout.travel":
            continue
        after = samples[index + 1] if index + 1 < len(samples) else None
        camera = after.get("v") if isinstance(after, dict) and after.get("name") == "layout.camera" else 0
        if (sample.get("v") or 0) > 0 or (camera or 0) > 0:
            count += 1
    return count


def commit_frames(samples):
    """Display frames in which a commit motion had a pane in flight: the `layout.commit` samples above 0 (one for each
    tick of a move). A commit motion has no layout spring, so `moving_frames` reads 0 for it. A build without the
    sample gives 0."""
    samples = samples if isinstance(samples, list) else []
    return sum(1 for sample in samples
               if isinstance(sample, dict) and sample.get("name") == "layout.commit" and (sample.get("v") or 0) > 0)


def commit_notes(notes):
    """The app's own notes of a commit motion while recording (each note whose text starts with `layout.commit`): the
    act that moves, or why a change showed in one frame. A build without such a note gives an empty list."""
    notes = notes if isinstance(notes, list) else []
    return [note["text"] for note in notes
            if isinstance(note, dict) and isinstance(note.get("text"), str) and note["text"].startswith("layout.commit")]


def commit_placements(samples, notes):
    """Each `layout.commit` note with its time in its own tick: `after_tick_ms` = the note's `t_ms` less the `t_ms` of
    the last `clock.dt_ms` sample at or before it. The clock writes that sample at the start of a tick, and the app
    writes the note after the tick placed the panes, so this is the placement's main-thread time in the tick that
    shows the act. None when no tick sample is before the note. A note with no time is left out."""
    samples = samples if isinstance(samples, list) else []
    ticks = sorted(sample["t_ms"] for sample in samples if isinstance(sample, dict)
                   and sample.get("name") == "clock.dt_ms" and isinstance(sample.get("t_ms"), (int, float)))
    placed = []
    for note in notes if isinstance(notes, list) else []:
        if not (isinstance(note, dict) and isinstance(note.get("text"), str) and note["text"].startswith("layout.commit")
                and isinstance(note.get("t_ms"), (int, float))):
            continue
        before = [t for t in ticks if t <= note["t_ms"]]
        placed.append({"text": note["text"], "t_ms": note["t_ms"],
                       "after_tick_ms": round(note["t_ms"] - before[-1], 1) if before else None})
    return placed


def layout_spans(spans):
    """The app's measured parts of a pane change while recording: each span whose name starts with `layout.` (the
    placement, the show and the hide loops), as {name: count, sum_ms, max_ms, max_at_ms (when the longest one
    started, ms from the record's start)}. The span `layout` (a whole motion, to its rest) is not one of them. A
    build without such a span gives an empty dict."""
    parts = {}
    for span in spans if isinstance(spans, list) else []:
        if not (isinstance(span, dict) and str(span.get("name") or "").startswith("layout.")
                and isinstance(span.get("ms"), (int, float))):
            continue
        part = parts.setdefault(span["name"], {"count": 0, "sum_ms": 0.0, "max_ms": None, "max_at_ms": None})
        part["count"] += 1
        part["sum_ms"] = round(part["sum_ms"] + span["ms"], 2)
        if part["max_ms"] is None or span["ms"] > part["max_ms"]:
            part["max_ms"], part["max_at_ms"] = span["ms"], span.get("at_ms")
    return parts


def placed_at(placements):
    """When the record's first `layout.commit` note came (ms from the record's start): the placement in the tick that
    shows the act. None with no such note."""
    for place in placements if isinstance(placements, list) else []:
        if isinstance(place, dict) and isinstance(place.get("t_ms"), (int, float)):
            return place["t_ms"]
    return None


def part_times(parts, placements):
    """For each part of `layout_spans`: when its longest span started, in ms after the placement (`placed_at`). None
    for a part with no time, and for each part of a record with no placement."""
    start = placed_at(placements)
    return {name: round(facts["max_at_ms"] - start, 1)
            if start is not None and isinstance(facts.get("max_at_ms"), (int, float)) else None
            for name, facts in parts.items()}


def probe_notes(notes, placements):
    """The app's notes of a hide or a release while recording (each note whose text starts with `layout.hide` or
    `layout.release`), each with ` at +N ms`: its time after the placement (`placed_at`). A note with no time, or a
    record with no placement, gives the text alone."""
    start, found = placed_at(placements), []
    for note in notes if isinstance(notes, list) else []:
        if not (isinstance(note, dict) and isinstance(note.get("text"), str)
                and note["text"].startswith(("layout.hide", "layout.release"))):
            continue
        timed = start is not None and isinstance(note.get("t_ms"), (int, float))
        found.append(note["text"] + (f" at +{round(note['t_ms'] - start, 1)} ms" if timed else ""))
    return found


def record_offset(motion, action_s):
    """The start of a `debug.motion` record in ms after the action was sent (below 0: the record started before the
    send, as the bench's does): the reply's `started_s` and `action_s` are both the uptime clock, so `t_ms` and
    `at_ms` of the record plus this are on the clock of a late frame's `after_action_ms`. None on a build without the
    field, and for a start that is not in the 10 s around the send (another clock)."""
    started = motion.get("started_s") if isinstance(motion, dict) else None
    if not (isinstance(started, (int, float)) and isinstance(action_s, (int, float))):
        return None
    offset = (started - action_s) * 1000
    return round(offset, 1) if -10000 <= offset <= 10000 else None


def turn_notes(notes, offset):
    """The turn probe's notes (`turn: total=11.5 wake=0.1 ...`, one for each long turn of the main run loop, written at
    the turn's end), each as a dict of its numbers, with `start_after_action_ms` and `end_after_action_ms` (`offset`
    is `record_offset`; None without it or without the note's time). A word that is not `name=number` is left out."""
    turns = []
    for note in notes if isinstance(notes, list) else []:
        if not (isinstance(note, dict) and isinstance(note.get("text"), str) and note["text"].startswith("turn: ")):
            continue
        turn = {}
        for word in note["text"][len("turn: "):].split():
            key, _, value = word.partition("=")
            try:
                turn[key] = int(value) if value.lstrip("-").isdigit() else float(value)
            except ValueError:
                continue
        end, total = note.get("t_ms"), turn.get("total")
        timed = offset is not None and isinstance(end, (int, float)) and isinstance(total, (int, float))
        turn["start_after_action_ms"] = round(end + offset - total, 1) if timed else None
        turn["end_after_action_ms"] = round(end + offset, 1) if timed else None
        turns.append(turn)
    return turns


def stalls_in(hangs, action_s, keep=10):
    """The main thread's stalls of a `debug.hangs` reply (the watchdog's records; with `--stall-ms` the app runs with
    its threshold there): each with `ms`, `cpu_ms`, `after_action_ms` (its start: the record's `start_uptime_ns` and
    `action_s` are both the uptime clock; None without one of them), the watchdog's `verdict`, `called` (what the
    run loop called, from the innermost run loop frame of the stack: main queue, timer, observer, source0, source1 or
    block; None with no such frame) and `frames` (the first `keep` frames of the ONE stack that the watchdog sampled
    in the stall, the leaf first; empty with no sample). A record with no duration is left out."""
    # What the run loop called, by a part of the name of its frame in a sampled stack.
    calls = (("SERVICING_THE_MAIN_DISPATCH_QUEUE", "main queue"), ("TIMER_CALLBACK", "timer"), ("OBSERVER_CALLBACK", "observer"),
             ("SOURCE0_PERFORM", "source0"), ("SOURCE1_PERFORM", "source1"), ("CALLING_OUT_TO_A_BLOCK", "block"))
    found = []
    for record in (hangs.get("records") if isinstance(hangs, dict) else None) or []:
        if not (isinstance(record, dict) and isinstance(record.get("duration_ms"), (int, float))):
            continue
        frames = [str(frame) for frame in record.get("frames") or []]
        start, cpu = record.get("start_uptime_ns"), record.get("cpu_ms")
        timed = isinstance(start, (int, float)) and isinstance(action_s, (int, float))
        found.append({"ms": round(record["duration_ms"], 1), "cpu_ms": round(cpu, 1) if isinstance(cpu, (int, float)) else None,
                      "after_action_ms": round(start / 1e6 - action_s * 1000, 1) if timed else None,
                      "verdict": record.get("verdict"),
                      "called": next((name for frame in frames for mark, name in calls if mark in frame), None),
                      "frames": frames[:keep]})
    return found


def turn_text(turn):
    """One long turn of `turn_notes` as a row's text: its length, its start, its parts and its layout counts."""
    parts = " + ".join(f"{name.replace('_', ' ')} {turn.get(name)}" for name in ("wake", "passes", "events", "before_commit", "commit", "after_commit"))
    return (f"{turn.get('total')} ms from {turn.get('start_after_action_ms')} ms after the action = {parts}; "
            f"{turn.get('pass_count')} passes, {turn.get('view_layouts')} view layouts ({turn.get('before_commit_view_layouts')} before "
            f"the commit) in {turn.get('window_layouts')} window passes")


def stall_text(stall, frames=6, width=90):
    """One stall of `stalls_in` as a row's text: its length, its CPU time, its start, the verdict, what the run loop
    called, and the first `frames` frames of its stack (each cut to `width` characters)."""
    stack = " < ".join(frame[:width] for frame in stall["frames"][:frames]) or "no stack sample"
    return (f"{stall['ms']} ms (cpu {stall['cpu_ms']}) from {stall['after_action_ms']} ms after the action, {stall['verdict']}, "
            f"the run loop called: {stall['called']}: {stack}")


def late_frames(frames, action_s=None):
    """Where the long intervals of a `debug.frames` reply are (stopped with `raw`). The probe's `missed` counts each
    interval above 1.5 refreshes one time, however long it is. `missed_refreshes` is the refreshes that those
    intervals skipped, summed (an interval of 6 refreshes skipped 5): from every interval when the reply has them,
    else from the kept stamps (`missed_frames`) when the probe kept each one, else None. Each kept stamp gets
    `refreshes` and `after_action_ms`: when its frame ticked, in ms after the action was sent (below 0: the long
    interval began before the send and holds it, the action's own frame). `action_at_ms` is the send, in ms after the
    probe's first frame; `action_s` and the reply's `first_frame_s` are both the uptime clock, and a send that is not
    in the 10 s after that frame is taken as another clock: no place then."""
    frames = frames if isinstance(frames, dict) else {}
    refresh = frames.get("refresh_ms")
    known = isinstance(refresh, (int, float)) and refresh > 0

    def skipped(interval):
        return max(1, round(interval / refresh) - 1)
    first = frames.get("first_frame_s")
    at = (action_s - first) * 1000 if isinstance(first, (int, float)) and isinstance(action_s, (int, float)) else None
    at = round(at, 1) if at is not None and -100 <= at <= 10000 else None
    stamps = [dict(miss) for miss in frames.get("missed_frames") or [] if isinstance(miss, dict)]
    for miss in stamps:
        interval, tick = miss.get("interval_ms"), miss.get("at_ms")
        miss["refreshes"] = skipped(interval) if known and isinstance(interval, (int, float)) else None
        miss["after_action_ms"] = round(tick - at, 1) if at is not None and isinstance(tick, (int, float)) else None
    intervals = frames.get("intervals_ms")
    if known and isinstance(intervals, list):
        total = sum(skipped(dt) for dt in intervals if isinstance(dt, (int, float)) and dt > refresh * 1.5)
    elif known and len(stamps) == (frames.get("missed") or 0):
        total = sum(miss["refreshes"] or 0 for miss in stamps)
    else:
        total = None
    return {"missed_refreshes": total, "missed_at_ms": frames.get("missed_at_ms"), "missed_split": frames.get("missed_split"),
            "missed_frames": stamps, "main_max_ms": frames.get("main_max_ms"), "action_at_ms": at}


def motion_arms(value):
    """`--pane-motion`: the arms to measure, each one time, in the option's order. No option is no arm: one pass with
    the app's own setting, and the rows keep their names. Another word than on or off raises ValueError."""
    if value is None:
        return []
    arms = [arm.strip() for arm in value.split(",")]
    # `hide-first` is the arm of a measure branch's switch: the motion is on, and its end hides the panes that the
    # change took out before it takes the moves off the layers (`debug.motion` kind probe.hideFirst).
    if not all(arm in ("on", "off", "hide-first") for arm in arms) or len(set(arms)) != len(arms):
        raise ValueError(f"--pane-motion takes on, off, hide-first or a list of them, not {value!r}")
    return arms


def arm_tag(label, arm):
    """The name of an arm's rows in a layout named `label`: the on arm (and no arm) keeps the layout's name."""
    return label if arm in (None, "on") else f"{label}-motion-{arm}"


def set_pane_motion(on, hide_first=False):
    """Sets `ui.paneAnimations` in the running app (`debug.motion` kind), and the measure branch's switch
    `probe.hideFirst` when the app has it (or when `hide_first` asks for it); returns an error string or None."""
    reply = rpc("debug.motion", {"action": "kind", "name": "paneAnimations", "value": on})
    seen = reply.get("pane_animations") if isinstance(reply, dict) else None
    if seen is not on:
        return f"pane_animations is {seen!r} after the call, not {on!r}"
    if not hide_first and "probe_hide_first" not in reply:
        return None  # a build without the switch
    reply = rpc("debug.motion", {"action": "kind", "name": "probe.hideFirst", "value": hide_first})
    seen = reply.get("probe_hide_first") if isinstance(reply, dict) else None
    return None if seen is hide_first else f"probe_hide_first is {seen!r} after the call, not {hide_first!r}"


def window_look(value):
    """`--window-look`: None for `opaque` (and for no option: the launch, the config and each row's name stay as they
    were), or the values of a see-through window with a blur. `see-through` alone takes round values; each value
    is an argument (`see-through:opacity=0.5,blur=glass,terminal-opacity=0.5,terminal-blur=8,behind=checker`), and
    `unset` leaves that key out. `opacity` and `blur` go to the app config (`appearance.backgroundOpacity`, 0 to 1,
    and `appearance.backgroundBlur`: frosted, glass, glass-clear or none); `terminal-opacity` and `terminal-blur` go
    to the terminal config file (`background-opacity`, and `background-blur`: a radius). `behind` is what the window
    is over: `desktop` (what the screen shows there), or the app's own `checker` or `stripes` panel. Another word, or
    a look that sets none of the 4 keys, raises ValueError."""
    if value is None or value == "opaque":
        return None
    word, colon, rest = value.partition(":")
    look = {"opacity": 0.8, "blur": "frosted", "terminal_opacity": 0.8, "terminal_blur": 20, "behind": "desktop"}
    refused = ValueError("--window-look takes opaque or see-through[:opacity=0..1,blur=frosted|glass|glass-clear|none,"
                         "terminal-opacity=0..1,terminal-blur=RADIUS,behind=desktop|checker|stripes] "
                         f"(unset leaves a key out; one key at least stays), not {value!r}")
    if word != "see-through" or (colon and not rest.strip()):
        raise refused
    seen = set()
    for part in rest.split(",") if colon else []:
        key, equals, text = (piece.strip() for piece in part.partition("="))
        key = key.replace("-", "_")
        if not equals or key not in look or key in seen:
            raise refused
        seen.add(key)
        try:
            if key == "behind":
                found = text if text in ("desktop", "checker", "stripes") else None
            elif text == "unset":
                look[key] = None
                continue
            elif key == "blur":
                found = text if text in ("frosted", "glass", "glass-clear", "none") else None
            elif key == "terminal_blur":
                found = int(text) if int(text) >= 0 else None
            else:
                found = float(text) if 0 <= float(text) <= 1 else None
        except ValueError:
            found = None
        if found is None:
            raise refused
        look[key] = found
    if all(look[key] is None for key in ("opacity", "blur", "terminal_opacity", "terminal_blur")):
        raise refused
    return look


def look_tag(look):
    """The part a see-through look adds to each row's layout name: each of its 4 values in the flag's order, then
    what the window is over when that is not the desktop. An opaque window adds nothing."""
    if not look:
        return ""
    values = [look["opacity"], look["blur"], look["terminal_opacity"], look["terminal_blur"]]
    over = "" if look["behind"] == "desktop" else f"-over-{look['behind']}"
    return "see-through-" + "-".join("unset" if value is None else format(value, "g") if isinstance(value, float)
                                     else str(value) for value in values) + over


def look_config(config, look):
    """The app config with the look's `appearance.backgroundOpacity` and `appearance.backgroundBlur` (a copy; the
    other keys stay). An opaque window gets `config` itself: the launch default."""
    if not look:
        return config
    appearance = dict(config.get("appearance") or {})
    if look["opacity"] is not None:
        appearance["backgroundOpacity"] = look["opacity"]
    if look["blur"] is not None:
        appearance["backgroundBlur"] = look["blur"]
    return {**config, "appearance": appearance} if appearance else dict(config)


def look_terminal_lines(look):
    """The look's lines of the terminal config file: an opacity and a blur radius. None for an opaque window."""
    if not look:
        return []
    lines = []
    if look["terminal_opacity"] is not None:
        lines.append(f"background-opacity = {look['terminal_opacity']:g}")
    if look["terminal_blur"] is not None:
        lines.append(f"background-blur = {look['terminal_blur']}")
    return lines


def look_problem(look, env, read=None):
    """Why the launched app did not get the look (None when it did, and for an opaque window): the app config and
    the terminal config file of the launch's own environment must hold each key and line of the look."""
    if not look:
        return None
    read = read or (lambda path: open(path).read())
    try:
        terminal = read(env["CMUX_NEXT_GHOSTTY_CONFIG"]).splitlines()
        appearance = json.loads(read(env["CMUX_NEXT_CONFIG_FILE"])).get("appearance") or {}
    except (KeyError, OSError, ValueError) as error:
        return f"the launch's config files were not read: {error!r}"
    missing = [line for line in look_terminal_lines(look) if line not in terminal]
    wanted = look_config({}, look).get("appearance") or {}
    missing += [f"appearance.{key}" for key, value in wanted.items() if appearance.get(key) != value]
    return f"not in the launch's config: {missing}" if missing else None


def not_applicable(step, columns):
    """Why `step` does not apply to a layout of `columns` columns (None when it does, and for STRESS: None
    columns). A drag presses the first vertical divider: a one-column layout (1x2) has none."""
    if step == "drag" and columns == 1:
        return "one column: no vertical divider to drag"
    return None


def activate(app_path, read_state=None, timeout=10.0):
    """Brings the bench app to the front with a key window: LaunchServices opens its bundle (`open`, the running
    app, as a Dock click), then `debug.window_list` is read until a main window is key. An app a script started
    is not let take the front from the app in front by itself (cmux-ad BENCH BASE REDS 2: no fleet run had a key
    window). Returns the last window state."""
    read_state = read_state or window_state
    try:
        subprocess.run(["open", app_path], capture_output=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as error:
        print(f"  (open {app_path}: {error})", flush=True)
    deadline = time.monotonic() + timeout
    state = read_state()
    while not state.get("window_key") and time.monotonic() < deadline:
        time.sleep(0.25)  # test harness: LaunchServices activates the app
        state = read_state()
    return state


def change(before, after):
    """after - before for two numbers (an int when whole), else None."""
    if not all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in (before, after)):
        return None
    value = round(after - before, 2)
    return int(value) if float(value).is_integer() else value


def counter(report, group, key):
    return ((report if isinstance(report, dict) else {}).get(group) or {}).get(key)


def first_window(report):
    windows = (report or {}).get("windows") if isinstance(report, dict) else None
    return windows[0] if windows else {}


def measure(label, name):
    global WINDOW_RESTORE
    window_geometry = first_window(rpc("debug.layers")) if name in WINDOW_ACTIONS else {}
    window_before = window_geometry.get("frame")
    if name == "window-zoom":
        WINDOW_RESTORE = window_before
    if name in WINDOW_ACTIONS:
        rpc("debug.motion", {"action": "trace_start", "targets": ["window"]})
        time.sleep(0.05)  # test harness: record the resting geometry before the input
    cef_before = rpc("debug.cef") if opts.browser else None  # outside the timed window, like the reads after it
    layers_before = first_window(rpc("debug.layers")) if opts.browser else None
    page_before = page_eval("window.__frames") if opts.browser else None
    rpc("debug.hangs", {"clear": True})
    background = bench_background.sample()
    rpc("debug.motion", {"action": "start"})
    rpc("debug.frames", {"action": "start"})
    rpc("debug.window_transition", {"action": "start"})
    action_s = time.monotonic()  # the uptime clock, as the probe's `first_frame_s` (late_frames)
    error = perform(name)
    time.sleep(1.2)  # test harness: the springs land (rest is under 0.5 s) and the PTY owner answers
    trace = rpc("debug.window_transition", {"action": "stop"}) or {}
    frames = rpc("debug.frames", {"action": "stop", "raw": True}) or {}
    motion = rpc("debug.motion", {"action": "stop"}) or {}
    background_cpu = bench_background.delta(background)
    window_trace = rpc("debug.motion", {"action": "trace_stop"}) if name in WINDOW_ACTIONS else None
    hangs = rpc("debug.hangs") or {}
    work = (motion.get("work") or {}).get("clock", {}) if isinstance(motion, dict) else {}
    # Each Core Animation commit while recording (MotionCommitProbe): with Chromium pages, how long a page's
    # resize wait (fork API 27 resize sync) held the frame. None on builds without the probe.
    commit = (motion.get("work") or {}).get("ca.commit") if isinstance(motion, dict) else None
    moving = moving_frames(motion.get("samples")) if isinstance(motion, dict) else 0
    committed = commit_frames(motion.get("samples")) if isinstance(motion, dict) else 0
    late = late_frames(frames, action_s)
    offset = record_offset(motion, action_s)
    hang_list = hangs.get("hangs") if isinstance(hangs, dict) else None
    result = {
        "label": label, "action": name, "error": error,
        "missed": frames.get("missed"), "frames_max_ms": frames.get("max_ms"), "frames_p99_ms": frames.get("p99_ms"),
        "frames_p50_ms": frames.get("p50_ms"), "frames_p95_ms": frames.get("p95_ms"), "frames": frames.get("frames"),
        "refresh_ms": frames.get("refresh_ms"), "moving_frames": moving, "commit_frames": committed, **late,
        "commit_notes": commit_notes(motion.get("notes")) if isinstance(motion, dict) else [],
        "commit_placements": commit_placements(motion.get("samples"), motion.get("notes")) if isinstance(motion, dict) else [],
        "layout_spans": layout_spans(motion.get("spans")) if isinstance(motion, dict) else {},
        "probe_notes": probe_notes(motion.get("notes"), commit_placements(motion.get("samples"), motion.get("notes")))
        if isinstance(motion, dict) else [],
        # A measure branch's fields (a build without them gives None, [] and no row text): the record's start on the
        # action's clock, the turn probe's long turns and its own counts, and the watchdog's stalls (--stall-ms).
        "record_start_after_action_ms": offset,
        "turns": turn_notes(motion.get("notes"), offset) if isinstance(motion, dict) else [],
        "turn_probe": motion.get("turn_probe") if isinstance(motion, dict) else None,
        "stalls": stalls_in(hangs, action_s),
        "background_cpu": background_cpu,
        "layout_max_ms": work.get("max_ms"), "layout_p95_ms": work.get("p95_ms"), "layout_p50_ms": work.get("p50_ms"),
        "commit_p50_ms": (commit or {}).get("p50_ms"), "commit_p95_ms": (commit or {}).get("p95_ms"),
        "commit_max_ms": (commit or {}).get("max_ms"), "commit_over_4": (commit or {}).get("over_4_ms"),
        "commits": (commit or {}).get("frames"),
        "grid_reports": trace.get("terminal_grid_reports"), "resizes_sent": trace.get("terminal_resizes_sent"),
        "hangs": len(hang_list) if isinstance(hang_list, list) else hangs.get("count"),
    }
    if name in WINDOW_ACTIONS:
        window_after = first_window(rpc("debug.layers")).get("frame")
        samples = [s for s in (window_trace or {}).get("samples") or [] if len(s.get("window") or []) == 2]
        # Analyze the axis that moved farthest, using the golden-interactions harness's active
        # interval (rest frames after the animation cannot hide a slow zoom in the p95).
        axis = max(range(2), key=lambda i: abs(samples[-1]["window"][i] - samples[0]["window"][i])) if samples else 0
        travel = frame_motion([s["window"][axis] for s in samples], [s["t"] for s in samples])
        intervals = travel["intervals"]
        trace_refresh = (window_trace or {}).get("refresh_ms")
        refresh = trace_refresh if finite_nonnegative(trace_refresh) else 0
        result.update(window_before=window_before, window_after=window_after, window_trace=window_trace,
                      window_intermediate=travel["intermediate"], window_max_step=travel["max_step"],
                      window_frame_p95_ms=round(percentile(intervals, 0.95), 2),
                      window_frame_max_ms=round(max(intervals, default=0), 2), window_refresh_ms=refresh,
                      window_frame_missed=sum(dt > refresh * 1.5 for dt in intervals) if refresh > 0 else None,
                      window_monitor_refresh_ms=frames.get("refresh_ms"),
                      window_monitor_missed=frames.get("missed"))
        if not window_before or not window_after or not any(abs(a - b) > 1 for a, b in zip(window_before, window_after)):
            error = error or "window zoom changed no frame"
        elif name == "window-unzoom" and (not WINDOW_RESTORE or any(abs(a - b) > 1 for a, b in zip(WINDOW_RESTORE, window_after))):
            error = error or f"window unzoom did not restore {WINDOW_RESTORE}: {window_after}"
        standard = window_geometry.get("screen_visible_frame")
        if name == "window-zoom" and (not standard or not window_after or any(abs(a - b) > 1 for a, b in zip(standard, window_after))):
            error = error or f"window zoom did not reach its screen's visible frame {standard}: {window_after}"
        if travel["intermediate"] == 0:
            error = error or "window zoom had no intermediate display frame (snapped or trace unavailable)"
        target_period = 1000.0 / WINDOW_TARGET_HZ
        min_period = target_period * (1 - WINDOW_REFRESH_TOLERANCE)
        max_period = target_period * (1 + WINDOW_REFRESH_TOLERANCE)
        monitor_refresh = frames.get("refresh_ms")
        if not finite_nonnegative(trace_refresh) or not frames.get("frames"):
            error = error or "window zoom has no display refresh evidence"
        if not (finite_nonnegative(trace_refresh) and min_period <= refresh <= max_period) or not (
                finite_nonnegative(monitor_refresh) and min_period <= monitor_refresh <= max_period):
            error = error or (f"window zoom display is not near {WINDOW_TARGET_HZ:.0f} Hz "
                              f"(trace {refresh}, monitor {monitor_refresh})")
        if travel["max_step"] > WINDOW_MAX_STEP:
            error = error or (f"window zoom geometry step {travel['max_step']:.3f} exceeds "
                              f"{WINDOW_MAX_STEP:.2f} of travel")
        if result["window_frame_missed"]:
            error = error or f"window zoom missed {result['window_frame_missed']} native display frame(s)"
        monitor_missed = result["window_monitor_missed"]
        if not finite_nonnegative(monitor_missed):
            error = error or f"window zoom display probe has invalid missed-frame count {monitor_missed!r}"
        elif monitor_missed:
            error = error or f"window zoom display probe missed {monitor_missed} frame(s)"
        if travel["intermediate"] < WINDOW_MIN_INTERMEDIATE:
            error = error or (f"window zoom had {travel['intermediate']} intermediate display frames; "
                              f"expected at least {WINDOW_MIN_INTERMEDIATE}")
        result["error"] = error
    extra = ""
    if name in WINDOW_ACTIONS:
        extra = (f"  window active p95 {result['window_frame_p95_ms']} max {result['window_frame_max_ms']} ms "
                 f"missed {result['window_frame_missed']} (refresh {result['window_refresh_ms']}) "
                 f"intermediate {result['window_intermediate']} max step {result['window_max_step']}")
    if opts.browser:
        cef_after = rpc("debug.cef")
        for key, group, field in CEF_DELTAS:
            result[key] = change(counter(cef_before, group, field), counter(cef_after, group, field))
        result["page_frames"] = change(page_before, page_eval("window.__frames"))
        layers_after = first_window(rpc("debug.layers"))
        for key, field in LAYER_DELTAS:
            result[key] = change(layers_before.get(field), layers_after.get(field))
        # Geometry posts per display frame the springs moved (a still action: per frame of the action).
        span = moving if name not in STILL else (frames.get("frames") or 0)
        result["posts_per_frame"] = round(result["trk_posts"] / span, 2) if isinstance(result["trk_posts"], (int, float)) and span else None
        extra += (f"  pump {result['pump_runs']} runs {result['pump_ms']} ms long {result['pump_long']} "
                 f"req {result['pump_now_req']}/{result['pump_delayed_req']}  clip {result['trk_clip_reads']} reads "
                 f"{result['trk_clip_builds']} builds {result['trk_clip_hits']} hits {result['trk_clip_ms']} ms  occl {result['trk_occl_reads']}  "
                 f"posts {result['trk_posts']} ({result['posts_per_frame']}/frame) skips {result['trk_skips']}  "
                 f"catchers {result['catcher_updates']} reorders {result['reorders']}  page rAF {result['page_frames']}")
    where = ", ".join(f"{miss.get('interval_ms')} ms {miss.get('cause')} at {miss.get('after_action_ms')} ms after the action"
                      for miss in late["missed_frames"][:8])
    if result["commit_placements"] or result["layout_spans"]:
        placed = ", ".join(f"{place['after_tick_ms']} ms" for place in result["commit_placements"][:4])
        times = part_times(result["layout_spans"], result["commit_placements"])
        parts = ", ".join(f"{part} {facts['count']}x sum {facts['sum_ms']} max {facts['max_ms']} ms"
                          + (f" at +{times[part]}" if times.get(part) is not None else "")
                          for part, facts in sorted(result["layout_spans"].items()))
        extra += (f"  commit note after its tick's start [{placed}]  parts [{parts}]"
                  f"  probe notes {result['probe_notes']}")
        start = placed_at(result["commit_placements"])
        if start is not None and offset is not None:
            extra += f"  placed {round(start + offset, 1)} ms after the action"
    if result["turns"] or result["turn_probe"]:
        extra += f"  long turns [{', '.join(turn_text(turn) for turn in result['turns'][:8])}]  turn probe {result['turn_probe']}"
    if opts.stall_ms:
        extra += f"  stalls [{', '.join(stall_text(stall) for stall in result['stalls'][:8])}]"
    print(f"  {label:<22} moved {moving:>3} commit {committed:>3}  frame p50 {result['frames_p50_ms']} p95 {result['frames_p95_ms']} "
          f"p99 {result['frames_p99_ms']} max {result['frames_max_ms']} ms  missed {result['missed']} "
          f"long intervals = {late['missed_refreshes']} refreshes [{where}] (refresh {result['refresh_ms']})  "
          f"main max {late['main_max_ms']} ms  tick p95 {result['layout_p95_ms']} max {result['layout_max_ms']} ms  "
          f"commit p95 {result['commit_p95_ms']} max {result['commit_max_ms']} ms  "
          f"grids {result['grid_reports']}/{result['resizes_sent']}  hangs {result['hangs']}  "
          f"background {background_cpu['total_s']} s{' OVER LIMIT' if background_cpu['over_limit'] else ''}  err {error}{extra}", flush=True)
    return result


SEQUENCE = {"split": ["split", "close"], "split-down": ["split-down", "close-down"], "close": [],
            "column": ["column", "column-close"], "zoom": ["zoom", "unzoom"], "drag": ["drag"],
            "keys": ["keys"], "window": ["window-zoom", "window-unzoom"],
            "scroll": ["scroll"], "idle": ["idle"],
            "page": ["page", "page-close"]}


def steps():
    wanted = opts.actions.split(",")
    names = []
    for name in wanted:
        names += SEQUENCE.get(name, [])
    if "close" in wanted and "split" not in wanted:
        names += ["split", "close"]  # a close needs a pane to close: the split before it is timed too
    return names


def record(name, label):
    folder = os.path.join(opts.out, "frames", label.replace(" ", "-"))
    reply = rpc("debug.window_record", {"dir": folder, "seconds": 2.0})
    if isinstance(reply, dict) and reply.get("error"):
        print(f"  (no recording of {label}: {reply['error']})", flush=True)
    time.sleep(0.2)  # test harness: the recorder takes its first frame at rest
    perform(name)
    time.sleep(2.2)  # test harness: the recording stops by itself


def profile(name, label):
    """Samples the app (`/usr/bin/sample`, 1 ms) while it repeats `name` (and its undo); prints the main
    thread's heaviest frames (the report's "Sort by top of stack" list) and keeps the whole report."""
    pair = {"split": ["split", "close"], "close": ["split", "close"], "split-down": ["split-down", "close-down"], "column": ["column", "column-close"],
            "column-close": ["column", "column-close"], "zoom": ["zoom", "unzoom"], "unzoom": ["zoom", "unzoom"],
            "window-zoom": ["window-zoom", "window-unzoom"], "window-unzoom": ["window-zoom", "window-unzoom"],
            "drag": ["drag"], "keys": ["keys"], "scroll": ["scroll"], "idle": ["idle"],
            "page": ["page", "page-close"], "page-close": ["page", "page-close"]}[name]
    path = os.path.join(opts.out, f"sample-{label}.txt")
    seconds = max(3, int(opts.sample_repeats * len(pair) * 1.0) + 1)
    sampler = subprocess.Popen(["/usr/bin/sample", str(app.pid), str(seconds), "1", "-mayDie", "-file", path],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.5)  # test harness: the sampler attaches
    for _ in range(opts.sample_repeats):
        for step in pair:
            perform(step)
            time.sleep(0.45)  # test harness: each spring lands before the next press
    sampler.wait(timeout=seconds + 60)
    try:
        text = open(path, errors="replace").read()
    except OSError:
        print(f"  (no sample for {label})", flush=True)
        return
    print(f"\n== sample {label}: main thread, inclusive share by subsystem", flush=True)
    for line in main_thread_buckets(text):
        print(line, flush=True)
    top = text.split("Sort by top of stack")
    if len(top) > 1:
        print(f"== sample {label}: heaviest frames (all threads, top of stack)", flush=True)
        print("\n".join(top[1].splitlines()[:30]), flush=True)


# Subsystems of a main-thread stack, first match wins per frame; a frame counts for a bucket only at the
# shallowest frame of that bucket on its path (inclusive time, never twice for one sample).
BUCKETS = [
    ("idle", ("mach_msg2_trap", "mach_msg_trap", "__CFRunLoopServiceMachPort")),
    ("ghostty", ("ghostty_", "renderer.", "Metal.", "IOSurfaceLayer", "terminal.", "font.")),
    ("chromium", ("CEF", "cef_", "Chromium", "chrome::", "content::", "blink::", "viz::", "CmuxNextBrowser")),
    ("ca-commit", ("CA::Transaction::commit", "CA::Context::commit", "CA::Layer::layout_and_display")),
    ("appkit-layout", ("_layoutSubtree", "layoutSubtreeIfNeeded", "NSView layout]", "_NSViewLayout", "updateConstraints")),
    ("appkit-display", ("_displayRectIgnoringOpacity", "displayIfNeeded", "drawRect", "NSViewDrawRect")),
    ("swiftui", ("SwiftUI", "AttributeGraph", "AG::")),
    ("layout(ours)", ("CmuxNextLayout", "ScreenContentView", "LayoutRootView", "PaneHostView", "SplitMotion")),
    ("store(ours)", ("DaemonStore", "CmuxNextDaemon", "WorkspaceContentController", "PaneController")),
]


def main_thread_buckets(text):
    graph = text.split("Call graph:", 1)
    if len(graph) < 2:
        return ["  (no call graph)"]
    lines = graph[1].splitlines()
    import re
    node = re.compile(r"^([ +!:|]*)(\d+) (.*)$")
    start = next((i for i, l in enumerate(lines) if "Thread_" in l and "com.apple.main-thread" in l), None)
    if start is None:  # the first thread of the call graph is the main thread
        start = next((i for i, l in enumerate(lines) if "Thread_" in l), None)
    if start is None:
        return ["  (no main thread)"]
    head = node.match(lines[start])
    total, base = int(head.group(2)), len(head.group(1))
    sums = {name: 0 for name, _ in BUCKETS}
    path = []  # (depth, bucket or None)
    for line in lines[start + 1:]:
        m = node.match(line)
        if not m:
            continue
        depth = len(m.group(1))
        if depth <= base:
            break  # the next thread
        while path and path[-1][0] >= depth:
            path.pop()
        symbol = m.group(3)
        bucket = next((name for name, keys in BUCKETS if any(k in symbol for k in keys)), None)
        if bucket and all(b != bucket for _, b in path):
            sums[bucket] += int(m.group(2))
        path.append((depth, bucket))
    # Self time per symbol (leaves of the main thread's tree), the heaviest first.
    leaves, rows = {}, []
    for line in lines[start + 1:]:
        m = node.match(line)
        if not m:
            continue
        if len(m.group(1)) <= base:
            break
        rows.append((len(m.group(1)), int(m.group(2)), m.group(3)))
    for i, (depth, count, symbol) in enumerate(rows):
        child = sum(c for d, c, _ in rows[i + 1:next((j for j in range(i + 1, len(rows)) if rows[j][0] <= depth), len(rows))] if d == min((r[0] for r in rows[i + 1:i + 2]), default=depth + 1))
        own = count - child if i + 1 < len(rows) and rows[i + 1][0] > depth else count
        name = symbol.split("  (in ")[0][:140]
        leaves[name] = leaves.get(name, 0) + max(own, 0)
    out = [f"  main thread samples {total} (1 ms each)"]
    for name, _ in BUCKETS:
        out.append(f"  {name:<15} {sums[name]:>6}  {100.0 * sums[name] / max(total, 1):5.1f}%")
    out.append("  main thread self time, heaviest (not idle):")
    idle = ("mach_msg2_trap", "mach_msg_trap", "__psynch_cvwait", "semaphore_wait_trap", "kevent")
    for name, count in sorted(leaves.items(), key=lambda kv: -kv[1])[:40]:
        if not name.startswith(idle) and count > 0:
            out.append(f"    {count:>6}  {name}")
    # The busiest non-idle branches of the main thread, to read who calls the heavy leaves.
    out.append("  main thread heavy branches (>= 1% of non-idle):")
    busy = max(total - sums.get("idle", 0), 1)
    shown = 0
    for depth, count, symbol in rows:
        if count * 100 >= busy and not any(k in symbol for k in idle) and depth - base <= 120:
            out.append("    " + " " * ((depth - base) // 2) + f"{count} {symbol.split('  (in ')[0][:150]}")
            shown += 1
            if shown >= 140:
                break
    return out


def cleanup():
    if os.environ.get("PANE_PERF_KEEP") or not LAUNCHED or BENCH is None:
        return
    rpc("action.run", {"action": "quitEndSessions"}, timeout=10)
    BENCH.stop()  # debug.quit, then only this tag's processes and daemons (tag_teardown.py)


def main():
    global app, SOCKET, BENCH, MEASURED
    arms = motion_arms(opts.pane_motion)  # another word than on or off ends the run here, before the app starts
    look = window_look(opts.window_look)  # so does another word for the window's look
    os.makedirs(opts.out, exist_ok=True)
    # The shared launch (bench_launch.py): its bench environment, a session check that fails at once with
    # no-gui-session, the state-folder socket, and a BENCH-LAUNCH report (crash, sample, log tail) on failure.
    # The app activates and its window becomes key (no CMUX_NEXT_NO_ACTIVATE), as for a person; without
    # no-activate the app reads no test window placement, so the window is placed through the socket below.
    # --stall-ms: the app's main-thread watchdog records, and samples a stack in, each stall from that many ms.
    stall_env = {"CMUX_NEXT_HANG_THRESHOLD_MS": str(opts.stall_ms)} if opts.stall_ms else {}
    BENCH = BenchApp(APP, out=opts.out, config=look_config(CONFIG, look), env={"CMUX_NEXT_NO_ACTIVATE": None, **stall_env},
                     window=None, screen=None, log_name=f"app-{TAG}.log")
    if look_terminal_lines(look):
        # A see-through window's terminal lines: the launch opens this file to append, so they stay in it.
        with open(os.path.join(BENCH.scratch, "ghostty"), "w") as terminal_config:
            terminal_config.write("\n".join(look_terminal_lines(look)) + "\n")
    try:
        BENCH.launch(timeout=120, on_start=lambda process: LAUNCHED.append(process.pid))
    except LaunchError as error:
        print(str(error), flush=True)
        row("the tagged app came up", "its socket answers with a window", error.reason, False)
        return
    app, SOCKET = BENCH.process, BENCH.socket
    macos = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
    host = subprocess.run(["hostname"], capture_output=True, text=True).stdout.strip()
    print(f"launched pid {app.pid} macOS {macos} host {host}", flush=True)
    time.sleep(5)  # test harness: launch work settles
    placed, window_problem = STRESS_MODULE.place_window(rpc)
    row("the window is placed on the main screen", f"{list(WINDOW)} pt on its screen", window_problem or str(placed.get("frame") if isinstance(placed, dict) else placed),
        window_problem is None)
    behind = None
    if look:
        # No see-through row from an opaque window: the launch's own config files hold the look, or the run ends.
        problem = look_problem(look, BENCH.launched_env or {})
        if not problem and look["behind"] != "desktop":
            behind = rpc("debug.capture_backdrop", {"pattern": look["behind"]})  # before the app takes the front
            if not (isinstance(behind, dict) and behind.get("backdrop_number")):
                problem = f"no {look['behind']} panel behind the window: {behind}"
        row("the window has the see-through look", look_tag(look), problem or "in the app config and the terminal config file",
            problem is None)
        if problem:
            UNMEASURED.append(f"window look: {problem}")
            return
    front = activate(APP)
    print(f"activated: window key {front['window_key']}, frontmost {front['frontmost']}", flush=True)
    # The bench conditions: the environment the app was really started with (mocked agent chats, the
    # isolated chief, no CMUX_NEXT_NO_ACTIVATE), the window's placement, and per layout whether the window
    # was key when it started (`layouts`).
    conditions = {"env": BENCH.launched_env, "window": STRESS_MODULE.window_on_screen(placed) if isinstance(placed, dict) else None,
                  "layouts": {}}
    # The window's look: its values, what the window is over, and the backdrop the app says it shows (`debug.themes`).
    themes = rpc("debug.themes")
    shown = (themes.get("windows") or [{}])[0].get("backdrop") if isinstance(themes, dict) else None
    conditions["window_look"] = {"look": "see-through" if look else "opaque", **(look or {}),
                                 "terminal_config": look_terminal_lines(look), "backdrop_shown": shown,
                                 "terminal_background": themes.get("ghostty_background") if isinstance(themes, dict) else None}
    if look:
        conditions["window_look"]["over"] = "the fixture's desktop" if behind is None else behind
    print("CONDITIONS " + json.dumps(conditions), flush=True)
    report = {"tag": TAG, "macos": macos, "host": host, "stream": opts.stream, "scrollback": opts.scrollback,
              "conditions": conditions, "runs": []}
    sequence = steps()
    labels = []  # each measured layout's name in the report: `<layout>-inactive` when its window was not key
    for name in opts.layouts.split(","):
        if name == "stress":
            problem = stress_layout()
            panes = STRESS.get("measured_panes") or 0
        else:
            columns, rows = (int(v) for v in name.split("x"))
            problem = layout(columns, rows)
            panes = columns * rows
        if problem:
            print(f"  {name}: {problem}", flush=True)
            row(f"{name}: the layout was built" if name == "stress" else f"{name}: the Chromium page runs (--browser)", "the STRESS shape" if name == "stress" else "window.__frames counting", problem, False)
            UNMEASURED.append(name)
            continue
        state = window_state()
        if not state["window_key"]:
            state = activate(APP)  # another app took the front since the last layout
        if name == "stress":
            # A bottom Dock over the window's lower edge, and chats the session replaced (none in STRESS).
            state.update(dock_overlap_pt=STRESS.get("dock_overlap_pt"), chat_fallbacks=STRESS.get("chat_fallbacks"))
        label = f"{name}-{look_tag(look)}" if look else name  # a see-through window's rows say its look's values
        label = label if state["window_key"] else f"{label}-inactive"
        # One pass for each arm in each round (--pane-motion): the off arm's rows are named <label>-motion-off.
        tags = {arm: arm_tag(label, arm) for arm in arms or [None]}
        for tag in tags.values():
            conditions["layouts"][tag] = state
        print(f"  {name}: window key {state['window_key']}, frontmost {state['frontmost']} (rows named {', '.join(tags.values())})", flush=True)
        labels += tags.values()
        rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"{name}-before.png")})
        for index, arm in [(index, arm) for index in range(opts.rounds) for arm in tags]:
            label = tags[arm]
            problem = set_pane_motion(arm != "off", hide_first=arm == "hide-first") if arm else None
            if problem:
                row(f"{label} #{index}: the pane motion is {arm}", "the app took the setting", problem, False)
                UNMEASURED.append(f"{label} #{index}: {problem}")
                continue
            for step in sequence:
                skip = not_applicable(step, columns if name != "stress" else None)
                if skip:
                    if index == 0:
                        print(f"  {label} {step}: not applicable ({skip}), not measured", flush=True)
                    continue
                if opts.browser and step not in ("close", "close-down", "column-close", "unzoom", "window-unzoom", "page-close"):
                    focus_page()  # each pair starts on the Chromium pane
                run = measure(f"{panes:>2}p {step} #{index}" + (f" {arm}" if arm else ""), step)
                run.update(layout=label, panes=panes, round=index, pane_motion=arm)
                report["runs"].append(run)
                if step in WINDOW_ACTIONS and run["error"]:
                    UNMEASURED.append(f"{label} {step} #{index}: {run['error']}")
                row(f"{label} {step} #{index}: ran", "no error", str(run["error"]), run["error"] is None)
                moved = f"{run['moving_frames']} spring frames, {run['commit_frames']} commit frames"
                if step not in STILL and arm == "off":
                    row(f"{label} {step} #{index}: still (the pane motion is off)", "0 frames", moved,
                        not run["moving_frames"] and not run["commit_frames"])
                elif step not in STILL:
                    animated = (run["moving_frames"] or 0) > 0 or (run["commit_frames"] or 0) > 0
                    row(f"{label} {step} #{index}: animated (layout springs, the strip camera or a commit motion moved)",
                        "> 0 frames", moved + ("" if animated else f"; the app's notes: {run['commit_notes'][:4]}"), animated)
                missed = run["missed"]
                row(f"{label} {step} #{index}: missed frames" + ("" if opts.gate else " (info)"),
                    f"<= {opts.missed_budget}", f"{missed} ({run['missed_refreshes']} refreshes)",
                    missed is not None and missed <= opts.missed_budget or not opts.gate)
                if opts.json:
                    json.dump(report, open(opts.json, "w"), indent=1)
                time.sleep(0.4)  # test harness: idle between runs
        if arms and set_pane_motion(True):
            print(f"  {name}: the pane motion did not go back on", flush=True)
        for wanted in filter(None, opts.sample.split(",")):
            where, _, what = wanted.partition(":")
            if where == name and not not_applicable(what, columns if name != "stress" else None):
                profile(what, f"{name}-{what}")
        if opts.record:
            for step in sequence:
                if not not_applicable(step, columns if name != "stress" else None):
                    record(step, f"{name}-{step}")
    print("\n== summary (median over rounds)")
    browser_keys = BROWSER_KEYS if opts.browser else []
    wide = max([13] + [len(step) for step in sequence])  # sidepanel-close
    print(f"  {'panes':<5} {'action':<{wide}} {'p50':>6} {'p95':>6} {'p99':>6} {'max':>6} {'missed':>6} "
          f"{'refr':>5} {'moved':>5} {'commit':>6} "
          f"{'tick95':>6} {'tickmx':>6} {'grids':>7}" + "".join(f" {h:>6}" for h in BROWSER_HEADS[:len(browser_keys)]))
    for name in labels:
        for step in sequence:
            runs = [r for r in report["runs"] if r["layout"] == name and r["action"] == step]
            if not runs:
                continue  # not applicable to this layout (1x2 drag): no all-None row for perf-budgets.py

            def med(key):
                values = sorted(v for v in (r.get(key) for r in runs) if v is not None)
                return values[len(values) // 2] if values else None
            summary = {key: med(key) for key in ["frames_p50_ms", "frames_p95_ms", "frames_p99_ms", "frames_max_ms", "missed",
                                                 "missed_refreshes", "main_max_ms", "commit_frames", "moving_frames",
                                                 "layout_p95_ms", "layout_max_ms", "grid_reports",
                                                 "resizes_sent", "commit_p95_ms", "commit_max_ms", "refresh_ms",
                                                 "window_intermediate", "window_max_step", "window_frame_p95_ms", "window_frame_max_ms",
                                                 "window_frame_missed", "window_refresh_ms"] + browser_keys}
            report.setdefault("summary", []).append({"layout": name, "action": step, **summary})

            def f(v):
                return "-" if v is None else (f"{v:.1f}" if isinstance(v, float) else str(v))
            grids = f"{f(summary['grid_reports'])}/{f(summary['resizes_sent'])}"
            print(f"  {name:<5} {step:<{wide}} {f(summary['frames_p50_ms']):>6} {f(summary['frames_p95_ms']):>6} "
                  f"{f(summary['frames_p99_ms']):>6} {f(summary['frames_max_ms']):>6} {f(summary['missed']):>6} "
                  f"{f(summary['missed_refreshes']):>5} {f(summary['moving_frames']):>5} {f(summary['commit_frames']):>6} "
                  f"{f(summary['layout_p95_ms']):>6} {f(summary['layout_max_ms']):>6} "
                  + (f"{grids:>7}" + "".join(f" {f(summary[k]):>6}" for k in browser_keys) if browser_keys else grids),
                  flush=True)
    if opts.json:
        json.dump(report, open(opts.json, "w"), indent=1)
    MEASURED = bool(report["runs"])  # at least one action was measured
    report["unmeasured"] = UNMEASURED
    if opts.json:
        json.dump(report, open(opts.json, "w"), indent=1)


def frontmost_app():
    """The frontmost app's bundle id now (`lsappinfo`)."""
    try:
        front = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True, timeout=5).stdout.strip()
        info = subprocess.run(["lsappinfo", "info", "-only", "bundleid", front], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError) as error:
        return f"unknown ({error})"
    return info.stdout.strip().partition("=")[2].strip('" ') or info.stdout.strip() or None


try:
    main()
except Exception:  # the step log is stdout only
    import traceback
    traceback.print_exc(file=sys.stdout)
finally:
    cleanup()
    # One artifact with everything (report, samples, pictures, recordings): artifacts/.../out.tgz.
    subprocess.run(["tar", "-czf", os.path.join(opts.out, "out.tgz"), "-C", opts.out]
                   + [p for p in os.listdir(opts.out) if p.endswith((".json", ".txt", ".png")) or p == "frames"], capture_output=True)
    if opts.record and os.path.isdir(os.path.join(opts.out, "frames")):
        # One artifact: the recordings and snapshots beside the report.
        subprocess.run(["tar", "-czf", os.path.join(opts.out, "frames.tgz"), "-C", opts.out, "frames"]
                       + [p for p in os.listdir(opts.out) if p.endswith(".png")], capture_output=True)
    if opts.json and os.path.exists(opts.json):
        # The step log keeps the numbers even when a row failed (no artifact comes back then).
        print("REPORT-JSON " + json.dumps(json.load(open(opts.json)).get("summary") or []), flush=True)
    print("\nRESULT", "PASS" if MEASURED and not UNMEASURED and ROWS and all(r[3] for r in ROWS) else "FAIL",
          f"({sum(r[3] for r in ROWS)}/{len(ROWS)})" + (f"; not measured: {', '.join(UNMEASURED)}" if UNMEASURED else ""))
    # Without --gate a row is information: the run passes when it measured (its artifact comes back). A run
    # that measured nothing (the app never came up, an exception before the summary), or skipped a layout it
    # was asked for (a refused STRESS shape, a Chromium page that never ran), fails either way.
    sys.exit(0 if MEASURED and not UNMEASURED and ROWS and (all(r[3] for r in ROWS) or not opts.gate) else 1)
