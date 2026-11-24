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
(`commit_frames`: the `layout.commit` samples; 0 on a build without them: only a build with the probe has them),
the samples of the pane trace in which a pane is not where it ends (`samples_in_a_move`: `debug.motion` trace through
each act of an arm's proof round, see below; the row `animated` reads it, and says NO SOURCE and fails when the build
gives no such trace and no frame of the 2 counts above), grids sent to the PTY owner
(`debug.window_transition`) and hangs (`debug.hangs`). With --record, a second pass records each action with
`debug.window_record` (frames/ in --out; the recording itself costs frames, so it never runs in the timed pass),
for --record-seconds each, with the pane trace through it (`debug.motion` trace: where each pane is at each display
tick) as trace.json beside the frames, a row that fails when the frames, their index or the trace are not there, and
a row that fails when no pane is in a move in 2 samples or more of that trace (the app showed the act in one frame).
With --record each pane's feed also ends with one line of text in a colour that no pixel of the window's backdrop
can have (`marker_color`, from the app's own answer): a reader of the stills tells text from the backdrop by it.
With --record-docked the pass goes on with a pane of a docked column: the focused pane's column is docked at the left
edge, and a split down, a zoom in, an unzoom and a close are recorded there (`record_docked`).
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
and its row `still` passes when no spring and no commit motion moved and the pane trace has 1 sample in a move at
the most. Without the option the app's own setting
runs one time and each row keeps its name.

The proof round. Before its timed rounds each arm runs its acts one time more, with the pane trace: the rows
`<layout> <act> proof round: animated (...)` (the off arm: `still`). That round is not timed and is in no number
(the report keeps it as `proof_rounds`). The timed rounds run with no pane trace: the trace's sampler works on the
main thread at each display tick, and a number of a round must stay comparable with each older round. An act with a
failed proof round has NO MOVE PROVED beside each of its numbers (the off arm: MOTION OFF NOT PROVED), in each round's
line, in the summary and as `move_proved` in the report, and its row fails the run.
The proof round's line and row say the move's rate too (`ticks` in the report): the count of the trace's samples
with a pane in a move, the median and the largest interval between them, and the refresh of the window's display
link. A median above 9 ms on a 120 Hz display prints MOVE AT HALF RATE; that is a print and fails no row. An
interval is between 2 ticks of the link on the main thread, with the trace's sampler on: it is not the time between
2 pictures on the display, and a move that the system animates with no tick of the app is not in it.
They say 2 times after the act too (`times` in the report): the first move, the first tick with a pane in a move, and
the visible end, the first tick at which each pane has 0.2 percent of its way or less left. The act's time is the
script's clock before it sends the act, so the control socket's time to the app is in both; a time is a tick's time.
A proof round of a split, a close, a zoom or an unzoom with the pane motion on and with no tick with a pane in a move
prints `first move: NONE`, and its row `a pane moves after the act` fails: that is not a missing number.
The line has the app's own spans of the act with a name that starts with `layout.` (count, sum, longest), if any.
Limits: the move is proved for an arm's settings in one round, not in each timed round. The row says that a pane's
rect moves: the 4 acts of the commit motion (split, close, zoom, unzoom) each move a pane's rect; New Column moves
no pane, only the strip camera (the same row holds it by the spring frames); at an unzoom the rings of the panes
that come back change their opacity with no rect move, and no row holds that (a reader of the --record stills
does); a pane that only fades at the place where it ends has 0 samples in a move and fails the row.

With --window-look KEY=VALUE[,KEY=VALUE...] the window has another look than the launch's opaque one, for example a
window with a picture background (`background=NAME,opacity=0.5,blur=none`, NAME a built-in picture). The option
writes the keys that it names and no other key, and no key has a default: `background`, `opacity` and `blur` are
`appearance.background`, `appearance.backgroundOpacity` and `appearance.backgroundBlur` of the app config;
`terminal-opacity` and `terminal-blur` are `background-opacity` and `background-blur` (a radius) of the terminal
config file, which the app also reads. The window is over the fixture's desktop, or with `behind=checker` (or
`stripes`) over the app's own patterned panel (`debug.capture_backdrop`). The report's conditions hold the look
(`window_look`) and in `resolved` what the running app itself says it shows: the background's kind and the
picture's id, the opacity (the alpha of the backdrop's tint, `debug.themes`) and the blur (the app's settings
answer: the debug read has no blur field). The row `the app shows the window's look` fails when that is not the
named look; the measures still run then, under the look's name. The conditions also list each window of another
app that is behind the window (`windows_behind`, from the screen's window list), and a run with a look has a row
that passes when there is none. Each row and summary of such a run is named <layout>-look-<each named key and its
value>, so it is never compared with an opaque window's rows. Without the option, or with `opaque`, the launch and
each row's name stay as they were. The option's keys are window_look.py's (this script has no parser of its own): a
key with a dot is any other path of the app's settings (`ui.animationSpeed=off`), and `name=WORD` is the look's
name, which a row's name then has in place of each value (<layout>-look-<name>). Each run, with a look or opaque,
prints `APP-SETTINGS` lines and keeps them in the conditions (`window_look.head`): each path that the launch wrote
with the app's own answer beside it, each other setting that the app holds, and the speed that its motion runs at.
`CLI-SETTINGS` lines (`window_look.cli`) are a try for the record: what the bundle's CLI answers for each path.
With a look, an argument that this script does not know ends the run before the app starts.

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
       [--record [--record-seconds S] [--record-layouts NAMES] [--record-docked]] [--json PATH] [--out DIR] [--gate] [--missed-budget N] [--pane-motion on,off]
       [--window-look opaque|KEY=VALUE[,KEY=VALUE...]]
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
parser.add_argument("--record-seconds", type=float, default=2.0,
                    help="--record: the length of each recording (0.2 s of it is before the action; 12 at most)")
parser.add_argument("--record-layouts", default="", help="--record: only these layouts (a list with commas; default: each)")
parser.add_argument("--record-docked", action="store_true",
                    help="--record: after a layout's recordings, the focused pane's column is docked at the left edge and a "
                         "split down, a zoom in, an unzoom and a close are recorded on a pane of it (not in the layout stress)")
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
                         "(`debug.motion` kind paneAnimations); the off arm's rows are named <layout>-motion-off")
parser.add_argument("--window-look", default=None,
                    help="opaque (the default: the launch as it was) or KEY=VALUE[,KEY=VALUE...] with background=NAME, "
                         "opacity=0..1, blur=frosted|glass|glass-clear|none (the app config), terminal-opacity=0..1, "
                         "terminal-blur=RADIUS (the terminal config file), behind=desktop|checker|stripes, "
                         "SETTINGS.PATH=VALUE (any other key of the app config) and name=WORD: only the named keys are "
                         "written; its rows are named <layout>-look-<the name, or each named key and its value>")
