#!/usr/bin/env python3
"""ext_pixel.py's steps against a fake app socket (no fleet, no app), and the pixel cases' journey files.

    python3 scripts/journeys/test_ext_pixel.py

px_film / px_springs: every motion.spring.* response set to its default / speed, damping kept, read back; Reduce Motion;
the reset. With the tunable store inactive (a Release build with bench hooks, cmux22 2026-11-03): `debug.tunables
activate` when the build has it; else the x1 and Reduce Motion films play and every other speed is one "not run" line,
the journey goes on. px_tunable records a value that did not take (the page backdrop stays on). px_record_start: a scan
row through every tab strip first, then rows and columns at 0.3 and 0.7 of every pane (device px, inside the recorder's
frame and its scan budget), and the judge's note. px_page: the openBrowser action takes url and engine only (the app
refuses any other argument: "openBrowser has no argument 'focus'", cmux22 2026-11-03) and the page's own report.
px_agent_css: theme.css beside the settings file. gen_pixel.py: every journey validates (run.py), stays in one lease,
names each film once; the x1 + Reduce Motion journeys fit three to a lease.

The recorder (cmux22 2026-11-03, kit 469b5922800): a second film's ScreenCaptureKit start gave no callback within
ext_video's 8 s, while the app bounds each of its two ScreenCaptureKit calls at 10 s (callLimit) and only then reports
an error. video_start takes `start_timeout` (default 8, as before) and reads the app's own start error as not run (it
was a StepError); px_record_start waits for the recorder to be idle (no recording running, the last one written),
starts with the app's own bound and retries a start that did not take once. The lease fetch moved every film raw (`tar c
*/video`, about 400 MB of scan for six films) and timed out at 240 s: run.py's VIDEO_FETCH compresses it (`tar cz`), which
take_videos reads as before; px_film records each film's movie and scan bytes in its result.
"""
import gzip
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE.parent / "cmux-next")]
import driver as D  # noqa: E402  (loads ext_*.py: ext_pixel installs with it)
import ext_pixel as X  # noqa: E402

DEFAULTS = {"move": (0.15, 1.0), "split": (0.23, 0.95), "scroll": (0.2, 0.9), "pinDrag": (0.215, 0.8385254915624211)}
OPEN_BROWSER_ARGS = ("url", "engine", "profile")


class FakeApp:
    """The control socket of a bench build with two panes (p0 terminal, p1 page) in one 1200 x 800 pt window at 2x.
    active: the tunable store takes overrides; activate: the build has `debug.tunables activate`."""

    def __init__(self, active=True, activate=False):
        self.active, self.can_activate, self.overrides, self.calls, self.motion = active, activate, {}, [], {}
        self.page_reads = 0
        self.pid = 4242

    def default(self, token):
        return DEFAULTS.get(token, (0.2, 0.9))

    def rpc(self, method, params=None, timeout=None):
        params = params or {}
        self.calls.append((method, params))
        if method == "debug.tunables":
            action = params.get("action")
            if action == "state":
                return {"available": self.active, "active": self.active}
            if action == "activate":
                if not self.can_activate:
                    raise D.StepError("debug.tunables: unknown action")  # App.rpc raises on a result's error
                self.active = True
                return {"available": True, "active": True}
            key = params.get("key", "")
            if action == "reset":
                self.overrides.clear()
                return {"active": self.active}
            if key.startswith("motion.spring."):
                r, d = self.default(key.split(".")[-1])
                default = {"response": r, "dampingFraction": d}
                if action == "set" and self.active:
                    value = params.get("value")
                    if value is None or value == default:
                        self.overrides.pop(key, None)
                    else:
                        self.overrides[key] = value
                return {"key": key, "value": self.overrides.get(key, default), "default": default, "changed": key in self.overrides}
            if key == "browserResize.pageBackdrop":
                if action == "set" and self.active:
                    if params.get("value") is None:
                        self.overrides.pop(key, None)
                    else:
                        self.overrides[key] = params["value"]
                return {"key": key, "value": self.overrides.get(key, True), "default": True, "changed": key in self.overrides}
            raise D.StepError("debug.tunables: unknown key")
        if method == "debug.motion":
            self.motion[params.get("action")] = params.get("value")
            return {"reduce_motion": bool(self.motion.get("reduce")), "speed": self.motion.get("speed", "fast")}
        if method == "debug.pane_chrome":
            return {"windows": [{"id": "w1", "scale": 2.0, "panes": [
                {"pane": "pane-a", "cell": [0, 40, 600, 760], "border": [4, 70, 592, 726], "strip": [4, 40, 592, 28],
                 "pill": [10, 44, 200, 20], "strip_hidden": False},
                {"pane": "pane-b", "cell": [601, 40, 599, 760], "border": [605, 70, 591, 726], "strip": [605, 40, 591, 28],
                 "pill": [611, 44, 200, 20], "strip_hidden": False}]}]}
        if method == "debug.layers":
            return {"windows": [{"frame": [100, 50, 1200, 800], "screen_frame": [0, 0, 1512, 982]}]}
        if method == "debug.surfaces":
            return {"windows": [{"window": 1, "panes": [
                {"pane": "pane-a", "focused": False, "kind": "terminal"},
                {"pane": "pane-b", "focused": True, "kind": "browser", "selected_tab": "tab-b",
                 "url": "file:///private/tmp/jr-pixel-page.html?bg=00FF00&label=p1"}]}]}
        if method == "action.run":
            unknown = sorted(set(params.get("args") or {}) - set(OPEN_BROWSER_ARGS)) if params.get("action") == "openBrowser" else []
            if unknown:
                raise D.StepError("action.run: {'code': 'invalid_params', 'data': {'not_run': True, 'valid': ['url', 'engine', "
                                  f"'profile']}}, 'message': \"openBrowser has no argument '{unknown[0]}'\"}}")
            return {"ok": True}
        if method == "browser.page.eval":
            self.page_reads += 1
            return {"value": {"w": 591, "h": 696, "dpr": 2, "raf": 10 * self.page_reads, "bg": "#00FF00"}}
        raise AssertionError(f"unexpected rpc {method} {params}")

    def cmux(self, *args):
        self.calls.append(("cmux", args))
        return {"ok": True}


