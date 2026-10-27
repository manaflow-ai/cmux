#!/usr/bin/env python3
"""Window live resize and full screen on STRESS with Chromium selected (p03-rendering-115; done check DC16 in
plans/cmux-next/chrome-parity/p03-rendering.md). Not a CI job and not a gate: an agent runs it on the fleet.

Chrome's model: a window resize is `views::View::SetBoundsRect` then `Layout()` (ui/views/view.cc): new bounds,
the children placed again, no model work. Here a live-resize event of a screen at rest is
`ScreenContentView.resizeInPlace()`: the geometry at the new size and frames only where a rect changed, no
reconcile. DC16 wants, per resize event, main-thread time p99 <= 4 ms and 0 model reconciles.

Launches a tagged DEV app through bench_launch.py, builds STRESS (perf-stress-session.py, Chromium selected: 60
workspaces, 4 x 3 grid plus nested splits, 6 tabs per pane, 10 busy terminals; its own shape check), then, --rounds
times each, with RenderStats disarmed (a timed pass):

  live-resize   the window's bottom-right corner pressed and dragged one `debug.mouse` event per 120 Hz frame
                (--steps events each way), in by DRAG points and back; AppKit's own resize tracking reads the
                events (`inLiveResize` holds) and the user's pointer never moves
  full-screen   toggleFullScreen in, then out (each waits for AppKit's did-enter / did-exit)

Per pass, from `debug.window_transition` (each outermost window layout pass and its main-thread ms, the window's
resize notices), `debug.frames` (frame intervals, main ms per frame, `NSView.layout()` calls), deltas of
`debug.layout_counters` (`screen_reconciles`, `screen_resizes_in_place`, terminal grid reports) and the Chromium
host's resize counts (`debug.cef` host_resize; null when Chromium runs in process):

  main ms per resize event   p50 / p95 / p99 / max of the window layout passes a resize caused: the window's size
                             differs from the previous pass's (or, with none before it, a resize notice came
                             first). The other passes (display-cycle and explicit ones, the settle after a drag)
                             are their own distribution, `main_ms_other_layouts`, and DC16 does not read them
  view layouts               `NSView.layout()` calls in all and per resize event
  grids per frame            terminal grid reports / recorded frames (a live resize should report at most one
                             grid per terminal per frame)
  page resize waits          the host's fenced, late and cut resizes (`debug.cef` host_resize deltas)
  reconciles per event       screen reconciles / resize events (DC16: 0); resizes in place per event. A build
                             before p03-rendering-115 has no screen counters: these are null with a
                             `counting_note`, the other rows are still recorded (the base of a base-vs-head run),
                             and DC16 reports its reconciles as unmeasured

`--count` adds one armed pass of the live resize (`debug.frames` with `render: true`, RenderStats,
p03-rendering-001): frame sets and layouts per resize event, counts only, never ms.

Measurement validity (PATTERNS P12): the report records host, chip, macOS, the build and the display refresh (from
an unarmed `debug.frames` probe); `--expect-hz` (default --vdisplay's) fails the run on another rate.

Exit status: 0 when every pass ran; 1 when a pass or a check failed (the reason is in `problems`: no resize came,
an armed `--count` pass on a build without RenderStats); 2 when the session has the wrong shape (StressShapeError, Chromium not real,
the display at another rate). The DC16 verdict is reported (`dc16`), not an exit status.

Usage:
  window-live-resize-bench.py --app APP --out DIR [--json PATH] [--rounds 3] [--steps 60] [--count]
                              [--vdisplay 120 | --expect-hz 120]
  window-live-resize-bench.py --self-test     the statistics, the pass flow and the exit codes on a fake app
Fleet (an owned mini's console; base and head, macOS 26 and 27):
  nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA -- \\
    python3 scripts/cmux-next/window-live-resize-bench.py --app "$NX_APP" --out "$NX_ARTIFACTS" --vdisplay 120
"""
import argparse, importlib.util, json, os, sys, time, types

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