opts, _unknown = parser.parse_known_args()
TAG, APP = opts.tag, os.path.abspath(opts.app.rstrip("/"))
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_launch import BenchApp, LaunchError  # noqa: E402  the shared GUI launch (session check, failure report)
import bench_background  # noqa: E402  background daemon CPU per round (a reader drops a round over its limit)
import window_look as looks  # noqa: E402  the window's look: the option's keys, the launch's config, the app's own answers


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


def marker_color(backdrop):
    """The colour of the one text line that --record puts in each pane: [r, g, b], each channel 0 or 255, the end
    that is farther from what a pixel of the window's backdrop can show. `backdrop` is `debug.themes`'
    `windows[0].backdrop`: under a tint `#RRGGBBAA` of alpha A (the tint, or the glass's, or an opaque window's sheet
    with A = 1) a channel of the backdrop is between tint x A and tint x A + (1 - A) x 255, whatever is behind it. A
    reader of the stills takes a pixel outside that range as text; this line is far outside it in each pane. None
    when the backdrop has no such colour (it was not read)."""
    if not isinstance(backdrop, dict):
        return None
    text = next((backdrop.get(name) for name in ("tint", "glassTint", "sheet") if backdrop.get(name)), None)
    if not (isinstance(text, str) and len(text) in (7, 9) and text[0] == "#"):
        return None
    try:
        tint = [int(text[at:at + 2], 16) for at in (1, 3, 5)]
        alpha = int(text[7:9], 16) / 255 if len(text) == 9 else 1.0
    except ValueError:
        return None
    color = []
    for channel in tint:
        low = channel * alpha
        high = low + (1 - alpha) * 255
        color.append(255 if 255 - high >= low else 0)
    return color


def marker_command(color):
    """What a pane's feed goes on with to print the marker line in `color` (`marker_color`); nothing without one."""
    if not color:
        return ""
    return f"; printf '\\033[38;2;{color[0]};{color[1]};{color[2]}m%s\\033[0m\\n' 'the pane text of the stills'"


def stills_facts(trace, at_start, names):
    """What one recording of --record left for a reader of its stills: `frames` (the frame files among `names`, the
    recording folder's files), `index` (frames.json is there), `samples` and `samples_with_panes` of the pane trace
    that ran through it (`trace`: the reply of `debug.motion` trace_stop), `samples_at_record_start` (the samples of
    `at_start`, the trace read directly after the recorder's start: the first frame is the next sample or the one
    after it; None when it was not read), `presentation_rects` (each pane row of the trace has 22 numbers or more: a
    build with a sampler that says where a pane is in each sample, not only where it ends), `samples_in_a_move` (the
    samples in which a pane is not where it ends by more than 0.5 pt: 0 = the trace followed no move, and a reader
    has only where each pane ends) and `problem`: None, or what is missing (2 frames at the least, the index, a pane
    in each sample)."""
    frames = sum(1 for name in names if name.startswith("frame-") and name.endswith(".jpg"))
    samples = trace.get("samples") if isinstance(trace, dict) and isinstance(trace.get("samples"), list) else []
    rows = [row for sample in samples if isinstance(sample, dict) for row in sample.get("panes") or []]
    with_panes = sum(1 for sample in samples if isinstance(sample, dict) and sample.get("panes"))
    first = at_start.get("samples") if isinstance(at_start, dict) else None
    missing = ([f"{frames} frames"] if frames < 2 else []) + ([] if "frames.json" in names else ["no frames.json"])
    if not samples:
        missing.append(f"no sample in the pane trace: {trace!r}"[:200])
    elif with_panes != len(samples):
        missing.append(f"{with_panes} of {len(samples)} samples have a pane")
    # samples_in_a_move: `move_facts` (a pane IS not where it ends: its last 4 numbers against its first rect).
    return {"frames": frames, "index": "frames.json" in names, "samples": len(samples), "samples_with_panes": with_panes,
            "samples_at_record_start": len(first) if isinstance(first, list) else None,
            "presentation_rects": bool(rows) and all(isinstance(row, list) and len(row) >= 22 for row in rows),
            "samples_in_a_move": move_facts(trace)["samples_in_a_move"], "problem": "; ".join(missing) or None}


def pane_in_a_move(sample):
    """If a pane of one sample of the pane trace IS not where it ends, by more than 0.5 pt: a pane row's last 4
    numbers against its first rect. A row of fewer than 22 entries does not say where the pane is: not in a move."""
    def moves(row):
        return isinstance(row, list) and len(row) >= 22 and any(abs(now - end) > 0.5 for now, end in zip(row[-4:], row[1:5]))
    return isinstance(sample, dict) and any(moves(row) for row in sample.get("panes") or [])


def move_ticks(trace):
    """The rate of a move in a pane trace. A sample is one tick of the window's display link, and its `t` the link's
    own time of that tick: the link that steps the app's frame clients of that window. `ticks`: the samples with a
    pane in a move (`pane_in_a_move`); `median_ms` and `largest_ms`: of the intervals that end at such a sample (None
    below 2 ticks: a change in one frame is not a move); `refresh_ms`: the trace's own, one refresh of the link at
    its last tick (None when the trace does not say it); `half_rate`: the display is at 120 Hz (within 3 Hz) and the
    median is above 9 ms, so the move did not tick at each refresh.
    Limits: an interval is between 2 ticks of the link on the main thread, not between 2 pictures on the display; a
    move that the system animates with no tick of the app is not in it; the sampler has a cost at each tick."""
    samples = trace.get("samples") if isinstance(trace, dict) and isinstance(trace.get("samples"), list) else []
    marks = [(sample.get("t") if isinstance(sample, dict) else None, pane_in_a_move(sample)) for sample in samples]
    ticks = sum(1 for _, moving in marks if moving)
    gaps = sorted(now - before for (before, _), (now, moving) in zip(marks, marks[1:])
                  if moving and all(isinstance(at, (int, float)) and not isinstance(at, bool) for at in (before, now)))
    refresh = trace.get("refresh_ms") if isinstance(trace, dict) else None
    refresh = refresh if isinstance(refresh, (int, float)) and not isinstance(refresh, bool) and refresh > 0 else None
    if ticks < 2 or not gaps:
        return {"ticks": ticks, "median_ms": None, "largest_ms": None, "refresh_ms": refresh, "half_rate": False}
    middle = len(gaps) // 2
    median = round(gaps[middle] if len(gaps) % 2 else (gaps[middle - 1] + gaps[middle]) / 2, 2)
    return {"ticks": ticks, "median_ms": median, "largest_ms": round(gaps[-1], 2), "refresh_ms": refresh,
            "half_rate": refresh is not None and abs(1000.0 / refresh - 120) <= 3 and median > 9}


