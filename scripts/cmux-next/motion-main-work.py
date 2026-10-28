#!/usr/bin/env python3
"""Main-thread render work per motion frame, counted (p03-rendering-002; done check DC2 and DC13 in
plans/cmux-next/chrome-parity/p03-rendering.md). Not a CI job and not a gate: an agent runs it on the fleet.

Chrome's model: cc::RenderingStatsInstrumentation (cc/debug/rendering_stats_instrumentation.cc) records
per-frame counts only while `record_rendering_stats` is on, and a timing trace is a separate run. The same split
here: this script arms RenderStats (`debug.frames` with `render: true`, task p03-rendering-001) and reports
counts only; its hooks cost time, so no millisecond from an armed pass is ever reported. Timing comes from
motion-hitches.py (task p03-rendering-007), with RenderStats disarmed: same --sessions, --tunable and --vdisplay,
its light session is `build_light` here, and its scenarios (motion_scenarios.py) are the rows below with the same
inputs, each timed step named for its row's phase, so the count and time reports join by (scenario, phase) (the
self-test checks every timed step is a row here).

Launches a tagged DEV app through bench_launch.py, once per session (fresh state each time, so STRESS is
perf-stress-session.py's shape and not STRESS plus the light workspace), and runs each scenario --rounds times:

  light   a workspace of 2 panes, the first with a terminal and a Chromium page (selected)
  stress  perf-stress-session.py, Chromium selected (60 workspaces, 4 x 3 grid plus nested splits, 6 tabs
          per pane, 10 busy terminals); its own shape check

  cmd-d              splitRight on the base pane (the new pane closes again, not counted)
  cmd-shift-d        splitDown, the same way
  cmd-w              closeTab on a pane made for it (its one terminal: the pane closes)
  zoom               toggleSplitZoom on the base pane; undo: toggleSplitZoom
  new-column         newColumn (closed again, not counted)
  close-last-column  STRIP_COLUMNS new columns, each right of the strip's last column, so the strip overflows and
                     its camera sits at the end; closePane on the last one (the camera shifts back); the others
                     close again, not counted
  workspace-switch   goToWorkspace to the neighbor workspace; undo: back
  strip-pan          Command + trackpad scroll over a pane of an overflowing strip (input-driven: each event may
                     do O(1) work, so frames 2..n of this row are per-event work, not spring frames)
  sidebar-toggle     toggleSidebar; undo: toggleSidebar
  toggle-omnibar     palette.browserToggleOmnibar on the base pane's Chromium page; undo: the same
  band-reveal        with the sidebar hidden, the pointer over the title bar's top-left corner opens the collapsed
                     toolbar band; undo: the pointer moves away (the band closes after its delay)
  window-zoom        zoomWindow; undo: zoomWindow
  hover-card         the pointer over the base pane's last tab: the tab hover card fades in; undo: the pointer
                     moves away (the card fades out)
  sidebar-reorder    moveWorkspaceUp on the measured workspace; undo: moveWorkspaceDown
  canvas-zoom        with the screen shown as a canvas (toggleCanvasLayout, untimed; off again after the row):
                     canvasZoomIn; undo: canvasZoomOut (the camera as it was)
  canvas-reset       the same canvas, one canvasZoomIn untimed first: canvasZoomReset (zoom 1 about the same center)
  canvas-overview    the same canvas: canvasOverview (center and zoom move); undo: canvasOverview (the camera before)
  scroll-to-row      stress only: goToWorkspace to the first workspace (the sidebar scrolls to its row); undo: back

The canvas rows count the camera's moves (p03-rendering-031: with `motion.renderServer` on, Core Animation runs
them and frames 2..n do no camera step); like strip-pan they are counting-only rows, not motion_scenarios.py's.

"Away" is `debug.mouse move` to the base pane's content centre, off every hover target, so DebugHover sends the
band's probe and the tab strip their mouseExited as a real pointer would (`leave` only clears the layout's
pointer: the card and the band would stay up). After the undo pass the card must be hidden and the band closed,
else the pass has an error; every scenario must leave no card showing and no pointer inside the title bar.

One counting pass per measured step (`do`, and `undo` where listed). `debug.frames start` with `render: true`
and `raw: true`; a pre-roll of idle frames; a read (`mark`); the step; a read when its reply came (`mark2`);
the settle; `stop`. Frame 1 is the step's own turn: the first frame in [mark, mark2] with more structural work
(frame sets, layouts, window calls or tracking-area adds) than the busiest idle pre-roll frame, else the first
with any, else mark2. Frames 2..n are every frame after it until stop. A pass whose pre-roll had structural
work is `noisy`: background work can land in its frames 2..n. Per pass: frame 1's counts, frames 2..n's sums
and per-frame max of frame_sets, layouts, window_calls, tracking_area_adds (contents_sets and damage_rects too,
as context), the idle pre-roll's sums, `debug.layout_counters` deltas, `update_visibility` (the
LayoutRootView.updateVisibility calls of the pass; a build without that counter is a problem, not a blank), and
the busiest RenderStats owners of the pass (all its frames).

DC2 wants frame_sets = 0 and layouts = 0 in frames 2..n of every spring with `motion.renderServer` on, and
updateVisibility <= 2 per spring; DC13 wants window_calls = 0. The summary prints each scenario's median and max
over rounds; this script reports, it does not judge, so a nonzero count is no failure. A pass whose step failed
counts nowhere, and `zero_frames_2_n` reads only passes that are not noisy: with none it is null, never true.

The motion backend: `--tunable motion.renderServer=on|off` (any KEY=VALUE, repeatable) sets the tunable over
`debug.tunables` after each launch and reads it back (another value fails the run); the run resets it at the
end. Every launch records the read-back `motion.renderServer`, asked for or not.

Measurement validity (PATTERNS P12): the report records host, chip, macOS and the display refresh (from an
unarmed `debug.frames` probe); `--expect-hz` fails the run on another rate. Chromium pages must be real
(`debug.cef` ready, no unavailable reason, no WebKit fallback) at the start and the end of each session.

Exit status: 0 when every pass ran; 1 when a pass or a check failed (the reason is in `problems`); 2 when a
session has the wrong shape (STRESS's StressShapeError, the light session's check, or a scenario that left
another pane count, focus, workspace order, a hover card or the pointer in the title bar behind).

Usage:
  motion-main-work.py --app APP --out DIR [--json PATH] [--sessions light,stress] [--scenarios a,b]
                      [--rounds 3] [--settle 1.0] [--vdisplay 120 | --expect-hz 120]
                      [--tunable motion.renderServer=on]
  motion-main-work.py --self-test     the frame split, the report rules and the scenario flow on a fake app
  motion-main-work.py --dry-run       every call on BenchApp, Stress and its module bound to the real signature
Fleet (an owned mini's console; base and head, macOS 26 and 27):
  nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA -- \\
    python3 scripts/cmux-next/motion-main-work.py --app "$NX_APP" --out "$NX_ARTIFACTS" --vdisplay 120 \\
    --tunable motion.renderServer=on
"""
import argparse, ast, contextlib, importlib.util, inspect, io, json, os, platform, subprocess, sys, tempfile, time, types

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bench_launch  # noqa: E402
from bench_launch import BenchApp  # noqa: E402

SCHEMA = "motion-main-work/v2"
# DC2 and DC13's counters, and the ones a frame-1 search reads (structural work, not content).
COUNTERS = ("frame_sets", "layouts", "window_calls", "tracking_area_adds")
CONTEXT = ("contents_sets", "damage_rects")
ALL_COUNTERS = COUNTERS + CONTEXT
WINDOW = (40, 40, 1600, 1000)
PRE_ROLL_S = 0.2
STRIP_COLUMNS = 3
RENDER_SERVER = "motion.renderServer"


class ShapeError(RuntimeError):
    """The session is not the shape this script measures."""


class CountingError(RuntimeError):
    """The build cannot count (no RenderStats) or a pass's reply has no per-frame counts."""


class SetupError(RuntimeError):
    """A tunable the run asked for does not read back as asked."""


# -- the frame split and the report rules (pure; --self-test covers them) --

def per_frame(reply):
    """{counter: [count per recorded frame]} from a `debug.frames stop` reply with `raw: true`; raises
    CountingError when a counter's series is missing or the series differ in length."""
    if not isinstance(reply, dict) or reply.get("error"):
        raise CountingError(f"debug.frames answered {str(reply)[:200]}")
    series = {}
    for key in ALL_COUNTERS:
        values = reply.get(f"{key}_per_frame")
        if not isinstance(values, list):
            raise CountingError(f"debug.frames has no {key}_per_frame: a build without RenderStats "
                                "(p03-rendering-001), or a Release build")
        series[key] = [int(v) for v in values]
    lengths = {len(v) for v in series.values()}
    if len(lengths) != 1:
        raise CountingError(f"per-frame series of different lengths {sorted(lengths)}")
    return series


