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
  drag        the first vertical divider pressed and dragged 120 pt out and back, one event per 120 Hz frame
  sidepanel   the window's right sidebar shown (switchRightSidebarToFiles, keyboard stays put) and hidden
              (toggleRightSidebar, sidepanel-close): the main pane loses and regains its width at once, no spring
  scroll      (--browser) the page scrolled 1500 px down and back over about 1 s, one step per page animation frame
  idle        nothing for 1 s: with --browser the page keeps animating, so this is the Chromium pump at rest
  page        a browser page opening on the right (splitBrowserRight, Leo's "opening up a new thing on the
              right"), then its close (page-close)

The bench app activates and its window is key where the host allows it (CMUX_NEXT_NO_ACTIVATE is removed from
the bench environment), as for a person. Each layout reads whether the window really is key (`debug.window_list`)
when it starts: a layout measured with a window that is not key is named `<layout>-inactive` (rows
`panes.<action>.<layout>-inactive.*`), so it is never compared with rows of a key window. The window goes on the
main screen at the STRESS size (perf-stress-session.py `place_window`). A layout asked for and not measured (a
STRESS shape refused, a Chromium page that never ran) fails the run, --gate or not.

Per action: display frame intervals p50/p95/p99/max and missed frames (`debug.frames`), the layout's main-thread
work per frame (`debug.motion` clock), each Core Animation commit (`debug.motion` work `ca.commit`: with Chromium
pages it holds the resize wait of fork API 27), frames the springs moved, grids sent to the PTY owner
(`debug.window_transition`) and hangs (`debug.hangs`). With --record, a second pass records each action with
`debug.window_record` (frames/ in --out; the recording itself costs frames, so it never runs in the timed pass).

With --browser the top-left pane of each layout shows a Chromium page instead of a fed terminal (a local probe: a
requestAnimationFrame loop counting into window.__frames, a spinner, a tall grid of cards; the first split terminal
takes --stream), and each action pair starts with that pane focused. Per action it adds the change of `debug.cef`'s
pump counters (pump_runs, pump_ms, pump_long, pump_now_req, pump_delayed_req), its tracker counters (trk_clip_reads,
trk_occl_reads, trk_clip_builds, trk_clip_hits, trk_clip_ms, trk_posts, trk_skips; None on builds without them), of the page's own animation
frames (page_frames), of `debug.layers` divider catcher panel updates and child window reorders (catcher_updates, reorders), and
the fork geometry posts per moving frame (posts_per_frame). A layout whose page never runs fails one row and is skipped.

Usage: pane-perf-terminal.py --tag <tag> --app PATH [--layouts 1x2,4x2,6x5] [--browser]
       [--actions split,close,column,zoom,drag,sidepanel,scroll,idle,page] [--rounds 3] [--scrollback 5000] [--stream]
       [--record] [--json PATH] [--out DIR] [--gate] [--missed-budget N]
"""
import argparse, glob, json, os, pathlib, signal, subprocess, sys, tempfile, time

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
opts, _unknown = parser.parse_known_args()
TAG, APP = opts.tag, os.path.abspath(opts.app.rstrip("/"))
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_launch import BenchApp, LaunchError  # noqa: E402  the shared GUI launch (session check, failure report)


def load_stress():
    """perf-stress-session.py as a module: the STRESS builder and the shared window placement."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("perf_stress_session", os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                                                   "perf-stress-session.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


STRESS_MODULE = load_stress()
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
STILL = ("drag", "sidepanel", "sidepanel-close", "scroll", "idle")  # actions that move no layout spring


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
    opened = action("openBrowser.chromium", {"url": pathlib.Path(path).resolve().as_uri()}, timeout=120)  # --out may be relative
    if isinstance(opened, dict) and opened.get("error"):
        return f"openBrowser.chromium refused: {opened['error']}"

    def ready():  # the focused tab: the page's once it lands
        reply = rpc("browser.page.eval", {"script": "document.readyState === 'complete' && window.__frames > 2"}, timeout=20)
        if isinstance(reply, dict) and reply.get("value") is True and reply.get("tab"):
            PROBE["tab"] = reply["tab"]
            return True
        return None
    if not wait(ready, 60, step=0.5):
        cef = rpc("debug.cef")
        cef = cef if isinstance(cef, dict) else {}
        return (f"the probe page never ran in a Chromium tab within 60 s (openBrowser.chromium {json.dumps(opened)[:160]}; "
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
            action("openBrowser.chromium", {"url": PAGE}, settle=1.5, timeout=120)
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


def perform(name):
    """Runs one action; returns an error string or None."""
    verbs = {"split": "splitRight", "split-down": "splitDown", "close": "closePane", "close-down": "closePane",
             "column": "newColumn", "column-close": "closePane", "zoom": "toggleSplitZoom", "unzoom": "toggleSplitZoom",
             "sidepanel": "switchRightSidebarToFiles", "sidepanel-close": "toggleRightSidebar",
             "page": "splitBrowserRight", "page-close": "closePane"}
    if name == "drag":
        return drag_divider()
    if name == "idle":
        time.sleep(1.0)  # test harness: nothing happens but the page's own animation
        return None
    if name == "scroll":
        if not PROBE.get("tab"):
            return "scroll needs --browser"
        return None if page_eval(SCROLL_SCRIPT) is True else "the page did not start its scroll"
    # The right sidebar shows without taking the keyboard, so the focused pane keeps it.
    reply = action(verbs[name], focus=not name.startswith("sidepanel"))
    return str(reply.get("error")) if isinstance(reply, dict) and reply.get("error") else None


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
    cef_before = rpc("debug.cef") if opts.browser else None  # outside the timed window, like the reads after it
    layers_before = first_window(rpc("debug.layers")) if opts.browser else None
    page_before = page_eval("window.__frames") if opts.browser else None
    rpc("debug.hangs", {"clear": True})
    rpc("debug.motion", {"action": "start"})
    rpc("debug.frames", {"action": "start"})
    rpc("debug.window_transition", {"action": "start"})
    error = perform(name)
    time.sleep(1.2)  # test harness: the springs land (rest is under 0.5 s) and the PTY owner answers
    trace = rpc("debug.window_transition", {"action": "stop"}) or {}
    frames = rpc("debug.frames", {"action": "stop"}) or {}
    motion = rpc("debug.motion", {"action": "stop"}) or {}
    hangs = rpc("debug.hangs") or {}
    work = (motion.get("work") or {}).get("clock", {}) if isinstance(motion, dict) else {}
    # Each Core Animation commit while recording (MotionCommitProbe): with Chromium pages, how long a page's
    # resize wait (fork API 27 resize sync) held the frame. None on builds without the probe.
    commit = (motion.get("work") or {}).get("ca.commit") if isinstance(motion, dict) else None
    moving = sum(1 for s in (motion.get("samples") or []) if s.get("name") == "layout.travel" and (s.get("v") or 0) > 0) \
        if isinstance(motion, dict) else 0
    hang_list = hangs.get("hangs") if isinstance(hangs, dict) else None
    result = {
        "label": label, "action": name, "error": error,
        "missed": frames.get("missed"), "frames_max_ms": frames.get("max_ms"), "frames_p99_ms": frames.get("p99_ms"),
        "frames_p50_ms": frames.get("p50_ms"), "frames_p95_ms": frames.get("p95_ms"), "frames": frames.get("frames"),
        "refresh_ms": frames.get("refresh_ms"), "moving_frames": moving,
        "layout_max_ms": work.get("max_ms"), "layout_p95_ms": work.get("p95_ms"), "layout_p50_ms": work.get("p50_ms"),
        "commit_p50_ms": (commit or {}).get("p50_ms"), "commit_p95_ms": (commit or {}).get("p95_ms"),
        "commit_max_ms": (commit or {}).get("max_ms"), "commit_over_4": (commit or {}).get("over_4_ms"),
        "commits": (commit or {}).get("frames"),
        "grid_reports": trace.get("terminal_grid_reports"), "resizes_sent": trace.get("terminal_resizes_sent"),
        "hangs": len(hang_list) if isinstance(hang_list, list) else hangs.get("count"),
    }
    extra = ""
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
        extra = (f"  pump {result['pump_runs']} runs {result['pump_ms']} ms long {result['pump_long']} "
                 f"req {result['pump_now_req']}/{result['pump_delayed_req']}  clip {result['trk_clip_reads']} reads "
                 f"{result['trk_clip_builds']} builds {result['trk_clip_hits']} hits {result['trk_clip_ms']} ms  occl {result['trk_occl_reads']}  "
                 f"posts {result['trk_posts']} ({result['posts_per_frame']}/frame) skips {result['trk_skips']}  "
                 f"catchers {result['catcher_updates']} reorders {result['reorders']}  page rAF {result['page_frames']}")
    print(f"  {label:<22} moved {moving:>3}  frame p50 {result['frames_p50_ms']} p95 {result['frames_p95_ms']} "
          f"p99 {result['frames_p99_ms']} max {result['frames_max_ms']} ms  missed {result['missed']} "
          f"(refresh {result['refresh_ms']})  tick p95 {result['layout_p95_ms']} max {result['layout_max_ms']} ms  "
          f"commit p95 {result['commit_p95_ms']} max {result['commit_max_ms']} ms  "
          f"grids {result['grid_reports']}/{result['resizes_sent']}  hangs {result['hangs']}  err {error}{extra}", flush=True)
    return result


SEQUENCE = {"split": ["split", "close"], "split-down": ["split-down", "close-down"], "close": [],
            "column": ["column", "column-close"], "zoom": ["zoom", "unzoom"], "drag": ["drag"],
            "sidepanel": ["sidepanel", "sidepanel-close"], "scroll": ["scroll"], "idle": ["idle"],
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
            "drag": ["drag"], "sidepanel": ["sidepanel", "sidepanel-close"],
            "sidepanel-close": ["sidepanel", "sidepanel-close"], "scroll": ["scroll"], "idle": ["idle"],
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
    os.makedirs(opts.out, exist_ok=True)
    # The shared launch (bench_launch.py): its bench environment, a session check that fails at once with
    # no-gui-session, the state-folder socket, and a BENCH-LAUNCH report (crash, sample, log tail) on failure.
    # The app activates and its window becomes key (no CMUX_NEXT_NO_ACTIVATE), as for a person; without
    # no-activate the app reads no test window placement, so the window is placed through the socket below.
    BENCH = BenchApp(APP, out=opts.out, config=CONFIG, env={"CMUX_NEXT_NO_ACTIVATE": None}, window=None, screen=None,
                     log_name=f"app-{TAG}.log")
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
    # The bench conditions: the environment the app was really started with (mocked agent chats, the
    # isolated chief, no CMUX_NEXT_NO_ACTIVATE), the window's placement, and per layout whether the window
    # was key when it started (`layouts`).
    conditions = {"env": BENCH.launched_env, "window": STRESS_MODULE.window_on_screen(placed) if isinstance(placed, dict) else None,
                  "layouts": {}}
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
        if name == "stress":
            # A bottom Dock over the window's lower edge, and chats the session replaced (none in STRESS).
            state.update(dock_overlap_pt=STRESS.get("dock_overlap_pt"), chat_fallbacks=STRESS.get("chat_fallbacks"))
        label = name if state["window_key"] else f"{name}-inactive"
        conditions["layouts"][label] = state
        print(f"  {name}: window key {state['window_key']}, frontmost {state['frontmost']} (rows named {label})", flush=True)
        labels.append(label)
        rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"{name}-before.png")})
        for index in range(opts.rounds):
            for step in sequence:
                if opts.browser and step not in ("close", "close-down", "column-close", "unzoom", "sidepanel-close", "page-close"):
                    focus_page()  # each pair starts on the Chromium pane
                run = measure(f"{panes:>2}p {step} #{index}", step)
                run.update(layout=label, panes=panes, round=index)
                report["runs"].append(run)
                row(f"{label} {step} #{index}: ran", "no error", str(run["error"]), run["error"] is None)
                if step not in STILL:
                    row(f"{label} {step} #{index}: animated (layout springs moved)", "> 0 frames",
                        str(run["moving_frames"]), (run["moving_frames"] or 0) > 0)
                missed = run["missed"]
                row(f"{label} {step} #{index}: missed frames" + ("" if opts.gate else " (info)"),
                    f"<= {opts.missed_budget}", str(missed), missed is not None and missed <= opts.missed_budget or not opts.gate)
                if opts.json:
                    json.dump(report, open(opts.json, "w"), indent=1)
                time.sleep(0.4)  # test harness: idle between runs
        for wanted in filter(None, opts.sample.split(",")):
            where, _, what = wanted.partition(":")
            if where == name:
                profile(what, f"{name}-{what}")
        if opts.record:
            for step in sequence:
                record(step, f"{name}-{step}")
    print("\n== summary (median over rounds)")
    browser_keys = BROWSER_KEYS if opts.browser else []
    wide = max([13] + [len(step) for step in sequence])  # sidepanel-close
    print(f"  {'panes':<5} {'action':<{wide}} {'p50':>6} {'p95':>6} {'p99':>6} {'max':>6} {'missed':>6} {'moved':>5} "
          f"{'tick95':>6} {'tickmx':>6} {'grids':>7}" + "".join(f" {h:>6}" for h in BROWSER_HEADS[:len(browser_keys)]))
    for name in labels:
        for step in sequence:
            runs = [r for r in report["runs"] if r["layout"] == name and r["action"] == step]

            def med(key):
                values = sorted(v for v in (r.get(key) for r in runs) if v is not None)
                return values[len(values) // 2] if values else None
            summary = {key: med(key) for key in ["frames_p50_ms", "frames_p95_ms", "frames_p99_ms", "frames_max_ms", "missed",
                                                 "moving_frames", "layout_p95_ms", "layout_max_ms", "grid_reports",
                                                 "resizes_sent", "commit_p95_ms", "commit_max_ms", "refresh_ms"] + browser_keys}
            report.setdefault("summary", []).append({"layout": name, "action": step, **summary})

            def f(v):
                return "-" if v is None else (f"{v:.1f}" if isinstance(v, float) else str(v))
            grids = f"{f(summary['grid_reports'])}/{f(summary['resizes_sent'])}"
            print(f"  {name:<5} {step:<{wide}} {f(summary['frames_p50_ms']):>6} {f(summary['frames_p95_ms']):>6} "
                  f"{f(summary['frames_p99_ms']):>6} {f(summary['frames_max_ms']):>6} {f(summary['missed']):>6} "
                  f"{f(summary['moving_frames']):>5} {f(summary['layout_p95_ms']):>6} {f(summary['layout_max_ms']):>6} "
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