def ticks_said(ticks):
    """`move_ticks` as the text of a proof round's line and row. MOVE AT HALF RATE is a print: it fails no row."""
    if ticks["median_ms"] is None:
        return f"{ticks['ticks']} tick{'' if ticks['ticks'] == 1 else 's'} in the move: below 2, no rate of a move"
    rate = (f"the window's display link says {ticks['refresh_ms']} ms a refresh ({round(1000.0 / ticks['refresh_ms'])} Hz)"
            if ticks["refresh_ms"] else "the trace does not say the display's rate")
    return (f"{ticks['ticks']} ticks in the move, median interval {ticks['median_ms']} ms, largest {ticks['largest_ms']} ms; {rate}"
            + ("  MOVE AT HALF RATE" if ticks["half_rate"] else ""))


def move_times(trace, action_s):
    """When a move starts and ends after the act, by a pane trace. `action_s`: the script's uptime clock directly
    before it sends the act; the trace's `t0_s` is its first tick's host time on that clock, and a sample's `t` the
    ms after it. `first_move_ms`: from the act to the first tick with a pane in a move (`pane_in_a_move`).
    `visible_end_ms`: from the act to the first tick after that one at which each pane has 0.2 percent of its way or
    less left. A pane's way, for each of its rect's 4 numbers: its largest distance from its end from the first
    tick in a move on (a number that is 0.5 pt or less from its end in each tick has no way). `problem`: None, or
    why a time is not said.
    Limits: the act's time is the script's send, so the control socket's time to the app is in both times; a time
    is a tick's time, so one refresh is the grain; the sampler has a cost at each tick."""
    def number(value):
        return isinstance(value, (int, float)) and not isinstance(value, bool)

    def left(sample):  # how far each number of each pane's rect is from its end
        return {(row[0], at): abs(now - end) for row in sample.get("panes") or [] if isinstance(row, list) and len(row) >= 22
                for at, (now, end) in enumerate(zip(row[-4:], row[1:5]))}

    def none(problem):
        return {"first_move_ms": None, "visible_end_ms": None, "problem": problem}

    samples = trace.get("samples") if isinstance(trace, dict) and isinstance(trace.get("samples"), list) else []
    first = next((at for at, sample in enumerate(samples) if pane_in_a_move(sample)), None)
    if first is None:
        return none("no pane in a move in the trace")
    if not number(action_s):
        return none("the script has no time of the act")
    start, moved = trace.get("t0_s"), samples[first:]
    if not number(start) or not all(isinstance(sample, dict) and number(sample.get("t")) for sample in moved):
        return none("the trace does not say its ticks' host time")
    after = [round((start - action_s) * 1000 + sample["t"], 1) for sample in moved]
    if after[0] < 0:
        return none("the first move is before the act: the trace's clock is not the script's")
    lefts, way = [left(sample) for sample in moved], {}
    for one in lefts:
        for key, distance in one.items():
            way[key] = max(way.get(key, 0.0), distance)
    last = max(at for at, one in enumerate(lefts) if any(way[key] > 0.5 and distance > 0.002 * way[key] for key, distance in one.items()))
    end = after[last + 1] if last + 1 < len(after) else None
    return {"first_move_ms": after[0], "visible_end_ms": end, "problem": None if end is not None else "the trace ends in the move"}


def times_said(times):
    """`move_times` as the text of a proof round's line and row. No tick with a pane in a move: `first move: NONE`."""
    if times["first_move_ms"] is None:
        return "first move: NONE" if times["problem"] == "no pane in a move in the trace" else f"no time after the act: {times['problem']}"
    end = f"visible end {times['visible_end_ms']} ms after the act" if times["visible_end_ms"] is not None else f"no visible end: {times['problem']}"
    return f"first move {times['first_move_ms']} ms after the act, {end} (the act's time is the script's send; a time is a tick's)"


def first_move_row(arm, act, times):
    """The row `a pane moves after the act` of a proof round: (its name, what it expects, what it saw, passed), or
    None for the arm with the pane motion off and for an act that is not one of the 4 acts of the commit motion (New
    Column moves the strip camera only). `times`: the act's `move_times`. A round in which no tick has a pane in
    a move fails: `first move: NONE` is not a missing number. A move with no time (a trace with no clock) passes,
    and the row says why it has no time."""
    if arm == "off" or act not in ("split", "close", "zoom", "unzoom"):
        return None
    none = times["problem"] == "no pane in a move in the trace"
    seen = (times_said(times) if none else f"first move {times['first_move_ms']} ms after the act" if times["first_move_ms"] is not None
            else f"a pane moves; {times_said(times)}")
    return ("proof round: a pane moves after the act", "a tick with a pane in a move", seen, not none)


def parts_said(parts):
    """`layout_spans` of an act (the app's own spans with a name that starts with `layout.`) as the text of a proof
    round's line: each part's count, sum and longest one with its start. A build with no such span: no text."""
    return "".join(f"; {name} {part['count']} x, sum {part['sum_ms']} ms, max {part['max_ms']} ms at {part['max_at_ms']} ms"
                   for name, part in sorted((parts or {}).items()))


def move_facts(trace):
    """What a pane trace (the reply of `debug.motion` trace_stop) says of a move: `samples`, `samples_in_a_move` (the
    samples in which a pane IS not where it ends by more than 0.5 pt: a pane row's last 4 numbers against its first
    rect) and `no_source`: None, or why this trace cannot say if a pane moved (no sample, no pane in a sample, or a
    build with a sampler that says only where a pane ends: a pane row of fewer than 22 entries)."""
    samples = trace.get("samples") if isinstance(trace, dict) and isinstance(trace.get("samples"), list) else []
    rows = [row for sample in samples if isinstance(sample, dict) for row in sample.get("panes") or []]
    in_a_move = sum(1 for sample in samples if pane_in_a_move(sample))
    if not samples:
        no_source = f"no sample in the pane trace: {trace!r}"[:200]
    elif not rows:
        no_source = f"no pane in the {len(samples)} samples of the pane trace"
    elif not all(isinstance(row, list) and len(row) >= 22 for row in rows):
        no_source = "the build's pane trace does not say where a pane is in a sample (a pane row of fewer than 22 entries)"
    else:
        no_source = None
    return {"samples": len(samples), "samples_in_a_move": in_a_move, "no_source": no_source}


