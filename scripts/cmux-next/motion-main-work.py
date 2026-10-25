#!/usr/bin/env python3
"""Main-thread render work per motion frame, counted (p03-rendering-002; done check DC2 and DC13 in
plans/cmux-next/chrome-parity/p03-rendering.md). Not a CI job and not a gate: an agent runs it on the fleet.

Chrome's model: cc::RenderingStatsInstrumentation (cc/debug/rendering_stats_instrumentation.cc) records
per-frame counts only while `record_rendering_stats` is on, and a timing trace is a separate run. The same split
here: this script arms RenderStats (`debug.frames` with `render: true`, task p03-rendering-001) and reports
counts only; its hooks cost time, so no millisecond from an armed pass is ever reported. Timing comes from
motion-hitches.py (task p03-rendering-007), with RenderStats disarmed.

Launches a tagged DEV app through bench_launch.py and, per session, runs each scenario --rounds times:

  light   a workspace of 2 panes, the first with a terminal and a Chromium page (selected)
  stress  perf-stress-session.py, Chromium selected (60 workspaces, 4 x 3 grid plus nested splits, 6 tabs
          per pane, 10 busy terminals); its own shape check

  cmd-d              splitRight on the base pane (the new pane closes again, not counted)
  cmd-shift-d        splitDown, the same way
  cmd-w              closeTab on a pane made for it (its one terminal: the pane closes)
  zoom               toggleSplitZoom on the base pane; undo: toggleSplitZoom
  new-column         newColumn (closed again, not counted)
  close-last-column  closePane on a column made for it
  workspace-switch   goToWorkspace to the neighbor workspace; undo: back
  strip-pan          Command + trackpad scroll over a pane of an overflowing strip (input-driven: each event may
                     do O(1) work, so frames 2..n of this row are per-event work, not spring frames)
  sidebar-toggle     toggleSidebar; undo: toggleSidebar
  toggle-omnibar     palette.browserToggleOmnibar on the base pane's Chromium page; undo: the same
  band-reveal        with the sidebar hidden, the pointer over the title bar's top-left corner opens the collapsed
                     toolbar band; undo: the pointer leaves (the band closes after its delay)
  window-zoom        zoomWindow; undo: zoomWindow
  hover-card         the pointer over the base pane's last tab: the tab hover card fades in; undo: the pointer leaves
  sidebar-reorder    moveWorkspaceUp on the measured workspace; undo: moveWorkspaceDown
  scroll-to-row      stress only: goToWorkspace to the first workspace (the sidebar scrolls to its row); undo: back

One counting pass per measured step (`do`, and `undo` where listed). `debug.frames start` with `render: true`
and `raw: true`; a pre-roll of idle frames; a read (`mark`); the step; a read when its reply came (`mark2`);
the settle; `stop`. Frame 1 is the step's own turn: the first frame in [mark, mark2] with structural work
(frame sets, layouts, window calls or tracking-area adds), else mark2. Frames 2..n are every frame after it
until stop. Per pass: frame 1's counts, frames 2..n's sums and per-frame max of frame_sets, layouts,
window_calls, tracking_area_adds (contents_sets and damage_rects too, as context), the idle pre-roll's sums,
`debug.layout_counters` deltas (`update_visibility` when the build counts it: the updateVisibility calls per
spring), and the busiest RenderStats owners of the pass (all its frames).

DC2 wants frame_sets = 0 and layouts = 0 in frames 2..n of every spring with `motion.renderServer` on; DC13
wants window_calls = 0. The summary prints each scenario's median and max over rounds; this script reports, it
does not judge, so a nonzero count is no failure.

Measurement validity (PATTERNS P12): the report records host, chip, macOS and the display refresh (from an
unarmed `debug.frames` probe); `--expect-hz` fails the run on another rate. Chromium pages must be real
(`debug.cef` ready, no unavailable reason, no WebKit fallback) at the start and the end of each session.

Exit status: 0 when every pass ran; 1 when a pass or a check failed (the reason is in `problems`); 2 when a
session has the wrong shape (STRESS's StressShapeError, the light session's check, or a scenario that left
another pane count, focus or workspace behind).

Usage:
  motion-main-work.py --app APP --out DIR [--json PATH] [--sessions light,stress] [--scenarios a,b]
                      [--rounds 3] [--settle 1.0] [--vdisplay 120 | --expect-hz 120]
  motion-main-work.py --self-test     the frame split and the report rules, no app
  motion-main-work.py --dry-run       every call on BenchApp, Stress and its module bound to the real signature
Fleet (an owned mini's console; base and head, macOS 26 and 27):
  nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA -- \\
    python3 scripts/cmux-next/motion-main-work.py --app "$NX_APP" --out "$NX_ARTIFACTS" --vdisplay 120
"""
import argparse, ast, importlib.util, inspect, json, os, platform, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bench_launch  # noqa: E402
from bench_launch import BenchApp  # noqa: E402