class FakeJourney:
    def __init__(self, app, config_dir):
        self.app, self.marks, self.config_dir = app, {}, config_dir
        self.out = Path(config_dir) / "out"
        self.ext_panes = {"p0": {"pane": "pane-a", "term": "t-a", "host_pid": 1, "window": "w1"},
                          "p1": {"pane": "pane-b", "term": "t-b", "host_pid": 1, "window": "w1"}}
        self.video = None
        self.played = []

    def config_file(self):
        return os.path.join(self.config_dir, "cmux-next.json")

    def step_wait(self, step):  # the sub-steps a px_film plays (the driver's own handlers in a journey)
        self.played.append(step.get("title"))
        return {}


def film(name, speed=None, reduce=False):
    step = {"do": "px_film", "name": name, "steps": [{"do": "wait", "seconds": 0, "title": f"{name} play"}],
            "after": [{"do": "wait", "seconds": 0, "title": f"{name} rebuild"}]}
    step.update({"reduce": True} if reduce else {"speed": speed})
    return step


class ExtPixelTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ext-pixel-")
        self.app = FakeApp()
        self.j = FakeJourney(self.app, self.tmp)

    def test_springs_scale_every_response(self):
        out = X.step_px_springs(self.j, {"speed": 0.25})
        self.assertEqual(len(out["keys"]), 16)
        self.assertEqual(self.app.overrides["motion.spring.move"], {"response": 0.6, "dampingFraction": 1.0})
        self.assertEqual(self.app.overrides["motion.spring.split"], {"response": 0.92, "dampingFraction": 0.95})
        self.assertEqual(self.app.overrides["motion.spring.pinDrag"]["dampingFraction"], 0.8385254915624211)
        self.assertEqual(self.app.motion["speed"], "fast")
        self.assertIs(self.app.motion["reduce"], False)
        self.assertEqual(self.j.px["springs"]["move"]["damping"], 1.0)
        X.step_px_springs(self.j, {"speed": 4})
        self.assertAlmostEqual(self.app.overrides["motion.spring.split"]["response"], 0.0575)
        X.step_px_springs(self.j, {"speed": 1})
        self.assertEqual(self.app.overrides, {})  # a value equal to the default resets the key
        X.step_px_springs(self.j, {"reduce": True})
        self.assertIs(self.app.motion["reduce"], True)
        self.assertEqual(self.j.px["reduce"], True)
        X.step_px_springs(self.j, {"reset": True})
        self.assertIsNone(self.app.motion["reduce"])

    def test_films_with_the_store_active(self):
        out = [X.step_px_film(self.j, film("f-s025", 0.25)), X.step_px_film(self.j, film("f-reduce", reduce=True))]
        self.assertEqual([o["status"] for o in out], ["recorded", "recorded"])
        self.assertEqual(self.j.played, ["f-s025 play", "f-s025 rebuild", "f-reduce play", "f-reduce rebuild"])
        self.assertEqual([f["film"] for f in self.j.px["films"]], ["f-s025", "f-reduce"])
        self.assertEqual(self.j.px["springs_source"], "defaults")

    def test_store_inactive_plays_x1_and_reduce_only(self):
        self.app.active = False
        out = {s: X.step_px_film(self.j, film(f"f-{s}", speed)) for s, speed in (("s025", 0.25), ("s1", 1.0), ("s4", 4.0))}
        out["reduce"] = X.step_px_film(self.j, film("f-reduce", reduce=True))
        self.assertEqual({k: v["status"] for k, v in out.items()},
                         {"s025": "not run", "s1": "recorded", "s4": "not run", "reduce": "recorded"})
        self.assertTrue(out["s025"]["reason"].startswith("not run: tunable store inactive"), out["s025"]["reason"])
        self.assertEqual(self.j.played, ["f-s1 play", "f-s1 rebuild", "f-reduce play", "f-reduce rebuild"])
        self.assertEqual(self.app.overrides, {})
        self.assertIs(self.app.motion["reduce"], True)
        self.assertEqual(sum(1 for m, p in self.app.calls if m == "debug.tunables" and p.get("action") == "activate"), 1)
        with self.assertRaises(D.NotRun):
            X.step_px_springs(self.j, {"speed": 2})

    def test_activate_turns_the_store_on(self):
        self.app = FakeApp(active=False, activate=True)
        self.j = FakeJourney(self.app, self.tmp)
        out = X.step_px_film(self.j, film("f-s05", 0.5))
        self.assertEqual(out["status"], "recorded")
        self.assertTrue(self.j.px["store"]["activated"])
        self.assertEqual(self.app.overrides["motion.spring.move"], {"response": 0.3, "dampingFraction": 1.0})

    def test_backdrop_that_did_not_take_is_recorded(self):
        self.app.active = False
        out = X.step_px_tunable(self.j, {"key": "browserResize.pageBackdrop", "value": False})
        self.assertFalse(out["applied"])
        self.assertIs(out["value"], True)
        self.assertIn("tunable store inactive", out["why"])
        self.app.active = True
        self.j = FakeJourney(self.app, self.tmp)
        out = X.step_px_tunable(self.j, {"key": "browserResize.pageBackdrop", "value": False})
        self.assertTrue(out["applied"])
        self.assertTrue(X.step_px_tunable(self.j, {"key": "browserResize.pageBackdrop", "value": None})["applied"])

    def test_record_start_lines_and_note(self):
        X.step_px_springs(self.j, {"speed": 0.5})
        self.app.overrides["browserResize.pageBackdrop"] = False
        started = {}

        def fake_start(j, step):
            started.update(step)
            j.video = {"notes": {}}
            return {"refresh_ms": 8.33}

        real, X.V.step_video_start = X.V.step_video_start, fake_start
        try:
            out = X.step_px_record_start(self.j, {"name": "px-x-s05", "seconds": 8, "require_hz": 120, "spring": "split",
                                                   "input": "keys", "fixture": {"p0": {"kind": "tui", "fill": "#FFFF00"},
                                                                                "p1": {"kind": "page", "fill": "#00FF00"}}})
        finally:
            X.V.step_video_start = real
        # The strip row (both strips: y 40 + 28 / 2 = 54 pt), then rows at 0.3 and 0.7 of the panes' height (shared), and
        # columns at 0.3 and 0.7 of each one's width.
        self.assertEqual(started["rows"], [108, 576, 1156])
        self.assertEqual(started["columns"], [363, 837, 1565, 2037])
        self.assertEqual(out["strip_rows"], {"pane-a": 108, "pane-b": 108})
        self.assertEqual(started["require_hz"], 120)
        note = self.j.video["notes"]["pixel"]
        self.assertEqual(note["panes"], {"pane-a": {"kind": "tui", "agent": False, "fill": "#FFFF00", "label": "p0"},
                                         "pane-b": {"kind": "page", "agent": False, "fill": "#00FF00", "label": "p1"}})
        self.assertEqual({k: note["spring"][k] for k in ("token", "response", "damping")},
                         {"token": "split", "response": 0.46, "damping": 0.95})
        self.assertEqual(note["speed"], 0.5)
        self.assertIs(note["page_backdrop"], False)
        self.assertEqual(note["lines"]["strip_rows"], {"pane-a": 108, "pane-b": 108})
        self.assertEqual(note["chrome"][1]["pill"], [611, 44, 200, 20])
        self.assertEqual(note["window_frame"], [100.0, 50.0, 1200.0, 800.0])
        # The recorder's frame: from the window's top-left (132 pt below the screen's top) to the screen's right and bottom.
        self.assertEqual(note["frame"], [2824, 1700])
        self.assertEqual(out["dropped_lines"], 0)

    def test_record_start_spring_default_when_the_store_is_inactive(self):
        self.app.active = False
        X.step_px_film(self.j, film("f-s1", 1.0))

        def fake_start(j, step):
            j.video = {"notes": {}}
            return {}

        real, X.V.step_video_start = X.V.step_video_start, fake_start
        try:
            X.step_px_record_start(self.j, {"name": "n", "seconds": 4, "spring": "move", "spring_default": {"response": 0.15, "damping": 1.0},
                                            "fixture": {"p0": {"kind": "tui", "fill": "#FFFF00"}}})
        finally:
            X.V.step_video_start = real
        note = self.j.video["notes"]["pixel"]
        self.assertEqual(note["springs_source"], "defaults (tunable store inactive)")
        self.assertEqual((note["spring"]["response"], note["spring"]["damping"]), (0.15, 1.0))
        self.assertIs(note["page_backdrop"], True)
        self.assertFalse(note["store"]["active"])

    def test_scan_budget_drops_lines(self):
        rects = [[0, 0, 300, 400], [300, 0, 300, 400], [600, 0, 300, 400]]
        rows, cols, strips, dropped, used = X.scan_lines(rects, 2.0, 3024, 1964, 60.0, strips=[[0, 0, 300, 20]])
        self.assertLessEqual(used, X.SCAN_BUDGET)
        self.assertGreater(dropped, 0)
        self.assertEqual(strips, {0: 20})
        self.assertIn(20, rows, "the strip row comes first")

    def test_page_opens_the_fixture(self):
        out = X.step_px_page(self.j, {"pane": "p1", "bg": "#00FF00", "label": "p1", "timeout": 5})
        run = next(p for m, p in self.app.calls if m == "action.run")
        self.assertEqual(run["action"], "openBrowser")
        self.assertEqual(run["args"], {"url": "file:///tmp/jr-pixel-page.html?bg=00FF00&label=p1", "engine": "cef"})
        self.assertIs(run["focus"], True)  # the run's own focus selects the new tab
        self.assertIsNone(out["navigated"])  # /private/tmp is the same page
        self.assertEqual(out["page"]["dpr"], 2)

    def test_agent_css(self):
        out = X.step_px_agent_css(self.j, {"fill": "#0000FF"})
        text = Path(out["path"]).read_text()
        self.assertEqual(out["path"], os.path.join(self.tmp, "agent-pane", "theme.css"))
        self.assertIn("background: #0000FF !important", text)
        self.assertIn("border: 1px solid #FF0000", text)
        X.step_px_agent_css(self.j, {"remove": True})
        self.assertFalse(Path(out["path"]).exists())