def animated_row(arm, moving, committed, move, notes):
    """The row of one timed act that says if the act moved: (its name, what it expects, what it saw, passed).
    `move`: `move_facts` of the pane trace that ran through the act; `moving` and `committed`: `moving_frames` and
    `commit_frames` of the same act (the app's own samples; `layout.commit` is only in a build with the probe).
    With the motion on (`arm` on, or None: the app's own setting) the act is animated when a pane is in a move in 2
    samples or more (a change that the app shows in one frame has 1 sample at the most: a new pane's first sample),
    or a spring or commit frame is there (New Column moves only the strip camera, and no pane). With the motion off
    it is still with 1 sample at the most and no such frame. A row with no source (no trace that says where a pane
    is, and no frame of the app's samples) says NO SOURCE and fails: it does not say that the app did not move."""
    counts = f"{moving} spring frames, {committed} commit frames"
    seen = (f"NO SOURCE: {move['no_source']}; {counts}" if move["no_source"]
            else f"{move['samples_in_a_move']} of {move['samples']} samples of the pane trace in a move; {counts}")
    traced = not move["no_source"]
    if arm == "off":
        return ("still (the pane motion is off)", "1 sample in a move at the most, 0 frames", seen,
                traced and move["samples_in_a_move"] <= 1 and not moving and not committed)
    animated = (moving or 0) > 0 or (committed or 0) > 0 or (traced and move["samples_in_a_move"] >= 2)
    return ("animated (a pane's rect moves in the pane trace, or a layout spring, the strip camera or a commit motion moved)",
            "2 samples in a move or more, or above 0 frames", seen + ("" if animated or not traced else f"; the app's notes: {list(notes)[:4]}"),
            animated)


def proof_round_row(arm, run):
    """The row of one act of an arm's proof round: (its name, what it expects, what it saw, passed). `run`: that
    act's `measure` with `proof`. The rule is `animated_row`'s. The limit is in the row's own text: the timed
    rounds of the arm run with no trace, so the move is proved for the arm's settings, not for each timed round."""
    said, expected, seen, passed = animated_row(arm, run["moving_frames"], run["commit_frames"], run["move"], run["commit_notes"])
    rate = "" if run["move"]["no_source"] else f"; {ticks_said(run['ticks'])}; {times_said(run['times'])}"  # prints, no part of `passed`
    return (f"proof round: {said}",
            f"{expected} (the move is proved for this arm's settings in one round, not in each timed round)", seen + rate, passed)


def proof_mark(arm, passed):
    """What each number of a timed round gets beside it: nothing when the same act of the arm's proof round passed,
    else NO MOVE PROVED (the off arm: MOTION OFF NOT PROVED). `passed` None: the proof round did not run the act."""
    if passed:
        return ""
    return "MOTION OFF NOT PROVED" if arm == "off" else "NO MOVE PROVED"


def stills_clock(index, trace):
    """Where the first frame of one recording is on the pane trace's clock. `index`: the recorder's frames.json;
    its `t0_s` is the first frame's host time, and a frame's host time is `t0_s` + its entry of `times`. `trace`:
    the reply of trace_stop; its `t0_s` is its first sample's host time and each sample's `t` the ms after it. The
    recorder starts after the trace and ends before it, so a `t0_s` on the trace's clock is from the trace's first
    sample to its last one, and not farther from the trace's `t0_s` than the recording is long (the suite starts
    the recorder 0.1 s after the trace). `clock_problem`: None, or why a reader cannot place the frames in the
    trace by time."""
    def number(value):
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    first = index.get("t0_s") if isinstance(index, dict) and number(index.get("t0_s")) else None
    times = index.get("times") if isinstance(index, dict) else None
    start = trace.get("t0_s") if isinstance(trace, dict) and number(trace.get("t0_s")) else None
    samples = trace.get("samples") if isinstance(trace, dict) and isinstance(trace.get("samples"), list) else []
    stamps = [sample.get("t") for sample in samples if isinstance(sample, dict) and number(sample.get("t"))]
    inside, problem = None, None
    if not isinstance(index, dict):
        problem = "frames.json was not read"
    elif first is None:
        problem = "frames.json has no t0_s (the recorder does not say its first frame's host time)"
    elif not (isinstance(times, list) and len(times) >= 2 and number(times[1]) and times[1] > 0):
        problem = f"no second frame after the first (times {times!r})"[:120]
    elif start is None:
        problem = "the trace has no t0_s"
    elif not stamps:
        problem = "the trace has no sample"
    else:
        end = round(start + max(stamps) / 1000, 6)
        inside = round((first - start) * 1000, 2)
        length = max(value for value in times if number(value))
        if not start <= first <= end:
            problem = f"t0_s {first} is not inside the trace ({start} to {end}): not the trace's clock"
        elif first - start > length:
            problem = (f"t0_s {first} is {round(first - start, 3)} s after the trace's t0_s {start}, more than the "
                       f"recording's length {round(length, 3)} s: 2 clocks")
    return {"first_frame_t0_s": first, "trace_t0_s": start, "first_frame_in_trace_ms": inside, "clock_problem": problem}


def stills_cost(recorded, rounds):
    """The missed refreshes of one recorded act (the pane trace and the recorder run through it) beside those of
    the timed rounds of the same act with the motion on (no trace, no recorder), each from the same probe over the
    same 1.2 s after the act. A trace that makes the motion late shows here: `more_than_each_round` (None when
    one side has no count). No time of a recorded act is a number of the suite."""
    known = [value for value in rounds if isinstance(value, (int, float))]
    counted = isinstance(recorded, (int, float))
    more = recorded > max(known) if counted and known else None
    text = (f"{recorded} missed refreshes with the trace and the recorder" if counted
            else "the missed refreshes of the recorded act were not counted")
    text += f"; the timed rounds of the same act: {known}" if known else "; no timed round of the same act with the motion on"
    return {"missed_refreshes": recorded if counted else None, "rounds_missed_refreshes": known, "more_than_each_round": more,
            "text": text + (" = MORE THAN EACH ROUND" if more else "")}


MARKER = []  # --record: the marker line's colour, one time, after the app said what its window shows (main)


def feed(stream=False):
    text = f"seq 1 {opts.scrollback}{marker_command(MARKER[0] if MARKER else None)}\r" if opts.scrollback else ""
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
    if not all(arm in ("on", "off") for arm in arms) or len(set(arms)) != len(arms):
        raise ValueError(f"--pane-motion takes on, off or on,off, not {value!r}")
    return arms


def set_pane_motion(on):
    """Sets `ui.paneAnimations` in the running app (`debug.motion` kind); returns an error string or None."""
    reply = rpc("debug.motion", {"action": "kind", "name": "paneAnimations", "value": on})
    seen = reply.get("pane_animations") if isinstance(reply, dict) else None
    return None if seen is on else f"pane_animations is {seen!r} after the call, not {on!r}"