SCHEMA = "motion-main-work/v1"
# DC2 and DC13's counters, and the ones a frame-1 search reads (structural work, not content).
COUNTERS = ("frame_sets", "layouts", "window_calls", "tracking_area_adds")
CONTEXT = ("contents_sets", "damage_rects")
ALL_COUNTERS = COUNTERS + CONTEXT
WINDOW = (40, 40, 1600, 1000)
PRE_ROLL_S = 0.2
STRIP_COLUMNS = 3


class ShapeError(RuntimeError):
    """The session is not the shape this script measures."""


class CountingError(RuntimeError):
    """The build cannot count (no RenderStats) or a pass's reply has no per-frame counts."""


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
    first frame in [mark, mark2] with structural work, else mark2 (a step whose own turn did nothing, such as a
    hover that shows its card after a delay); frames 2..n follow it. Returns the pass's count record, or raises
    CountingError when no frame came after the step."""
    total = len(series[COUNTERS[0]])
    mark = max(0, min(mark, total))
    last = min(mark2, total - 1)
    if total == 0 or mark >= total:
        raise CountingError(f"no frame recorded after the step ({total} frames, mark {mark})")
    frame1 = next((i for i in range(mark, last + 1) if structural(series, i) > 0), max(mark, last))
    after = range(frame1 + 1, total)
    work = [i for i in after if structural(series, i) > 0]
    return {
        "idle": {"frames": mark, **{k: sum(series[k][:mark]) for k in ALL_COUNTERS}},
        "frame1": {"offset": frame1 - mark, **{k: series[k][frame1] for k in ALL_COUNTERS}},
        "frames_2_n": {"frames": len(after), **{k: sum(series[k][i] for i in after) for k in ALL_COUNTERS}},
        "frames_2_n_max": {k: max((series[k][i] for i in after), default=0) for k in ALL_COUNTERS},
        "frames_2_n_with_work": len(work),
        "last_work_frame": (work[-1] - frame1 + 1) if work else None,
    }


def counter_delta(before, after):
    """Integer counters of `debug.layout_counters` that moved between two reads."""
    if not isinstance(before, dict) or not isinstance(after, dict):
        return {}
    out = {}
    for key, value in after.items():
        if isinstance(value, int) and not isinstance(value, bool) and isinstance(before.get(key), int):
            if value != before[key]:
                out[key] = value - before[key]
    return out


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
    """One row per (session, scenario, phase): per counter the median and max over rounds of frames 2..n,
    `zero_frames_2_n` (DC2: frame_sets and layouts 0 in every round), and the errors."""
    groups = {}
    for record in passes:
        groups.setdefault((record["session"], record["scenario"], record["phase"]), []).append(record)
    rows = []
    for (session, scenario, phase), records in groups.items():
        counted = [r for r in records if r.get("counts")]
        row = {"session": session, "scenario": scenario, "phase": phase, "rounds": len(records),
               "counted": len(counted), "errors": sorted({r["error"] for r in records if r.get("error")})}
        for key in ALL_COUNTERS:
            values = [r["counts"]["frames_2_n"][key] for r in counted]
            row[key] = {"median": median(values), "max": max(values) if values else None}
        row["frames"] = median([r["counts"]["frames_2_n"]["frames"] for r in counted])
        visibility = [r["layout_counters"].get("update_visibility") for r in counted if "update_visibility" in r["layout_counters"]]
        row["update_visibility"] = {"median": median(visibility), "max": max(visibility)} if visibility else None
        row["zero_frames_2_n"] = bool(counted) and all(
            r["counts"]["frames_2_n"]["frame_sets"] == 0 and r["counts"]["frames_2_n"]["layouts"] == 0 for r in counted)
        rows.append(row)
    return rows


def self_test():
    """The frame split, the delta and the no-ms rule on fixed series."""
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
    # Content-only frames (busy terminals) never become frame 1.
    s = series(contents_sets=[0, 3, 3, 3, 3], window_calls=[0, 0, 0, 1, 0])
    check("content is not structural", split_pass(s, mark=1, mark2=3)["frame1"]["offset"], 2)
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
    check("ms keys", ms_keys({"counts": {"frames": 1}, "x": [{"p95_ms": 1}], "ms": 2}), ["x[0].p95_ms", "ms"])
    passes = [{"session": "light", "scenario": "cmd-d", "phase": "do", "round": r, "error": None,
               "counts": split_pass(series(frame_sets=[0, 2, f], layouts=[0, 1, 0]), 1, 1),
               "layout_counters": {"update_visibility": 2}} for r, f in enumerate((0, 0, 4))]
    row = summarize(passes)[0]
    check("summary frame_sets", row["frame_sets"], {"median": 0, "max": 4})
    check("summary zero", row["zero_frames_2_n"], False)
    check("summary visibility", row["update_visibility"], {"median": 2, "max": 2})
    check("summary has no ms", ms_keys(row), [])
    for line in failures:
        print("SELF-TEST FAIL " + line, flush=True)
    print(f"SELF-TEST {'FAIL' if failures else 'PASS'} ({len(failures)} failed)", flush=True)
    return 1 if failures else 0


# -- the app side --

def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def error_of(reply):
    return str(reply.get("error"))[:200] if isinstance(reply, dict) and reply.get("error") else None


class Session:
    """One measured workspace in the launched app: its builder (perf-stress-session.Stress), the base pane, the
    pane count and workspace order that every scenario must leave as it found them."""

    def __init__(self, name, app, stress_module, opts):
        self.name, self.app, self.stress_module, self.opts = name, app, stress_module, opts
        self.builder = stress_module.Stress(lambda m, p=None, timeout=60: app.rpc(m, p, timeout), selected="chromium")
        self.workspace = self.base = None
        self.panes = 0
        self.order = []
        self.shape = {}

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

    # The two sessions.

    def build(self):
        if self.name == "stress":
            self.shape = self.builder.build()  # raises StressShapeError on another shape
            self.workspace = self.shape["measured"]
            self.base = self.pane_ids()[0]
        else:
            self.workspace, panes = self.builder.build_light(kinds=("chromium",))
            self.base = panes[0]
            tabs = self.builder.tabs(self.workspace, self.base)
            selected = next((t.get("kind") for t in tabs if t.get("selected")), None)
            self.shape = {"measured": self.workspace, "panes": len(panes), "base_tabs": [t.get("kind") for t in tabs],
                          "base_selected": selected, "workspaces": len(self.workspace_ids()),
                          "chromium_unavailable": self.chromium_problems()}
            problems = []
            if len(panes) != 2:
                problems.append(f"{len(panes)} panes, not 2")
            if selected != "browser":
                problems.append(f"the base pane shows a {selected} tab, not the Chromium page")
            if self.shape["workspaces"] < 2:
                problems.append("no second workspace to switch to")
            if self.shape["chromium_unavailable"]:
                problems.append(f"Chromium is not real: {self.shape['chromium_unavailable']}")
            if problems:
                raise ShapeError("light session has the wrong shape: " + "; ".join(problems))
        self.panes = len(self.pane_ids())
        self.order = self.workspace_ids()
        self.builder.focus_pane(self.base)

    def restore_check(self, scenario):
        """Raises ShapeError when `scenario` left another pane count, workspace order or shown workspace."""
        if not self.wait_panes(self.panes):
            raise ShapeError(f"{self.name}: {scenario} left {len(self.pane_ids())} panes, not {self.panes}")
        order = self.workspace_ids()
        if order != self.order:
            raise ShapeError(f"{self.name}: {scenario} left the workspaces in another order")
        if not self.builder.window_showing(self.workspace):
            raise ShapeError(f"{self.name}: {scenario} left workspace {self.workspace} hidden")
        self.builder.focus_pane(self.base)

    # Scenario steps.

    def neighbor(self):
        index = self.order.index(self.workspace)
        return self.order[index - 1] if index > 0 else self.order[index + 1]

    def target_for(self, verb):
        """Splits aim at the base pane by id (as the STRESS builder does); other verbs act on the focused pane,
        which every scenario starts on (`restore_check` focuses it)."""
        return f"pane:{self.base}" if verb.startswith("split") else None

    def made_pane(self, verb):
        """`verb` on the base pane, untimed; returns the new pane's id once the layout settled."""
        before = set(self.pane_ids())
        if self.act(verb, target=self.target_for(verb)):
            return None
        made = self.stress_module.wait(lambda: next((p for p in self.pane_ids() if p not in before), None), 15, step=0.05)
        time.sleep(self.opts.settle)  # test harness: the untimed spring lands before the counted step
        return made

    def close_pane(self, pane):
        return self.act("closePane", target=f"pane:{pane}") if pane else "no pane to close"

    def close_new(self, before):
        for pane in [p for p in self.pane_ids() if p not in before]:
            self.close_pane(pane)
        time.sleep(self.opts.settle)  # test harness: the untimed close lands

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

    def close_column(self):
        state = {}

        def prepare():
            state["pane"] = self.made_pane("newColumn")
            return None if state["pane"] else "newColumn made no column"

        def perform():
            return self.close_pane(state["pane"])
        return prepare, perform

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
                time.sleep(0.5)  # test harness: each column's motion lands before the next
            made = [p for p in self.pane_ids() if p not in before]
            if len(made) < STRIP_COLUMNS:
                return f"newColumn made {len(made)} of {STRIP_COLUMNS} columns"
            reply = self.rpc("debug.mouse", {"action": "hover", "pane": made[-1]}) or {}
            if not isinstance(reply.get("x"), (int, float)):
                return f"no point for pane {made[-1]}: {str(reply)[:120]}"
            state["point"] = {"x": reply["x"], "y": reply["y"]}
            time.sleep(self.opts.settle)  # test harness: the last column lands
            return None

        def perform():
            delivered = []

            def send(phase, dx, hover):
                reply = self.rpc("debug.mouse", {"action": "scroll", **state["point"], "dx": dx, "dy": 0, "phase": phase,
                                                 "modifiers": ["cmd"], "hover": hover}) or {}
                delivered.append(reply.get("delivered_to") or reply.get("error") or "?")
            send("began", 24, True)
            for _ in range(40):
                time.sleep(1 / 120)  # test harness: one event per 120 Hz frame, like a trackpad
                send("changed", 24, False)
            send("ended", 0, False)
            taken = sum(1 for d in delivered if d == "LayoutRootView")
            return None if taken == len(delivered) else f"the layout took {taken} of {len(delivered)} events"

        def cleanup():
            self.close_new(before)
        return prepare, perform, cleanup

    def band(self):
        """The collapsed toolbar band: sidebar hidden (untimed), the pointer over the top-left corner, then away."""
        x, y = self.opts.band_point

        def presence():
            for window in (self.rpc("debug.pane_chrome") or {}).get("windows") or []:
                controls = window.get("window_controls") or {}
                if "band_presence" in controls:
                    return controls["band_presence"]
            return None

        def prepare():
            error = self.act("toggleSidebar")
            time.sleep(self.opts.settle)  # test harness: the sidebar slide lands
            return error

        def perform():
            return error_of(self.rpc("debug.mouse", {"action": "move", "x": x, "y": y}))

        def opened():
            shown = presence()
            return None if isinstance(shown, (int, float)) and shown > 0 else f"the band did not open at ({x}, {y}): presence {shown}"

        def undo():
            return error_of(self.rpc("debug.mouse", {"action": "leave"}))

        def cleanup():
            self.act("toggleSidebar")
            time.sleep(self.opts.settle)  # test harness: the sidebar slide lands
        return prepare, perform, opened, undo, cleanup

    def hover(self):
        state = {}

        def card():
            return self.rpc("debug.hover_cards") or {}

        def prepare():
            for window in (self.rpc("debug.pane_chrome") or {}).get("windows") or []:
                pane = next((p for p in window.get("panes") or [] if p.get("pane") == self.base), None)
                if pane and pane.get("strip") and pane.get("tab_slots"):
                    sx, sy, _sw, sh = pane["strip"]
                    slot = pane["tab_slots"][-1]
                    state["point"] = {"x": sx + slot[0] + slot[1] / 2, "y": sy + sh / 2}
                    try:
                        state["delay_s"] = float(card().get("delay_ms") or "") / 1000
                    except ValueError:
                        state["delay_s"] = 0.6  # the hover card's default delay is 500 ms
                    return None
            return "no tab strip geometry for the base pane"

        def perform():
            return error_of(self.rpc("debug.mouse", {"action": "move", **state["point"]}))

        def shown():
            showing = card().get("card_showing")
            return None if showing == "true" else f"no hover card showed (card_showing {showing})"

        def undo():
            return error_of(self.rpc("debug.mouse", {"action": "leave"}))
        return prepare, perform, shown, undo, state

    def scenarios(self):
        """(name, prepare, perform, after_do, undo, cleanup, settle_s); each callable returns an error or None.
        `after_do` checks the step did what it names (read after the counted pass)."""
        s = self.opts.settle
        go = lambda target: (lambda: self.act("goToWorkspace", {"workspace": target}))  # noqa: E731
        run = lambda verb: (lambda: self.act(verb))  # noqa: E731
        split_right = self.split_and_close("splitRight")
        split_down = self.split_and_close("splitDown")
        new_column = self.split_and_close("newColumn")
        cmd_w_prepare, cmd_w = self.cmd_w()
        column_prepare, column_close = self.close_column()
        pan_prepare, pan, pan_cleanup = self.strip_pan()
        band_prepare, band_open, band_opened, band_close, band_cleanup = self.band()
        hover_prepare, hover_in, hover_shown, hover_out, hover_state = self.hover()
        rows = [
            ("cmd-d", *split_right[:2], None, None, split_right[2], s),
            ("cmd-shift-d", *split_down[:2], None, None, split_down[2], s),
            ("cmd-w", cmd_w_prepare, cmd_w, None, None, None, s),
            ("zoom", None, run("toggleSplitZoom"), None, run("toggleSplitZoom"), None, s),
            ("new-column", *new_column[:2], None, None, new_column[2], s),
            ("close-last-column", column_prepare, column_close, None, None, None, s),
            ("workspace-switch", None, go(self.neighbor()), None, go(self.workspace), None, s),
            ("strip-pan", pan_prepare, pan, None, None, pan_cleanup, s),
            ("sidebar-toggle", None, run("toggleSidebar"), None, run("toggleSidebar"), None, s),
            ("toggle-omnibar", None, run("palette.browserToggleOmnibar"), None, run("palette.browserToggleOmnibar"), None, s),
            ("band-reveal", band_prepare, band_open, band_opened, band_close, band_cleanup, s + 0.4),
            ("window-zoom", None, run("zoomWindow"), None, run("zoomWindow"), None, s + 0.4),
            ("hover-card", hover_prepare, hover_in, hover_shown, hover_out, None, None),
            ("sidebar-reorder", None, run("moveWorkspaceUp"), None, run("moveWorkspaceDown"), None, s),
        ]
        if self.name == "stress":
            rows.append(("scroll-to-row", None, go(self.order[0]), None, go(self.workspace), None, s))
        self.hover_state = hover_state
        return rows

    def settle_for(self, name, settle):
        """The hover card's settle is its delay plus the fade."""
        if settle is None:
            return getattr(self, "hover_state", {}).get("delay_s", 0.6) + self.opts.settle
        return settle