class FakeClock:
    """time.monotonic / sleep / time for ext_video's waits (no real waiting in a test)."""

    def __init__(self):
        self.t = 1000.0

    def monotonic(self):
        return self.t

    def sleep(self, seconds):
        self.t += max(0.0, float(seconds))

    def time(self):
        return 1.7e9 + self.t


class RecorderApp(FakeApp):
    """The app's recorder (MotionScreenRecord): ScreenCaptureKit's start takes `start_s` of the fake clock; with
    `error_after`, the app gives up first (its own 10 s call limit), forgets the recording and reports the error on every
    record_read until the next start; record_stop answers "no recording" then."""

    def __init__(self, clock, start_s, error_after=None):
        super().__init__()
        self.clock, self.start_s, self.error_after = clock, start_s, error_after
        self.recording, self.written, self.last_error, self.started_at, self.starts = False, True, None, None, 0

    def rpc(self, method, params=None, timeout=None):
        params = params or {}
        if method == "debug.journal":
            return {"entries": []}
        if method != "debug.motion" or params.get("action") not in ("trace_start", "record_start", "record_read", "record_stop",
                                                                      "trace_stop", "trace_read"):
            return super().rpc(method, params, timeout)
        self.calls.append((method, params))
        action = params["action"]
        if action == "trace_start":
            return {"views": 3}
        if action in ("trace_stop", "trace_read"):
            return {"refresh_ms": 8.333, "samples": []}
        if action == "record_start":
            self.starts += 1
            self.recording, self.written, self.last_error, self.started_at = True, False, None, self.clock.t
            return {"starting": True, "width": 2872, "height": 1816, "scale": 2.0}
        if action == "record_stop":
            if not self.recording:
                raise D.StepError("debug.motion: no recording")
            self.recording, self.written = False, True
            return {"written": True}
        if self.recording and self.error_after is not None and self.clock.t - self.started_at >= self.error_after:
            self.recording, self.written, self.last_error = False, True, "start the capture: no answer within 10 s"
        if self.last_error:
            raise D.StepError(f"debug.motion: {self.last_error}")
        capturing = self.recording and self.clock.t - self.started_at >= self.start_s
        return {"capturing": capturing, "written": self.written, "callbacks": 0, "frames": 0}