def screen_windows():
    """Each on-screen window, front to back: layer, pid, owner and bounds {x, y, width, height} in top-left points
    (CGWindowList without the desktop's own elements: bounds, layers and owner names need no grant)."""
    import ctypes
    cg = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    cf = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    pointer = ctypes.c_void_p
    cg.CGWindowListCopyWindowInfo.restype, cg.CGWindowListCopyWindowInfo.argtypes = pointer, [ctypes.c_uint32, ctypes.c_uint32]
    cf.CFArrayGetCount.restype, cf.CFArrayGetCount.argtypes = ctypes.c_long, [pointer]
    cf.CFArrayGetValueAtIndex.restype, cf.CFArrayGetValueAtIndex.argtypes = pointer, [pointer, ctypes.c_long]
    cf.CFDictionaryGetValue.restype, cf.CFDictionaryGetValue.argtypes = pointer, [pointer, pointer]
    cf.CFStringCreateWithCString.restype = pointer
    cf.CFStringCreateWithCString.argtypes = [pointer, ctypes.c_char_p, ctypes.c_uint32]
    cf.CFStringGetCString.restype = ctypes.c_bool
    cf.CFStringGetCString.argtypes = [pointer, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
    cf.CFNumberGetValue.restype, cf.CFNumberGetValue.argtypes = ctypes.c_bool, [pointer, ctypes.c_int, pointer]
    cf.CFRelease.argtypes = [pointer]
    keys = {}

    def value(record, name):
        if name not in keys:
            keys[name] = cf.CFStringCreateWithCString(None, name.encode(), 0x08000100)  # UTF-8
        return cf.CFDictionaryGetValue(record, keys[name]) if record else None

    def number(record, name):
        found, out = value(record, name), ctypes.c_double()
        return out.value if found and cf.CFNumberGetValue(found, 13, ctypes.byref(out)) else 0.0  # a double

    listed = cg.CGWindowListCopyWindowInfo(1 | 16, 0)  # on screen only, no desktop elements
    windows = []
    try:
        for index in range(cf.CFArrayGetCount(listed) if listed else 0):
            record = cf.CFArrayGetValueAtIndex(listed, index)
            name, text = value(record, "kCGWindowOwnerName"), ctypes.create_string_buffer(256)
            bounds = value(record, "kCGWindowBounds")
            windows.append({"layer": int(number(record, "kCGWindowLayer")), "pid": int(number(record, "kCGWindowOwnerPID")),
                            "owner": text.value.decode(errors="replace") if name and cf.CFStringGetCString(name, text, 256, 0x08000100) else None,
                            "bounds": {key: number(bounds, key[0].upper() + key[1:]) for key in ("x", "y", "width", "height")}})
    finally:
        for made in [listed, *keys.values()]:
            if made:
                cf.CFRelease(made)
    return windows


def windows_behind(windows, pid):
    """The windows of other apps that are behind the app's window: from `screen_windows` (front to back), each
    window in the normal layer of another process that is below the app's largest normal window and under a part of
    it. None when the list has no window of the app."""
    mine = [window for window in windows if window["pid"] == pid and window["layer"] == 0]
    if not mine:
        return None
    main = max(mine, key=lambda window: window["bounds"]["width"] * window["bounds"]["height"])
    a = main["bounds"]

    def under(b):
        return (b["x"] < a["x"] + a["width"] and a["x"] < b["x"] + b["width"]
                and b["y"] < a["y"] + a["height"] and a["y"] < b["y"] + b["height"])
    below = windows[next(index for index, window in enumerate(windows) if window is main) + 1:]
    return [{"owner": window["owner"], "bounds": window["bounds"]} for window in below
            if window["pid"] != pid and window["layer"] == 0 and under(window["bounds"])]


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


def measure(label, name, proof=False, mark=""):
    """One act, measured. `proof`: the act of a proof round: it runs with the pane trace (an act that moves a pane),
    its line says that it is not timed, and its numbers go into no summary. A timed round runs with no pane trace:
    the trace's sampler costs main-thread time at each display tick. `mark`: `proof_mark` of the act's arm."""
    global WINDOW_RESTORE
    window_geometry = first_window(rpc("debug.layers")) if name in WINDOW_ACTIONS else {}
    window_before = window_geometry.get("frame")
    if name == "window-zoom":
        WINDOW_RESTORE = window_before
    proof = proof and name not in STILL
    traced = name in WINDOW_ACTIONS or proof  # a window act: the window's size; a proof round's act that moves a pane: the panes
    if traced:
        rpc("debug.motion", {"action": "trace_start", "targets": ["window"] if name in WINDOW_ACTIONS else ["panes"]})
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
    stopped_trace = rpc("debug.motion", {"action": "trace_stop"}) if traced else None
    window_trace = stopped_trace if name in WINDOW_ACTIONS else None
    move = move_facts(stopped_trace) if proof else None  # the proof round's row reads it (proof_round_row)
    ticks = move_ticks(stopped_trace) if proof else None  # the move's rate, from the same trace
    times = move_times(stopped_trace, action_s) if proof else None  # the first move and the visible end after the act
    hangs = rpc("debug.hangs") or {}
    work = (motion.get("work") or {}).get("clock", {}) if isinstance(motion, dict) else {}
    # Each Core Animation commit while recording (MotionCommitProbe): with Chromium pages, how long a page's
    # resize wait (fork API 27 resize sync) held the frame. None on builds without the probe.
    commit = (motion.get("work") or {}).get("ca.commit") if isinstance(motion, dict) else None
    moving = moving_frames(motion.get("samples")) if isinstance(motion, dict) else 0
    committed = commit_frames(motion.get("samples")) if isinstance(motion, dict) else 0
    late = late_frames(frames, action_s)
    hang_list = hangs.get("hangs") if isinstance(hangs, dict) else None
    result = {
        "label": label, "action": name, "error": error,
        "missed": frames.get("missed"), "frames_max_ms": frames.get("max_ms"), "frames_p99_ms": frames.get("p99_ms"),
        "frames_p50_ms": frames.get("p50_ms"), "frames_p95_ms": frames.get("p95_ms"), "frames": frames.get("frames"),
        "refresh_ms": frames.get("refresh_ms"), "moving_frames": moving, "commit_frames": committed, "move": move, "ticks": ticks, "times": times, "proof": proof,
        "samples_in_a_move": move["samples_in_a_move"] if move and not move["no_source"] else None, **late,
        "commit_notes": commit_notes(motion.get("notes")) if isinstance(motion, dict) else [],
        "commit_placements": commit_placements(motion.get("samples"), motion.get("notes")) if isinstance(motion, dict) else [],
        "layout_spans": layout_spans(motion.get("spans")) if isinstance(motion, dict) else {},
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
    if proof:
        said = (f"NO SOURCE: {move['no_source']}" if move["no_source"]
                else f"{move['samples_in_a_move']} of {move['samples']} samples of the pane trace in a move; {ticks_said(ticks)}; {times_said(times)}"
                     f"{parts_said(result.get('layout_spans'))}")
        print(f"  {label:<22} proof round (not timed, not in the numbers): {said}; moved {moving} commit {committed}  err {error}", flush=True)
        return result
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
        parts = ", ".join(f"{part} {facts['count']}x sum {facts['sum_ms']} max {facts['max_ms']} ms"
                          for part, facts in sorted(result["layout_spans"].items()))
        extra += f"  commit note after its tick's start [{placed}]  parts [{parts}]"
    print(f"  {label:<22} moved {moving:>3} commit {committed:>3}  frame p50 {result['frames_p50_ms']} p95 {result['frames_p95_ms']} "
          f"p99 {result['frames_p99_ms']} max {result['frames_max_ms']} ms  missed {result['missed']} "
          f"long intervals = {late['missed_refreshes']} refreshes [{where}] (refresh {result['refresh_ms']})  "
          f"main max {late['main_max_ms']} ms  tick p95 {result['layout_p95_ms']} max {result['layout_max_ms']} ms  "
          f"commit p95 {result['commit_p95_ms']} max {result['commit_max_ms']} ms  "
          f"grids {result['grid_reports']}/{result['resizes_sent']}  hangs {result['hangs']}  "
          f"background {background_cpu['total_s']} s{' OVER LIMIT' if background_cpu['over_limit'] else ''}  err {error}{extra}"
          + (f"  {mark}" if mark else ""), flush=True)
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


def record(name, label, rounds=()):
    """One recording of `name` (an untimed pass): the window's frames (`debug.window_record`), and through them the
    pane trace (`debug.motion` trace: where each pane is at each display tick), kept beside the frames as
    trace.json. A reader compares the stills of the move with the stills at rest before and after it. The row fails
    when the frames, their index or the trace are not there. A second row fails when the recorder's index does not
    say its first frame's host time, or says one that is not inside the trace (`stills_clock`). `rounds`: the missed
    refreshes of the timed rounds of the same act with the motion on; the recorded act's own count (the frame probe
    over the same 1.2 s after the act) is printed beside them (`stills_cost`). Returns what trace.json keeps, less
    the trace."""
    folder = os.path.join(opts.out, "frames", label.replace(" ", "-"))
    rpc("debug.motion", {"action": "trace_start", "targets": ["panes", "window"]})  # the window's size: a still's scale
    time.sleep(0.1)  # test harness: the trace has samples at rest before the recorder starts
    reply = rpc("debug.window_record", {"dir": folder, "seconds": opts.record_seconds})
    at_start = rpc("debug.motion", {"action": "trace_read"})
    if isinstance(reply, dict) and reply.get("error"):
        print(f"  (no recording of {label}: {reply['error']})", flush=True)
    time.sleep(0.2)  # test harness: the recorder takes its first frame at rest
    rpc("debug.frames", {"action": "start"})
    action_s = time.monotonic()  # the uptime clock, as in a timed round (measure)
    error = perform(name)
    time.sleep(1.2)  # test harness: the same time after the act as a timed round has (measure)
    late = late_frames(rpc("debug.frames", {"action": "stop", "raw": True}) or {}, action_s)
    time.sleep(max(0.0, opts.record_seconds - 1.2) + 0.2)  # test harness: the recording stops by itself
    trace = rpc("debug.motion", {"action": "trace_stop"})
    deadline = time.monotonic() + 10
    while not os.path.exists(os.path.join(folder, "frames.json")) and time.monotonic() < deadline:
        time.sleep(0.25)  # test harness: the recorder's own queue writes its index after its last frame
    facts = stills_facts(trace, at_start, os.listdir(folder) if os.path.isdir(folder) else [])
    try:
        index = json.load(open(os.path.join(folder, "frames.json")))
    except (OSError, ValueError):
        index = None
    clock = stills_clock(index, trace)
    cost = stills_cost(late["missed_refreshes"], rounds)
    kept = {"act": name, "label": label, "error": error, "seconds": opts.record_seconds, **facts, **clock, "cost": cost}
    print(f"  {label}: recorded: {cost['text']}", flush=True)
    if os.path.isdir(folder):
        json.dump({**kept, "trace": trace}, open(os.path.join(folder, "trace.json"), "w"))
    seen = ", ".join(f"{key.replace('_', ' ')} {value}" for key, value in facts.items() if key != "problem")
    row(f"{label}: the recording has its frames, its index and a pane trace", "2 frames or more, frames.json, a pane in each sample",
        f"{facts['problem'] or 'each is there'} ({seen})" + (f"; the act: {error}" if error else ""), not facts["problem"] and not error)
    row(f"{label}: the recording's first frame has a host time inside the pane trace", "frames.json's t0_s from the trace's first sample to its last",
        clock["clock_problem"] or f"{clock['first_frame_in_trace_ms']} ms after the trace's first sample", not clock["clock_problem"])
    if name not in STILL:  # the pass has the pane motion on: an act that the app shows in one frame fails here
        move = move_facts(trace)
        row(f"{label}: a pane is in a move in the recording's pane trace", "2 samples in a move or more",
            f"NO SOURCE: {move['no_source']}" if move["no_source"] else f"{move['samples_in_a_move']} of {move['samples']} samples in a move",
            not move["no_source"] and move["samples_in_a_move"] >= 2)
    return kept


def theme_facts(themes):
    """What `debug.themes` says of the theme that the app resolved: the first window's theme (`spec`, `effective_spec`,
    `source`), its background color, `is_dark` and its appearance's name, the theme of each terminal's surface (each
    name one time), and the terminal's own background color. Only `problem` when the answer names no window."""
    windows = themes.get("windows") if isinstance(themes, dict) else None
    window = windows[0] if isinstance(windows, list) and windows and isinstance(windows[0], dict) else None
    if window is None:
        return {"problem": f"no window in debug.themes: {str(themes)[:120]}"}
    terminals = themes.get("terminals") if isinstance(themes.get("terminals"), list) else []
    return {"problem": None,
            **{name: window.get(name) for name in ("spec", "effective_spec", "source", "window_background", "is_dark", "appearance")},
            "surface_themes": sorted({str(terminal.get("surface_theme")) for terminal in terminals if isinstance(terminal, dict)}),
            "terminal_background": themes.get("ghostty_background")}


def cli_settings(cli, paths, env, run=None):
    """What the bundle's own CLI says for each settings path of `paths` (the look's): `config get PATH`, and
    `settings get PATH` when the CLI refuses the first word. One line for each call: the exit code and the first 300
    characters of what it printed. A try for the record, in the launch's own environment: it reads only, it fails
    no row, and a CLI that is not there or gives no answer in 10 s is said in the line."""
    lines = []
    run = run or subprocess.run
    environment = {name: value for name, value in {**os.environ, **env}.items() if isinstance(value, str)}
    for path in paths:
        for word in ("config", "settings"):
            done = None
            try:
                done = run([cli, "--json", word, "get", path], capture_output=True, text=True, timeout=10, env=environment)
                said = f"exit {done.returncode}: {' '.join((done.stdout or done.stderr or '').split())[:300]}"
            except (OSError, subprocess.SubprocessError) as error:
                said = f"not run: {error!r}"[:300]
            lines.append(f"{word} get {path}: {said}")
            if done is not None and done.returncode == 0:
                break
    return lines


def docked_state(reply):
    """What `debug.dock` says of the window's docked columns (`reply`), for --record-docked: `columns` (each column
    of each window's active screen as `EDGE MODE, shown or not shown, N panes`), `panes` (the panes of the ONE shown
    column in the docked mode) and `problem`: None when there is exactly one such column with a pane, else why not.
    A column in the overlay mode and the strip have another ground under a pane, so they are not the fixture."""
    if not isinstance(reply, dict):
        return {"problem": f"no reply of debug.dock: {reply!r}"[:200], "columns": [], "panes": []}
    windows = reply.get("windows") if isinstance(reply.get("windows"), list) else []
    found = [column for window in windows if isinstance(window, dict)
             for column in ((window.get("screen") or {}).get("dock") or []) if isinstance(column, dict)]
    columns = [f"{c.get('edge')} {c.get('mode')}, {'shown' if c.get('shown') else 'not shown'}, {len(c.get('panes') or [])} panes"
               for c in found]
    fixture = [c for c in found if c.get("mode") == "docked" and c.get("shown") and c.get("panes")]
    if reply.get("error"):
        problem = str(reply["error"])[:200]
    elif reply.get("supported") is False:
        problem = "the daemon does not serve dock columns"
    elif not isinstance(reply.get("windows"), list):
        problem = f"debug.dock names no window: {reply!r}"[:200]
    elif not found:
        problem = "no docked column"
    elif not fixture:
        problem = "no shown column in the docked mode with a pane"
    elif len(fixture) > 1:
        problem = f"{len(fixture)} columns in the docked mode: 1 is the fixture"
    else:
        problem = None
    return {"problem": problem, "columns": columns, "panes": list(fixture[0]["panes"]) if not problem else []}


DOCKED = ("split-down", "zoom", "unzoom", "close-down")  # --record-docked: the acts on a pane of the docked column


def record_docked(name):
    """--record-docked, after the layout's own recordings: the focused pane's column goes to the window's left edge
    (`column.dockLeft`: the app docks the column, or moves the pane's tab into a new docked column), and when
    `debug.dock` then shows one column in the docked mode (`docked_state`; a failed row if not), one recording of each
    act of DOCKED with the focus in it: a split down, a zoom in, an unzoom, a close. Each recording keeps
    `docked_panes`, the column's panes after its act. Then `column.undock`. Returns the recordings by label."""
    label = f"{name}-docked"
    reply = action("column.dockLeft", settle=1.5)
    refused = str(reply.get("error")) if isinstance(reply, dict) and reply.get("error") else None
    state = docked_state(rpc("debug.dock"))
    problem = refused or state["problem"]
    row(f"{label}: the focused pane is in a column in the docked mode", "1 shown column in the docked mode, with a pane",
        f"{problem or 'it is'} (columns: {state['columns']})", not problem)
    acts = {}
    if problem:
        return acts
    for step in DOCKED:
        kept = record(step, f"{label}-{step}")
        kept["docked_panes"] = docked_state(rpc("debug.dock"))["panes"]
        acts[f"{label}-{step}"] = kept
    back = action("column.undock", settle=0.8)
    if isinstance(back, dict) and back.get("error"):
        print(f"  {label}: the column did not go back to the strip: {back['error']}", flush=True)
    return acts


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
    look = looks.window_look(opts.window_look)  # so does another word for the window's look
    if look and _unknown:
        # A value with a space that came as 2 arguments would be cut with no word: no measure of half a look.
        raise ValueError(f"--window-look came with arguments that this script does not know: {_unknown}")
    os.makedirs(opts.out, exist_ok=True)
    # The shared launch (bench_launch.py): its bench environment, a session check that fails at once with
    # no-gui-session, the state-folder socket, and a BENCH-LAUNCH report (crash, sample, log tail) on failure.
    # The app activates and its window becomes key (no CMUX_NEXT_NO_ACTIVATE), as for a person; without
    # no-activate the app reads no test window placement, so the window is placed through the socket below.
    BENCH = BenchApp(APP, out=opts.out, config=looks.look_config(CONFIG, look), env={"CMUX_NEXT_NO_ACTIVATE": None},
                     window=None, screen=None, log_name=f"app-{TAG}.log")
    if looks.look_terminal_lines(look):
        # A look's named terminal lines: the launch opens this file to append, so they stay in it.
        with open(os.path.join(BENCH.scratch, "ghostty"), "w") as terminal_config:
            terminal_config.write("\n".join(looks.look_terminal_lines(look)) + "\n")
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
        # No row of a look from the launch's opaque window: the launch's own config files hold the look, or the run ends.
        problem = looks.look_problem(look, BENCH.launched_env or {})
        if not problem and look.get("behind", "desktop") != "desktop":
            behind = rpc("debug.capture_backdrop", {"pattern": look["behind"]})  # before the app takes the front
            if not (isinstance(behind, dict) and behind.get("backdrop_number")):
                problem = f"no {look['behind']} panel behind the window: {behind}"
        row("the launch's config holds the window's look", looks.look_tag(look), problem or "each named key and line", problem is None)
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
    # The window's look: its named keys, what the window is over, and what the app itself says it shows and holds
    # (window_look.py `shown_look`: `debug.themes`' backdrop, the app's own settings answers and the speed that its
    # motion runs at). A picture loads and a tint blends after the launch: a look waits for them (test harness: at
    # most 10 s); an opaque window is read one time.
    seen, look_fault = looks.shown_look(rpc, look)
    resolved, shown = seen["resolved"], seen["backdrop_shown"]
    conditions["window_look"] = {"look": looks.look_tag(look) or "opaque", **(look or {}),
                                 "terminal_config": looks.look_terminal_lines(look), "resolved": resolved, "backdrop_shown": shown,
                                 "terminal_background": seen["terminal_background"]}
    # The report's head: each key that the launch wrote with the app's own answer, and each other setting the app holds.
    conditions["window_look"]["head"] = looks.look_head(look, seen)
    for line in conditions["window_look"]["head"]:
        print("APP-SETTINGS " + line, flush=True)
    # The theme that the app resolved (the settings answer has only its name): what the window and the terminals draw with.
    conditions["window_look"]["theme"] = theme_facts(rpc("debug.themes"))
    print("APP-THEME " + json.dumps(conditions["window_look"]["theme"]), flush=True)
    conditions["window_look"]["cli"] = cli_settings(CLI, looks.look_paths(look), BENCH.launched_env or {})
    for line in conditions["window_look"]["cli"]:
        print("CLI-SETTINGS " + line, flush=True)
    if look:
        row("the app shows the window's look", looks.look_tag(look),
            look_fault or f"{resolved['background']} {resolved['picture']!r}, opacity {resolved['opacity']}, blur {resolved['blur']!r}",
            look_fault is None)
    try:
        others = windows_behind(screen_windows(), app.pid)
    except Exception as error:  # noqa: BLE001  a read for the record: no failure of it ends a measure
        others = f"not read: {error!r}"
    conditions["window_look"]["windows_behind"] = others
    if look:
        conditions["window_look"]["over"] = "the fixture's desktop" if behind is None else behind
        row("no window of another app is behind the window with the look", "none", str(others)[:300], others == [])
    if opts.record:
        # Each pane's feed ends with one line in a colour that the window's backdrop cannot show (by the app's answer).
        MARKER.append(marker_color(shown))
        conditions["stills"] = {"marker_color": MARKER[0], "record_seconds": opts.record_seconds,
                                # The layouts are built one time: the timed rounds of this run have the line too.
                                "scene": "each pane that the suite feeds has 1 line more than in a run without --record "
                                         "(the stills' marker line), in the timed rounds of this run too"}
        print(f"STILLS SCENE: {conditions['stills']['scene']}", flush=True)
        row("--record: the marker line has a colour", "a colour far from the backdrop's, by the app's answer", str(MARKER[0]), MARKER[0] is not None)
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
        label = f"{name}-{looks.look_tag(look)}" if look else name  # a look's rows say each of its named values
        label = label if state["window_key"] else f"{label}-inactive"
        # One pass for each arm in each round (--pane-motion): the off arm's rows are named <label>-motion-off.
        tags = {arm: label if arm != "off" else f"{label}-motion-off" for arm in arms or [None]}
        for tag in tags.values():
            conditions["layouts"][tag] = state
        print(f"  {name}: window key {state['window_key']}, frontmost {state['frontmost']} (rows named {', '.join(tags.values())})", flush=True)
        labels += tags.values()
        rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"{name}-before.png")})
        # The proof round: each arm runs its acts one time FIRST, with the pane trace. It is not timed and not in
        # the numbers; its row says if the arm's acts moved (or stayed still, the off arm). The timed rounds after
        # it run with no trace.
        proved = {}
        for arm in tags:
            label = tags[arm]
            problem = set_pane_motion(arm == "on") if arm else None
            if problem:
                row(f"{label} proof round: the pane motion is {arm}", "the app took the setting", problem, False)
                continue
            for step in sequence:
                if step in STILL or not_applicable(step, columns if name != "stress" else None):
                    continue
                if opts.browser and step not in ("close", "close-down", "column-close", "unzoom", "window-unzoom", "page-close"):
                    focus_page()  # each pair starts on the Chromium pane
                run = measure(f"{panes:>2}p {step} proof" + (f" {arm}" if arm else ""), step, proof=True)
                report.setdefault("proof_rounds", []).append({
                    "layout": label, "action": step, "pane_motion": arm, "error": run["error"], "move": run["move"], "ticks": run["ticks"],
                    "times": run["times"], "layout_spans": run.get("layout_spans"),
                    "samples_in_a_move": run["samples_in_a_move"], "moving_frames": run["moving_frames"],
                    "commit_frames": run["commit_frames"], "commit_notes": run["commit_notes"]})
                row(f"{label} {step} proof round: ran", "no error", str(run["error"]), run["error"] is None)
                said, expected, seen, passed = proof_round_row(arm, run)
                row(f"{label} {step} {said}", expected, seen, passed)
                moved = first_move_row(arm, step, run["times"]) if run["times"] else None  # an act that moves no layout spring has no trace
                if moved:
                    row(f"{label} {step} {moved[0]}", *moved[1:])
                proved[(arm, step)] = passed and run["error"] is None and (moved is None or moved[3])
                time.sleep(0.4)  # test harness: idle between runs
        for index, arm in [(index, arm) for index in range(opts.rounds) for arm in tags]:
            label = tags[arm]
            problem = set_pane_motion(arm == "on") if arm else None
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
                mark = "" if step in STILL else proof_mark(arm, proved.get((arm, step)))
                run = measure(f"{panes:>2}p {step} #{index}" + (f" {arm}" if arm else ""), step, mark=mark)
                run.update(layout=label, panes=panes, round=index, pane_motion=arm,
                           move_proved=None if step in STILL else not mark)
                report["runs"].append(run)
                if step in WINDOW_ACTIONS and run["error"]:
                    UNMEASURED.append(f"{label} {step} #{index}: {run['error']}")
                row(f"{label} {step} #{index}: ran", "no error", str(run["error"]), run["error"] is None)
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
        if opts.record and (not opts.record_layouts or name in opts.record_layouts.split(",")):
            moved = tags.get("on", tags.get(None))  # the rows of the rounds with the motion on (the record pass has it on)
            for step in sequence:
                if not not_applicable(step, columns if name != "stress" else None):
                    rounds = [run.get("missed_refreshes") for run in report["runs"] if run.get("layout") == moved and run.get("action") == step]
                    conditions["stills"].setdefault("acts", {})[f"{name}-{step}"] = record(step, f"{name}-{step}", rounds)
            if opts.record_docked and name != "stress":
                try:
                    conditions["stills"].setdefault("acts", {}).update(record_docked(name))
                except Exception as error:  # this part comes last: its fault is a failed row, and the report and the stills before it stay
                    row(f"{name}-docked: the recordings of a docked column ran", "no exception", repr(error)[:200], False)
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
            unproved = next((proof_mark(r.get("pane_motion"), False) for r in runs if r.get("move_proved") is False), "")
            proof = next((p for p in report.get("proof_rounds", []) if p["layout"] == name and p["action"] == step), {})
            summary["samples_in_a_move"] = proof.get("samples_in_a_move")  # of the arm's proof round: no timed round has a trace
            report.setdefault("summary", []).append({"layout": name, "action": step, **summary,
                                                     "move_proved": None if step in STILL else not unproved})

            def f(v):
                return "-" if v is None else (f"{v:.1f}" if isinstance(v, float) else str(v))
            grids = f"{f(summary['grid_reports'])}/{f(summary['resizes_sent'])}"
            print(f"  {name:<5} {step:<{wide}} {f(summary['frames_p50_ms']):>6} {f(summary['frames_p95_ms']):>6} "
                  f"{f(summary['frames_p99_ms']):>6} {f(summary['frames_max_ms']):>6} {f(summary['missed']):>6} "
                  f"{f(summary['missed_refreshes']):>5} {f(summary['moving_frames']):>5} {f(summary['commit_frames']):>6} "
                  f"{f(summary['layout_p95_ms']):>6} {f(summary['layout_max_ms']):>6} "
                  + (f"{grids:>7}" + "".join(f" {f(summary[k]):>6}" for k in browser_keys) if browser_keys else grids)
                  + (f"  {unproved}" if unproved else ""), flush=True)
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