def structural(series, index):
    return sum(series[key][index] for key in COUNTERS)


def split_pass(series, mark, mark2):
    """Splits one pass's per-frame counts at the step: frames [0, mark) are the idle pre-roll; frame 1 is the
    first frame in [mark, mark2] with more structural work than the busiest idle frame, else the first with any,
    else mark2 (a step whose own turn did nothing, such as a hover that shows its card after a delay); frames
    2..n follow it. `noisy`: the pre-roll had structural work. Returns the pass's count record, or raises
    CountingError when no frame came after the step."""
    total = len(series[COUNTERS[0]])
    mark = max(0, min(mark, total))
    if total == 0 or mark >= total:
        raise CountingError(f"no frame recorded after the step ({total} frames, mark {mark})")
    last = min(max(mark2, mark), total - 1)
    idle_max = max((structural(series, i) for i in range(mark)), default=0)
    turn = range(mark, last + 1)
    frame1 = next((i for i in turn if structural(series, i) > idle_max), None)
    if frame1 is None:
        frame1 = next((i for i in turn if structural(series, i) > 0), last)
    after = range(frame1 + 1, total)
    work = [i for i in after if structural(series, i) > 0]
    return {
        "noisy": idle_max > 0,
        "idle": {"frames": mark, "structural_max": idle_max, **{k: sum(series[k][:mark]) for k in ALL_COUNTERS}},
        "frame1": {"offset": frame1 - mark, **{k: series[k][frame1] for k in ALL_COUNTERS}},
        "frames_2_n": {"frames": len(after), **{k: sum(series[k][i] for i in after) for k in ALL_COUNTERS}},
        "frames_2_n_max": {k: max((series[k][i] for i in after), default=0) for k in ALL_COUNTERS},
        "frames_2_n_with_work": len(work),
        "last_work_frame": (work[-1] - frame1 + 1) if work else None,
    }


def is_count(value):
    return isinstance(value, int) and not isinstance(value, bool)


def counter_delta(before, after):
    """Integer counters of `debug.layout_counters` that moved between two reads."""
    if not isinstance(before, dict) or not isinstance(after, dict):
        return {}
    return {key: value - before[key] for key, value in after.items()
            if is_count(value) and is_count(before.get(key)) and value != before[key]}


def visibility_delta(before, after):
    """`update_visibility` calls between two `debug.layout_counters` reads, or None on a build without it."""
    values = [read.get("update_visibility") if isinstance(read, dict) else None for read in (before, after)]
    return values[1] - values[0] if all(is_count(v) for v in values) else None


def ms_keys(value, path=""):
    """Every key under `value` that names milliseconds (`*_ms`, `ms`): an armed pass reports none."""
    found = []
    if isinstance(value, dict):
        for key, item in value.items():
            here = f"{path}.{key}" if path else str(key)
            if str(key) == "ms" or str(key).endswith("_ms") or "_ms_" in str(key):
                found.append(here)
            found += ms_keys(item, here)
    elif isinstance(value, list):
        for index, item in enumerate(value):
            found += ms_keys(item, f"{path}[{index}]")
    return found