class VideoStartTimeoutTests(unittest.TestCase):
    """ext_video's video_start waits for the app's own answer when asked (`start_timeout`); 8 s stays the default."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ext-pixel-vs-")
        self.clock = FakeClock()
        self.saved = (X.V.time, X.V._bypass_dialog)
        X.V.time, X.V._bypass_dialog = self.clock, (lambda j: None)

    def tearDown(self):
        X.V.time, X.V._bypass_dialog = self.saved

    def start(self, app, **step):
        j = FakeJourney(app, self.tmp)
        return j, X.V.step_video_start(j, dict({"name": "px-f-s1", "seconds": 8, "require_hz": 120, "lead": 0.5}, **step))

    def test_default_bound_is_still_8_s(self):
        with self.assertRaises(D.NotRun) as caught:
            self.start(RecorderApp(self.clock, start_s=9.0))
        self.assertIn("ScreenCaptureKit did not start", str(caught.exception))

    def test_a_slow_start_is_waited_for(self):
        app = RecorderApp(self.clock, start_s=9.0)
        j, out = self.start(app, start_timeout=22)
        self.assertEqual(out["refresh_ms"], 8.333)
        self.assertEqual(j.video["name"], "px-f-s1")
        self.assertEqual(app.starts, 1)

    def test_the_apps_own_start_error_is_not_run(self):
        app = RecorderApp(self.clock, start_s=1e9, error_after=10.0)
        with self.assertRaises(D.NotRun) as caught:  # was a StepError (a journey fail): record_read and record_stop raise
            self.start(app, start_timeout=22)
        self.assertIn("no answer within 10 s", str(caught.exception))


class RecorderWaitTests(unittest.TestCase):
    """px_record_start: the recorder idle first (a real signal: no recording running, the last one written), the app's own
    start bound, one retry of a start that did not take; px_film: each film's bytes."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ext-pixel-rw-")
        self.clock = FakeClock()
        self.saved = (X.V.time, X.V._bypass_dialog, X.D.now, X.time)
        X.V.time, X.V._bypass_dialog = self.clock, (lambda j: None)
        X.D.now, X.time = self.clock.monotonic, self.clock

    def tearDown(self):
        X.V.time, X.V._bypass_dialog, X.D.now, X.time = self.saved

    def record(self, app, **step):
        j = FakeJourney(app, self.tmp)
        out = X.step_px_record_start(j, dict({"name": "px-f-reduce", "seconds": 8, "require_hz": 120, "lead": 0.5,
                                              "fixture": {"p0": {"kind": "tui", "fill": "#FFFF00"}}}, **step))
        return j, out

    def test_waits_for_the_last_recording_to_be_written(self):
        app = RecorderApp(self.clock, start_s=0.2)
        app.recording, app.written, app.started_at = False, False, self.clock.t  # the last film still being written
        written_at = self.clock.t + 1.5
        real = app.rpc

        def rpc(method, params=None, timeout=None):
            if method == "debug.motion" and (params or {}).get("action") == "record_read" and not app.recording \
                    and self.clock.t >= written_at:
                app.written = True
            if method == "debug.motion" and (params or {}).get("action") == "record_start" and not app.written:
                raise D.StepError("debug.motion: the last recording is still being written (read until written)")
            return real(method, params, timeout)

        app.rpc = rpc
        j, out = self.record(app)
        self.assertEqual(app.starts, 1)
        self.assertGreaterEqual(out["recorder"]["idle"][0]["waited_s"], 1.5)
        self.assertEqual(j.video["notes"]["pixel"]["recorder"]["attempts"], [])

    def test_a_start_that_did_not_take_is_tried_again(self):
        app = RecorderApp(self.clock, start_s=0.2, error_after=10.0)
        first = {"n": 0}
        real = app.rpc

        def rpc(method, params=None, timeout=None):
            if method == "debug.motion" and (params or {}).get("action") == "record_start":
                first["n"] += 1
                app.start_s = 1e9 if first["n"] == 1 else 0.2  # the first start hangs, the app ends it at 10 s
            return real(method, params, timeout)

        app.rpc = rpc
        j, out = self.record(app)
        self.assertEqual(app.starts, 2)
        attempts = j.video["notes"]["pixel"]["recorder"]["attempts"]
        self.assertEqual(len(attempts), 1)
        self.assertIn("no answer within 10 s", attempts[0])
        self.assertEqual(len(out["recorder"]["idle"]), 2)

    def test_start_bound_is_the_apps_call_limits(self):
        seen = {}
        real = X.V.step_video_start

        def fake(j, step):
            seen.update(step)
            j.video = {"notes": {}}
            return {}

        X.V.step_video_start = fake
        try:
            self.record(RecorderApp(self.clock, start_s=0.2))
        finally:
            X.V.step_video_start = real
        self.assertEqual(seen["start_timeout"], X.START_TIMEOUT)
        self.assertGreaterEqual(X.START_TIMEOUT, 21)  # two ScreenCaptureKit calls of at most 10 s each, and a margin

    def test_other_not_runs_are_not_retried(self):
        calls = {"n": 0}
        real = X.V.step_video_start

        def fake(j, step):
            calls["n"] += 1
            raise D.NotRun("video_start px-f-reduce: the window's display runs at 16.67 ms a frame, not 120 Hz")

        X.V.step_video_start = fake
        try:
            with self.assertRaises(D.NotRun):
                self.record(RecorderApp(self.clock, start_s=0.2))
        finally:
            X.V.step_video_start = real
        self.assertEqual(calls["n"], 1)

    def test_film_records_its_bytes(self):
        app = FakeApp()
        j = FakeJourney(app, self.tmp)
        video = j.out / "video"
        video.mkdir(parents=True)
        (video / "f-s1.mov").write_bytes(b"m" * 1234)
        (video / "f-s1.mov.scan").write_bytes(b"s" * 56789)
        line = X.step_px_film(j, film("f-s1", 1.0))
        self.assertEqual(line["bytes"], {"movie": 1234, "scan": 56789})
        self.assertEqual(j.px["films"][-1]["bytes"], {"movie": 1234, "scan": 56789})