SCHEMA = "window-live-resize/v1"
WINDOW = (40, 40, 1600, 1000)
DRAG = (-240, -120)  # in, then back: a shrink stays on any display the window fits
EVENT_HZ = 120
DC16_P99_MS = 4.0
HOST_RESIZE_KEYS = ("fence_resizes", "fence_joined", "fence_late", "fence_cut")


class ShapeError(RuntimeError):
    """The session or the display is not what this script measures."""


class CountingError(RuntimeError):
    """The build cannot count what the armed `--count` pass reads (no per-frame RenderStats)."""


NO_SCREEN_COUNTERS = ("debug.layout_counters has no screen_reconciles / screen_resizes_in_place (a build before "
                      "p03-rendering-115): reconciles per resize event not counted")


# -- the statistics (pure; --self-test covers them) --

def percentile(values, p):
    """Nearest-rank percentile of `values`, None when empty."""
    ordered = sorted(values)
    if not ordered:
        return None
    rank = max(1, min(len(ordered), int(-(-p * len(ordered) // 100))))
    return round(ordered[rank - 1], 3)


def distribution(values):
    return {"n": len(values), "p50": percentile(values, 50), "p95": percentile(values, 95),
            "p99": percentile(values, 99), "max": round(max(values), 3) if values else None}


def delta(before, after, key):
    a, b = (after or {}).get(key), (before or {}).get(key)
    return a - b if isinstance(a, (int, float)) and isinstance(b, (int, float)) else None


def host_resize(cef):
    """The Chromium host's resize counts from a `debug.cef` reply, or None (Chromium in process)."""
    row = (cef or {}).get("host_resize") if isinstance(cef, dict) else None
    return {k: row.get(k) for k in HOST_RESIZE_KEYS} if isinstance(row, dict) else None


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def split_layouts(events):
    """The trace's window layout passes (main ms), split into the ones a resize caused and the rest. A pass is a
    resize's when the window's size (its `w` / `h`) differs from the previous pass's; the first pass, or one with
    no size, when a resize notice came after the previous pass."""
    caused, other = [], []
    size, notice = None, False
    for event in events:
        if event.get("e") == "resize":
            notice = True
            continue
        if event.get("e") != "layout" or not number(event.get("ms")):
            continue
        shown = (event["w"], event["h"]) if number(event.get("w")) and number(event.get("h")) else None
        resized = shown != size if shown and size else notice
        (caused if resized else other).append(event["ms"])
        size, notice = shown or size, False
    return caused, other


def judge_pass(trace, frames, counters_before, counters_after, cef_before, cef_after):
    """One timed pass's row from its `debug.window_transition` stop, `debug.frames` stop (raw) and the counter
    reads around it. A build with no screen counters gets null reconciles and a `counting_note`."""
    events = trace.get("events") or []
    resize_ms, other_ms = split_layouts(events)
    resizes = sum(1 for e in events if e.get("e") == "resize")
    reconciles = delta(counters_before, counters_after, "screen_reconciles")
    in_place = delta(counters_before, counters_after, "screen_resizes_in_place")
    counted = reconciles is not None and in_place is not None
    frame_count = frames.get("frames") or 0
    view_layouts = sum(frames.get("view_layouts_per_frame") or [])
    grids = trace.get("terminal_grid_reports")
    before_host, after_host = host_resize(cef_before), host_resize(cef_after)
    waits = {k: delta(before_host, after_host, k) for k in HOST_RESIZE_KEYS} if before_host and after_host else None
    return {
        "resize_events": resizes, "layout_passes": len(resize_ms) + len(other_ms), "resize_layout_passes": len(resize_ms),
        "main_ms_per_event": distribution(resize_ms), "main_ms_other_layouts": distribution(other_ms),
        "main_ms_per_frame": distribution([m for m in frames.get("main_ms") or [] if isinstance(m, (int, float))]),
        "frames": frame_count, "missed": frames.get("missed"), "refresh_ms": frames.get("refresh_ms"),
        "view_layouts": view_layouts, "view_layouts_per_event": round(view_layouts / resizes, 2) if resizes else None,
        "root_layouts": trace.get("root_layouts"), "grid_reports": grids,
        "grids_per_frame": round(grids / frame_count, 3) if isinstance(grids, int) and frame_count else None,
        "terminal_resizes_sent": trace.get("terminal_resizes_sent"), "page_resize_waits": waits,
        "screen_reconciles": reconciles if counted else None, "screen_resizes_in_place": in_place if counted else None,
        "reconciles_per_event": round(reconciles / resizes, 3) if counted and resizes else None,
        "counting_note": None if counted else NO_SCREEN_COUNTERS,
    }


def dc16(rows):
    """DC16 over every live-resize row: main ms per resize event p99 <= 4 and 0 reconciles per event. On a build
    without the screen counters the reconciles are unmeasured (null) and so is the verdict; the p99 still is."""
    live = [r for r in rows if r["scenario"] == "live-resize" and not r.get("error")]
    if not live:
        return {"measured": False}
    worst = max((r["main_ms_per_event"]["p99"] or 0) for r in live)
    counted = all(r["screen_reconciles"] is not None for r in live)
    reconciles = sum(r["screen_reconciles"] for r in live) if counted else None
    p99_pass = worst <= DC16_P99_MS
    return {"measured": True, "p99_ms_worst": worst, "p99_pass": p99_pass, "reconciles": reconciles,
            "reconciles_measured": counted, "pass": p99_pass and reconciles == 0 if counted else None}


# -- the app side --

def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def error_of(reply):
    return str(reply.get("error"))[:200] if isinstance(reply, dict) and reply.get("error") else None


class Bench:
    """One launched app with STRESS built. `sleep` and `clock` are the harness's (the self-test's fake advances)."""

    def __init__(self, app, opts, sleep=time.sleep, clock=time.monotonic):
        self.app, self.opts, self.sleep, self.clock = app, opts, sleep, clock

    def rpc(self, method, params=None, timeout=60):
        return self.app.rpc(method, params, timeout)

    def window_frame(self):
        layers = ((self.rpc("debug.layers") or {}).get("windows") or [{}])[0]
        return layers.get("frame")

    def counters(self):
        return self.rpc("debug.layout_counters") or {}

    def drag(self, dx, dy):
        """One live-resize drag of the bottom-right corner by (dx, dy), one event per 120 Hz frame. Returns the
        window frame before and after."""
        before = self.window_frame()
        if not before:
            return before, None
        x0, y0 = before[2] - 1, before[3] - 1
        self.rpc("debug.mouse", {"action": "down", "x": x0, "y": y0})
        started, steps = self.clock(), self.opts.steps
        for step in range(1, steps + 1):
            x, y = x0 + dx * step / steps, y0 + dy * step / steps
            self.rpc("debug.mouse", {"action": "drag", "x": x, "y": y, "to_x": x, "to_y": y, "steps": 1,
                                     "press": False, "release": False})
            wait = started + step / EVENT_HZ - self.clock()
            if wait > 0:
                self.sleep(wait)  # bench script: one drag event per 120 Hz frame
        self.rpc("debug.mouse", {"action": "up", "x": x0 + dx, "y": y0 + dy})
        self.sleep(0.5)  # bench script: the live resize ends
        return before, self.window_frame()

    def live_resize(self):
        """In by DRAG and back. Returns its notes; an error when the window did not resize."""
        inward = self.drag(*DRAG)
        back = self.drag(-DRAG[0], -DRAG[1])
        resized = all(b and a and b[2] != a[2] for b, a in (inward, back))
        return {"frames": [inward, back], "error": None if resized else "the window did not resize"}

    def full_screen(self):
        """Into full screen and out; each waits for AppKit's did-enter / did-exit."""
        notes = {}
        for label, notice in (("enter", "didEnter"), ("exit", "didExit")):
            reply = self.rpc("action.run", {"action": "toggleFullScreen", "focus": True, "origin": "user"})
            if error_of(reply):
                return {"error": f"toggleFullScreen ({label}): {error_of(reply)}"}
            deadline = self.clock() + 10
            while self.clock() < deadline:
                events = (self.rpc("debug.window_transition") or {}).get("events") or []
                if any(e.get("e") == notice for e in events):
                    break
                self.sleep(0.1)  # bench script: AppKit's full-screen animation runs on its own clock
            else:
                return {"error": f"no {notice} within 10 s"}
            self.sleep(0.5)  # bench script: the last layout after the notice
            notes[label] = self.window_frame()
        return {"frames": notes, "error": None}

    def timed_pass(self, scenario, round_index):
        step = {"live-resize": self.live_resize, "full-screen": self.full_screen}[scenario]
        counters_before, cef_before = self.counters(), self.rpc("debug.cef")
        self.rpc("debug.window_transition", {"action": "start"})
        self.rpc("debug.frames", {"action": "start"})
        notes = step()
        frames = self.rpc("debug.frames", {"action": "stop", "raw": True}) or {}
        trace = self.rpc("debug.window_transition", {"action": "stop"}) or {}
        row = {"scenario": scenario, "round": round_index, "error": notes.get("error"), "notes": notes}
        row.update(judge_pass(trace, frames, counters_before, self.counters(), cef_before, self.rpc("debug.cef")))
        if not row["error"] and not row["resize_events"]:
            row["error"] = "no window resize notice in the pass"
        return row

    def counting_pass(self, round_index):
        """The live resize with RenderStats armed: frame sets and layouts per resize event (counts only)."""
        started = self.rpc("debug.frames", {"action": "start", "render": True, "raw": True}) or {}
        if error_of(started):
            raise CountingError(f"debug.frames render start: {error_of(started)}")
        self.rpc("debug.window_transition", {"action": "start"})
        notes = self.live_resize()
        reply = self.rpc("debug.frames", {"action": "stop", "raw": True}) or {}
        trace = self.rpc("debug.window_transition", {"action": "stop"}) or {}
        sets, layouts = reply.get("frame_sets_per_frame"), reply.get("layouts_per_frame")
        if not isinstance(sets, list) or not isinstance(layouts, list):
            raise CountingError("debug.frames has no frame_sets_per_frame: a build without RenderStats "
                                "(p03-rendering-001), or a Release build")
        resizes = sum(1 for e in trace.get("events") or [] if e.get("e") == "resize")
        return {"scenario": "live-resize-counts", "round": round_index, "error": notes["error"], "resize_events": resizes,
                "frame_sets": sum(sets), "layouts": sum(layouts),
                "frame_sets_per_event": round(sum(sets) / resizes, 2) if resizes else None,
                "layouts_per_event": round(sum(layouts) / resizes, 2) if resizes else None}


def refresh_probe(app, sleep=time.sleep):
    """The display refresh from an unarmed `debug.frames` pass (no RenderStats hooks)."""
    app.rpc("debug.frames", {"action": "start"})
    sleep(0.3)  # bench script: about 36 frames at 120 Hz
    reply = app.rpc("debug.frames", {"action": "stop"}) or {}
    refresh = reply.get("refresh_ms") if isinstance(reply, dict) else None
    return round(refresh, 3) if isinstance(refresh, (int, float)) and refresh > 0 else None


def environment(app, opts, refresh_ms):
    """Host, chip, macOS, build and display rate (motion-main-work.py's record, the same keys)."""
    return load("motion_main_work", "motion-main-work.py").environment(app, opts, refresh_ms)


def main(opts, launcher=None, stress_module=None, sleep=time.sleep, clock=time.monotonic, facts=environment):
    """The run. `launcher` makes the app (BenchApp), `stress_module` is perf-stress-session.py, `sleep` and `clock`
    the harness's and `facts` the host record: the self-test passes fakes of all."""
    os.makedirs(opts.out, exist_ok=True)
    if launcher is None:
        from bench_launch import BenchApp
        launcher = BenchApp
    stress_module = stress_module or load("perf_stress_session", "perf-stress-session.py")
    report = {"schema": SCHEMA, "environment": {}, "session": {}, "passes": [], "counts": [], "problems": []}
    status, display = 0, None
    expect = opts.expect_hz or opts.vdisplay
    try:
        if opts.vdisplay:
            display = stress_module.start_vdisplay(opts.vdisplay, opts.out, opts.vdisplay_hold)
        app = launcher(opts.app, out=opts.out, window=WINDOW)
        try:
            app.launch(timeout=180)
            refresh = refresh_probe(app, sleep)
            report["environment"] = facts(app, opts, refresh)
            print("RESIZE-ENV " + json.dumps(report["environment"]), flush=True)
            if expect and (not refresh or abs(refresh - 1000 / expect) > 0.15 * 1000 / expect):
                raise ShapeError(f"the display refreshes every {refresh} ms, not {expect} Hz")
            builder = stress_module.Stress(lambda m, p=None, timeout=60: app.rpc(m, p, timeout), selected="chromium")
            report["session"] = builder.build()  # raises StressShapeError on another shape
            unavailable = stress_module.cef_problems(app.rpc("debug.cef"), stress_module.WEB_DEV_CONFIG)
            if unavailable:
                raise ShapeError(f"Chromium is not real: {unavailable}")
            bench = Bench(app, opts, sleep, clock)
            for round_index in range(opts.rounds):
                for scenario in ("live-resize", "full-screen"):
                    row = bench.timed_pass(scenario, round_index)
                    report["passes"].append(row)
                    print(f"RESIZE-PASS {scenario} {round_index} " + json.dumps(
                        {k: row[k] for k in ("error", "resize_events", "main_ms_per_event", "reconciles_per_event")}), flush=True)
                if opts.count:
                    report["counts"].append(bench.counting_pass(round_index))
        finally:
            app.stop()
    except (ShapeError, stress_module.StressShapeError) as error:
        report["problems"].append(f"{type(error).__name__}: {error}")
        status = 2
    except Exception as error:  # the run fails with the reason in the report
        report["problems"].append(f"{type(error).__name__}: {error}")
        status = 1
    finally:
        if display:
            display.terminate()  # the helper this script started, by its process
    report["problems"] += [f"{r['scenario']} round {r['round']}: {r['error']}" for r in report["passes"] + report["counts"]
                           if r.get("error")]
    report["dc16"] = dc16(report["passes"])
    if report["problems"] and not status:
        status = 1
    if not report["passes"] and not status:
        report["problems"].append("no pass ran")
        status = 1
    path = opts.json or os.path.join(opts.out, "window-live-resize.json")
    with open(path, "w") as f:
        json.dump(report, f, indent=1)
    print(f"RESIZE-REPORT {path} DC16 {json.dumps(report['dc16'])}", flush=True)
    print("RESULT " + ("PASS" if not status else f"FAIL {json.dumps(report['problems'])[:2000]}"), flush=True)
    return status


# -- the self-test: the statistics, then the pass flow and the exit codes on a fake app --

class FakeApp:
    """A socket double: a window the drag resizes, full screen, the counters and the traces. `knobs`: old_build
    (no screen counters), stuck (the window never resizes), reconciles (each resize event reconciles once)."""

    def __init__(self, knobs, clock):
        self.knobs, self.clock = knobs, clock
        self.frame = [40.0, 40.0, 1600.0, 1000.0]
        self.full = False
        self.counters = {"screen_reconciles": 5, "screen_resizes_in_place": 0, "terminal_grid_reports": 0}
        self.events = []
        self.frames = 0
        self.pressed = None

    def launch(self, timeout):
        return None

    def stop(self):
        return None

    def resize(self, width, height):
        self.frame[2:] = [width, height]
        self.events += [{"e": "resize", "w": width, "h": height}, {"e": "layout", "ms": 1.5, "w": width, "h": height}]
        self.frames += 1
        key = "screen_reconciles" if self.knobs.get("reconciles") else "screen_resizes_in_place"
        self.counters[key] += 1

    def rpc(self, method, params=None, timeout=60):
        params = params or {}
        action = params.get("action")
        if method == "debug.layers":
            return {"windows": [{"frame": list(self.frame)}]}
        if method == "debug.layout_counters":
            return {} if self.knobs.get("old_build") else dict(self.counters)
        if method == "debug.cef":
            return {"host_resize": {"fence_resizes": self.frames, "fence_joined": 0, "fence_late": 0, "fence_cut": 0}}
        if method == "debug.mouse":
            if action == "down":
                self.pressed = (params["x"], params["y"], self.frame[2], self.frame[3])
            elif action == "drag" and self.pressed and not self.knobs.get("stuck"):
                x0, y0, w, h = self.pressed
                self.resize(w + params["x"] - x0, h + params["y"] - y0)
            elif action == "up":
                self.pressed = None
                # A display-cycle pass in the settle, at the size the drag left: no resize caused it.
                self.events.append({"e": "layout", "ms": 9.0, "w": self.frame[2], "h": self.frame[3]})
            return {}
        if method == "action.run":
            self.full = not self.full
            self.resize(1920.0 if self.full else 1600.0, 1200.0 if self.full else 1000.0)
            self.events.append({"e": "didEnter" if self.full else "didExit"})
            return {}
        if method == "debug.window_transition":
            if action == "start":
                self.events, self.base_grids = [], self.counters["terminal_grid_reports"]
            return {"events": list(self.events), "root_layouts": len(self.events), "terminal_grid_reports": 0,
                    "terminal_resizes_sent": 0}
        if method == "debug.frames":
            if action == "start":
                self.frames = 0
                return {}
            frames = max(self.frames, 1)
            reply = {"frames": frames, "refresh_ms": 1000 / 120, "missed": 0, "main_ms": [1.0] * frames,
                     "view_layouts_per_frame": [2] * frames}
            if params.get("raw"):
                reply.update({"frame_sets_per_frame": [3] * frames, "layouts_per_frame": [1] * frames})
            return reply
        return {"error": f"fake: no {method}"}


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.now += max(seconds, 0.001)


def fake_stress(shape_error=False):
    class StressShapeError(RuntimeError):
        pass

    class Stress:
        def __init__(self, rpc, selected="terminal"):
            assert selected == "chromium", selected

        def build(self):
            if shape_error:
                raise StressShapeError("13 panes, not 14")
            return {"measured": "w60", "panes": 14}

    return types.SimpleNamespace(Stress=Stress, StressShapeError=StressShapeError, WEB_DEV_CONFIG=None,
                                 cef_problems=lambda cef, config: None, start_vdisplay=lambda *a: None)


def fake_run(tmp, knobs=None, shape_error=False, count=True):
    clock = FakeClock()
    opts = parse(["--app", "Fake.app", "--out", tmp, "--rounds", "2", "--steps", "6", "--expect-hz", "120"]
                 + (["--count"] if count else []))
    status = main(opts, launcher=lambda app, out, window: FakeApp(knobs or {}, clock), stress_module=fake_stress(shape_error),
                  sleep=clock.sleep, clock=clock, facts=lambda app, opts, refresh: {"host": "fake", "refresh_ms": refresh})
    with open(os.path.join(tmp, "window-live-resize.json")) as f:
        return status, json.load(f)


def self_test():
    import tempfile
    assert percentile([], 99) is None
    assert percentile([1, 2, 3, 4], 50) == 2 and percentile([1, 2, 3, 4], 99) == 4 and percentile([5], 1) == 5
    assert distribution([2.0, 1.0])["max"] == 2.0
    assert delta({"a": 1}, {"a": 4}, "a") == 3 and delta({}, {"a": 4}, "a") is None
    assert host_resize({"host_resize": None}) is None
    unsized = judge_pass({"events": []}, {}, {}, {}, None, None)
    assert unsized["screen_reconciles"] is None and unsized["counting_note"] == NO_SCREEN_COUNTERS, unsized
    # The passes a resize caused, not the display-cycle passes around them (the trace starts mid-size).
    trace = [{"e": "layout", "ms": 0.1, "w": 800, "h": 600}, {"e": "resize"}, {"e": "layout", "ms": 6.0, "w": 801, "h": 600},
             {"e": "layout", "ms": 0.1, "w": 801, "h": 600}, {"e": "layout", "ms": 5.0, "w": 802, "h": 600},
             {"e": "resize"}, {"e": "layout", "ms": 0.2}]
    assert split_layouts(trace) == ([6.0, 5.0, 0.2], [0.1, 0.1]), split_layouts(trace)
    assert split_layouts([{"e": "resize"}, {"e": "layout", "ms": 2.0, "w": 1, "h": 1}]) == ([2.0], [])
    assert dc16([]) == {"measured": False}
    with tempfile.TemporaryDirectory() as tmp:
        status, report = fake_run(tmp)
        assert status == 0, report["problems"]
        live = [r for r in report["passes"] if r["scenario"] == "live-resize"]
        assert len(live) == 2 and len(report["passes"]) == 4, report["passes"]
        assert live[0]["resize_events"] == 12 and live[0]["reconciles_per_event"] == 0.0, live[0]
        assert live[0]["main_ms_per_event"]["p99"] == 1.5 and live[0]["page_resize_waits"]["fence_resizes"] is not None
        # The settle pass after each drag (9 ms, no resize) is its own distribution, not DC16's.
        assert live[0]["resize_layout_passes"] == 12 and live[0]["layout_passes"] == 14, live[0]
        assert live[0]["main_ms_other_layouts"] == {"n": 2, "p50": 9.0, "p95": 9.0, "p99": 9.0, "max": 9.0}, live[0]
        assert report["dc16"] == {"measured": True, "p99_ms_worst": 1.5, "p99_pass": True, "reconciles": 0,
                                  "reconciles_measured": True, "pass": True}, report["dc16"]
        assert report["counts"][0]["frame_sets_per_event"] is not None
        assert report["environment"]["refresh_ms"] == round(1000 / 120, 3)
    with tempfile.TemporaryDirectory() as tmp:
        status, report = fake_run(tmp, knobs={"reconciles": True}, count=False)
        assert status == 0 and report["dc16"]["pass"] is False and report["dc16"]["reconciles"] == 24, report["dc16"]
    with tempfile.TemporaryDirectory() as tmp:
        status, report = fake_run(tmp, shape_error=True)
        assert status == 2 and "StressShapeError" in report["problems"][0], report["problems"]
    with tempfile.TemporaryDirectory() as tmp:
        # The base of a base-vs-head run: no screen counters, every timed row still recorded.
        status, report = fake_run(tmp, knobs={"old_build": True})
        assert status == 0 and not report["problems"], report["problems"]
        live = [r for r in report["passes"] if r["scenario"] == "live-resize"]
        assert len(report["passes"]) == 4 and all(r["screen_reconciles"] is None and r["reconciles_per_event"] is None
                                                  and r["counting_note"] for r in report["passes"]), report["passes"]
        assert live[0]["main_ms_per_event"]["p99"] == 1.5 and live[0]["view_layouts"] and live[0]["grids_per_frame"] == 0.0
        assert report["dc16"] == {"measured": True, "p99_ms_worst": 1.5, "p99_pass": True, "reconciles": None,
                                  "reconciles_measured": False, "pass": None}, report["dc16"]
    with tempfile.TemporaryDirectory() as tmp:
        status, report = fake_run(tmp, knobs={"stuck": True}, count=False)
        assert status == 1 and any("did not resize" in p for p in report["problems"]), report["problems"]
    print("self-test: ok")
    return 0


def parse(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--app", default=os.environ.get("NX_APP"), help="the tagged app bundle (default $NX_APP)")
    parser.add_argument("--out", help="the artifact folder")
    parser.add_argument("--json", help="the report's path (default OUT/window-live-resize.json)")
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--steps", type=int, default=60, help="drag events each way, one per 120 Hz frame")
    parser.add_argument("--count", action="store_true", help="add an armed RenderStats pass per round (counts only)")
    parser.add_argument("--vdisplay", type=float, default=0,
                        help="make a virtual main display at this rate first (perf-stress-session.py start_vdisplay)")
    parser.add_argument("--vdisplay-hold", type=float, default=3600)
    parser.add_argument("--expect-hz", type=float, default=0,
                        help="fail unless the display refreshes at this rate (default: --vdisplay's)")
    parser.add_argument("--self-test", action="store_true")
    opts = parser.parse_args(argv)
    if not opts.self_test and (not opts.app or not opts.out):
        parser.error("name the tagged app with --app (or $NX_APP) and the artifact folder with --out")
    return opts


if __name__ == "__main__":
    options = parse()
    sys.exit(self_test() if options.self_test else main(options))
