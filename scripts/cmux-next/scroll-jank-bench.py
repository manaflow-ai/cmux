#!/usr/bin/env python3
"""Scroll jank per cmux NEXT scroll target with real trackpad gestures, in Chrome's metric names (p04-input.md task
072; DC4).

Launches the tagged app itself on a GUI host (bench_launch.BenchApp: a scratch cmux.json, the hang watchdog at 8 ms,
frontmost for real input) and, per session (light, or STRESS from perf-stress-session.py) and per --stall value,
scrolls each target with --gestures trackpad-like gestures at the display rate (hid_input.HidPoster.scroll_gesture:
began, changed events, ended, then decaying momentum; directions alternate):

  sidebar              the sidebar's workspace list, grown to --sidebar-workspaces rows (400)
  strip                the columns strip, --columns columns wider than the window, panned with Command + a sideways
                       scroll over a pane (layout.scrollModifier `command`, set by the bench)
  rows                 one column of --rows rows, scrolled with Command + a vertical scroll over a pane
  tabstrip             one pane's tab strip with --tabs tabs (60), a sideways scroll over the strip
  terminal-scrollback  a `zsh -f` terminal with --scrollback-lines lines of `seq` output
  chromium-page        a tall local page in a Chromium tab; measured only when the page answers as Chromium
                       (`window.chrome` and a Chrome/ user agent) and debug.cef shows no unavailable state, no WebKit
                       fallback and a `ready` start (perf-stress-session.cef_problems): `verified` in its row
  webkit-page          the same page in a WebKit tab (the page must answer as WebKit)
  home                 the native Home transcript (the Home fixture)

The window and target geometry come from debug.layers and debug.pane_chrome; the setup shapes are the ones the
older scroll checks used (strip-scroll-check.py's strip of columns, sidebar-scroll-floor.swift's sidebar of rows).
Before each measured phase one gesture warms the target up. A phase resets `debug.input` and `debug.hangs`, runs
`debug.frames` (display frame intervals: a frame over 1.5 refresh periods is a dropped frame), records the app's
`input.latency` signposts (one per closed scroll slot, OS timestamp to presented frame), posts the gestures and
then one touch (began and ended with no movement), which starts the next scroll so the last gesture's PerScroll
histograms are emitted, as cc emits a scroll's at the next OnScrollStarted. It then reads `debug.input` (latency:
the app's InputLatencyLedger and its ScrollJankTracker; coalescer) and `debug.hangs`.

The scroll jank is Chrome's (cc/metrics/scroll_jank_dropped_frame_tracker.cc, ported in the app as
CmuxNextInputCore/ScrollJankTracker.swift): a presented scroll frame is delayed when the gap to the previous
presentation is over 1.5 vsyncs and its oldest input came before that presentation; its missed vsyncs are
(gap + vsync/2) / vsync - 1. Its histograms, by Chrome's names:

  Event.ScrollJank.DelayedFramesPercentage.FixedWindow   Event.ScrollJank.DelayedFramesPercentage.PerScroll
  Event.ScrollJank.MissedVsyncsSum.FixedWindow           Event.ScrollJank.MissedVsyncsSum.PerScroll
  Event.ScrollJank.MissedVsyncsMax.FixedWindow           Event.ScrollJank.MissedVsyncsMax.PerScroll

(FixedWindow: one value per 64 presented frames; PerScroll: one per scroll.) DC4 is judged on the bench's own fold
of the phase's signposts with the same formula (`signpost_jank`): the signposts are exactly the phase's slots. The
ledger's `scroll_jank` is reported beside it as `ledger_cross_check`, information only: InputLatencyTracker hands
closed slots to the ledger a half ring at a time, so at the reset the ring still holds the warm-up's last slots
and at the read it holds the phase's last ones (the closing touch's among them). Each row reports the delayed and
presented frames, DelayedFramesPercentage over the whole phase, the dropped display frames, and the presented time
of the scroll updates (p50/p95/p99/max).

Output: {header, dc4: one entry per session x stall x target, rows (input-latency-bench's row shape per kind, target
and stage), runs, log}. A DC4 entry has `expectation` (`zero_delayed`: with --stall none every target, and under a
stall sidebar, chromium-page and webkit-page; `report`: strip, rows, terminal-scrollback, tabstrip and home under a
stall, judged against task 102's written decision) and `met` (null when nothing was measured); the bench prints
numbers and asserts no time: it exits 0 whatever it measured (--self-test exits 1 when the self-test fails).

Real input needs the GUI session and the Accessibility grant (`nx-remote --needs input` or a whole mini); a run
where no scroll reached the app says so (`input_reached: false`). There is no debug-input mode: the app counts scroll
jank for a person's input only.

  scroll-jank-bench.py --app APP --out DIR [--json FILE] [--tag TAG]
      [--targets sidebar,strip,rows,tabstrip,terminal-scrollback,chromium-page,webkit-page,home]
      [--sessions light,stress] [--stall none,50ms/100ms] [--gestures 12] [--rate HZ]
  scroll-jank-bench.py --self-test

Fleet (an owned mini with a console; the step builds the app):
  cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh --ref SHA \\
    --artifact artifacts/split-spring/report.json --arg=--suite=scroll-jank --arg=--vdisplay=120 \\
    [--arg=--sessions=light,stress] [--arg=--stall=none,50ms/100ms]
"""
import argparse, contextlib, importlib.util, io, json, os, platform, subprocess, sys, tempfile, time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hid_input  # noqa: E402