class AgentPaneTests(unittest.TestCase):
    """px_agent: palette.newAgentChat aimed at the named pane (target pane:<id>, no focus: the app's targeted path opens
    the chat tab in that pane, AgentHandlers.openTargetedChat; with focus or no target a script's chat goes to a new
    left chat dock, NewChatPlacement .newDock), then the pane's selected tab is the chat (debug.surfaces kind
    conversation) and the pane is focused again."""

    def test_opens_the_chat_in_its_pane(self):
        class App(FakeApp):
            def __init__(self):
                super().__init__()
                self.kind = "terminal"

            def rpc(self, method, params=None, timeout=None):
                params = params or {}
                if method == "action.run" and params.get("action") == "palette.newAgentChat":
                    self.calls.append((method, params))
                    self.kind = "conversation"
                    return {"ran": True, "tab": "tab_chat"}
                if method == "debug.surfaces":
                    self.calls.append((method, params))
                    return {"windows": [{"window": 1, "panes": [{"pane": "pane-b", "focused": True, "kind": self.kind,
                                                                 "selected_tab": "tab_chat"}]}]}
                return super().rpc(method, params, timeout)

        app = App()
        j = FakeJourney(app, tempfile.mkdtemp())
        out = X.step_px_agent(j, {"pane": "p1", "timeout": 5})
        run = next(p for m, p in app.calls if m == "action.run")
        self.assertEqual(run["target"], "pane:pane-b")
        self.assertNotIn("focus", run)
        self.assertEqual(run["args"], {})
        self.assertEqual(out["kind"], "conversation")
        self.assertIn(("cmux", ("pane", "pane-b", "focus")), app.calls)

    def test_a_chat_that_never_shows_fails(self):
        class App(FakeApp):
            def rpc(self, method, params=None, timeout=None):
                if method == "action.run":
                    return {"ran": True}
                if method == "debug.surfaces":
                    return {"windows": [{"window": 1, "panes": [{"pane": "pane-b", "focused": True, "kind": "terminal"}]}]}
                return super().rpc(method, params, timeout)

        clock = FakeClock()
        saved = (X.D.now, X.time)
        X.D.now, X.time = clock.monotonic, clock
        try:
            with self.assertRaises(D.StepError) as caught:
                X.step_px_agent(FakeJourney(App(), tempfile.mkdtemp()), {"pane": "p1", "timeout": 5})
        finally:
            X.D.now, X.time = saved
        self.assertIn("p1", str(caught.exception))