def refresh_probe(app):
    """The display refresh from an unarmed `debug.frames` pass (no RenderStats hooks)."""
    app.rpc("debug.frames", {"action": "start"})
    time.sleep(0.3)  # test harness: about 36 frames at 120 Hz
    reply = app.rpc("debug.frames", {"action": "stop"}) or {}
    refresh = reply.get("refresh_ms") if isinstance(reply, dict) else None
    return round(refresh, 3) if isinstance(refresh, (int, float)) and refresh > 0 else None


def counting_pass(session, name, phase, round_index, step, settle):
    """One armed pass around `step`; returns its record (counts only)."""
    app = session.app
    record = {"session": session.name, "scenario": name, "phase": phase, "round": round_index, "error": None,
              "counts": None, "layout_counters": {}, "owners": []}
    counters = app.rpc("debug.layout_counters") or {}
    started = app.rpc("debug.frames", {"action": "start", "render": True, "raw": True}, timeout=120) or {}
    if error_of(started) or started.get("render_armed") is not True:
        raise CountingError(f"debug.frames did not arm RenderStats ({str(started)[:200]}): a Release build, or one "
                            "before p03-rendering-001")
    try:
        time.sleep(PRE_ROLL_S)  # test harness: idle frames before the step
        mark = (app.rpc("debug.frames") or {}).get("frames") or 0
        record["error"] = step()
        mark2 = (app.rpc("debug.frames") or {}).get("frames") or mark
        time.sleep(settle)  # test harness: the spring lands before stop
    finally:
        stopped = app.rpc("debug.frames", {"action": "stop", "raw": True}, timeout=60)
    record["counts"] = split_pass(per_frame(stopped), mark, mark2)
    record["layout_counters"] = counter_delta(counters, app.rpc("debug.layout_counters") or {})
    record["owners"] = [{k: v for k, v in owner.items() if k in ("owner",) + ALL_COUNTERS}
                        for owner in (stopped.get("render_owners") or [])[:8]]
    found = ms_keys({k: v for k, v in record.items()})
    if found:
        raise CountingError(f"an armed pass record carries milliseconds: {found}")
    return record