def load_script(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# input-latency-bench.py's options, rows and launch helpers (one copy of each).
latency_bench = load_script("input_latency_bench", "input-latency-bench.py")

TARGETS = ("sidebar", "strip", "rows", "tabstrip", "terminal-scrollback", "chromium-page", "webkit-page", "home")
# The InputTarget a target's scroll slots carry (InputTargetClassifier's rules in AppServices; a scroll the layout
# takes is retargeted to `layout`, InputLatencyDispatch.didDispatch). The tab strip and Home sit inside the layout's
# view tree; a Home transcript's selectable text is a text view.
EXPECTED_TARGETS = {
    "sidebar": ("sidebar",), "strip": ("layout",), "rows": ("layout",), "tabstrip": ("layout",),
    "terminal-scrollback": ("terminal",), "chromium-page": ("chromiumPage",), "webkit-page": ("webkitPage",),
    "home": ("layout", "textView"),
}
# The gesture per target: its axis and the modifiers held (layout.scrollModifier `command` for the strip and rows).
GESTURES = {
    "sidebar": ("y", ()), "strip": ("x", ("command",)), "rows": ("y", ("command",)), "tabstrip": ("x", ()),
    "terminal-scrollback": ("y", ()), "chromium-page": ("y", ()), "webkit-page": ("y", ()), "home": ("y", ()),
}
# DC4: under a main-thread stall these must still present every scroll frame on time (they scroll off the main
# thread); the others report numbers for task 102's decision.
ZERO_DELAYED_UNDER_STALL = ("sidebar", "chromium-page", "webkit-page")
SCROLL_KINDS = latency_bench.SCROLL_KINDS
UPDATE_KINDS = ("scrollFirstUpdate", "scrollUpdate", "scrollMomentum")
CHROME_NAMES = (
    "Event.ScrollJank.DelayedFramesPercentage.FixedWindow", "Event.ScrollJank.MissedVsyncsSum.FixedWindow",
    "Event.ScrollJank.MissedVsyncsMax.FixedWindow", "Event.ScrollJank.DelayedFramesPercentage.PerScroll",
    "Event.ScrollJank.MissedVsyncsSum.PerScroll", "Event.ScrollJank.MissedVsyncsMax.PerScroll",
)
WINDOW = (40, 40, 1400, 900)
PAGE = ("<!doctype html><title>scroll jank</title><body style='margin:0;font:15px -apple-system,sans-serif'>"
        + "".join(f"<p style='margin:0;padding:8px 16px;border-bottom:1px solid #ddd'>row {i}: the quick brown fox "
                  f"jumps over the lazy dog</p>" for i in range(1500)))
ENGINE_CHECK = latency_bench.ENGINE_CHECK


# ---------------------------------------------------------------- Chrome's scroll jank (reference port)
class ChromeScrollJank:
    """cc's ScrollJankDroppedFrameTracker (cc/metrics/scroll_jank_dropped_frame_tracker.cc), as the app ports it
    (ScrollJankTracker.swift): fed the scroll frames of the signposts, it emits Chrome's six histograms. Times in
    nanoseconds."""

    FIXED_WINDOW_FRAMES = 64

    def __init__(self):
        self.histograms = {name: {} for name in CHROME_NAMES}
        self.presented_frames = self.delayed_frames = self.skipped_frames = 0
        self.fixed = self._data()
        self.per_scroll = None
        self.previous_presented = 0

    @staticmethod
    def _data():
        return {"presented": 0, "delayed": 0, "missed_sum": 0, "missed_max": 0}

    @staticmethod
    def _percentage(data):
        return 100 * data["delayed"] // data["presented"] if data["presented"] else 0

    def _record(self, name, value):
        self.histograms[name][value] = self.histograms[name].get(value, 0) + 1

    def _emit(self, data, suffix):
        self._record(f"Event.ScrollJank.DelayedFramesPercentage.{suffix}", self._percentage(data))
        self._record(f"Event.ScrollJank.MissedVsyncsSum.{suffix}", data["missed_sum"])
        self._record(f"Event.ScrollJank.MissedVsyncsMax.{suffix}", data["missed_max"])

    def scroll_started(self):
        """OnScrollStarted: the previous scroll's PerScroll values, if it presented a frame."""
        if self.per_scroll is not None:
            if self.per_scroll["presented"] == 0 and self.previous_presented == 0:
                return  # a second start before the new scroll presented anything changes nothing
            if self.per_scroll["presented"] > 0:
                self._emit(self.per_scroll, "PerScroll")
        self.per_scroll = self._data()
        self.previous_presented = 0

    def frame(self, first_generated, last_generated, presented, vsync):
        """One presented scroll frame (ReportLatestPresentationData)."""
        if vsync <= 0 or first_generated <= 0 or last_generated < first_generated or presented <= last_generated:
            self.skipped_frames += 1
            return
        if self.previous_presented == 0 or presented <= self.previous_presented:
            if self.previous_presented == 0:
                self.previous_presented = presented
            self.skipped_frames += 1
            return
        gap = presented - self.previous_presented
        janky = gap > vsync + vsync // 2 and first_generated < self.previous_presented
        missed = (gap + vsync // 2) // vsync - 1 if janky else 0
        for data in (self.fixed, self.per_scroll if self.per_scroll is not None else self._new_scroll()):
            data["presented"] += 1
            if janky:
                data["delayed"] += 1
                data["missed_sum"] += missed
                data["missed_max"] = max(data["missed_max"], missed)
        self.presented_frames += 1
        self.delayed_frames += janky
        self.previous_presented = presented
        if self.fixed["presented"] == self.FIXED_WINDOW_FRAMES:
            self._emit(self.fixed, "FixedWindow")
            self.fixed = self._data()

    def _new_scroll(self):
        self.per_scroll = self._data()
        return self.per_scroll

    def snapshot(self):
        """The ledger's `scroll_jank` shape (InputLatencySnapshot.ScrollJank)."""
        return {"presented_frames": self.presented_frames, "delayed_frames": self.delayed_frames,
                "skipped_frames": self.skipped_frames,
                "histograms": {name: {"samples": [{"value": v, "count": c} for v, c in sorted(counts.items())]}
                               for name, counts in self.histograms.items() if counts}}


# A signpost's stages are whole microseconds after its gen_ns (InputLatencySignpostMessage.micros truncates), so a
# slot's presented time rebuilds to P - ((P - gen) mod 1000) ns: the slots of one frame land within this much of it.
SIGNPOST_RESOLUTION_NS = 1000


def signpost_jank(events, vsync_ns):
    """Chrome's scroll jank of a person's scroll signposts, folded as InputLatencyLedger folds slots: a begin or a
    first update starts a scroll; the updates and momentum that caused a frame update and were presented make
    frames, one per presentation time (slots whose rebuilt times are within SIGNPOST_RESOLUTION_NS are one frame,
    at the latest of them, the closest to the exact time). The last frame stays pending until the next scroll
    starts, as in the app."""
    tracker = ChromeScrollJank()
    pending = None

    def flush():
        nonlocal pending
        if pending:
            tracker.frame(pending[0], pending[1], pending[2], vsync_ns)
        pending = None

    for event in events:
        if event["entrypoint"] != "person" or event["kind"] not in SCROLL_KINDS:
            continue
        kind = event["kind"]
        if kind in ("scrollBegin", "scrollFirstUpdate"):
            flush()
            tracker.scroll_started()
        if kind not in UPDATE_KINDS:
            continue
        stages = event["stages_ms"]
        if not event["caused_frame_update"] or "presented" not in stages or event["generated_ns"] <= 0:
            continue
        first = event["generated_ns"]
        last = max(first, first + int(round(stages.get("last_generated", 0.0) * 1e6)))
        presented = first + int(round(stages["presented"] * 1e6))
        if pending and abs(pending[2] - presented) < SIGNPOST_RESOLUTION_NS:
            pending = (min(pending[0], first), max(pending[1], last), max(pending[2], presented))
            continue
        flush()
        pending = (first, last, presented)
    return tracker.snapshot()


def jank_fields(scroll_jank):
    """A DC4 row's jank numbers from a `scroll_jank` object (the ledger's or signpost_jank's): presented, delayed and
    skipped frames, DelayedFramesPercentage over the phase, the missed vsyncs (sum of the PerScroll sums, max of
    every Max), and each Chrome histogram ({emitted, max, samples}, null when it emitted nothing)."""
    if not isinstance(scroll_jank, dict):
        return None
    presented = int(scroll_jank.get("presented_frames") or 0)
    delayed = int(scroll_jank.get("delayed_frames") or 0)
    histograms = {}
    for name in CHROME_NAMES:
        samples = ((scroll_jank.get("histograms") or {}).get(name) or {}).get("samples") or []
        samples = [s for s in samples if s.get("count")]
        histograms[name] = {"emitted": sum(s["count"] for s in samples), "max": max(s["value"] for s in samples),
                            "samples": samples} if samples else None

    def total(name):
        return sum(s["value"] * s["count"] for s in (histograms[name] or {}).get("samples") or [])

    maxima = [(histograms[name] or {}).get("max") for name in CHROME_NAMES if "MissedVsyncsMax" in name]
    return {"presented_frames": presented, "delayed_frames": delayed,
            "skipped_frames": int(scroll_jank.get("skipped_frames") or 0),
            "delayed_frames_percentage": round(100.0 * delayed / presented, 2) if presented else None,
            "missed_vsyncs_sum": total("Event.ScrollJank.MissedVsyncsSum.PerScroll"),
            "missed_vsyncs_max": max([m for m in maxima if m is not None], default=0),
            "histograms": histograms}


# ---------------------------------------------------------------- options
def parse_stalls(spec):
    """`none,50ms/100ms` -> [None, (50, 100)] (input-latency-bench's parse_stall per value)."""
    return [latency_bench.parse_stall(v) for v in (spec or "none").split(",")]


def stall_label(stall):
    return f"{stall[0]}ms/{stall[1]}ms" if stall else "none"


def selected_targets(opts):
    return [t for t in (opts.targets or ",".join(TARGETS)).split(",") if t]


def build_parser():
    parser = argparse.ArgumentParser(description="Scroll jank per cmux scroll target, real trackpad gestures, Chrome's metric names.")
    parser.add_argument("--app")
    parser.add_argument("--tag", default="scroll-jank")
    parser.add_argument("--out")
    parser.add_argument("--json")
    parser.add_argument("--targets", help=f"comma list of {','.join(TARGETS)} (default: all)")
    parser.add_argument("--sessions", default="light", help="comma list of light,stress: one app launch each")
    parser.add_argument("--stall", default="none", help="comma list of none or MS/PERIOD: a main-thread debug.stall per condition")
    parser.add_argument("--gestures", type=int, default=12, help="measured gestures per target and condition")
    parser.add_argument("--rate", type=float, help="scroll events per second (default: the display's refresh, else 120)")
    parser.add_argument("--changes", type=int, default=30, help="changed events per gesture (fingers on the trackpad)")
    parser.add_argument("--momentum", type=int, default=24, help="momentum events per gesture")
    parser.add_argument("--delta", type=float, default=12.0, help="points per changed event")
    parser.add_argument("--pause", type=float, default=0.25, help="seconds between gestures (fingers off)")
    parser.add_argument("--sidebar-workspaces", type=int, default=400)
    parser.add_argument("--columns", type=int, default=6, help="strip columns")
    parser.add_argument("--rows", type=int, default=5, help="rows in the rows target's column")
    parser.add_argument("--tabs", type=int, default=60, help="tabs in the tabstrip target's pane")
    parser.add_argument("--scrollback-lines", type=int, default=20000)
    parser.add_argument("--self-test", action="store_true", help="run the bench against a fixture app and check every field")
    return parser


def validate(opts, parser):
    for target in selected_targets(opts):
        if target not in TARGETS:
            parser.error(f"--targets: unknown target {target} (one of {', '.join(TARGETS)})")
    for session in opts.sessions.split(","):
        if session not in ("light", "stress"):
            parser.error(f"--sessions: unknown session {session} (light or stress)")
    try:
        parse_stalls(opts.stall)
    except ValueError as error:
        parser.error(str(error))
    if opts.gestures <= 0 or opts.changes <= 0 or opts.momentum < 2 or opts.delta <= 0 or (opts.rate is not None and opts.rate <= 0):
        parser.error("--gestures, --changes, --delta and --rate must be positive and --momentum at least 2")


def display_rate(opts, refresh):
    """The scroll event rate: --rate, else the fastest display's refresh (a trackpad reports at the display rate)."""
    if opts.rate:
        return float(opts.rate)
    rates = (refresh or {}).get("hz") or []
    return float(max(rates)) if rates else 120.0


# ---------------------------------------------------------------- the bench
class Bench:
    """One bench run. The app, the poster, the signpost recorder and time are injected (the self-test fakes them)."""

    def __init__(self, opts, control, poster, recorder, rate_hz, pid=None, out=None, sleep=time.sleep, log=print,
                 cef_problems=None):
        self.opts, self.control, self.poster, self.recorder = opts, control, poster, recorder
        self.rate_hz, self.pid, self.sleep, self.log_line = rate_hz, pid, sleep, log
        self.out = out or tempfile.mkdtemp(prefix="scroll-jank-")
        self.cef_problems = cef_problems or latency_bench.load_stress_module().cef_problems
        self.session = "light"
        self.state = {}
        self.runs, self.notes = [], []

    def note(self, text):
        self.notes.append(text)
        self.log_line(text)

    # ------------------------------------------------------------ app helpers
    def workspace(self, key, name, *extra):
        """The target's own workspace, made once per session and shown."""
        ref = self.state.get(key)
        if not ref:
            ref = self.control.cli("workspace", "create", "--name", name, "--focus", *extra).stdout.strip()
            self.state[key] = ref
            self.sleep(1.5)  # the workspace shows and its first content draws
        if ref:
            self.control.cli("workspace", ref, "focus")
            self.sleep(0.5)  # the workspace shows
        return ref

    def workspace_count(self):
        reply = self.control.rpc("snapshot.get") or {}
        return len([w for w in ((reply.get("topology") or {}).get("workspaces") or []) if w.get("id")]) \
            if isinstance(reply, dict) else 0

    def chrome_window(self):
        chrome = self.control.rpc("debug.pane_chrome") or {}
        return ((chrome.get("windows") or [{}]) if isinstance(chrome, dict) else [{}])[0]

    def window_frame(self):
        layers = self.control.rpc("debug.layers") or {}
        window = ((layers.get("windows") or [{}]) if isinstance(layers, dict) else [{}])[0]
        return window.get("frame")

    def display_point(self, rect, frame=None):
        """The center of `rect` (top-left window points) on the display, or None."""
        frame = frame or self.window_frame()
        height = self.poster.backend.main_display_height()
        if not frame or not rect or height is None:
            return None
        return hid_input.window_point(frame, hid_input.rect_center(rect), height, top_left=True)

    def content_rect(self, chrome):
        """The shown pane's content (its border rect) when the workspace has one pane, else the main pane area."""
        panes = chrome.get("panes") or []
        return panes[0].get("border") if len(panes) == 1 and panes[0].get("border") else chrome.get("main_pane")

    def page(self, engine, target):
        key = f"{engine}_ws"
        first = not self.state.get(key)
        self.workspace(key, f"scroll jank {engine}")
        if first:
            path = os.path.join(self.out, "scroll-jank-page.html")
            with open(path, "w") as handle:
                handle.write(PAGE)
            self.control.action(f"openBrowser.{engine}", {"url": "file://" + path}, timeout=120)
            loaded = hid_input.wait(lambda: (self.control.rpc("browser.page.eval", {"script": "document.readyState === 'complete' && document.body.scrollHeight > 4 * innerHeight"},
                                                               timeout=20) or {}).get("value") is True, 60, step=0.5, sleep=self.sleep)
            if not loaded:
                return {"ok": False, "reason": f"the {engine} page did not load"}
        answered = (self.control.rpc("browser.page.eval", {"script": ENGINE_CHECK}, timeout=20) or {}).get("value")
        if answered != engine:
            return {"ok": False, "reason": f"the {target} answers as {answered!r}, not {engine}", "engine": answered}
        verified = {"engine": answered}
        if engine == "chromium":
            problems = self.cef_problems(self.control.rpc("debug.cef", timeout=20))
            if problems:
                return {"ok": False, "reason": f"the {target} is not verified Chromium: {'; '.join(problems)}", "engine": answered,
                        "verified": dict(verified, cef_problems=problems)}
            verified["cef"] = "ready, no WebKit fallback"
        return {"ok": True, "engine": answered, "verified": verified}

    # ------------------------------------------------------------ targets
    def setup(self, target):
        """Builds `target` once per session and shows it: {ok, rect (top-left window points) | reason, ...}."""
        if target == "sidebar":
            missing = self.opts.sidebar_workspaces - self.workspace_count()
            if missing > 0:
                with ThreadPoolExecutor(max_workers=8) as pool:
                    made = list(pool.map(lambda i: self.control.cli("workspace", "create", "--empty", "--name", f"scroll row {i:04d}"),
                                         range(missing)))
                self.note(f"{self.session} sidebar: made {sum(1 for r in made if r.returncode == 0)} of {missing} workspaces")
            self.workspace("sidebar_ws", "scroll jank sidebar")
            chrome = self.chrome_window()
            if (chrome.get("window_controls") or {}).get("sidebar_hidden"):
                return {"ok": False, "reason": "the sidebar is hidden"}
            return {"ok": True, "rect": chrome.get("sidebar"), "workspaces": self.workspace_count()}
        if target == "strip":
            self.control.rpc("settings.set", {"path": "layout.scrollModifier", "value": "command"})
            first = not self.state.get("strip_ws")
            self.workspace("strip_ws", "scroll jank strip")
            if first:
                for _ in range(self.opts.columns - 1):
                    self.control.action("newColumn")
                    self.sleep(0.3)  # one column at a time
            dock = self.control.rpc("debug.dock") or {}
            strip = (((dock.get("windows") or [{}])[0].get("screen") or {}).get("strip") or {}) if isinstance(dock, dict) else {}
            if not (strip.get("max_offset") or 0) > 0:
                return {"ok": False, "reason": f"the strip does not overflow the window (debug.dock strip {json.dumps(strip)[:160]})"}
            return {"ok": True, "rect": self.chrome_window().get("main_pane"), "strip": strip}
        if target == "rows":
            self.control.rpc("settings.set", {"path": "layout.scrollModifier", "value": "command"})
            first = not self.state.get("rows_ws")
            self.workspace("rows_ws", "scroll jank rows")
            if first:
                for _ in range(self.opts.rows - 1):
                    self.control.action("newRow")
                    self.sleep(0.3)  # one row at a time
            chrome = self.chrome_window()
            panes = len(chrome.get("panes") or [])
            if panes < 2:
                return {"ok": False, "reason": f"the column has {panes} row(s): newRow refused (layout.rows off?)"}
            return {"ok": True, "rect": chrome.get("main_pane"), "panes": panes}
        if target == "tabstrip":
            first = not self.state.get("tabs_ws")
            self.workspace("tabs_ws", "scroll jank tabs")
            if first:
                for _ in range(self.opts.tabs - 1):
                    self.control.action("newTab")
                self.sleep(1.0)  # the tabs lay out
            panes = self.chrome_window().get("panes") or [{}]
            slots, available = panes[0].get("tab_slots") or [], panes[0].get("tab_available") or 0
            content = max((x + w for x, w in slots), default=0)
            if content <= available:
                return {"ok": False, "reason": f"the tab strip does not overflow ({len(slots)} tabs, {content} of {available} pt)"}
            return {"ok": True, "rect": panes[0].get("strip"), "tabs": len(slots)}
        if target == "terminal-scrollback":
            first = not self.state.get("terminal_ws")
            self.workspace("terminal_ws", "scroll jank terminal", "--shell", "exec /bin/zsh -f")
            if first:
                self.control.action("terminal.sendText", {"text": f"seq 1 {self.opts.scrollback_lines}\r"})
                self.sleep(3.0)  # the output fills the scrollback
            return {"ok": True, "rect": self.content_rect(self.chrome_window())}
        if target in ("chromium-page", "webkit-page"):
            ready = self.page(target.split("-")[0], target)
            if ready.get("ok"):
                ready["rect"] = self.content_rect(self.chrome_window())
            return ready
        if target == "home":
            first = not self.state.get("home_ws")
            self.workspace("home_ws", "scroll jank home")
            if first:
                opened = self.control.rpc("debug.home_native_fixture.open", {"new": True})
                if hid_input.is_error(opened):
                    return {"ok": False, "reason": f"no Home fixture: {json.dumps(opened)[:160]}"}
                self.sleep(2.0)  # the transcript lays out
            return {"ok": True, "rect": self.content_rect(self.chrome_window())}
        return {"ok": False, "reason": f"unknown target {target}"}

    # ------------------------------------------------------------ measuring
    def gesture(self, point, axis, modifiers, sign):
        delta = sign * self.opts.delta
        dx, dy = (delta, 0.0) if axis == "x" else (0.0, delta)
        return self.poster.scroll_gesture(point, dy=dy, dx=dx, rate_hz=self.rate_hz, changes=self.opts.changes,
                                          momentum=self.opts.momentum, modifiers=modifiers)

    def start_stall(self, stall):
        if not stall:
            return []
        ms, period = stall
        thread = hid_input.Periodic("stall", lambda _: self.control.rpc("debug.stall", {"ms": ms}, timeout=10), period / 1000.0)
        thread.start()
        self.sleep(0.5)  # the stalls run before the first scroll
        return [thread]

    def measure(self, target, stall):
        label = stall_label(stall)
        base = {"session": self.session, "stall": label, "target": target, "phase": "scroll", "input": self.poster.input,
                "expected_targets": list(EXPECTED_TARGETS[target])}
        ready = self.setup(target)
        point = self.display_point(ready.get("rect")) if ready.get("ok") else None
        if ready.get("ok") and point is None:
            ready = {"ok": False, "reason": "no window frame or target rect (debug.layers, debug.pane_chrome)"}
        if not ready.get("ok"):
            self.note(f"{self.session} {target} stall {label}: not measured: {ready.get('reason')}")
            return self.record(dict(base, status="skipped", reason=ready.get("reason"), verified=ready.get("verified"), rows=[]))
        axis, modifiers = GESTURES[target]
        self.gesture(point, axis, modifiers, 1)  # warm-up, not measured
        self.sleep(self.opts.pause + 0.5)  # its momentum ends
        self.control.rpc("debug.input", {"action": "reset"})
        self.control.rpc("debug.hangs", {"clear": True})
        recording = self.recorder(self.pid)
        self.control.rpc("debug.frames", {"action": "start"})
        threads = self.start_stall(stall)
        posted = []
        for index in range(self.opts.gestures):
            posted.append(self.gesture(point, axis, modifiers, -1 if index % 2 == 0 else 1))
            self.sleep(self.opts.pause)  # fingers off between gestures
        self.poster.scroll_touch(point, modifiers)  # the next OnScrollStarted: the last gesture's PerScroll values
        self.sleep(0.5)  # the last frame lands
        load = latency_bench.Bench.stop_load(threads)
        frames = self.control.rpc("debug.frames", {"action": "stop"}, timeout=30) or {}
        events, lost = recording.stop() if recording else ([], 0)
        debug_input = self.control.rpc("debug.input", {"sections": ["latency", "coalescer"]}, timeout=30)
        hangs = self.control.rpc("debug.hangs", {"limit": 12}, timeout=20)
        hangs = {k: hangs.get(k) for k in ("count", "max_ms", "total_ms")} if isinstance(hangs, dict) and not hangs.get("error") \
            else {"error": (hangs or {}).get("error") if isinstance(hangs, dict) else None}
        scrolls = [e for e in events if e["kind"] in SCROLL_KINDS and e["entrypoint"] == "person"]
        landed = {}
        for event in scrolls:
            landed[event["target"]] = landed.get(event["target"], 0) + 1
        mine = [e for e in scrolls if e["target"] in EXPECTED_TARGETS[target]]
        status = "ok" if mine else ("wrong_target" if scrolls else "no_input")
        ctx = {"surface": target, "session": self.session, "condition": "idle" if not stall else f"stall:{label}",
               "storm": "none", "stall": label, "input": self.poster.input}
        absent = []
        latency = latency_bench.section(debug_input, "latency", absent)
        rows = latency_bench.stage_rows(mine, ctx, SCROLL_KINDS) + latency_bench.ledger_rows(latency, ctx, SCROLL_KINDS, "person")
        coalescer = latency_bench.section(debug_input, "coalescer", absent)
        rates = [p["rate_hz"] for p in posted if p.get("rate_hz")]
        run = dict(base, status=status, point=point, modifiers=list(modifiers), axis=axis, setup={k: v for k, v in ready.items() if k not in ("ok", "rect")},
                   verified=ready.get("verified"), gestures=len(posted), events=sum(p["events"] for p in posted),
                   late=sum(p["late"] for p in posted), rate_hz=round(sum(rates) / len(rates), 1) if rates else None,
                   landed=landed, signposts_lost=lost, frames=frames if isinstance(frames, dict) else {}, hangs=hangs, load=load,
                   scroll_jank=(latency or {}).get("scroll_jank"), signpost_jank=signpost_jank(mine, vsync_ns(frames, self.rate_hz)),
                   coalescer=latency_bench.coalescer_max(coalescer) if coalescer is not None else None, absent=absent,
                   update_ms=latency_bench.dist([e["stages_ms"]["presented"] for e in mine if e["kind"] in UPDATE_KINDS and "presented" in e["stages_ms"]]),
                   first_update_ms=latency_bench.dist([e["stages_ms"]["presented"] for e in mine
                                                       if e["kind"] == "scrollFirstUpdate" and "presented" in e["stages_ms"]]),
                   rows=rows)
        jank = jank_fields(run["signpost_jank"]) or {}
        self.note(f"{self.session} {target} stall {label}: {status}, {run['events']} events at {run['rate_hz']} Hz; "
                  f"delayed {jank.get('delayed_frames')}/{jank.get('presented_frames')} frames, dropped {run['frames'].get('missed')}; "
                  f"update p99 {(run['update_ms'] or {}).get('p99')} ms; landed {landed}")
        return self.record(run)

    def record(self, run):
        self.runs.append(run)
        return run

    # ------------------------------------------------------------ session
    def run_session(self, session):
        self.session = session
        for stall in parse_stalls(self.opts.stall):
            for target in selected_targets(self.opts):
                try:
                    self.measure(target, stall)
                except Exception as error:  # one target failing must not hide the others
                    self.note(f"{self.session} {target} stall {stall_label(stall)}: failed: {error!r}")
                    self.runs.append({"session": self.session, "stall": stall_label(stall), "target": target, "phase": "error",
                                      "error": repr(error)})


def vsync_ns(frames, rate_hz):
    """The display's refresh interval in ns: debug.frames' measured refresh, else the scroll rate's period."""
    refresh_ms = (frames or {}).get("refresh_ms") if isinstance(frames, dict) else None
    return int(round(float(refresh_ms) * 1e6)) if refresh_ms else int(round(1e9 / rate_hz))


# ---------------------------------------------------------------- DC4
LEDGER_CROSS_CHECK = ("presented_frames", "delayed_frames", "skipped_frames", "missed_vsyncs_sum", "missed_vsyncs_max")


def dc4_entry(run):
    """One DC4 entry: Chrome's jank numbers of the phase's signposts, the ledger's beside them (information only:
    its half-ring batches do not line up with the phase), the dropped display frames, the scroll update latency, and
    whether the DC4 expectation of the row was met (null when nothing was judged)."""
    stalled = run.get("stall") not in (None, "none")
    expectation = "zero_delayed" if not stalled or run["target"] in ZERO_DELAYED_UNDER_STALL else "report"
    entry = {"session": run.get("session"), "stall": run.get("stall"), "target": run["target"], "status": run.get("status"),
             "reason": run.get("reason"), "expectation": expectation, "met": None, "verified": run.get("verified"),
             "expected_targets": run.get("expected_targets"), "landed": run.get("landed")}
    if run.get("phase") != "scroll" or run.get("status") != "ok":
        return entry
    absent = list(run.get("absent") or [])
    ledger, jank = jank_fields(run.get("scroll_jank")), jank_fields(run.get("signpost_jank"))
    frames = run.get("frames") or {}
    entry.update(jank_source="signpost", **jank,
                 ledger_cross_check={k: ledger.get(k) for k in LEDGER_CROSS_CHECK} if ledger else None,
                 dropped_frames=frames.get("missed"), frames=frames.get("frames"), refresh_ms=frames.get("refresh_ms"),
                 frame_p99_ms=frames.get("p99_ms"), frame_max_ms=frames.get("max_ms"),
                 update_ms=run.get("update_ms"), first_update_ms=run.get("first_update_ms"),
                 gestures=run.get("gestures"), events=run.get("events"), rate_hz=run.get("rate_hz"), late=run.get("late"),
                 hangs=run.get("hangs"), coalescer_deliveries_per_frame_max=max(run["coalescer"].values()) if run.get("coalescer") else None)
    if frames.get("missed") is None:
        absent.append("debug.frames: no frame intervals")
    if not jank["presented_frames"]:
        absent.append("no presented scroll frame: nothing to judge")
    elif expectation == "zero_delayed" and (stalled or frames.get("missed") is not None):
        entry["met"] = jank["delayed_frames"] == 0 and (stalled or frames.get("missed") == 0)
    entry["absent"] = absent
    return entry


def header(opts, rate_hz, refresh=None):
    return {"schema": "cmux-scroll-jank/v1", "host": platform.node(), "macos": hid_input.macos_version(),
            "refresh": refresh if refresh is not None else hid_input.display_refresh(), "input": "real", "quotable": True,
            "tag": opts.tag, "app": opts.app, "sessions": opts.sessions.split(","), "targets": selected_targets(opts),
            "stall": opts.stall, "gestures": opts.gestures, "rate_hz": rate_hz, "changes": opts.changes,
            "momentum": opts.momentum, "chrome_metrics": list(CHROME_NAMES),
            "metric_source": "cc/metrics/scroll_jank_dropped_frame_tracker.cc (CmuxNextInputCore/ScrollJankTracker.swift)",
            "started": time.strftime("%Y-%m-%dT%H:%M:%S%z")}


def report(head, runs, notes):
    reached = any(run.get("status") == "ok" for run in runs if run.get("phase") == "scroll")
    return {"header": dict(head, input_reached=reached), "dc4": [dc4_entry(run) for run in runs if run.get("target")],
            "rows": [r for run in runs for r in run.get("rows") or []], "runs": runs, "log": notes}


# ---------------------------------------------------------------- launch
def run_launched(opts):
    """Launches the app once per session and measures it; returns the report."""
    from bench_launch import BenchApp, LaunchError
    out = os.path.abspath(opts.out or tempfile.mkdtemp(prefix="scroll-jank-"))
    os.makedirs(out, exist_ok=True)
    refresh = hid_input.display_refresh()
    rate_hz = display_rate(opts, refresh)
    head = header(opts, rate_hz, refresh)
    runs, notes = [], []
    for session in opts.sessions.split(","):
        try:
            app = BenchApp(os.path.abspath(opts.app.rstrip("/")), out=out, config={"browser": {"defaultEngine": "chromium"}},
                           window=WINDOW, log_name=f"app-{session}.log", perf_session=session,
                           env={"CMUX_NEXT_HANG_THRESHOLD_MS": "8", "CMUX_NEXT_NO_ACTIVATE": None})
            app.launch(timeout=180)
        except (LaunchError, SystemExit) as error:  # a wrong bundle exits from BenchApp; the bench reports it instead
            reason = getattr(error, "reason", None) or str(error)
            notes.append(f"{session}: the app did not come up: {reason}")
            runs.append({"session": session, "phase": "launch", "status": "failed", "reason": reason})
            continue
        bench = None
        try:
            cli = os.path.join(os.path.abspath(opts.app.rstrip("/")), "Contents/Resources/bin/cmux")
            control = hid_input.Control(app.socket, cli, os.path.join(app.scratch, "cmux.json"))
            bench = Bench(opts, control, hid_input.poster_for("real"), hid_input.SignpostRecording, rate_hz,
                          pid=app.process.pid, out=out)
            if session == "stress":
                stress = latency_bench.load_stress_module().Stress(control.rpc, log=bench.note)
                head.setdefault("stress", {})[session] = stress.build()
                time.sleep(5)  # the STRESS grid settles before the first measured input
            hid_input.bring_front(app.process.pid)
            time.sleep(1)  # activation settles
            bench.run_session(session)
        except Exception as error:  # STRESS did not build, or the app went away: report what was measured
            notes.append(f"{session}: stopped: {error!r}")
            runs.append({"session": session, "phase": "error", "label": "session", "error": repr(error)})
        finally:
            if bench is not None:
                runs += bench.runs
                notes += bench.notes
            app.stop()
        latency_bench.write(opts.json, report(head, runs, notes))
    return report(head, runs, notes)


# ---------------------------------------------------------------- self-test
SCROLL_KIND_RAW = {name: index for index, name in enumerate(hid_input.KINDS)}


# The fixture's ledger: a fixed `scroll_jank` unlike any phase's signpost fold, as the app's ledger is after its
# half-ring hand-off (the warm-up's last slots in, the phase's last batch out). DC4 must not take it.
FIXTURE_LEDGER_JANK = {"presented_frames": 7, "delayed_frames": 3, "skipped_frames": 5,
                       "histograms": {"Event.ScrollJank.MissedVsyncsSum.PerScroll": {"samples": [{"value": 11, "count": 1}]},
                                      "Event.ScrollJank.MissedVsyncsMax.PerScroll": {"samples": [{"value": 9, "count": 1}]}}}


class FixtureControl:
    """A fake app: canned replies for every method the bench calls. Its ledger's `scroll_jank` is FIXTURE_LEDGER_JANK
    (the app's own ledger is Swift); `cef` is debug.cef's reply."""

    def __init__(self, cef=None, sections=("latency", "coalescer"), sidebar_hidden=False):
        self.calls, self.created, self.stalls = [], 0, 0
        self.cef = cef if cef is not None else {"state": "ready"}
        self.sections, self.sidebar_hidden = sections, sidebar_hidden
        self.engines, self.shown = {}, None

    def rpc(self, method, params=None, timeout=30):
        params = params or {}
        self.calls.append(method)
        if method == "action.run":
            if params["action"].startswith("openBrowser."):
                self.engines[self.shown] = params["action"].split(".", 1)[1]
            return {"ok": True}
        if method == "browser.page.eval":
            script = params.get("script", "")
            return {"value": self.engines.get(self.shown)} if "window.chrome" in script else {"value": True}
        if method == "snapshot.get":
            return {"topology": {"workspaces": [{"id": f"w{i}"} for i in range(self.created)]}}
        if method == "debug.cef":
            return self.cef
        if method == "debug.stall":
            self.stalls += 1
            return {"ok": True}
        if method == "debug.frames":
            if params.get("action") == "stop":
                return {"frames": 400, "missed": 4 if self.stalls else 0, "refresh_ms": 8.33, "p99_ms": 8.4, "max_ms": 60.0 if self.stalls else 8.6}
            return {"running": True}
        if method == "debug.input":
            if params.get("action") == "reset":
                return {"reset": list(self.sections)}
            body = {"absent": [s for s in ("latency", "coalescer") if s not in self.sections]}
            if "latency" in self.sections:
                body["latency"] = {"rows": [{"kind": "scrollUpdate", "target": "sidebar", "entrypoint": "person",
                                             "presentation_source": "estimatedVsync", "display": {"refresh_hz": 120},
                                             "total": {"count": 3, "p50_ms": 7.0, "p95_ms": 9.0, "p99_ms": 9.5, "max_ms": 10.0},
                                             "stages": []}],
                                   "scroll_jank": FIXTURE_LEDGER_JANK}
            if "coalescer" in self.sections:
                body["coalescer"] = {"windows": [{"window": "w1", "consumers": [{"consumer": "layout.scroll", "deliveries_per_frame": {"max": 1}}]}]}
            return body
        if method == "debug.hangs":
            return {"count": 0, "max_ms": 0.0, "total_ms": 0.0}
        if method == "debug.layers":
            return {"windows": [{"frame": [40, 40, 1400, 900]}]}
        if method == "debug.pane_chrome":
            tabs = [[i * 120.0, 116.0] for i in range(60)] if self.shown == "workspace:scroll jank tabs" else [[0.0, 116.0]]
            panes = [{"cell": [240, 40, 1160, 860], "border": [244, 72, 1152, 824], "strip": [240, 40, 1160, 28],
                      "tab_slots": tabs, "tab_available": 1000.0}]
            if self.shown == "workspace:scroll jank rows":
                panes *= 5
            return {"windows": [{"sidebar": [0, 0, 240, 900], "main_pane": [240, 40, 1160, 860], "panes": panes,
                                 "window_controls": {"sidebar_hidden": self.sidebar_hidden}}]}
        if method == "debug.dock":
            return {"windows": [{"screen": {"strip": {"offset": 0, "max_offset": 2400}}}]}
        if method == "debug.home_native_fixture.open" or method == "settings.set":
            return {"ok": True}
        return {"ok": True}

    def action(self, name, args=None, focus=True, timeout=60, target=None):
        return self.rpc("action.run", {"action": name, "args": args or {}})

    def cli(self, *args, timeout=60):
        self.calls.append("cli " + " ".join(args[:2]))
        if args[:2] == ("workspace", "create"):
            self.created += 1
            ref = "workspace:" + args[args.index("--name") + 1]
            self.shown = ref if "--focus" in args else self.shown
            return subprocess.CompletedProcess(args, 0, ref + "\n", "")
        if args[0] == "workspace" and args[-1] == "focus":
            self.shown = args[1]
        return subprocess.CompletedProcess(args, 0, "", "")


def fixture_target(shown):
    """The InputTarget raw value the fixture app gives the scrolls in the shown workspace."""
    name = (shown or "").split("scroll jank ", 1)[-1]
    target = {"sidebar": "sidebar", "strip": "layout", "rows": "layout", "tabs": "layout", "terminal": "terminal",
              "chromium": "chromiumPage", "webkit": "webkitPage", "home": "layout"}.get(name, "other")
    return hid_input.TARGETS.index(target)


class FixtureRecording:
    """On stop, the fixture app's input.latency signposts for the scroll events posted since the phase began: one slot
    per event, presented 10 ms after it (over one 120 Hz vsync, so each frame's input came before the frame before
    it). While debug.stall runs, events 3 to 5 of every 10 wait for one frame 25 ms late (a missed presentation with
    input waiting: Chrome's delayed frame), and the next ones present no later than it (skipped, out of order)."""

    LATENCY_NS, STALL_NS = 10_000_000, 25_000_000

    def __init__(self, control, backend):
        self.control, self.backend, self.start = control, backend, len(backend.events)

    def presented_ns(self, times, index):
        if self.control.stalls and index % 10 in (3, 4, 5):
            last = min(index - index % 10 + 5, len(times) - 1)
            return times[last] + self.LATENCY_NS + self.STALL_NS
        return times[index] + self.LATENCY_NS

    def stop(self):
        lines, first_update = [], True
        target = fixture_target(self.control.shown)
        posted = [e for e in self.backend.events[self.start:] if e["type"] == "scroll"]
        times = [int(e["t"] * 1e9) + 1 for e in posted]
        for index, event in enumerate(posted):
            if event["phase"] == hid_input.SCROLL_BEGAN:
                kind, first_update = "scrollBegin", True
            elif event["phase"] == hid_input.SCROLL_CHANGED:
                kind = "scrollFirstUpdate" if first_update else "scrollUpdate"
                first_update = False
            elif event["phase"] == hid_input.SCROLL_ENDED:
                kind = "scrollEnd"
            else:
                kind = "scrollMomentum"
            frame = kind in UPDATE_KINDS
            presented = (self.presented_ns(times, index) - times[index]) // 1000 if frame else -1
            message = (f"kind={SCROLL_KIND_RAW[kind]} target={target} entry=0 source=0 vrr=0 coalesced=1 frame={int(frame)} "
                       f"gen_ns={times[index]} last_gen_us=-1 arrived_us=100 dispatch_start_us=150 ti_start_us=-1 "
                       f"ti_end_us=-1 dispatch_end_us=600 commit_us=900 content_us=-1 daemon_us=-1 pty_us=-1 echo_read_us=-1 "
                       f"echo_sent_us=-1 presented_us={presented}")
            lines.append(json.dumps({"eventType": "signpostEvent", "subsystem": hid_input.SIGNPOST_SUBSYSTEM, "category": "input",
                                     "signpostName": hid_input.INPUT_LATENCY, "signpostType": "event", "eventMessage": message}))
        return hid_input.latency_events(lines)


def tracker_cases(check):
    """Chrome's jank cases on the reference port (the same ones InputLatencyLedgerTests checks on the app's)."""
    vsync = 10_000_000
    tracker = ChromeScrollJank()
    tracker.scroll_started()
    tracker.frame(1, 1, 5 * vsync, vsync)  # a scroll's first frame: only the previous presentation
    tracker.frame(2, 2, 6 * vsync + 4 * vsync // 10, vsync)  # 1.4 vsync later: not janky
    tracker.frame(3, 3, 9 * vsync, vsync)  # 2.6 vsync later, input before the previous: janky, 2 missed
    check("first frame skipped", tracker.skipped_frames == 1 and tracker.presented_frames == 2, tracker.snapshot())
    check("1.4 and 2.6 vsync", tracker.delayed_frames == 1 and tracker.per_scroll["missed_sum"] == 2, tracker.per_scroll)
    tracker.frame(int(9.5 * vsync), int(9.5 * vsync), 12 * vsync, vsync)  # input after the previous presentation
    check("input after the previous frame is not jank", tracker.delayed_frames == 1, tracker.snapshot())
    tracker.scroll_started()
    snap = tracker.snapshot()["histograms"]
    check("per scroll at the next start", snap.get("Event.ScrollJank.DelayedFramesPercentage.PerScroll") == {"samples": [{"value": 33, "count": 1}]}
          and snap.get("Event.ScrollJank.MissedVsyncsMax.PerScroll") == {"samples": [{"value": 2, "count": 1}]}, snap)
    tracker.scroll_started()
    check("a second start changes nothing", tracker.snapshot()["histograms"] == snap, tracker.snapshot())
    for index in range(1, 66):
        tracker.frame(100 * vsync + index * vsync - 1, 100 * vsync + index * vsync - 1, 100 * vsync + index * vsync, vsync)
    # The window spans scrolls: the first scroll's 3 frames (1 delayed) and 61 of this one's 64 fill it (1 %).
    fixed = tracker.snapshot()["histograms"].get("Event.ScrollJank.DelayedFramesPercentage.FixedWindow")
    check("fixed window of 64", fixed == {"samples": [{"value": 1, "count": 1}]} and tracker.fixed["presented"] == 3,
          (fixed, tracker.fixed))


def signpost_event(kind, gen_ns, presented_ns):
    """A person's sidebar scroll slot as its input.latency signpost carries it (stages in whole microseconds after
    gen_ns, as InputLatencySignpostMessage.micros truncates), decoded."""
    frame = kind in UPDATE_KINDS
    presented = (presented_ns - gen_ns) // 1000 if frame else -1
    message = (f"kind={SCROLL_KIND_RAW[kind]} target={hid_input.TARGETS.index('sidebar')} entry=0 source=0 vrr=0 "
               f"coalesced=1 frame={int(frame)} gen_ns={gen_ns} last_gen_us=-1 presented_us={presented}")
    return hid_input.decode_latency_message(message)


def signpost_fold_cases(check):
    """Slots coalesced into one frame fold to that frame, though their truncated stages rebuild it a little apart.
    Checked against the reference port fed the exact frames, not against signpost_jank itself."""
    vsync = int(1e9 / 120)
    p1 = 1_000_000_000_000 + 333
    p2, p3 = p1 + vsync, p1 + 4 * vsync  # p3: three vsyncs after p2, its input from before p2 (delayed, 2 missed)
    frames = [(p1 - 5_000_123, p1 - 5_000_123, p1),
              (p2 - 6_000_777, p2 - 4_000_111, p2),  # two slots shown at exactly p2
              (p2 - 1_000_555, p2 - 1_000_555, p3)]
    events = [signpost_event("scrollBegin", p1 - 9_000_000, -1),
              signpost_event("scrollFirstUpdate", p1 - 5_000_123, p1),
              signpost_event("scrollUpdate", p2 - 4_000_111, p2),
              signpost_event("scrollUpdate", p2 - 6_000_777, p2),
              signpost_event("scrollUpdate", p2 - 1_000_555, p3),
              signpost_event("scrollBegin", p3 + 50_000_000, -1)]
    exact = ChromeScrollJank()
    exact.scroll_started()
    for first, last, presented in frames:
        exact.frame(first, last, presented, vsync)
    exact.scroll_started()
    folded = signpost_jank(events, vsync)
    check("coalesced slots are one frame", folded == exact.snapshot() and folded["skipped_frames"] == 1
          and folded["presented_frames"] == 2 and folded["delayed_frames"] == 1, (folded, exact.snapshot()))


def self_test():
    failures = []

    def check(name, condition, detail=""):
        if not condition:
            failures.append(f"{name}: {str(detail)[:400]}")

    tracker_cases(check)
    signpost_fold_cases(check)

    parser = build_parser()
    for argv in (["--targets", "sidebar,nope"], ["--sessions", "heavy"], ["--stall", "50ms"], ["--momentum", "1"]):
        try:
            with contextlib.redirect_stderr(io.StringIO()):
                validate(parser.parse_args(["--app", "x"] + argv), parser)
            failures.append(f"{argv} was not refused")
        except SystemExit:
            pass
    check("display rate", display_rate(parser.parse_args([]), {"hz": [60.0, 120.0]}) == 120.0
          and display_rate(parser.parse_args(["--rate", "90"]), {"hz": [120.0]}) == 90.0 and display_rate(parser.parse_args([]), {}) == 120.0)

    now = [0.0]

    def clock():
        return now[0]

    def sleep(seconds):
        now[0] += max(0.0, seconds)

    def run(control, argv):
        opts = parser.parse_args(["--app", "fixture", "--gestures", "4", "--changes", "10", "--momentum", "8",
                                  "--sidebar-workspaces", "12", "--tabs", "60", "--pause", "0"] + argv)
        validate(opts, parser)
        backend = hid_input.RecordingBackend(display_height=1080.0, clock=clock)
        poster = hid_input.HidPoster(backend, clock=clock, sleep=sleep)
        stress = latency_bench.load_stress_module()
        bench = Bench(opts, control, poster, lambda pid: FixtureRecording(control, backend), 120.0, pid=1, sleep=sleep,
                      log=lambda _: None, cef_problems=lambda cef: stress.cef_problems(cef))
        bench.run_session("light")
        return opts, backend, bench, report(header(opts, 120.0, {"hz": [120.0]}), bench.runs, bench.notes)

    # Every target, idle and under a stall.
    control = FixtureControl()
    opts, backend, bench, document = run(control, ["--stall", "none,50ms/100ms"])
    json.dumps(document, default=str)
    errors = [r for r in bench.runs if r.get("phase") == "error"]
    check("no failed phase", not errors, errors)
    dc4 = document["dc4"]
    check("every target and stall", sorted((e["target"], e["stall"]) for e in dc4)
          == sorted((t, s) for t in TARGETS for s in ("none", "50ms/100ms")), [(e["target"], e["stall"], e["status"], e.get("reason")) for e in dc4])
    check("every target measured", all(e["status"] == "ok" for e in dc4), [(e["target"], e["status"], e.get("reason")) for e in dc4])
    fields = {"presented_frames", "delayed_frames", "skipped_frames", "delayed_frames_percentage", "missed_vsyncs_sum", "missed_vsyncs_max",
              "histograms", "dropped_frames", "frames", "refresh_ms", "update_ms", "first_update_ms", "expectation", "met", "jank_source",
              "ledger_cross_check", "coalescer_deliveries_per_frame_max", "verified", "landed"}
    phase_runs = {(r["target"], r["stall"]): r for r in bench.runs if r.get("phase") == "scroll"}
    ledger = {"presented_frames": 7, "delayed_frames": 3, "skipped_frames": 5, "missed_vsyncs_sum": 11, "missed_vsyncs_max": 9}
    for entry in dc4:
        check(f"dc4 fields {entry['target']}", fields <= set(entry), sorted(fields - set(entry)))
        check(f"dc4 chrome names {entry['target']}", set(entry.get("histograms") or {}) == set(CHROME_NAMES), entry.get("histograms"))
        # DC4 takes the phase's signposts, never the ledger (its half-ring hand-off): the ledger is only beside it.
        own = jank_fields(phase_runs[(entry["target"], entry["stall"])]["signpost_jank"])
        check(f"dc4 judged on the signposts {entry['target']}", entry.get("jank_source") == "signpost"
              and all(entry[k] == own[k] for k in ledger) and entry["presented_frames"] != ledger["presented_frames"],
              {k: (entry.get(k), own[k]) for k in ledger})
        check(f"dc4 ledger beside it {entry['target']}", entry.get("ledger_cross_check") == ledger, entry.get("ledger_cross_check"))
    idle = {e["target"]: e for e in dc4 if e["stall"] == "none"}
    stalled = {e["target"]: e for e in dc4 if e["stall"] != "none"}
    for target, entry in idle.items():
        check(f"idle {target}", entry["met"] is True and entry["delayed_frames"] == 0 and entry["dropped_frames"] == 0
              and entry["delayed_frames_percentage"] == 0 and entry["presented_frames"] > 64, entry)
        check(f"idle {target} emits", (entry["histograms"]["Event.ScrollJank.DelayedFramesPercentage.PerScroll"] or {}).get("emitted") == 4
              and (entry["histograms"]["Event.ScrollJank.DelayedFramesPercentage.FixedWindow"] or {}).get("emitted", 0) >= 1, entry["histograms"])
        check(f"idle {target} update latency", (entry["update_ms"] or {}).get("p99") == 10.0, entry["update_ms"])
    for target, entry in stalled.items():
        expected = "zero_delayed" if target in ZERO_DELAYED_UNDER_STALL else "report"
        check(f"stall {target} expectation", entry["expectation"] == expected, entry)
        check(f"stall {target} jank", entry["delayed_frames"] > 0 and entry["missed_vsyncs_max"] >= 2 and entry["dropped_frames"] == 4, entry)
        check(f"stall {target} met", entry["met"] is (False if expected == "zero_delayed" else None), entry["met"])
    check("chromium verified", (idle["chromium-page"]["verified"] or {}).get("cef") and idle["webkit-page"]["verified"] == {"engine": "webkit"},
          (idle["chromium-page"]["verified"], idle["webkit-page"]["verified"]))
    check("expected targets landed", all(set(e["landed"]) <= set(EXPECTED_TARGETS[e["target"]]) for e in dc4), [(e["target"], e["landed"]) for e in dc4])
    scrolls = [e for e in backend.events if e["type"] == "scroll"]
    check("command held for strip and rows", any(e["flags"] == hid_input.FLAGS["command"] for e in scrolls)
          and any(e["flags"] == 0 for e in scrolls))
    check("workspaces for the sidebar", control.created >= 12, control.created)
    check("strip modifier set", "settings.set" in control.calls)
    check("rows shape", all(r["input"] == "real" and r["surface"] in TARGETS for r in document["rows"]) and document["rows"])
    check("header", document["header"]["input_reached"] and document["header"]["chrome_metrics"] == list(CHROME_NAMES))

    # Not Chromium: debug.cef with a WebKit fallback leaves chromium-page unmeasured, with the reason.
    control = FixtureControl(cef={"state": "ready", "fallback": [{"reason": "startFailed"}]})
    _, _, _, document = run(control, ["--targets", "chromium-page"])
    entry = document["dc4"][0]
    check("unverified chromium skipped", entry["status"] == "skipped" and "WebKit fallbacks" in (entry["reason"] or "")
          and entry["met"] is None, entry)

    # Wrong target, no ledger: scrolls that land elsewhere are not the target's, and the signposts stand in.
    control = FixtureControl(sections=("coalescer",))
    _, _, bench, document = run(control, ["--targets", "sidebar,terminal-scrollback"])
    entries = {e["target"]: e for e in document["dc4"]}
    check("signpost jank without a ledger", entries["sidebar"]["jank_source"] == "signpost" and entries["sidebar"]["met"] is True
          and entries["sidebar"]["ledger_cross_check"] is None and any("latency" in a for a in entries["sidebar"]["absent"]),
          entries["sidebar"])
    control = FixtureControl(sidebar_hidden=True)
    _, _, _, document = run(control, ["--targets", "sidebar"])
    check("hidden sidebar skipped", document["dc4"][0]["status"] == "skipped" and not document["header"]["input_reached"], document["dc4"][0])

    if failures:
        print("scroll-jank-bench self-test FAILED:\n  " + "\n  ".join(failures))
        return 1
    print(f"scroll-jank-bench self-test: ok ({len(TARGETS)} targets x 2 conditions)")
    return 0


def main():
    parser = build_parser()
    opts = parser.parse_args()
    if opts.self_test:
        return self_test()
    if not opts.app:
        parser.error("--app is required")
    validate(opts, parser)
    try:
        document = run_launched(opts)
    except Exception as error:  # the bench reports what it measured and exits 0; the error is in the report
        print(f"scroll-jank-bench: stopped: {error!r}", flush=True)
        document = {"header": header(opts, display_rate(opts, None)), "dc4": [], "rows": [], "runs": [], "log": [f"stopped: {error!r}"]}
    latency_bench.write(opts.json or (os.path.join(opts.out, "report.json") if opts.out else None), document)
    print(json.dumps({"dc4": document["dc4"], "header": document["header"]}, indent=1, default=str), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