class WindowFrameTests(unittest.TestCase):
    """px_window_frame: the window's bottom-right corner moved through ext_window's window_drag (debug.mouse into AppKit's
    resize tracking, the path the R3a journeys use), its frame read back."""

    def test_window_drag_of_the_corner(self):
        calls = []

        class Win:
            pass

        def fake(j, step):
            calls.append(step)
            return {"frame_before": [76, 116, 1361, 792], "frame_after": [76, 266, 1061, 642], "dragged": step["by"]}

        real = X.W.step_window_drag
        X.W.step_window_drag = fake
        try:
            j = FakeJourney(FakeApp(), tempfile.mkdtemp())
            j.video = {"hid": [], "notes": {}}
            out = X.step_px_window_frame(j, {"by": [-300, -150], "ms": 600, "mark": "in"})
        finally:
            X.W.step_window_drag = real
        self.assertEqual(calls[0]["edge"], "bottom-right")
        self.assertEqual(calls[0]["by"], [-300, -150])
        self.assertEqual(calls[0]["events"], 72)  # 600 ms at 120 events a second
        self.assertEqual(calls[0]["hz"], 120)
        self.assertEqual(out["frame_after"], [76, 266, 1061, 642])
        self.assertEqual(j.video["hid"][0]["kind"], "window_drag")
        self.assertIn("in", j.marks)