def print_pass(record):
    after = (record.get("counts") or {}).get("frames_2_n") or {}
    print(f"  {record['session']:<6} {record['scenario']:<18} {record['phase']:<4} #{record['round']}: frames 2..n "
          f"{after.get('frames')}: frame_sets {after.get('frame_sets')} layouts {after.get('layouts')} window_calls "
          f"{after.get('window_calls')} tracking {after.get('tracking_area_adds')}  err {record.get('error')}", flush=True)


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
        for name, prepare, perform, after_do, undo, cleanup, wanted_settle in plan:
            problem = prepare() if prepare else None
            settle = session.settle_for(name, wanted_settle)  # after prepare: the hover card's delay is read there
            if problem:
                report["passes"].append({"session": session.name, "scenario": name, "phase": "do", "round": round_index,
                                         "error": f"prepare: {problem}", "counts": None, "layout_counters": {}, "owners": []})
                print_pass(report["passes"][-1])
            else:
                record = counting_pass(session, name, "do", round_index, perform, settle)
                if not record["error"] and after_do:
                    record["error"] = after_do()
                report["passes"].append(record)
                print_pass(record)
                if undo:
                    record = counting_pass(session, name, "undo", round_index, undo, settle)
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


def main(opts):
    os.makedirs(opts.out, exist_ok=True)
    stress_module = load("perf_stress_session", "perf-stress-session.py")
    report = {"schema": SCHEMA, "environment": {}, "sessions": {}, "passes": [], "summary": [], "problems": []}
    status = 0
    display = None
    app = BenchApp(opts.app, out=opts.out, window=WINDOW)
    try:
        if opts.vdisplay:
            display = stress_module.start_vdisplay(opts.vdisplay, opts.out, opts.vdisplay_hold)
        app.launch(timeout=180)
        refresh = refresh_probe(app)
        report["environment"] = environment(app, opts, refresh)
        print("MOTION-ENV " + json.dumps(report["environment"]), flush=True)
        expect = opts.expect_hz or opts.vdisplay
        if expect and (not refresh or abs(refresh - 1000 / expect) > 0.15 * 1000 / expect):
            raise ShapeError(f"the display refreshes every {refresh} ms, not {expect} Hz")
        for name in filter(None, opts.sessions.split(",")):
            run_session(Session(name, app, stress_module, opts), opts, report)
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
        app.stop()
        if display:
            display.terminate()  # the helper this script started, by its process
    report["summary"] = summarize(report["passes"])
    errors = [f"{r['session']} {r['scenario']} {r['phase']}: {'; '.join(r['errors'])}" for r in report["summary"] if r["errors"]]
    report["problems"] += errors
    if report["problems"] and not status:
        status = 1
    if not report["passes"] and not status:
        report["problems"].append("no pass ran")
        status = 1
    print("\n== frames 2..n per pass (median / max over rounds); counts, never ms")
    print(f"  {'session':<6} {'scenario':<18} {'phase':<5} {'sets':>9} {'layouts':>9} {'window':>9} {'track':>9} {'vis':>7} zero")
    for row in report["summary"]:
        cell = lambda key: f"{row[key]['median']}/{row[key]['max']}"  # noqa: E731
        vis = row["update_visibility"]
        print(f"  {row['session']:<6} {row['scenario']:<18} {row['phase']:<5} {cell('frame_sets'):>9} {cell('layouts'):>9} "
              f"{cell('window_calls'):>9} {cell('tracking_area_adds'):>9} {(str(vis['median']) if vis else '-'):>7} "
              f"{row['zero_frames_2_n']}", flush=True)
    path = opts.json or os.path.join(opts.out, "motion-main-work.json")
    with open(path, "w") as f:
        json.dump(report, f, indent=1)
    print(f"MOTION-REPORT {path}", flush=True)
    print("RESULT " + ("PASS" if not status else f"FAIL {json.dumps(report['problems'])[:2000]}"), flush=True)
    return status


def dry_run():
    """Binds every call on BenchApp (`app.`), Stress (`builder.`) and the STRESS module (`stress_module.`) in
    this file to the real signature, as bench-command-pan.py --dry-run does."""
    stress_module = load("perf_stress_session", "perf-stress-session.py")
    tree = ast.parse(open(os.path.abspath(__file__)).read())
    problems, checked = [], 0
    for call in (node for node in ast.walk(tree) if isinstance(node, ast.Call)):
        func = call.func
        if isinstance(func, ast.Name) and func.id == "BenchApp":
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
    parser.add_argument("--self-test", action="store_true", help="the frame split and report rules; no app")
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
    parser.add_argument("--vdisplay", type=float, default=0,
                        help="make a virtual main display at this rate first (perf-stress-session.py start_vdisplay)")
    parser.add_argument("--vdisplay-hold", type=float, default=3600)
    parser.add_argument("--expect-hz", type=float, default=None,
                        help="fail unless the display refreshes at this rate (default: --vdisplay's)")
    opts, _unknown = parser.parse_known_args(argv)
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