def median(values):
    values = sorted(v for v in values if isinstance(v, (int, float)))
    return values[len(values) // 2] if values else None


def summarize(passes):
    """One row per (session, scenario, phase): per counter the median and max over rounds of frames 2..n of the
    passes whose step ran (`counted`; a failed step counts nowhere), how many of them are `noisy`,
    `zero_frames_2_n` (DC2: frame_sets and layouts 0 in every counted pass that is not noisy; null when there is
    none), `update_visibility` per pass, and the errors."""
    groups = {}
    for record in passes:
        groups.setdefault((record["session"], record["scenario"], record["phase"]), []).append(record)
    rows = []
    for (session, scenario, phase), records in groups.items():
        counted = [r for r in records if r.get("counts") and not r.get("error")]
        quiet = [r for r in counted if not r["counts"].get("noisy")]
        row = {"session": session, "scenario": scenario, "phase": phase, "rounds": len(records),
               "counted": len(counted), "noisy": len(counted) - len(quiet),
               "errors": sorted({r["error"] for r in records if r.get("error")})}
        for key in ALL_COUNTERS:
            values = [r["counts"]["frames_2_n"][key] for r in counted]
            row[key] = {"median": median(values), "max": max(values) if values else None}
        row["frames"] = median([r["counts"]["frames_2_n"]["frames"] for r in counted])
        visibility = [r["update_visibility"] for r in counted if r.get("update_visibility") is not None]
        row["update_visibility"] = {"median": median(visibility), "max": max(visibility)} if visibility else None
        row["update_visibility_missing"] = len(counted) - len(visibility)
        row["zero_frames_2_n"] = all(
            r["counts"]["frames_2_n"]["frame_sets"] == 0 and r["counts"]["frames_2_n"]["layouts"] == 0
            for r in quiet) if quiet else None
        rows.append(row)
    return rows


def tunable_arg(text):
    """KEY=VALUE for --tunable: on/true and off/false are booleans, else JSON, else the string."""
    key, sep, raw = text.partition("=")
    if not sep or not key.strip():
        raise argparse.ArgumentTypeError(f"--tunable wants KEY=VALUE, not {text!r}")
    lowered = raw.strip().lower()
    if lowered in ("on", "true"):
        return key.strip(), True
    if lowered in ("off", "false"):
        return key.strip(), False
    try:
        return key.strip(), json.loads(raw)
    except ValueError:
        return key.strip(), raw


# -- the app side --

def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def error_of(reply):
    return str(reply.get("error"))[:200] if isinstance(reply, dict) and reply.get("error") else None


def build_light(builder, chromium_problems):
    """The light session, for this script and motion-hitches.py (their reports join by scenario, so both measure
    this one): a workspace of 2 panes, the first with a terminal and a Chromium page (selected), and a second
    workspace to switch to. Returns its shape ({measured, base, panes, ...}); raises ShapeError on another one.
    `builder` is a perf-stress-session.Stress; `chromium_problems()` lists why Chromium is not real."""
    workspace, panes = builder.build_light(kinds=("chromium",))
    tabs = builder.tabs(workspace, panes[0]) if panes else []
    selected = next((t.get("kind") for t in tabs if t.get("selected")), None)
    shape = {"measured": workspace, "base": panes[0] if panes else None, "panes": len(panes),
             "base_tabs": [t.get("kind") for t in tabs], "base_selected": selected,
             "workspaces": len(builder.workspaces()), "chromium_unavailable": chromium_problems()}
    problems = []
    if len(panes) != 2:
        problems.append(f"{len(panes)} panes, not 2")
    if selected != "browser":
        problems.append(f"the base pane shows a {selected} tab, not the Chromium page")
    if shape["workspaces"] < 2:
        problems.append("no second workspace to switch to")
    if shape["chromium_unavailable"]:
        problems.append(f"Chromium is not real: {shape['chromium_unavailable']}")
    if problems:
        raise ShapeError("light session has the wrong shape: " + "; ".join(problems))
    return shape


def neighbor(order, workspace):
    """The workspace a switch goes to: the one above `workspace` in the sidebar's `order`, else the one below."""
    index = order.index(workspace)
    return order[index - 1] if index > 0 else order[index + 1]


class Session:
    """One measured workspace in the launched app: its builder (perf-stress-session.Stress), the base pane, the
    pane count and workspace order that every scenario must leave as it found them. `sleep` is the harness's
    clock (the self-test's fake app advances its frames on it)."""

    def __init__(self, name, app, stress_module, opts, sleep=time.sleep):
        self.name, self.app, self.stress_module, self.opts, self.sleep = name, app, stress_module, opts, sleep
        self.builder = stress_module.Stress(lambda m, p=None, timeout=60: app.rpc(m, p, timeout), selected="chromium")
        self.workspace = self.base = None
        self.panes = 0
        self.order = []
        self.shape = {}
        self.hover_state = {}

    # Socket helpers.

    def rpc(self, method, params=None, timeout=60):
        return self.app.rpc(method, params, timeout)

    def act(self, name, args=None, target=None):
        params = {"action": name, "args": args or {}, "focus": True, "origin": "script"}
        if target:
            params["target"] = target
        return error_of(self.rpc("action.run", params, timeout=60))

    def pane_ids(self):
        return [p["id"] for p in self.builder.panes(self.builder.workspace(self.workspace))]

    def workspace_ids(self):
        return [w["id"] for w in self.builder.workspaces()]

    def wait_panes(self, count, seconds=10):
        return self.stress_module.wait(lambda: len(self.pane_ids()) == count, seconds, step=0.05)

    def chromium_problems(self):
        return self.stress_module.cef_problems(self.rpc("debug.cef"), self.stress_module.WEB_DEV_CONFIG)

    def windows(self):
        return (self.rpc("debug.pane_chrome") or {}).get("windows") or []

    def card_showing(self):
        return (self.rpc("debug.hover_cards") or {}).get("card_showing") == "true"

    def pointer_in_titlebar(self):
        return any((w.get("titlebar_buttons") or {}).get("pointer_inside") for w in self.windows())

    def band_presence(self):
        for window in self.windows():
            controls = window.get("window_controls") or {}
            if "band_presence" in controls:
                return controls["band_presence"]
        return None

    # The two sessions.

    def build(self):
        if self.name == "stress":
            self.shape = self.builder.build()  # raises StressShapeError on another shape
            self.workspace = self.shape["measured"]
            self.base = self.pane_ids()[0]
        else:
            self.shape = build_light(self.builder, self.chromium_problems)
            self.workspace, self.base = self.shape["measured"], self.shape["base"]
        self.panes = len(self.pane_ids())
        self.order = self.workspace_ids()
        self.builder.focus_pane(self.base)

    def restore_check(self, scenario):
        """Raises ShapeError when `scenario` left another pane count, workspace order or shown workspace, a hover
        card showing, or the pointer inside the title bar (the band engaged)."""
        if not self.wait_panes(self.panes):
            raise ShapeError(f"{self.name}: {scenario} left {len(self.pane_ids())} panes, not {self.panes}")
        order = self.workspace_ids()
        if order != self.order:
            raise ShapeError(f"{self.name}: {scenario} left the workspaces in another order")
        if not self.builder.window_showing(self.workspace):
            raise ShapeError(f"{self.name}: {scenario} left workspace {self.workspace} hidden")
        if self.card_showing():
            raise ShapeError(f"{self.name}: {scenario} left a hover card showing")
        if self.pointer_in_titlebar():
            raise ShapeError(f"{self.name}: {scenario} left the pointer inside the title bar")
        self.builder.focus_pane(self.base)

    # Scenario steps.

    def neighbor(self):
        return neighbor(self.order, self.workspace)

    def target_for(self, verb):
        """Splits aim at the base pane by id (as the STRESS builder does); other verbs act on the focused pane,
        which every scenario starts on (`restore_check` focuses it)."""
        return f"pane:{self.base}" if verb.startswith("split") else None

    def made_pane(self, verb, target=None, settle=None):
        """`verb` (on `target`, else as `target_for` says), untimed; returns the new pane's id once its spring
        landed."""
        before = set(self.pane_ids())
        if self.act(verb, target=target or self.target_for(verb)):
            return None
        made = self.stress_module.wait(lambda: next((p for p in self.pane_ids() if p not in before), None), 15, step=0.05)
        self.sleep(self.opts.settle if settle is None else settle)  # test harness: the untimed spring lands
        return made

    def last_column_pane(self):
        """A pane of the strip's last column (the topology's highest `column`), or None."""
        panes = [p for p in self.builder.panes(self.builder.workspace(self.workspace)) if is_count(p.get("column"))]
        if not panes:
            return None
        last = max(p["column"] for p in panes)
        return next(p["id"] for p in panes if p["column"] == last)

    def close_pane(self, pane):
        return self.act("closePane", target=f"pane:{pane}") if pane else "no pane to close"

    def close_new(self, before):
        for pane in [p for p in self.pane_ids() if p not in before]:
            self.close_pane(pane)
        self.sleep(self.opts.settle)  # test harness: the untimed close lands

    def away(self):
        """The pointer to the base pane's content centre, off every hover target: tracking-area owners get their
        mouseExited (DebugHover), the hover cards hear the move."""
        return error_of(self.rpc("debug.mouse", {"action": "move", "pane": self.base}))

    def split_and_close(self, verb):
        """`verb` counted; the pane it made closes again, uncounted."""
        before = set()

        def prepare():
            before.clear()
            before.update(self.pane_ids())
            return None

        def perform():
            return self.act(verb, target=self.target_for(verb))

        def cleanup():
            self.close_new(before)
        return prepare, perform, cleanup

    def cmd_w(self):
        state = {}

        def prepare():
            state["pane"] = self.made_pane("splitRight")
            if not state["pane"]:
                return "splitRight made no pane"
            tabs = self.builder.tabs(self.workspace, state["pane"])
            state["tab"] = tabs[0]["id"] if len(tabs) == 1 else None
            return None if state["tab"] else f"the new pane has {len(tabs)} tabs, not 1"

        def perform():
            error = self.act("closeTab", target=f"tab:{state['tab']}")
            if not error and not self.wait_panes(self.panes):
                return "closeTab left the pane"
            return error
        return prepare, perform

    def close_last_column(self):
        """STRIP_COLUMNS columns, each right of the strip's last column (the strip overflows, the camera follows
        the newest to the end); the counted step closes the last one; the others close again, uncounted."""
        before = set()
        state = {}

        def prepare():
            before.clear()
            before.update(self.pane_ids())
            state.clear()
            for index in range(STRIP_COLUMNS):
                last = self.last_column_pane()
                if not last:
                    return "the topology names no pane column"
                made = self.made_pane("newColumn", target=f"pane:{last}", settle=0.5)
                if not made:
                    return f"newColumn right of {last} made no column ({index} of {STRIP_COLUMNS})"
                state["pane"] = made
            if self.last_column_pane() != state["pane"]:
                return f"the newest column {state['pane']} is not the strip's last one ({self.last_column_pane()})"
            self.sleep(self.opts.settle)  # test harness: the camera lands at the strip's end
            return None

        def perform():
            return self.close_pane(state["pane"])

        def cleanup():
            self.close_new(before)
        return prepare, perform, cleanup

    def strip_pan(self):
        """Overflows the strip with STRIP_COLUMNS new columns, pans it with one Command trackpad gesture over the
        newest column (bench-command-pan.py's gesture), closes the columns again."""
        before = set()
        state = {}

        def prepare():
            before.clear()
            before.update(self.pane_ids())
            for _ in range(STRIP_COLUMNS):
                self.act("newColumn")
                self.sleep(0.5)  # test harness: each column's motion lands before the next
            made = [p for p in self.pane_ids() if p not in before]
            if len(made) < STRIP_COLUMNS:
                return f"newColumn made {len(made)} of {STRIP_COLUMNS} columns"
            reply = self.rpc("debug.mouse", {"action": "hover", "pane": made[-1]}) or {}
            if not isinstance(reply.get("x"), (int, float)):
                return f"no point for pane {made[-1]}: {str(reply)[:120]}"
            state["point"] = {"x": reply["x"], "y": reply["y"]}
            self.sleep(self.opts.settle)  # test harness: the last column lands
            return None

        def perform():
            delivered = []

            def send(phase, dx, hover):
                reply = self.rpc("debug.mouse", {"action": "scroll", **state["point"], "dx": dx, "dy": 0, "phase": phase,
                                                 "modifiers": ["cmd"], "hover": hover}) or {}
                delivered.append(reply.get("delivered_to") or reply.get("error") or "?")
            send("began", 24, True)
            for _ in range(40):
                self.sleep(1 / 120)  # test harness: one event per 120 Hz frame, like a trackpad
                send("changed", 24, False)
            send("ended", 0, False)
            taken = sum(1 for d in delivered if d == "LayoutRootView")
            return None if taken == len(delivered) else f"the layout took {taken} of {len(delivered)} events"

        def cleanup():
            self.close_new(before)
            # The gesture's first event moved the pointer onto the newest column, which closed: away from it.
            self.away()
        return prepare, perform, cleanup

    def canvas(self, zoomed=False):
        """The measured screen shown as a canvas for the row (toggleCanvasLayout, untimed; with `zoomed`, one
        canvasZoomIn after it, untimed), and as its daemon layout again after it. Returns (prepare, cleanup)."""
        state = {}

        def prepare():
            state["on"] = False
            error = self.act("toggleCanvasLayout")
            if error:
                return f"toggleCanvasLayout: {error}"
            state["on"] = True
            error = self.act("canvasZoomIn") if zoomed else None
            self.sleep(self.opts.settle)  # test harness: the untimed change lands before the counted step
            return f"canvasZoomIn: {error}" if error else None

        def cleanup():
            if state.pop("on", False):
                self.act("toggleCanvasLayout")
                self.sleep(self.opts.settle)  # test harness: the daemon layout lands
        return prepare, cleanup

    def band(self):
        """The collapsed toolbar band: sidebar hidden (untimed), the pointer over the top-left corner, then away."""
        x, y = self.opts.band_point

        def prepare():
            error = self.act("toggleSidebar")
            self.sleep(self.opts.settle)  # test harness: the sidebar slide lands
            return error

        def perform():
            return error_of(self.rpc("debug.mouse", {"action": "move", "x": x, "y": y}))

        def opened():
            shown = self.band_presence()
            return None if isinstance(shown, (int, float)) and shown > 0 else f"the band did not open at ({x}, {y}): presence {shown}"

        def closed():
            shown = self.band_presence()
            if shown != 0 or self.pointer_in_titlebar():
                return f"the band did not close when the pointer moved away: presence {shown}"
            return None

        def cleanup():
            self.act("toggleSidebar")
            self.sleep(self.opts.settle)  # test harness: the sidebar slide lands
        return prepare, perform, opened, self.away, closed, cleanup

    def hover(self):
        state = self.hover_state

        def prepare():
            for window in self.windows():
                pane = next((p for p in window.get("panes") or [] if p.get("pane") == self.base), None)
                if pane and pane.get("strip") and pane.get("tab_slots"):
                    sx, sy, _sw, sh = pane["strip"]
                    slot = pane["tab_slots"][-1]
                    state["point"] = {"x": sx + slot[0] + slot[1] / 2, "y": sy + sh / 2}
                    try:
                        state["delay_s"] = float((self.rpc("debug.hover_cards") or {}).get("delay_ms") or "") / 1000
                    except ValueError:
                        state["delay_s"] = 0.6  # the hover card's default delay is 500 ms
                    return None
            return "no tab strip geometry for the base pane"

        def perform():
            return error_of(self.rpc("debug.mouse", {"action": "move", **state["point"]}))

        def shown():
            return None if self.card_showing() else "no hover card showed"

        def hidden():
            return "the hover card still shows after the pointer moved away" if self.card_showing() else None
        return prepare, perform, shown, self.away, hidden

    def scenarios(self):
        """(name, prepare, perform, after_do, undo, after_undo, cleanup, settle_s); each callable returns an error
        or None. `after_do` and `after_undo` check the step did what it names (read after its counted pass)."""
        s = self.opts.settle
        go = lambda target: (lambda: self.act("goToWorkspace", {"workspace": target}))  # noqa: E731
        run = lambda verb: (lambda: self.act(verb))  # noqa: E731
        split_right = self.split_and_close("splitRight")
        split_down = self.split_and_close("splitDown")
        new_column = self.split_and_close("newColumn")
        cmd_w_prepare, cmd_w = self.cmd_w()
        column_prepare, column_close, column_cleanup = self.close_last_column()
        pan_prepare, pan, pan_cleanup = self.strip_pan()
        band_prepare, band_open, band_opened, band_away, band_closed, band_cleanup = self.band()
        hover_prepare, hover_in, hover_shown, hover_away, hover_hidden = self.hover()
        zoom_prepare, zoom_cleanup = self.canvas()
        reset_prepare, reset_cleanup = self.canvas(zoomed=True)
        overview_prepare, overview_cleanup = self.canvas()
        rows = [
            ("cmd-d", *split_right[:2], None, None, None, split_right[2], s),
            ("cmd-shift-d", *split_down[:2], None, None, None, split_down[2], s),
            ("cmd-w", cmd_w_prepare, cmd_w, None, None, None, None, s),
            ("zoom", None, run("toggleSplitZoom"), None, run("toggleSplitZoom"), None, None, s),
            ("new-column", *new_column[:2], None, None, None, new_column[2], s),
            ("close-last-column", column_prepare, column_close, None, None, None, column_cleanup, s),
            ("workspace-switch", None, go(self.neighbor()), None, go(self.workspace), None, None, s),
            ("strip-pan", pan_prepare, pan, None, None, None, pan_cleanup, s),
            ("sidebar-toggle", None, run("toggleSidebar"), None, run("toggleSidebar"), None, None, s),
            ("toggle-omnibar", None, run("palette.browserToggleOmnibar"), None, run("palette.browserToggleOmnibar"),
             None, None, s),
            ("band-reveal", band_prepare, band_open, band_opened, band_away, band_closed, band_cleanup, s + 0.4),
            ("window-zoom", None, run("zoomWindow"), None, run("zoomWindow"), None, None, s + 0.4),
            ("hover-card", hover_prepare, hover_in, hover_shown, hover_away, hover_hidden, None, None),
            ("sidebar-reorder", None, run("moveWorkspaceUp"), None, run("moveWorkspaceDown"), None, None, s),
            ("canvas-zoom", zoom_prepare, run("canvasZoomIn"), None, run("canvasZoomOut"), None, zoom_cleanup, s),
            ("canvas-reset", reset_prepare, run("canvasZoomReset"), None, None, None, reset_cleanup, s),
            ("canvas-overview", overview_prepare, run("canvasOverview"), None, run("canvasOverview"), None, overview_cleanup, s),
        ]
        if self.name == "stress":
            rows.append(("scroll-to-row", None, go(self.order[0]), None, go(self.workspace), None, None, s))
        return rows

    def settle_for(self, name, settle):
        """The hover card's settle is its delay plus the fade (and, away, its grace plus the fade)."""
        if settle is None:
            return self.hover_state.get("delay_s", 0.6) + self.opts.settle
        return settle


def refresh_probe(app, sleep=time.sleep):
    """The display refresh from an unarmed `debug.frames` pass (no RenderStats hooks)."""
    app.rpc("debug.frames", {"action": "start"})
    sleep(0.3)  # test harness: about 36 frames at 120 Hz
    reply = app.rpc("debug.frames", {"action": "stop"}) or {}
    refresh = reply.get("refresh_ms") if isinstance(reply, dict) else None
    return round(refresh, 3) if isinstance(refresh, (int, float)) and refresh > 0 else None


def apply_tunables(app, wanted):
    """Sets each (key, value) of `wanted` over `debug.tunables`, then reads `motion.renderServer` and every wanted
    key back: {key: value, or "absent: <why>"}. Raises SetupError when a wanted key reads back another value."""
    for key, value in wanted:
        app.rpc("debug.tunables", {"action": "set", "key": key, "value": value})
    readback = {}
    for key in dict.fromkeys([RENDER_SERVER] + [key for key, _ in wanted]):
        row = app.rpc("debug.tunables", {"action": "get", "key": key})
        readback[key] = row["value"] if isinstance(row, dict) and "value" in row and not error_of(row) \
            else f"absent: {error_of(row) or str(row)[:120]}"
    wrong = [f"{key} reads back {readback[key]!r}, not {value!r}" for key, value in wanted if readback[key] != value]
    if wrong:
        raise SetupError("; ".join(wrong))
    return readback


def reset_tunables(app, wanted):
    """Back to the defaults (`set` with a null value) for every key this run set."""
    for key, _ in wanted:
        app.rpc("debug.tunables", {"action": "set", "key": key, "value": None})


def counting_pass(session, name, phase, round_index, step, settle):
    """One armed pass around `step`; returns its record (counts only)."""
    app, sleep = session.app, session.sleep
    record = {"session": session.name, "scenario": name, "phase": phase, "round": round_index, "error": None,
              "counts": None, "layout_counters": {}, "update_visibility": None, "owners": []}
    counters = app.rpc("debug.layout_counters") or {}
    started = app.rpc("debug.frames", {"action": "start", "render": True, "raw": True}, timeout=120) or {}
    if error_of(started) or started.get("render_armed") is not True:
        raise CountingError(f"debug.frames did not arm RenderStats ({str(started)[:200]}): a Release build, or one "
                            "before p03-rendering-001")
    try:
        sleep(PRE_ROLL_S)  # test harness: idle frames before the step
        mark = (app.rpc("debug.frames") or {}).get("frames") or 0
        record["error"] = step()
        mark2 = (app.rpc("debug.frames") or {}).get("frames") or mark
        sleep(settle)  # test harness: the spring lands before stop
    finally:
        stopped = app.rpc("debug.frames", {"action": "stop", "raw": True}, timeout=60)
    record["counts"] = split_pass(per_frame(stopped), mark, mark2)
    after = app.rpc("debug.layout_counters") or {}
    record["layout_counters"] = counter_delta(counters, after)
    record["update_visibility"] = visibility_delta(counters, after)
    record["owners"] = [{k: v for k, v in owner.items() if k in ("owner",) + ALL_COUNTERS}
                        for owner in (stopped.get("render_owners") or [])[:8]]
    return record


def print_pass(record):
    after = (record.get("counts") or {}).get("frames_2_n") or {}
    print(f"  {record['session']:<6} {record['scenario']:<18} {record['phase']:<4} #{record['round']}: frames 2..n "
          f"{after.get('frames')}: frame_sets {after.get('frame_sets')} layouts {after.get('layouts')} window_calls "
          f"{after.get('window_calls')} tracking {after.get('tracking_area_adds')} visibility "
          f"{record.get('update_visibility')}  err {record.get('error')}", flush=True)


def run_session(session, opts, report):
    try:
        session.build()
    except (ShapeError, session.stress_module.StressShapeError) as error:
        raise ShapeError(str(error)) from error
    report["sessions"][session.name] = session.shape
    print(f"MOTION-SESSION {session.name} " + json.dumps(session.shape)[:600], flush=True)
    wanted = set(filter(None, opts.scenarios.split(",")))
    plan = [row for row in session.scenarios() if not wanted or row[0] in wanted]
    for round_index in range(opts.rounds):
        for name, prepare, perform, after_do, undo, after_undo, cleanup, wanted_settle in plan:
            problem = prepare() if prepare else None
            settle = session.settle_for(name, wanted_settle)  # after prepare: the hover card's delay is read there
            if problem:
                report["passes"].append({"session": session.name, "scenario": name, "phase": "do", "round": round_index,
                                         "error": f"prepare: {problem}", "counts": None, "layout_counters": {},
                                         "update_visibility": None, "owners": []})
                print_pass(report["passes"][-1])
            else:
                for phase, step, check in (("do", perform, after_do), ("undo", undo, after_undo)):
                    if not step:
                        continue
                    record = counting_pass(session, name, phase, round_index, step, settle)
                    if not record["error"] and check:
                        record["error"] = check()
                    report["passes"].append(record)
                    print_pass(record)
            if cleanup:
                cleanup()
            session.restore_check(name)
    late = session.chromium_problems()
    if late:
        report["problems"].append(f"{session.name}: Chromium was not real at the end: {late}")


def environment(app, opts, refresh_ms):
    def out(*cmd):
        try:
            return subprocess.run(cmd, capture_output=True, text=True, timeout=10).stdout.strip() or None
        except (OSError, subprocess.TimeoutExpired):
            return None
    try:
        sha = bench_launch.build_sha(app.app)
    except bench_launch.RecordError as error:
        sha = f"unknown: {error}"[:200]
    facts = bench_launch.host_facts()
    return {"host": facts.get("host") or platform.node(), "macos": facts.get("macos"),
            "macos_build": out("/usr/bin/sw_vers", "-buildVersion"),
            "chip": out("/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"),
            "low_power_mode": facts.get("low_power_mode"), "build_sha": sha,
            "main_display_hz": bench_launch.main_display_hz(), "refresh_ms": refresh_ms,
            "refresh_hz": round(1000 / refresh_ms, 1) if refresh_ms else None,
            "vdisplay_hz": opts.vdisplay or None, "expect_hz": opts.expect_hz, "rounds": opts.rounds}


def main(opts, launcher=BenchApp, stress_module=None, sleep=time.sleep, facts=environment):
    """The run. `launcher` makes the app (BenchApp), `stress_module` is perf-stress-session.py, `sleep` the harness
    clock and `facts` the host record: the self-test passes fakes of all four."""
    os.makedirs(opts.out, exist_ok=True)
    stress_module = stress_module or load("perf_stress_session", "perf-stress-session.py")
    report = {"schema": SCHEMA, "environment": {}, "launches": {}, "sessions": {}, "passes": [], "summary": [],
              "problems": []}
    status = 0
    display = None
    expect = opts.expect_hz or opts.vdisplay
    try:
        if opts.vdisplay:
            display = stress_module.start_vdisplay(opts.vdisplay, opts.out, opts.vdisplay_hold)
        for name in filter(None, opts.sessions.split(",")):
            # Each session in its own launch: fresh state, so no session measures another's leftovers.
            folder = os.path.join(opts.out, name)
            os.makedirs(folder, exist_ok=True)
            app = launcher(opts.app, out=folder, window=WINDOW)
            try:
                app.launch(timeout=180)
                refresh = refresh_probe(app, sleep)
                if not report["environment"]:
                    report["environment"] = facts(app, opts, refresh)
                    print("MOTION-ENV " + json.dumps(report["environment"]), flush=True)
                launch = {"refresh_ms": refresh, "tunables_asked": dict(opts.tunable)}
                report["launches"][name] = launch
                launch["tunables"] = apply_tunables(app, opts.tunable)
                report["environment"].setdefault("tunables", launch["tunables"])
                print(f"MOTION-LAUNCH {name} " + json.dumps(launch), flush=True)
                if expect and (not refresh or abs(refresh - 1000 / expect) > 0.15 * 1000 / expect):
                    raise ShapeError(f"the display refreshes every {refresh} ms, not {expect} Hz")
                run_session(Session(name, app, stress_module, opts, sleep), opts, report)
            finally:
                try:
                    reset_tunables(app, opts.tunable)
                except Exception as error:  # the app may be gone; the reason goes in the report
                    report["problems"].append(f"{name}: the tunables were not reset: {type(error).__name__}: {error}")
                app.stop()
    except ShapeError as error:
        report["problems"].append(f"ShapeError: {error}")
        status = 2
    except stress_module.StressShapeError as error:
        report["problems"].append(f"StressShapeError: {error}")
        status = 2
    except Exception as error:  # the run fails with the reason in the report
        report["problems"].append(f"{type(error).__name__}: {error}")
        status = 1
    finally:
        if display:
            display.terminate()  # the helper this script started, by its process
    report["summary"] = summarize(report["passes"])
    report["problems"] += [f"{r['session']} {r['scenario']} {r['phase']}: {'; '.join(r['errors'])}"
                           for r in report["summary"] if r["errors"]]
    if any(r["update_visibility_missing"] for r in report["summary"]):
        report["problems"].append("debug.layout_counters has no update_visibility: a build before p03-rendering-002 "
                                  "counts no LayoutRootView.updateVisibility calls, so DC2's per-spring limit is not measured")
    carried = ms_keys({"passes": report["passes"], "summary": report["summary"]})
    if carried:
        report["problems"].append(f"armed passes carry milliseconds: {carried[:8]}")
    if report["problems"] and not status:
        status = 1
    if not report["passes"] and not status:
        report["problems"].append("no pass ran")
        status = 1
    print("\n== frames 2..n per pass (median / max over rounds); counts, never ms")
    print(f"  {'session':<6} {'scenario':<18} {'phase':<5} {'sets':>9} {'layouts':>9} {'window':>9} {'track':>9} "
          f"{'vis':>7} {'noisy':>5} zero")
    for row in report["summary"]:
        cell = lambda key: f"{row[key]['median']}/{row[key]['max']}"  # noqa: E731
        vis = row["update_visibility"]
        print(f"  {row['session']:<6} {row['scenario']:<18} {row['phase']:<5} {cell('frame_sets'):>9} {cell('layouts'):>9} "
              f"{cell('window_calls'):>9} {cell('tracking_area_adds'):>9} {(str(vis['median']) if vis else 'none'):>7} "
              f"{row['noisy']:>5} {row['zero_frames_2_n']}", flush=True)
    path = opts.json or os.path.join(opts.out, "motion-main-work.json")
    with open(path, "w") as f:
        json.dump(report, f, indent=1)
    print(f"MOTION-REPORT {path}", flush=True)
    print("RESULT " + ("PASS" if not status else f"FAIL {json.dumps(report['problems'])[:2000]}"), flush=True)
    return status


# -- the self-test: the pure rules, then the scenario flow and the exit codes on a fake app --

class FakeApp:
    """A socket double for --self-test: the topology, the actions the scenarios run, `debug.frames` with
    RenderStats (one frame per action, idle frames on the harness clock), hover cards, the toolbar band and
    `debug.tunables`. `knobs` make it wrong on purpose: light_panes, leak_close, no_render, no_visibility,
    sticky_card, ignore_tunables."""

    STRIP = [0.0, 40.0, 800.0, 28.0]  # the base pane's tab strip, top-left window points
    CONTENT = (400.0, 500.0)  # a pane's content centre

    def __init__(self, knobs):
        self.knobs = knobs
        self.count = 0
        self.frames = None
        self.render = False
        self.layout_passes = self.visibility = 0
        self.sidebar_hidden = self.band_inside = self.card = self.running = self.canvas = False
        self.tunables = {RENDER_SERVER: False}
        self.mouse_actions = []
        first = self.new_workspace()
        self.spaces = [first]
        self.shown, self.focused = first["id"], first["screens"][0]["panes"][0]["id"]

    def make_id(self, prefix):
        self.count += 1
        return f"{prefix}{self.count}"

    def new_pane(self, column, kinds=("terminal",)):
        tabs = [{"id": self.make_id("t"), "kind": kind, "selected": i == len(kinds) - 1} for i, kind in enumerate(kinds)]
        return {"id": self.make_id("p"), "column": column, "tabs": tabs}

    def new_workspace(self, columns=1):
        panes = [self.new_pane(0, ("terminal", "browser"))] + [self.new_pane(c) for c in range(1, columns)]
        return {"id": self.make_id("w"), "screens": [{"panes": panes}]}

    def launch(self, timeout=180):
        self.running = True

    def stop(self):
        self.running = False

    def sleep(self, seconds):
        if self.frames is not None:
            self.frames += [dict.fromkeys(ALL_COUNTERS, 0) for _ in range(max(1, round(seconds * 120)))]

    def work(self, **counts):
        """The action's own frame (frame 1); a correct build does nothing in the frames after it."""
        self.layout_passes += 1
        self.visibility += 1
        if self.frames is not None:
            self.frames.append({**dict.fromkeys(ALL_COUNTERS, 0), **counts})

    def find(self, pane_id):
        for space in self.spaces:
            for pane in space["screens"][0]["panes"]:
                if pane["id"] == pane_id:
                    return space, pane
        return None, None

    def find_tab(self, tab_id):
        for space in self.spaces:
            for pane in space["screens"][0]["panes"]:
                if any(t["id"] == tab_id for t in pane["tabs"]):
                    return space, pane
        return None, None

    def topology(self):
        return {"workspaces": self.spaces, "windows": [{"key": "win1", "workspace": self.shown, "focused_pane": self.focused}],
                "focus": {"workspace": self.shown, "pane": self.focused}}

    def rpc(self, method, params=None, timeout=60):
        if not self.running:
            raise ConnectionError(f"{method}: the fake app is not running")
        params = params or {}
        handler = getattr(self, "on_" + method.replace(".", "_"), None)
        return handler(params) if handler else {"error": f"unknown method {method}"}

    def on_snapshot_get(self, params):
        return {"topology": self.topology()}

    def on_fake_build(self, params):
        if params["session"] == "stress":
            self.spaces += [self.new_workspace(), self.new_workspace()]
            space = self.new_workspace(columns=4)
        else:
            space = self.new_workspace(columns=self.knobs.get("light_panes", 2))
        self.spaces.append(space)
        self.shown = space["id"]
        return {"workspace": space["id"], "panes": [p["id"] for p in space["screens"][0]["panes"]]}

    def on_action_run(self, params):
        name, target, args = params["action"], params.get("target") or "", params.get("args") or {}
        pane_id = target[len("pane:"):] if target.startswith("pane:") else self.focused
        space, pane = self.find(pane_id)
        if name in ("splitRight", "splitDown", "newColumn"):
            right = name != "splitDown"
            if right:
                for other in space["screens"][0]["panes"]:
                    if other["column"] > pane["column"]:
                        other["column"] += 1
            made = self.new_pane(pane["column"] + (1 if right else 0))
            space["screens"][0]["panes"].append(made)
            self.focused = made["id"]
            self.work(frame_sets=3, layouts=1)
        elif name == "closePane":
            if not self.knobs.get("leak_close"):
                self.remove(space, pane)
            self.work(frame_sets=2, layouts=1)
        elif name == "closeTab":
            space, pane = self.find_tab(target[len("tab:"):])
            pane["tabs"] = [t for t in pane["tabs"] if t["id"] != target[len("tab:"):]]
            if not pane["tabs"]:
                self.remove(space, pane)
            self.work(frame_sets=2, layouts=1)
        elif name == "pane.focus":
            self.focused = pane_id
        elif name == "toggleSidebar":
            self.sidebar_hidden = not self.sidebar_hidden
            self.work(layouts=1)
        elif name in ("toggleSplitZoom", "zoomWindow", "palette.browserToggleOmnibar"):
            self.work(layouts=1, window_calls=1 if name == "zoomWindow" else 0)
        elif name == "goToWorkspace":
            self.shown = args["workspace"]
            self.work(layouts=1)
        elif name in ("moveWorkspaceUp", "moveWorkspaceDown"):
            index = next(i for i, s in enumerate(self.spaces) if s["id"] == self.shown)
            other = index - 1 if name == "moveWorkspaceUp" else index + 1
            self.spaces[index], self.spaces[other] = self.spaces[other], self.spaces[index]
            self.work(layouts=1)
        elif name == "toggleCanvasLayout":
            self.canvas = not self.canvas
            self.work(frame_sets=2, layouts=1)
        elif name in ("canvasZoomIn", "canvasZoomOut", "canvasZoomReset", "canvasOverview"):
            if not self.canvas:
                return {"error": f"{name}: the screen is not a canvas"}
            self.work(layouts=1)  # the camera rests in the action's turn; Core Animation shows the move
        else:
            return {"error": f"unknown action {name}"}
        return {}

    def remove(self, space, pane):
        panes = space["screens"][0]["panes"]
        panes.remove(pane)
        if not any(p["column"] == pane["column"] for p in panes):
            for other in panes:
                if other["column"] > pane["column"]:
                    other["column"] -= 1
        if self.focused == pane["id"]:
            self.focused = panes[0]["id"]

    def on_debug_frames(self, params):
        action = params.get("action")
        if action == "start":
            self.frames, self.render = [], bool(params.get("render"))
            return {"render_armed": True} if self.render else {"running": True}
        if action == "stop":
            frames, self.frames = self.frames or [], None
            reply = {"frames": len(frames), "refresh_ms": 1000 / 120}
            if self.render and not self.knobs.get("no_render"):
                reply.update({f"{k}_per_frame": [f[k] for f in frames] for k in ALL_COUNTERS})
                reply["render_owners"] = [{"owner": "LayoutRootView", "layouts": sum(f["layouts"] for f in frames)}]
            return reply
        return {"frames": len(self.frames or [])}

    def on_debug_layout_counters(self, params):
        reply = {"layout_root_layouts": self.layout_passes}
        if not self.knobs.get("no_visibility"):
            reply["update_visibility"] = self.visibility
        return reply

    def on_debug_mouse(self, params):
        action = params.get("action")
        self.mouse_actions.append(action)
        if action == "scroll":
            return {"delivered_to": "LayoutRootView"}
        if action == "leave":
            return {}  # as the app: only the layout's pointer clears; no tracking-area owner hears an exit
        x, y = self.CONTENT if "pane" in params else (params["x"], params["y"])
        if action == "move":
            sx, sy, sw, sh = self.STRIP
            on_strip = sx <= x <= sx + sw and sy <= y <= sy + sh
            self.band_inside = x < 200 and y < 30
            self.card = on_strip or (self.card and bool(self.knobs.get("sticky_card")))
        return {"x": x, "y": y}

    def on_debug_pane_chrome(self, params):
        space = next(s for s in self.spaces if s["id"] == self.shown)
        base = space["screens"][0]["panes"][0]["id"]
        presence = 1 if not self.sidebar_hidden or self.band_inside else 0
        return {"windows": [{"panes": [{"pane": base, "strip": self.STRIP, "tab_slots": [[0, 100], [100, 100]]}],
                             "window_controls": {"band_presence": presence},
                             "titlebar_buttons": {"pointer_inside": self.band_inside}}]}

    def on_debug_hover_cards(self, params):
        return {"card_showing": "true" if self.card else "false", "delay_ms": "0"}

    def on_debug_cef(self, params):
        return {"state": "ready"}

    def on_debug_tunables(self, params):
        key = params.get("key")
        if key not in self.tunables:
            return {"error": "unknown key"}
        if params.get("action") == "set" and not self.knobs.get("ignore_tunables"):
            self.tunables[key] = False if params.get("value") is None else params["value"]
        return {"key": key, "value": self.tunables[key]}


class FakeStress:
    """perf-stress-session.Stress's surface that Session uses, over the fake app's socket."""

    def __init__(self, rpc, selected="terminal", **_):
        self.rpc = rpc

    def topology(self):
        return self.rpc("snapshot.get")["topology"]

    def workspaces(self):
        return self.topology()["workspaces"]

    def workspace(self, workspace_id):
        return next((w for w in self.workspaces() if w["id"] == workspace_id), None)

    @staticmethod
    def panes(workspace):
        return [p for s in (workspace or {}).get("screens") or [] for p in s.get("panes") or []]

    def tabs(self, workspace_id, pane_id):
        return next((p["tabs"] for p in self.panes(self.workspace(workspace_id)) if p["id"] == pane_id), [])

    def focus_pane(self, pane_id):
        self.rpc("action.run", {"action": "pane.focus", "target": f"pane:{pane_id}"})

    def window_showing(self, workspace):
        return next((w for w in self.topology()["windows"] if w["workspace"] == workspace), None)

    def build_light(self, kinds=()):
        reply = self.rpc("fake.build", {"session": "light"})
        return reply["workspace"], reply["panes"]

    def build(self):
        return {"measured": self.rpc("fake.build", {"session": "stress"})["workspace"]}


class FakeLauncher:
    """BenchApp's place in main(): one FakeApp per launch; its `sleep` is the harness clock of the newest app."""

    def __init__(self, knobs):
        self.knobs, self.apps = knobs, []

    def __call__(self, path, out=None, window=None):
        self.apps.append(FakeApp(self.knobs))
        return self.apps[-1]

    def sleep(self, seconds):
        if self.apps:
            self.apps[-1].sleep(seconds)


class FakeShapeError(RuntimeError):
    pass


def fake_wait(predicate, seconds, step=0.25):
    for _ in range(3):
        value = predicate()
        if value:
            return value
    return None


def fake_run(argv, **knobs):
    """main() on the fake app; returns (status, report, launcher)."""
    module = types.SimpleNamespace(Stress=FakeStress, StressShapeError=FakeShapeError, WEB_DEV_CONFIG=None, wait=fake_wait,
                                   cef_problems=lambda cef, config: [] if cef.get("state") == "ready" else ["not ready"],
                                   start_vdisplay=lambda *a: None)
    launcher = FakeLauncher(knobs)
    with tempfile.TemporaryDirectory() as out:
        opts = parse(["--app", "fake.app", "--out", out, "--settle", "0", "--rounds", "1", *argv])
        with contextlib.redirect_stdout(io.StringIO()):
            status = main(opts, launcher=launcher, stress_module=module, sleep=launcher.sleep,
                          facts=lambda app, opts, refresh: {"host": "fake", "refresh_ms": refresh})
        with open(os.path.join(out, "motion-main-work.json")) as f:
            report = json.load(f)
    return status, report, launcher


def self_test():
    """The frame split, the delta, the summary rules, the arguments, then the scenario flow and exit codes."""
    failures = []

    def check(name, got, want):
        if got != want:
            failures.append(f"{name}: got {got!r}, want {want!r}")

    def series(**columns):
        length = max(len(v) for v in columns.values())
        return {k: list(columns.get(k, [0] * length)) for k in ALL_COUNTERS}

    # Idle 0..1, the step's turn at 3 (inside [2, 4]), two spring frames with frame sets after it.
    s = series(frame_sets=[0, 0, 0, 5, 2, 0, 1, 0], layouts=[0, 0, 0, 3, 0, 0, 0, 0],
               contents_sets=[1, 1, 1, 1, 1, 1, 1, 1])
    split = split_pass(s, mark=2, mark2=4)
    check("frame1 offset", split["frame1"]["offset"], 1)
    check("frame1 frame_sets", split["frame1"]["frame_sets"], 5)
    check("frames 2..n count", split["frames_2_n"]["frames"], 4)
    check("frames 2..n frame_sets", split["frames_2_n"]["frame_sets"], 3)
    check("frames 2..n layouts", split["frames_2_n"]["layouts"], 0)
    check("frames 2..n max", split["frames_2_n_max"]["frame_sets"], 2)
    check("frames with work", split["frames_2_n_with_work"], 2)
    check("last work frame (frame numbers from 1)", split["last_work_frame"], 4)
    check("idle", (split["idle"]["frames"], split["idle"]["contents_sets"]), (2, 2))
    check("quiet pre-roll", split["noisy"], False)
    # Content-only frames (busy terminals) never become frame 1.
    s = series(contents_sets=[0, 3, 3, 3, 3], window_calls=[0, 0, 0, 1, 0])
    check("content is not structural", split_pass(s, mark=1, mark2=3)["frame1"]["offset"], 2)
    # Background structural work (1 per frame at most in the pre-roll) at mark is not the step's turn.
    split = split_pass(series(frame_sets=[1, 0, 1, 4, 1, 0]), mark=2, mark2=4)
    check("noise is not frame 1", split["frame1"]["offset"], 1)
    check("noisy pre-roll", (split["noisy"], split["idle"]["structural_max"]), (True, 1))
    # A step whose turn did nothing (a hover card that shows later): frame 1 is mark2, the fade follows.
    s = series(window_calls=[0, 0, 0, 0, 1, 1, 1])
    split = split_pass(s, mark=1, mark2=2)
    check("quiet step frame1", split["frame1"]["offset"], 1)
    check("quiet step window calls after", split["frames_2_n"]["window_calls"], 3)
    # mark2 past the recorded frames clamps to the last one.
    check("clamped", split_pass(series(layouts=[0, 0, 0]), mark=1, mark2=9)["frame1"]["offset"], 1)
    try:
        split_pass(series(layouts=[0, 0]), mark=2, mark2=2)
        failures.append("no frame after the step: no CountingError")
    except CountingError:
        pass
    try:
        per_frame({"frame_sets_per_frame": [0]})
        failures.append("missing series: no CountingError")
    except CountingError:
        pass
    reply = {f"{k}_per_frame": [0, 1] for k in ALL_COUNTERS}
    reply["p95_ms"] = 3.2
    check("per_frame reads only counts", sorted(per_frame(reply)), sorted(ALL_COUNTERS))
    check("delta", counter_delta({"a": 1, "b": 2, "c": "x", "d": True}, {"a": 4, "b": 2, "c": "y", "d": False, "e": 1}), {"a": 3})
    check("visibility delta", visibility_delta({"update_visibility": 3}, {"update_visibility": 3}), 0)
    check("no visibility counter", visibility_delta({}, {"update_visibility": 3}), None)
    check("ms keys", ms_keys({"counts": {"frames": 1}, "x": [{"p95_ms": 1}], "ms": 2}), ["x[0].p95_ms", "ms"])

    def record(frame_sets_after, error=None, visibility=2, noisy_frame=0):
        counts = split_pass(series(frame_sets=[noisy_frame, 2, frame_sets_after], layouts=[0, 1, 0]), 1, 1)
        return {"session": "light", "scenario": "cmd-d", "phase": "do", "round": 0, "error": error, "counts": counts,
                "layout_counters": {}, "update_visibility": visibility}
    row = summarize([record(0), record(0), record(4)])[0]
    check("summary frame_sets", row["frame_sets"], {"median": 0, "max": 4})
    check("summary zero", row["zero_frames_2_n"], False)
    check("summary visibility", row["update_visibility"], {"median": 2, "max": 2})
    check("summary has no ms", ms_keys(row), [])
    # Passes whose step failed count nowhere: three refused steps are no DC2 pass.
    row = summarize([record(0, error="refused") for _ in range(3)])[0]
    check("errored passes: counted", row["counted"], 0)
    check("errored passes: zero is null", row["zero_frames_2_n"], None)
    check("errored passes: errors", row["errors"], ["refused"])
    row = summarize([record(0), record(4, error="refused")])[0]
    check("one errored pass is left out", (row["counted"], row["frame_sets"]["max"], row["zero_frames_2_n"]), (1, 0, True))
    row = summarize([record(3, noisy_frame=1)])[0]
    check("noisy passes give no verdict", (row["noisy"], row["zero_frames_2_n"]), (1, None))
    row = summarize([record(0, visibility=None)])[0]
    check("missing visibility counted", (row["update_visibility"], row["update_visibility_missing"]), (None, 1))
    check("tunable on", tunable_arg("motion.renderServer=on"), ("motion.renderServer", True))
    check("tunable number", tunable_arg("a.b=0.5"), ("a.b", 0.5))
    with contextlib.redirect_stderr(io.StringIO()):
        for argv in (["--self-test", "--sesions", "stress"], ["--self-test", "--tunable", "noequals"]):
            try:
                parse(argv)
                failures.append(f"parse {argv}: no error")
            except SystemExit:
                pass

    # The scenario flow on the fake app.
    status, report, launcher = fake_run(["--sessions", "light,stress"])
    check("fake run status", (status, report["problems"]), (0, []))
    check("one launch per session", (len(launcher.apps), sorted(report["launches"])), (2, ["light", "stress"]))
    check("render server read back", report["launches"]["light"]["tunables"], {RENDER_SERVER: False})
    rows = {(r["session"], r["scenario"], r["phase"]): r for r in report["summary"]}
    check("every scenario ran", len({k[1] for k in rows}), 18)
    timed = load("motion_scenarios", "motion_scenarios.py")
    check("every timed step (motion-hitches.py) is a row", sorted(set(timed.rows()) - {k[1:] for k in rows}), [])
    check("the timed scenarios are the DC2 rows", sorted(timed.names()),
          sorted({k[1] for k in rows} - {"strip-pan", "scroll-to-row", "canvas-zoom", "canvas-reset", "canvas-overview"}))
    check("canvas rows counted", [rows.get(("light", n, p), {}).get("counted") for n, p in
                                  (("canvas-zoom", "do"), ("canvas-zoom", "undo"), ("canvas-reset", "do"),
                                   ("canvas-overview", "do"), ("canvas-overview", "undo"))], [1, 1, 1, 1, 1])
    check("the canvas rows leave the daemon layout", [app.canvas for app in launcher.apps], [False, False])
    check("the timed strip has as many columns", timed.STRIP_COLUMNS, STRIP_COLUMNS)
    check("hover-card undo counted", rows.get(("light", "hover-card", "undo"), {}).get("counted"), 1)
    check("band-reveal undo counted", rows.get(("light", "band-reveal", "undo"), {}).get("counted"), 1)
    check("clean build: zero frames 2..n", sorted({r["zero_frames_2_n"] for r in report["summary"]}, key=str), [True])
    check("visibility measured", rows.get(("light", "cmd-d", "do"), {}).get("update_visibility"), {"median": 1, "max": 1})
    check("the pointer never only leaves", "leave" in launcher.apps[0].mouse_actions, False)
    status, report, _ = fake_run(["--sessions", "light"], light_panes=3)
    check("light with 3 panes", status, 2)
    status, report, _ = fake_run(["--sessions", "light", "--scenarios", "cmd-d"], leak_close=True)
    check("a scenario that leaves a pane", (status, any("left 3 panes" in p for p in report["problems"])), (2, True))
    status, report, _ = fake_run(["--sessions", "light"], no_render=True)
    check("no RenderStats", (status, any("_per_frame" in p for p in report["problems"])), (1, True))
    status, report, _ = fake_run(["--sessions", "light", "--scenarios", "hover-card"], sticky_card=True)
    check("a card that stays", (status, any("hover card" in p for p in report["problems"])), (2, True))
    status, report, _ = fake_run(["--sessions", "light", "--scenarios", "zoom"], no_visibility=True)
    check("no update_visibility counter", (status, any("update_visibility" in p for p in report["problems"])), (1, True))
    status, report, launcher = fake_run(["--sessions", "light", "--scenarios", "zoom", "--tunable", "motion.renderServer=on"])
    check("tunable on", (status, report["launches"]["light"]["tunables"]), (0, {RENDER_SERVER: True}))
    check("tunable reset at the end", launcher.apps[0].tunables[RENDER_SERVER], False)
    status, report, _ = fake_run(["--sessions", "light", "--scenarios", "zoom", "--tunable", "motion.renderServer=on"],
                                 ignore_tunables=True)
    check("tunable that does not read back", (status, any("reads back" in p for p in report["problems"])), (1, True))
    status, report, _ = fake_run(["--sessions", "light", "--scenarios", "zoom", "--tunable", "motion.nope=on"])
    check("unknown tunable", status, 1)
    for line in failures:
        print("SELF-TEST FAIL " + line, flush=True)
    print(f"SELF-TEST {'FAIL' if failures else 'PASS'} ({len(failures)} failed)", flush=True)
    return 1 if failures else 0


def dry_run():
    """Binds every call on BenchApp (`app.`, `launcher(...)`), Stress (`builder.`) and the STRESS module
    (`stress_module.`) in this file to the real signature, as bench-command-pan.py --dry-run does."""
    stress_module = load("perf_stress_session", "perf-stress-session.py")
    tree = ast.parse(open(os.path.abspath(__file__)).read())
    problems, checked = [], 0
    for call in (node for node in ast.walk(tree) if isinstance(node, ast.Call)):
        func = call.func
        if isinstance(func, ast.Name) and func.id in ("BenchApp", "launcher"):
            label, function, bound = "BenchApp", BenchApp.__init__, True
        elif isinstance(func, ast.Attribute):
            owner = func.value
            name = owner.attr if isinstance(owner, ast.Attribute) else owner.id if isinstance(owner, ast.Name) else None
            if name == "app" and hasattr(BenchApp, func.attr):
                label, function, bound = f"BenchApp.{func.attr}", getattr(BenchApp, func.attr), True
            elif name == "builder" and hasattr(stress_module.Stress, func.attr):
                member = inspect.getattr_static(stress_module.Stress, func.attr)
                label, function = f"Stress.{func.attr}", getattr(stress_module.Stress, func.attr)
                bound = not isinstance(member, staticmethod)
            elif name == "stress_module" and callable(getattr(stress_module, func.attr, None)):
                value = getattr(stress_module, func.attr)
                if inspect.isclass(value) and issubclass(value, BaseException):
                    continue
                label = f"perf_stress_session.{func.attr}"
                function, bound = (value.__init__, True) if inspect.isclass(value) else (value, False)
            elif name == "bench_launch" and callable(getattr(bench_launch, func.attr, None)):
                label, function, bound = f"bench_launch.{func.attr}", getattr(bench_launch, func.attr), False
            else:
                continue
        else:
            continue
        if any(isinstance(a, ast.Starred) for a in call.args) or any(k.arg is None for k in call.keywords):
            continue
        try:
            inspect.signature(function).bind(*([None] if bound else []), *[None] * len(call.args),
                                             **{k.arg: None for k in call.keywords})
            checked += 1
        except TypeError as error:
            problems.append(f"line {call.lineno}: {label}: {error}")
    for line in problems:
        print("DRY-RUN " + line, flush=True)
    print(f"DRY-RUN {'FAIL' if problems or not checked else 'PASS'}: {checked} calls bound, {len(problems)} wrong", flush=True)
    return 1 if problems or not checked else 0


def parse(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--self-test", action="store_true", help="the frame split, report rules and a fake-app run")
    parser.add_argument("--dry-run", action="store_true", help="bind the calls to the real signatures; no app")
    parser.add_argument("--app")
    parser.add_argument("--out")
    parser.add_argument("--json")
    parser.add_argument("--tag")  # split-spring passes it; the app's name carries the tag
    parser.add_argument("--sessions", default="light,stress")
    parser.add_argument("--scenarios", default="", help="comma list; default every scenario")
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--settle", type=float, default=1.0, help="seconds after a step for its spring to land")
    parser.add_argument("--band-point", type=lambda v: tuple(float(p) for p in v.split(",")), default=(90.0, 12.0),
                        help="X,Y window point (top-left) that opens the collapsed toolbar band")
    parser.add_argument("--tunable", type=tunable_arg, action="append", default=[], metavar="KEY=VALUE",
                        help="set over debug.tunables after each launch and read back, e.g. motion.renderServer=on")
    parser.add_argument("--vdisplay", type=float, default=0,
                        help="make a virtual main display at this rate first (perf-stress-session.py start_vdisplay)")
    parser.add_argument("--vdisplay-hold", type=float, default=3600)
    parser.add_argument("--expect-hz", type=float, default=None,
                        help="fail unless the display refreshes at this rate (default: --vdisplay's)")
    opts = parser.parse_args(argv)
    if not (opts.self_test or opts.dry_run) and not (opts.app and opts.out):
        parser.error("--app and --out are required (or --self-test / --dry-run)")
    return opts


if __name__ == "__main__":
    options = parse()
    if options.self_test:
        sys.exit(self_test())
    if options.dry_run:
        sys.exit(dry_run())
    sys.exit(main(options))