class VideoFetchTests(unittest.TestCase):
    """run.py's lease fetch of the films: compressed on the mini (`tar cz`), read back by take_videos unchanged."""

    def test_fetch_is_compressed_and_read_back(self):
        import run as R
        with tempfile.TemporaryDirectory() as mini, tempfile.TemporaryDirectory() as vm:
            video = Path(mini) / "px-a-s1r" / "video"
            video.mkdir(parents=True)
            header = json.dumps({"width": 2872, "height": 1816, "rows": [28], "columns": [762]}).encode() + b"\n"
            row = (b"\x00\xff\xff\xff" * 400 + b"\x00\x00\xff\xff" * 2472)  # BGRA: a yellow run, then a red one
            scan = header + b"".join(b"\x00" * 8 + row + b"\xff\x00\xff\xff" * 1816 for _ in range(600))
            (video / "px-a-s1r-s1.mov.scan").write_bytes(scan)
            (video / "px-a-s1r-s1.mov").write_bytes(os.urandom(200_000))  # an encoded movie does not compress
            stream = subprocess.run(["sh", "-c", f"cd '{mini}' && {R.VIDEO_FETCH}"], capture_output=True, timeout=120).stdout
            self.assertTrue(stream.startswith(b"\x1f\x8b"), "the fetch is gzip")
            self.assertLess(len(stream), 600_000, f"{len(stream)} bytes for {len(scan)} bytes of scan")
            R.take_videos(stream, Path(vm), {"px-a-s1r"})
            self.assertEqual((Path(vm) / "px-a-s1r" / "video" / "px-a-s1r-s1.mov.scan").read_bytes(), scan)
            self.assertEqual(len((Path(vm) / "px-a-s1r" / "video" / "px-a-s1r-s1.mov").read_bytes()), 200_000)

    def test_take_videos_still_reads_an_uncompressed_fetch(self):
        import run as R
        import tarfile
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w") as tar:
            data = b"scan bytes"
            info = tarfile.TarInfo("rk-x/video/rk-x.mov.scan")
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
        with tempfile.TemporaryDirectory() as vm:
            R.take_videos(buf.getvalue(), Path(vm), {"rk-x"})
            self.assertEqual((Path(vm) / "rk-x" / "video" / "rk-x.mov.scan").read_bytes(), b"scan bytes")
        self.assertEqual(gzip.decompress(gzip.compress(b"x")), b"x")


class PixelCasesTests(unittest.TestCase):
    def test_generated_journeys(self):
        with tempfile.TemporaryDirectory() as out:
            done = subprocess.run([sys.executable, str(HERE / "video-cases" / "gen_pixel.py"), "--out", out], capture_output=True,
                                  text=True, timeout=120)
            self.assertEqual(done.returncode, 0, done.stderr)
            import run as R
            specs = [json.loads(p.read_text()) for p in sorted(Path(out).glob("*.json"))]
            self.assertEqual({s["id"]: R.validate(s) for s in specs}, {s["id"]: [] for s in specs})
            self.assertGreaterEqual(len(specs), 22)
            names = [n for s in specs for n in s["recordings"]]
            self.assertEqual(len(names), len(set(names)))
            labels = {n.rsplit("-", 1)[1] for n in names}
            self.assertEqual(labels, {"s025", "s05", "s1", "s2", "s4", "reduce"})
            for s in specs:
                self.assertLessEqual(s["budget_seconds"], 250, s["id"])
                films = [st for st in s["steps"] if st["do"] == "px_film"]
                self.assertEqual([f["name"] for f in films], s["recordings"])
                for f in films:
                    starts = [st for st in f["steps"] if st["do"] == "px_record_start"]
                    self.assertEqual([st["name"] for st in starts], [f["name"]])
                    self.assertEqual(starts[0]["require_hz"], 120)
                    self.assertEqual(starts[0]["mbps"], 60)  # flat fixture colors: a capped movie, the scan is exact
                    self.assertEqual(f["steps"][-1], {"do": "video_stop", "name": f["name"], "tail": 0.4,
                                                      "title": f"the motion ends; stop the recording ({f['name']})"})
                    self.assertTrue(("speed" in f) != ("reduce" in f), f)
                self.assertEqual(films[-1]["after"], [], "the last film needs no pane back")
                last = [st for st in s["steps"] if st["do"] == "expect"][-1]
                kinds = {D.KIND[next(iter(c))] for c in last["all"]}
                self.assertEqual(kinds, {"app", "daemon", "frame"}, s["id"])
                self.assertEqual([st["do"] for st in s["finally"]], ["px_springs", "px_tunable", "px_agent_css", "settings_file"])
                self.assertEqual(s["steps"][0]["set"]["appearance"]["surfaces"]["tabBar"], {"color": "#000000", "opacity": 1})
            # cmux22 2026-11-03 (kit ae6563d7d44): the after check clicked p0's left edge (x=208, the sidebar boundary) and
            # the click did not focus; the fixture's #00FFFF ground hid the echo from text recognition. Now: focus by the
            # app (rk_focus), the fixture colors off, then the echo checked by app, daemon and frame.
            for s in specs:
                after = s["steps"][[i for i, st in enumerate(s["steps"]) if st["do"] == "px_film"][-1] + 1:]
                dos = [st["do"] for st in after]
                self.assertNotIn("use_pane", dos, s["id"])
                self.assertEqual(dos[:2], ["rk_focus", "settings_file"], s["id"])
                self.assertEqual(after[0]["pane"], "p0")
                self.assertEqual(after[1]["unset"], ["appearance.themeEdits", "appearance.surfaces"])
                self.assertEqual(dos[-1], "expect")
                # cmux22 2026-11-03 (sweep c7cef08): the echo was typed 0.28 s after the real HID Ctrl-C, before zsh had
                # redrawn its prompt; the daemon showed "J> cho rv-done-..." (the 'e' lost). The line is typed only once
                # the daemon's screen ends with the bare prompt again, and the final check is unchanged.
                i = dos.index("hid_key")
                self.assertEqual(dos[i + 1:i + 3], ["expect", "type"], s["id"])
                ready = after[i + 1]
                self.assertEqual(ready["all"], [{"daemon_prompt": True}, {"app_prompt": True}])
                self.assertEqual(ready["since"], "ctrlc")
                self.assertEqual(after[-1]["all"], [{"daemon_line": "rv-done-${nonce}"}, {"app_text_line": "rv-done-${nonce}"},
                                                    {"frame_text": "rv-done-${nonce}"}])
            # The 6-pane layout fits the 1361 x 792 pt window (cmux22: the third splitDown had no room): 3 columns of 2
            # rows by newColumn, newRow, each column's width preset, and a full-width window.
            six = next(s for s in specs if s["id"] == "px-keys-single-6-s1r")
            acts = [st.get("action") for st in six["steps"] if st["do"] in ("action", "try_action")]
            self.assertEqual(acts.count("newColumn"), 2, acts)
            self.assertEqual(acts.count("newRow"), 3, acts)
            self.assertNotIn("splitDown", acts)
            self.assertIn("column.widthOneThird", acts)
            place = next(st for st in six["steps"] if st["do"] == "window_place")
            self.assertEqual(place["fraction"], [0.0, 0.05, 1.0, 0.9])
            # An agent chat opens in its own pane (cmux22 2026-11-03, sweep c7cef08: palette.newAgentChat with no target
            # docked the chat in a new left column and left a bare terminal in its pane, so p3's splitDown split the
            # wrong column). Every agent pane: a px_agent step with its pane named, never a bare palette.newAgentChat.
            for s in specs:
                for st in s["steps"]:
                    self.assertFalse(st["do"] == "action" and st.get("action") == "palette.newAgentChat", s["id"])
            t4 = next(s for s in specs if s["id"] == "px-col-drag-4-s1r")
            agents = [st for st in t4["steps"] if st["do"] == "px_agent"]
            self.assertEqual([st["pane"] for st in agents], ["p2"])
            # T4's build: strip columns p0 | p1 | p2, and p3 a row under p2 (focused first), in a full-width window, so
            # every pane is a fixture pane and the column edge between p0 and p1 has 150 pt of room each way.
            names = [(st["do"], st.get("action") or st.get("as") or st.get("pane")) for st in t4["steps"]
                     if st["do"] in ("action", "adopt_pane", "rk_focus", "px_agent", "px_page")]
            i = names.index(("adopt_pane", "p3"))
            self.assertEqual(names[i - 2:i + 1], [("rk_focus", "p2"), ("action", "newRow"), ("adopt_pane", "p3")], names)
            self.assertEqual([a for d, a in names if d == "action" and a != "workspace.newAtBottom"], ["newColumn", "newColumn", "newRow"])
            self.assertEqual(next(st for st in t4["steps"] if st["do"] == "window_place")["fraction"], [0.0, 0.05, 1.0, 0.9])
            for jid in ("px-col-drag-4-s1r", "px-window-resize-4-s1r"):
                spec = next(s for s in specs if s["id"] == jid)
                self.assertEqual([st["pane"] for st in spec["steps"] if st["do"] == "px_agent"], ["p2"], jid)
            # The window resize is the app's own window frame, animated (ext_pixel px_window_frame): a CuaDriver drag never
            # reached the window's corner on cmux22.
            wr = next(s for s in specs if s["id"] == "px-window-resize-4-s1r")
            film_steps = [st for f in wr["steps"] if f["do"] == "px_film" for st in f["steps"]]
            self.assertFalse([st for st in film_steps if st["do"] == "hid_drag"])
            frames = [st for st in film_steps if st["do"] == "px_window_frame"]
            self.assertEqual([st["by"] for st in frames], [[-300, -150], [300, 150]] * 2)  # two films: x1 and Reduce Motion
            self.assertEqual(next(st for st in film_steps if st["do"] == "px_record_start")["input"], "window resize (window_drag)")
            s1r = {s["id"]: s for s in specs if s["id"].endswith("-s1r")}
            self.assertEqual(len(s1r), 11)
            self.assertTrue(all([n.rsplit("-", 1)[1] for n in s["recordings"]] == ["s1", "reduce"] for s in s1r.values()))
            for trio in (("px-keys-single-3k-s1r", "px-col-drag-2-s1r", "px-close-pane-3-s1r"),
                         ("px-window-resize-4-s1r", "px-row-drag-3r-s1r", "px-close-column-c3-s1r")):
                self.assertLessEqual(sum(s1r[i]["budget_seconds"] for i in trio), 260, trio)


if __name__ == "__main__":
    unittest.main(verbosity=2)
