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
import math
import os
import re
import subprocess
import sys
import tempfile
import time
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

    def __init__(self, active=True, activate=False, switches=()):
        self.active, self.can_activate, self.overrides, self.calls, self.motion = active, activate, {}, [], {}
        self.switches = set(switches)  # boolean tunables this build has (default false)
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
                # The app resets one section (`section`), one key, or `all`: only the springs here.
                if params.get("all") or params.get("section") == "springs":
                    for k in [k for k in self.overrides if k.startswith("motion.spring.") or params.get("all")]:
                        self.overrides.pop(k, None)
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
            if key in self.switches:
                if action == "set" and self.active:
                    if params.get("value") is None:
                        self.overrides.pop(key, None)
                    else:
                        self.overrides[key] = params["value"]
                return {"key": key, "value": self.overrides.get(key, False), "default": False, "changed": key in self.overrides}
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
            return {"windows": [{"id": "w1", "scale": 2.0, "main_pane": [0, 40, 1200, 760], "panes": [
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
        self.assertEqual(note["main_pane"], [0, 40, 1200, 760])  # debug.pane_chrome's main pane: the panes' visible area
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



STALL = ("video_start {name}: ScreenCaptureKit did not start: debug.motion: ScreenCaptureKit did not start the capture "
         "within 10.0 seconds")  # sweep-b08cc6f-120x2, px-new-column-c2-s025: both starts, 0.5 s apart


class FilmJourney(FakeJourney):
    """A journey that plays px_record_start as a film's sub-step (the driver installs ext steps on its journeys)."""

    def step_px_record_start(self, step):
        return X.step_px_record_start(self, step)


def recorded_film(name, speed=1.0):
    """A film as gen_pixel.py writes it: focus and wait, the recorder, the motion, the rebuild after it."""
    return {"do": "px_film", "name": name, "speed": speed,
            "steps": [{"do": "wait", "seconds": 0, "title": f"{name} settle"},
                      {"do": "px_record_start", "name": name, "seconds": 8, "require_hz": 120, "lead": 0.5,
                       "fixture": {"p0": {"kind": "tui", "fill": "#FFFF00"}}},
                      {"do": "wait", "seconds": 0, "title": f"{name} play"}],
            "after": [{"do": "wait", "seconds": 0, "title": f"{name} rebuild"}]}


class FilmNotStartedTests(unittest.TestCase):
    """A film whose recording ScreenCaptureKit does not start (sweep-b08cc6f-120x2, cmux22: 4 of 40 starts stalled at the
    app's 10 s bound; the retry 0.5 s later took in px-close-pane-3-s025 and px-col-drag-2-s1, not in
    px-new-column-c2-s025) is that film's "not run" line: before the recorder every film only focuses and waits, so its
    motion and its rebuild are skipped and the journey goes on with the next film. It was the whole journey's not run:
    px-new-column-c2 lost all six films. A second film whose recorder does not start ends the journey (not run)."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ext-pixel-ns-")
        self.clock = FakeClock()
        self.saved = (X.V.step_video_start, X.D.now, X.time)
        X.D.now, X.time = self.clock.monotonic, self.clock
        self.starts, self.stalls = [], set()

        def video_start(j, step):
            self.starts.append(step["name"])
            if step["name"] in self.stalls:
                raise D.NotRun(STALL.format(name=step["name"]))
            if step["name"] in getattr(self, "slow_display", ()):
                raise D.NotRun(f"video_start {step['name']}: the window's display runs at 16.67 ms a frame, not 120 Hz")
            j.video = {"name": step["name"], "notes": {}}
            return {"path": step["name"] + ".mov"}

        X.V.step_video_start = video_start

    def tearDown(self):
        X.V.step_video_start, X.D.now, X.time = self.saved

    def test_a_film_that_does_not_start_is_not_run_and_the_next_film_records(self):
        self.stalls = {"px-f-s025"}
        j = FilmJourney(FakeApp(), self.tmp)
        first = X.step_px_film(j, recorded_film("px-f-s025", 0.25))
        self.assertEqual(first["status"], "not run")
        self.assertIn("ScreenCaptureKit did not start", first["reason"])
        self.assertIn("after 1 earlier start(s)", first["reason"])
        self.assertEqual(self.starts, ["px-f-s025", "px-f-s025"])  # the retry ran
        self.assertEqual(j.played, ["px-f-s025 settle"])  # no motion, no rebuild: nothing of the film ran
        second = X.step_px_film(j, recorded_film("px-f-s05", 0.5))
        self.assertEqual(second["status"], "recorded")
        self.assertEqual(j.played, ["px-f-s025 settle", "px-f-s05 settle", "px-f-s05 play", "px-f-s05 rebuild"])
        self.assertEqual([(f["film"], f["status"]) for f in j.px["films"]],
                         [("px-f-s025", "not run"), ("px-f-s05", "recorded")])
        self.assertIn("ScreenCaptureKit did not start", j.px["films"][0]["reason"])

    def test_a_second_film_that_does_not_start_ends_the_journey(self):
        self.stalls = {"px-f-s025", "px-f-s1"}
        j = FilmJourney(FakeApp(), self.tmp)
        self.assertEqual(X.step_px_film(j, recorded_film("px-f-s025", 0.25))["status"], "not run")
        self.assertEqual(X.step_px_film(j, recorded_film("px-f-s05", 0.5))["status"], "recorded")
        with self.assertRaises(D.NotRun) as caught:
            X.step_px_film(j, recorded_film("px-f-s1", 1.0))
        self.assertIn("ScreenCaptureKit did not start", str(caught.exception))
        self.assertIn("2 films of this journey", str(caught.exception))

    def test_other_not_runs_still_end_the_journey(self):
        self.slow_display = {"px-f-s025"}
        j = FilmJourney(FakeApp(), self.tmp)
        with self.assertRaises(D.NotRun) as caught:
            X.step_px_film(j, recorded_film("px-f-s025", 0.25))
        self.assertIn("not 120 Hz", str(caught.exception))
        self.assertEqual(self.starts, ["px-f-s025"])


SWITCH = "motion.frameOwner.terminals"


def switch_film(name, value, speed=None, reduce=False):
    step = film(name, speed, reduce)
    step["switch"] = {"key": SWITCH, "value": value}
    return step


class SwitchFilmTests(unittest.TestCase):
    """px_film {switch: {key, value}}: the switch set (debug.tunables set) and read back before the film; a switch that
    does not take (an inactive store, a key this build does not have) makes the film "not run" with the reason, never a
    film at the default."""

    def test_switch_set_and_read_back_before_each_film(self):
        app = FakeApp(switches=[SWITCH])
        j = FakeJourney(app, tempfile.mkdtemp())
        off = X.step_px_film(j, switch_film("f-off-s1", False, speed=1.0))
        self.assertEqual(off["status"], "recorded")
        self.assertEqual(off["switch"], {"key": SWITCH, "wanted": False, "value": False, "applied": True})
        on = X.step_px_film(j, switch_film("f-on-reduce", True, reduce=True))
        self.assertEqual(on["status"], "recorded")
        self.assertIs(app.overrides[SWITCH], True)
        self.assertEqual(j.played, ["f-off-s1 play", "f-off-s1 rebuild", "f-on-reduce play", "f-on-reduce rebuild"])
        self.assertEqual(j.px["films"][-1]["switch"]["value"], True)
        # The note px_record_start writes carries the switch the film ran with.
        self.assertEqual(j.px["switch"], {"key": SWITCH, "wanted": True, "value": True, "applied": True})

    def test_unknown_switch_key_is_not_run(self):
        app = FakeApp()  # this build has no such tunable
        j = FakeJourney(app, tempfile.mkdtemp())
        out = X.step_px_film(j, switch_film("f-on-s1", True, speed=1.0))
        self.assertEqual(out["status"], "not run")
        self.assertIn(SWITCH, out["reason"])
        self.assertIn("unknown key", out["reason"])
        self.assertEqual(j.played, [])

    def test_inactive_store_switch_is_not_run(self):
        app = FakeApp(active=False, switches=[SWITCH])
        j = FakeJourney(app, tempfile.mkdtemp())
        out = X.step_px_film(j, switch_film("f-on-s1", True, speed=1.0))
        self.assertEqual(out["status"], "not run")
        self.assertIn("tunable store inactive", out["reason"])
        self.assertEqual(j.played, [])
        # OFF is the default, but a film is never taken on a switch the kit could not set: not run too.
        off = X.step_px_film(j, switch_film("f-off-s1", False, speed=1.0))
        self.assertEqual(off["status"], "not run")
        self.assertEqual(j.played, [])


class SwitchStepTests(unittest.TestCase):
    """px_switch {key, value}: a journey-level switch (the typing variants set it after the app's relaunch): set, read
    back, the result kept; a switch that does not take makes the whole round "not run" with the reason."""

    def test_sets_and_reads_back(self):
        app = FakeApp(switches=[SWITCH])
        out = X.step_px_switch(FakeJourney(app, tempfile.mkdtemp()), {"key": SWITCH, "value": True})
        self.assertEqual(out, {"key": SWITCH, "wanted": True, "value": True, "applied": True})
        self.assertIs(app.overrides[SWITCH], True)

    def test_activates_the_store_first(self):
        app = FakeApp(active=False, activate=True, switches=[SWITCH])
        out = X.step_px_switch(FakeJourney(app, tempfile.mkdtemp()), {"key": SWITCH, "value": True})
        self.assertTrue(out["applied"])
        self.assertTrue(any(m == "debug.tunables" and p.get("action") == "activate" for m, p in app.calls))

    def test_a_switch_that_does_not_take_is_not_run(self):
        for app, words in ((FakeApp(), "unknown key"), (FakeApp(active=False, switches=[SWITCH]), "tunable store inactive")):
            with self.assertRaises(D.NotRun) as caught:
                X.step_px_switch(FakeJourney(app, tempfile.mkdtemp()), {"key": SWITCH, "value": True})
            self.assertIn(SWITCH, str(caught.exception))
            self.assertIn(words, str(caught.exception))


# Sweep sweep-b08cc6f-120x2 on cmux22 (build 8e149f2e, feat b08cc6f4d398, kit 5f254a9c6b4): px_agent failed in all 4
# journeys with an agent pane. px-col-drag-4's result.json cut both texts at 300 characters; these are them, verbatim.
REAL_ROW_TEXT = ('{"attach": "live", "blank": false, "cold_keep_alive": false, "collapsed": false, "content_in_window": true, '
                 '"content_installed": true, "content_size": "434x764", "content_visible": true, "focused": true, "font_scale": 1, '
                 '"foreign_pages": 0, "frame_held": false, "grid": {"cell_height": 17, "cell_widt')
REAL_ANSWER_TEXT = ('{"action": "palette.newAgentChat", "args": {}, "created": [], "idempotency_key": null, "ran": true, "resolved": '
                    '{"id": "pane_3320ea05eb0244f6b9600af0454137f2", "key": "pane_3320ea05eb0244f6b9600af0454137f2", "kind": "pane"}, '
                    '"result": {"pane": "pane_3320ea05eb0244f6b9600af0454137f2", "tab": "tab_fa5')
REAL_PANE = "pane_3320ea05eb0244f6b9600af0454137f2"
CHAT_TAB = "tab_fa5" + "0" * 29  # the run's text stops at "tab_fa5"
TERMINAL_TAB = "tab_p2_terminal"  # after the cut: the tab the pane showed before
# The row in full, its keys sorted as the app sends them. Up to the cut, the run's; after it, the fields
# SurfaceDiagnosticsReport.make and PaneSurfaceStatus.json add for a terminal tab at b08cc6f4d398. "attach", "grid",
# "font_scale" and "frame_held" come only from a terminal tab (`case .terminal(let entry)`): the pane showed its terminal.
REAL_ROW = {"attach": "live", "blank": False, "cold_keep_alive": False, "collapsed": False, "content_in_window": True,
            "content_installed": True, "content_size": "434x764", "content_visible": True, "focused": True, "font_scale": 1,
            "foreign_pages": 0, "frame_held": False,
            "grid": {"cell_height": 17, "cell_width": 8, "frame_height": 764, "frame_width": 434, "frame_x": 852, "frame_y": 74,
                     "origin_x": 856, "origin_y": 78, "window": "win_1"},
            "kind": "terminal", "last_frame_holds": 0, "link": "connected", "local_history_mismatch": 0, "local_snapshots": 0,
            "pane": REAL_PANE, "phase": "live", "presence": "visible", "selected_tab": TERMINAL_TAB, "shown_tab": TERMINAL_TAB,
            "skipped_images": 0, "snapshots": 0, "surface": {"exists": True, "grid": "54x44", "paused": None},
            "surface_swaps": 0, "visible": True, "window_drawable": True, "window_occluded": False, "workspace": "ws_case"}
# The same pane once the chat tab is selected: TabContent.agent reports kind "agent" (PaneController+Diagnostics.swift),
# no terminal fields; its content_visible is content_installed.
AGENT_ROW = {"blank": False, "cold_keep_alive": False, "collapsed": False, "content_in_window": True, "content_installed": True,
             "content_size": "434x764", "content_visible": True, "focused": True, "foreign_pages": 0, "kind": "agent",
             "pane": REAL_PANE, "phase": "live", "presence": "visible", "selected_tab": CHAT_TAB, "shown_tab": CHAT_TAB,
             "visible": True, "window_drawable": True, "window_occluded": False, "workspace": "ws_case"}
REAL_ANSWER = {"action": "palette.newAgentChat", "args": {}, "created": [], "idempotency_key": None, "ran": True,
               "resolved": {"id": REAL_PANE, "key": REAL_PANE, "kind": "pane"},
               "result": {"pane": REAL_PANE, "tab": CHAT_TAB, "workspace": "ws_case"}}


# Sweep sweep-b08cc6f-120x2-20261103T185429Z-cmux22 (kit f813234c5a1): px_agent passed in 3 of 4 journeys; in
# px-col-drag-4 its tab.focus came 0.01 s after the open had answered the tab, and the app refused it, verbatim:
RACE_TAB = "tab_f14f791ee29dce3b389c8d923408bb50"
REAL_NOT_FOUND = ("action.run: {'code': 'not_found', 'data': {'id': 'tab_f14f791ee29dce3b389c8d923408bb50', 'kind': 'tab', "
                  "'not_run': True}, 'message': 'No tab matches tab_f14f791ee29dce3b389c8d923408bb50'}")
PENDING_TAB = "pending_tab_7d1c"  # ProvisionalTab.idPrefix: the app's stand-in for a tab the daemon does not have yet


class TargetedChatApp(FakeApp):
    """The app at b08cc6f4d398 for px_agent, its store and its control snapshot apart.

    palette.newAgentChat aimed at a pane a window shows opens the chat tab in it and leaves the selection alone
    (AgentChatPlacement.openTab(selects: shown == nil), #23085); with `selects` (a pane no window shows) the app selects
    it. Its answer names the tab from the store (AgentTabCreated.key, TabModel.id). action.run resolves a `tab:` target
    against the control snapshot (PublicIDTargetResolver over ControlTopology), the one snapshot.get prints, which lists
    the tab `lag` seconds after the open: a tab.focus before that is refused, not_found, as in the run (REAL_NOT_FOUND).
    With `pending` the snapshot lists the app's provisional stand-in (`pending_tab_`) first. tab.focus on a listed tab
    selects it (a focus action: its run may change the selection); debug.surfaces then shows it (AGENT_ROW)."""

    def __init__(self, clock, chat=CHAT_TAB, lag=0.0, selects=False, honours_focus=True, answer=None, pending=False,
                 listed=True):
        super().__init__()
        self.clock, self.chat, self.lag, self.pending, self.listed = clock, chat, lag, pending, listed
        self.selects, self.honours_focus = selects, honours_focus
        self.selected, self.opened_at, self.refused = TERMINAL_TAB, None, []
        self.answer = answer if answer is not None else dict(REAL_ANSWER, result=dict(REAL_ANSWER["result"], tab=chat))

    def topology_tabs(self):
        tabs = [{"id": TERMINAL_TAB, "kind": "terminal", "surface": "s1", "title": "zsh"}]
        if self.opened_at is not None and self.listed:
            if self.clock.t - self.opened_at >= self.lag:
                tabs.append({"id": self.chat, "kind": "conversation", "surface": "s2", "title": "New chat"})
            elif self.pending:
                tabs.append({"id": PENDING_TAB, "kind": "conversation", "surface": "s2", "title": "New chat"})
        return tabs

    def rpc(self, method, params=None, timeout=None):
        params = params or {}
        if method == "action.run" and params.get("action") == "palette.newAgentChat":
            self.calls.append((method, params))
            self.opened_at = self.clock.t
            if self.selects:
                self.selected = self.chat
            return json.loads(json.dumps(self.answer))
        if method == "action.run" and params.get("action") == "tab.focus":
            self.calls.append((method, params))
            wanted = str(params.get("target", ""))[len("tab:"):]
            if wanted not in [t["id"] for t in self.topology_tabs()]:
                self.refused.append(wanted)
                error = {"code": "not_found", "data": {"id": wanted, "kind": "tab", "not_run": True},
                         "message": f"No tab matches {wanted}"}
                raise D.StepError(f"action.run: {error}")  # App.rpc: f"{method}: {reply['error']}"
            if self.honours_focus:
                self.selected = wanted
            return {"action": "tab.focus", "args": {}, "created": [], "ran": True,
                    "resolved": {"id": wanted, "key": wanted, "kind": "tab"}}
        if method == "snapshot.get":
            self.calls.append((method, params))
            pane = {"id": REAL_PANE, "handle": "7", "selected_tab": self.selected, "tabs": self.topology_tabs(), "tab_groups": []}
            return {"sequence": 42, "topology": {"loaded": True, "workspaces": [
                {"id": "ws_case", "screens": [{"id": "screen_1", "panes": [pane]}]}]}}
        if method == "debug.surfaces":
            self.calls.append((method, params))
            row = dict(AGENT_ROW, selected_tab=self.chat, shown_tab=self.chat) if self.selected == self.chat else REAL_ROW
            return {"windows": [{"window": "1", "panes": [json.loads(json.dumps(row))]}]}
        return super().rpc(method, params, timeout)


class AgentPaneTests(unittest.TestCase):
    """px_agent: palette.newAgentChat aimed at the named pane (target pane:<id>, no focus: with focus or no target a
    script's chat goes to a new left chat dock, NewChatPlacement .newDock). The open answers its tab from the store before
    the control snapshot lists it, and action.run finds a `tab:` target only in that snapshot; so px_agent waits until
    snapshot.get lists the pane's chat tab (kind conversation, never a provisional pending_tab_ id), the answered id or
    else the one new chat tab, then selects it with tab.focus unless the pane shows it, then waits until debug.surfaces
    reports it selected and shown with kind "agent", all in one 20 s budget, and focuses the pane again.
    Sweep sweep-b08cc6f-120x2 16:19Z failed all 4 agent journeys (kind "conversation" awaited in debug.surfaces, no
    select); 18:54Z failed 1 of 4 (tab.focus 0.01 s after the open: not_found)."""

    def setUp(self):
        self.clock = FakeClock()
        self.saved = (X.D.now, X.time)
        X.D.now, X.time = self.clock.monotonic, self.clock

    def tearDown(self):
        X.D.now, X.time = self.saved

    def journey(self, app):
        j = FakeJourney(app, tempfile.mkdtemp())
        j.ext_panes["p2"] = {"pane": REAL_PANE, "term": "t-c", "host_pid": 1, "window": "w1"}
        return j

    def runs(self, app, action):
        return [p for m, p in app.calls if m == "action.run" and p.get("action") == action]

    def test_the_rows_are_the_runs(self):
        self.assertEqual(json.dumps(REAL_ROW)[:300], REAL_ROW_TEXT)
        self.assertEqual(json.dumps(REAL_ANSWER)[:300], REAL_ANSWER_TEXT)

    def test_the_refusal_is_the_runs(self):
        app = TargetedChatApp(self.clock, chat=RACE_TAB, lag=0.15)
        app.rpc("action.run", {"action": "palette.newAgentChat", "target": f"pane:{REAL_PANE}", "args": {}})
        with self.assertRaises(D.StepError) as caught:
            app.rpc("action.run", {"action": "tab.focus", "target": f"tab:{RACE_TAB}"})
        self.assertEqual(str(caught.exception), REAL_NOT_FOUND)

    def test_waits_for_the_snapshot_to_list_the_tab_before_the_select(self):
        app = TargetedChatApp(self.clock, chat=RACE_TAB, lag=0.15)
        out = X.step_px_agent(self.journey(app), {"pane": "p2", "timeout": 20})
        self.assertEqual(app.refused, [])  # no tab.focus before the snapshot listed the tab
        self.assertEqual(self.runs(app, "tab.focus"), [{"action": "tab.focus", "target": f"tab:{RACE_TAB}"}])
        self.assertEqual((out["kind"], out["tab"], out["tab_source"]), ("agent", RACE_TAB, "answer"))
        self.assertGreaterEqual(out["listed_s"], 0.15)
        self.assertEqual(app.calls[-1], ("cmux", ("pane", REAL_PANE, "focus")))
        self.assertLess(self.clock.t - 1000.0, 1.0)

    def test_selects_the_chat_tab_the_open_left_unselected(self):
        app = TargetedChatApp(self.clock)
        out = X.step_px_agent(self.journey(app), {"pane": "p2", "timeout": 20})
        self.assertEqual(self.runs(app, "palette.newAgentChat"),
                         [{"action": "palette.newAgentChat", "target": f"pane:{REAL_PANE}", "args": {}}])
        self.assertEqual(self.runs(app, "tab.focus"), [{"action": "tab.focus", "target": f"tab:{CHAT_TAB}"}])
        self.assertEqual((out["kind"], out["tab"], out["pane"]), ("agent", CHAT_TAB, REAL_PANE))
        self.assertEqual(app.calls[-1], ("cmux", ("pane", REAL_PANE, "focus")))
        self.assertLess(self.clock.t - 1000.0, 1.0)  # shown on the first read after the select: no 20 s wait

    def test_a_chat_the_app_selected_needs_no_select(self):
        app = TargetedChatApp(self.clock, selects=True)
        out = X.step_px_agent(self.journey(app), {"pane": "p2"})
        self.assertEqual((out["kind"], out["tab"]), ("agent", CHAT_TAB))
        self.assertEqual(self.runs(app, "tab.focus"), [])

    def test_a_provisional_tab_is_never_selected(self):
        app = TargetedChatApp(self.clock, chat=RACE_TAB, lag=0.35, pending=True)
        out = X.step_px_agent(self.journey(app), {"pane": "p2", "timeout": 20})
        self.assertEqual(app.refused, [])
        self.assertEqual(self.runs(app, "tab.focus"), [{"action": "tab.focus", "target": f"tab:{RACE_TAB}"}])
        self.assertEqual(out["tab"], RACE_TAB)

    def test_an_answer_without_a_tab_takes_the_new_chat_tab_the_snapshot_lists(self):
        app = TargetedChatApp(self.clock, chat=RACE_TAB, lag=0.15,
                              answer={"action": "palette.newAgentChat", "ran": True, "result": {"pane": REAL_PANE}})
        out = X.step_px_agent(self.journey(app), {"pane": "p2", "timeout": 20})
        self.assertEqual((out["tab"], out["tab_source"]), (RACE_TAB, "report"))
        self.assertEqual(self.runs(app, "tab.focus"), [{"action": "tab.focus", "target": f"tab:{RACE_TAB}"}])

    def test_an_answered_id_the_snapshot_never_lists_gives_way_to_the_new_chat_tab(self):
        # Were the answer's id a stand-in the store replaced, the new chat tab the snapshot lists is the chat.
        app = TargetedChatApp(self.clock, chat=RACE_TAB, lag=0.15,
                              answer=dict(REAL_ANSWER, result=dict(REAL_ANSWER["result"], tab="tab_stand_in")))
        out = X.step_px_agent(self.journey(app), {"pane": "p2", "timeout": 20})
        self.assertEqual((out["tab"], out["tab_source"]), (RACE_TAB, "report"))
        self.assertEqual(app.refused, [])

    def test_a_tab_the_snapshot_never_lists_fails_at_the_budget_without_a_select(self):
        app = TargetedChatApp(self.clock, chat=RACE_TAB, listed=False)
        with self.assertRaises(D.StepError) as caught:
            X.step_px_agent(self.journey(app), {"pane": "p2", "timeout": 20})
        text = str(caught.exception)
        self.assertEqual(self.runs(app, "tab.focus"), [])
        self.assertIn("snapshot.get", text)
        self.assertIn(RACE_TAB, text)  # the answered tab
        self.assertIn(TERMINAL_TAB, text)  # the tabs the pane lists
        self.assertGreaterEqual(self.clock.t - 1000.0, 20.0)
        self.assertLess(self.clock.t - 1000.0, 21.0)

    def test_a_chat_that_never_shows_fails_with_the_fields_that_matter(self):
        app = TargetedChatApp(self.clock, honours_focus=False)
        with self.assertRaises(D.StepError) as caught:
            X.step_px_agent(self.journey(app), {"pane": "p2", "timeout": 20})
        text = str(caught.exception)
        self.assertIn(CHAT_TAB, text)
        self.assertIn('"kind": "terminal"', text)
        self.assertIn(f'"selected_tab": "{TERMINAL_TAB}"', text)
        self.assertGreaterEqual(self.clock.t - 1000.0, 20.0)  # one 20 s budget for the whole step
        self.assertLess(self.clock.t - 1000.0, 21.0)


class SwitchVariantTests(unittest.TestCase):
    """gen_pixel.py --switch KEY: each case filmed with the switch OFF and ON at x1 and under Reduce Motion (4 films), in
    journeys named <case>-sw-<short> (split by budget, -a/-b), the switch reset in finally."""

    S4 = ("px-col-drag-2", "px-row-drag-3r", "px-keys-single-3k", "px-new-column-c2", "px-close-column-c3")

    def generate(self, out, *extra):
        args = [sys.executable, str(HERE / "video-cases" / "gen_pixel.py"), "--out", out, "--switch", SWITCH]
        for case in self.S4:
            args += ["--only", case]
        done = subprocess.run(args + list(extra), capture_output=True, text=True, timeout=120)
        self.assertEqual(done.returncode, 0, done.stderr)
        return [json.loads(p.read_text()) for p in sorted(Path(out).glob("*.json"))]

    def test_variants(self):
        import run as R
        with tempfile.TemporaryDirectory() as out:
            specs = self.generate(out)
            self.assertTrue(specs)
            self.assertTrue(all("-sw-terminals" in s["id"] for s in specs), [s["id"] for s in specs])
            self.assertEqual({s["id"]: R.validate(s) for s in specs}, {s["id"]: [] for s in specs})
            per_case = {}
            for s in specs:
                self.assertLessEqual(s["budget_seconds"], 250, s["id"])
                for f in [st for st in s["steps"] if st["do"] == "px_film"]:
                    # A film name is <case>-sw-terminals[-a|-b|-c]-<off|on>-<s1|reduce>.
                    m = re.fullmatch(r"(px-[a-z0-9-]+?)-sw-terminals(?:-[abc])?-(off|on)-(s1|reduce)", f["name"])
                    self.assertTrue(m, f["name"])
                    case, state, speed = m.groups()
                    self.assertEqual(f["switch"], {"key": SWITCH, "value": state == "on"}, f["name"])
                    self.assertEqual(f.get("speed") if speed == "s1" else f.get("reduce"), 1.0 if speed == "s1" else True, f["name"])
                    per_case.setdefault(case, []).append(f"{state}-{speed}")
                self.assertEqual(s["finally"][0], {"do": "px_tunable", "key": SWITCH, "value": None,
                                                   "title": f"clean-up: {SWITCH} back to its default"})
                last = [st for st in s["steps"] if st["do"] == "expect"][-1]
                self.assertEqual({D.KIND[next(iter(c))] for c in last["all"]}, {"app", "daemon", "frame"})
            # Every case: off-s1, on-s1, off-reduce, on-reduce, in that order.
            self.assertEqual(sorted(per_case), sorted(self.S4))
            for case, labels in per_case.items():
                self.assertEqual(labels, ["off-s1", "on-s1", "off-reduce", "on-reduce"], case)
            # 5 cases x 4 films: each case one journey of 4 films, split -a/-b only when one lease cannot hold it.
            names = [n for s in specs for n in s["recordings"]]
            self.assertEqual(len(names), 20)
            self.assertEqual(len(names), len(set(names)))

    def test_a_plain_run_keeps_the_switch_journeys(self):
        """A regeneration without --switch never deletes switch journeys an earlier --switch run wrote."""
        with tempfile.TemporaryDirectory() as out:
            specs = self.generate(out)
            done = subprocess.run([sys.executable, str(HERE / "video-cases" / "gen_pixel.py"), "--out", out],
                                  capture_output=True, text=True, timeout=120)
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertEqual(sorted(p.name for p in Path(out).glob("*-sw-*.json")), sorted(s["id"] + ".json" for s in specs))

    def test_without_switch_no_variants(self):
        with tempfile.TemporaryDirectory() as out:
            done = subprocess.run([sys.executable, str(HERE / "video-cases" / "gen_pixel.py"), "--out", out, "--only", "px-col-drag-2"],
                                  capture_output=True, text=True, timeout=120)
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertFalse([p.name for p in Path(out).glob("*-sw-*.json")])


class TypingSwitchVariantTests(unittest.TestCase):
    """typing/gen_load.py --switch KEY: typing-load-l6-sw-<short>, typing-load-l6 with the switch set (and read back) right
    after the relaunch's smoke_ready, every other step and option the same; the switch reset first in finally."""

    def generate(self, out, key=SWITCH):
        done = subprocess.run([sys.executable, str(HERE / "typing" / "gen_load.py"), "--out", out, "--switch", key],
                              capture_output=True, text=True, timeout=120)
        self.assertEqual(done.returncode, 0, done.stderr)
        return [json.loads(p.read_text()) for p in sorted(Path(out).glob("*.json"))]

    def test_variant(self):
        import run as R
        base = json.loads((HERE / "journeys" / "video" / "typing-load-l6.json").read_text())
        with tempfile.TemporaryDirectory() as out:
            specs = self.generate(out)
            self.assertEqual([s["id"] for s in specs], ["typing-load-l6-sw-terminals"])
            v = specs[0]
            self.assertEqual(R.validate(v), [])
            i = next(n for n, st in enumerate(v["steps"]) if st["do"] == "probe_relaunch")
            self.assertEqual(v["steps"][i + 1], {"do": "smoke_ready", "timeout": 60})
            self.assertEqual(v["steps"][i + 2], {"do": "px_switch", "key": SWITCH, "value": True,
                                                 "title": f"set-up: {SWITCH} ON (after the relaunch: a bench build keeps tunables in memory only)"})
            # Every other step the same as typing-load-l6, in order; the same options and budget.
            self.assertEqual(v["steps"][:i + 2] + v["steps"][i + 3:], base["steps"])
            for key in ("budget_seconds", "options", "continue_not_judged", "source"):
                self.assertEqual(v.get(key), base.get(key), key)
            # P1, not P0: dogfood-gate.py needs a pass of every P0 journey on a build, and a stage switch exists only on its
            # own stage builds. A P0 variant would refuse every other dogfood build. run.py --journey picks it either way.
            self.assertEqual(base["priority"], "P0")
            self.assertEqual(v["priority"], "P1")
            self.assertEqual(v["finally"], [{"do": "px_tunable", "key": SWITCH, "value": None,
                                             "title": f"clean-up: {SWITCH} back to its default"}] + base["finally"])
            # The films keep typing-load-l6's names (the ledger and the judges read the parts by label).
            self.assertEqual([st.get("label") for st in v["steps"] if st["do"] == "typist_play"],
                             [st.get("label") for st in base["steps"] if st["do"] == "typist_play"])
            self.assertIn(SWITCH, v["title"])

    def test_other_stage_switches(self):
        with tempfile.TemporaryDirectory() as out:
            self.assertEqual([s["id"] for s in self.generate(out, "motion.frameOwner.timing")], ["typing-load-l6-sw-timing"])
        with tempfile.TemporaryDirectory() as out:
            self.assertEqual([s["id"] for s in self.generate(out, "motion.frameOwner.contentPolicy")],
                             ["typing-load-l6-sw-contentpolicy"])

    def test_off_variant(self):
        """--off: typing-load-l6-sw-<short>-off, the same journey with the switch set to false (and read back) the same way:
        an A/B of the same app state in one build (the refactor owner's local typing-load-l6-sw-contentpolicy-off)."""
        key = "motion.frameOwner.contentPolicy"
        with tempfile.TemporaryDirectory() as on_dir, tempfile.TemporaryDirectory() as off_dir:
            on = self.generate(on_dir, key)[0]
            done = subprocess.run([sys.executable, str(HERE / "typing" / "gen_load.py"), "--out", off_dir, "--switch", key, "--off"],
                                  capture_output=True, text=True, timeout=120)
            self.assertEqual(done.returncode, 0, done.stderr)
            specs = [json.loads(p.read_text()) for p in sorted(Path(off_dir).glob("*.json"))]
        self.assertEqual([s["id"] for s in specs], ["typing-load-l6-sw-contentpolicy-off"])
        off = specs[0]
        import run as R
        self.assertEqual(R.validate(off), [])
        i = next(n for n, st in enumerate(off["steps"]) if st["do"] == "px_switch")
        self.assertEqual(off["steps"][i], {"do": "px_switch", "key": key, "value": False,
                                           "title": f"set-up: {key} OFF (after the relaunch: a bench build keeps tunables in memory only)"})
        self.assertEqual(off["steps"][:i] + off["steps"][i + 1:], on["steps"][:i] + on["steps"][i + 1:])
        self.assertEqual((off["priority"], off["finally"]), (on["priority"], on["finally"]))
        self.assertTrue(off["title"].endswith(f"with {key} OFF"), off["title"])
        self.assertEqual(json.loads((HERE / "journeys" / "video" / "typing-load-l6-sw-contentpolicy-off.json").read_text()), off)

    def test_plain_generation_unchanged(self):
        done = subprocess.run([sys.executable, str(HERE / "typing" / "gen_load.py"), "--check"], capture_output=True, text=True,
                              timeout=120)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)


HANGS_READ = {"do": "rpc", "method": "debug.hangs", "params": {"limit": 64},
              "title": "after the typing: the watchdog's main-thread stalls over its threshold, each with its sampled stack "
                       "(finds a key stall such as the Ctrl-C one; reads only)"}


class TypingHangsReadTests(unittest.TestCase):
    """typing/gen_load.py: every typing round reads debug.hangs {limit: 64} once, after the measured keys (the probe's
    `after` mark, before load_stop), so each round carries the watchdog's main-thread stalls with their stacks. A read
    only: it is after the last typist_play and the last video_stop, so no measured key or film sees it. Every profile and
    film choice, and the switch variants (generated from typing-load-l6)."""

    def specs(self):
        return [json.loads(p.read_text()) for p in sorted((HERE / "journeys" / "video").glob("typing-load-l[0-9]*.json"))]

    def check(self, spec):
        dos = [st["do"] for st in spec["steps"]]
        reads = [i for i, st in enumerate(spec["steps"]) if st.get("method") == "debug.hangs"]
        self.assertEqual(len(reads), 1, spec["id"])
        i = reads[0]
        self.assertEqual(spec["steps"][i], HANGS_READ, spec["id"])
        self.assertEqual(spec["steps"][i - 1], {"do": "probe_mark", "as": "after"}, spec["id"])
        last_key = max(n for n, d in enumerate(dos) if d in ("typist_play", "video_stop"))
        self.assertGreater(i, last_key, spec["id"])
        if "load_stop" in dos:
            self.assertEqual(dos[i + 1], "load_stop", spec["id"])

    def test_every_typing_round_reads_the_hangs_after_the_keys(self):
        specs = self.specs()
        self.assertGreaterEqual(len(specs), 14)
        for spec in specs:
            self.check(spec)

    def test_the_switch_variants_read_them_too(self):
        with tempfile.TemporaryDirectory() as out:
            done = subprocess.run([sys.executable, str(HERE / "typing" / "gen_load.py"), "--out", out, "--switch",
                                   "motion.frameOwner.timing"], capture_output=True, text=True, timeout=120)
            self.assertEqual(done.returncode, 0, done.stderr)
            for path in Path(out).glob("*.json"):
                self.check(json.loads(path.read_text()))


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
            # s0125: the terminal-only S2b cases (x0.125, the slowest speed every spring takes: a response is clamped to 2 s).
            self.assertEqual(labels, {"s0125", "s025", "s05", "s1", "s2", "s4", "reduce"})
            self.assertEqual(sorted(s["id"] for s in specs if any(n.endswith("-s0125") for n in s["recordings"])),
                             ["px-keys-then-clamp-2x", "px-keys-then-clamp-chase-2x", "px-keys-then-drag-3t", "px-keys-then-split-drag-2st"])
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
                fixture = [st["key"] for st in s["finally"][:-4]]  # a case's fixture tunables (the tab outline) go back first
                self.assertEqual([st["do"] for st in s["finally"]], ["px_tunable"] * len(fixture) + STANDARD_FINALLY, s["id"])
                self.assertTrue(all(st["value"] is None for st in s["finally"][:-4]), s["id"])
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
                self.assertEqual(after[1]["unset"], ["appearance.themeEdits", "appearance.surfaces", "sidebar.hoverCards"])
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
            self.assertFalse([s["id"] for s in specs if "-sw-" in s["id"]], "switch variants only with --switch")
            s1r = {s["id"]: s for s in specs if s["id"].endswith("-s1r")}
            # one per case (px-keys-held-2-tabclose the 12th, px-close-pane-3t the 13th, px-keys-held-2-tabclose-narrow the 14th,
            # px-keys-rk-3t the 15th, px-keys-held-2-dt and px-col-drag-2-dt the 16th and 17th: S5 m16 item 5, docked DevTools;
            # px-keys-single-2w, px-keys-held-2w and px-col-drag-2w the 18th to 20th: cmux-ad m18, the text re-wrap fixture)
            self.assertEqual(len(s1r), 20)
            # cmux-ad m18: the wrap cases' two panes are normal-screen shells that print wrapped solid-color lines (never the
            # alternate-screen border fixture, which Ghostty does not re-wrap), filmed with five scan rows per pane.
            for jid in ("px-keys-single-2w-s1r", "px-keys-held-2w-s1r", "px-col-drag-2w-s1r"):
                typed = [st["text"] for st in s1r[jid]["steps"] if st["do"] == "type" and "COLUMNS * 2 + 5" in st.get("text", "")]
                self.assertEqual(len(typed), 2, jid)
                self.assertFalse([st for st in s1r[jid]["steps"] if st["do"] == "type" and "jr-tui-border" in st.get("text", "")], jid)
                starts = [st for f in s1r[jid]["steps"] if f["do"] == "px_film" for st in f["steps"] if st["do"] == "px_record_start"]
                self.assertEqual([st["lines_per_pane"] for st in starts], [[0.15, 0.3, 0.45, 0.6, 0.75]] * 2, jid)
                self.assertEqual({v["kind"] for v in starts[0]["fixture"].values()}, {"wrap"}, jid)
            narrow = [st for f in s1r["px-keys-held-2-tabclose-narrow-s1r"]["steps"] if f["do"] == "px_film" for st in f["steps"]]
            shrink = [st for st in narrow if st["do"] == "rk_press" and st["key"] == "h" and st.get("count") == 30]
            self.assertEqual(len(shrink), 4)  # per film: the 30 x Ctrl-Shift-H set-up and the play's own burst, 2 films
            # The split tree is binary: every film of a close case closes the same split, so the pane comes back the way the
            # layout made it. px-close-pane-3: p1 nested with p2 (splitLeft on p2); px-close-pane-3t (S3d case (a)): p1
            # nested with p0 (p2 made first, then splitRight on p0), and back by splitRight on p0.
            def set_up(spec):
                return [(st["do"], st.get("pane") or st.get("action") or st.get("as")) for st in spec["steps"]
                        if st["do"] in ("rk_focus", "action", "adopt_pane")]

            def rebuild(spec):
                film = next(f for f in spec["steps"] if f["do"] == "px_film")
                return [(st["do"], st.get("pane") or st.get("action") or st.get("as")) for st in film.get("after", [])
                        if st["do"] in ("rk_focus", "action", "adopt_pane")]
            self.assertEqual(rebuild(s1r["px-close-pane-3-s1r"]), [("rk_focus", "p2"), ("action", "splitLeft"), ("adopt_pane", "p1")])
            self.assertEqual(rebuild(s1r["px-close-pane-3t-s1r"]), [("rk_focus", "p0"), ("action", "splitRight"), ("adopt_pane", "p1")])
            # Every held-keys film starts with p0 at half the pane area (a held film ends with p0 at its minimum width).
            for jid in ("px-keys-held-2-s1r", "px-keys-held-2-tabclose-s1r"):
                for film in (f for f in s1r[jid]["steps"] if f["do"] == "px_film"):
                    dos = [(st["do"], st.get("action")) for st in film["steps"]]
                    self.assertLess([d for d, _ in dos].index("px_equalize"), [d for d, _ in dos].index("px_record_start"), (jid, film["name"]))
            made = [x for x in set_up(s1r["px-close-pane-3t-s1r"]) if x[0] != "rk_focus" or x[1] == "p0"]
            self.assertLess(made.index(("adopt_pane", "p2")), made.index(("adopt_pane", "p1")))
            self.assertEqual(made[made.index(("adopt_pane", "p1")) - 2:made.index(("adopt_pane", "p1")) + 1],
                             [("rk_focus", "p0"), ("action", "splitRight"), ("adopt_pane", "p1")])
            self.assertTrue(all([n.rsplit("-", 1)[1] for n in s["recordings"]] == ["s1", "reduce"] for s in s1r.values()))
            for trio in (("px-keys-single-3k-s1r", "px-col-drag-2-s1r", "px-close-pane-3-s1r"),
                         ("px-window-resize-4-s1r", "px-row-drag-3r-s1r", "px-close-column-c3-s1r")):
                self.assertLessEqual(sum(s1r[i]["budget_seconds"] for i in trio), 260, trio)



class KeepTests(unittest.TestCase):
    """px_film `keep`: a sub-step's whole reply goes to <out>/<film>.<keep>.json (a long array is never cut at RESULT_CHARS),
    result.json keeps the file name, and run.py's RESULT_FILE takes that file back from the capture host."""

    def test_a_kept_reply_is_whole_in_its_file_and_named_in_the_line(self):
        class J(FakeJourney):
            def step_rpc(self, step):
                return {"reply": {"intervals_ms": [8.33] * 2000}}
        j = J(FakeApp(), tempfile.mkdtemp())
        j.out.mkdir(parents=True, exist_ok=True)
        f = film("f-s1", 1.0)
        f["steps"] = [{"do": "rpc", "method": "debug.frames", "params": {"action": "stop", "raw": True}, "keep": "frames"}] + f["steps"]
        X.step_px_film(j, f)
        kept = j.out / "f-s1.frames.json"
        self.assertEqual(len(json.loads(kept.read_text())["reply"]["intervals_ms"]), 2000)
        line = next(st for st in j.px["films"][-1].get("steps", []) if st.get("do") == "rpc") if j.px["films"][-1].get("steps") else None
        import run as R
        self.assertTrue(R.RESULT_FILE.fullmatch("px-a-wp/f-s1.frames.json".replace("f-s1", "px-a-s1")))
        self.assertIsNone(R.RESULT_FILE.fullmatch("px-a-wp/other.json"))


class EqualizeApp:
    """action.run equalizeSplits: answers, or times out (as on feat 8dea72b7d62f) or fails otherwise; debug.pane_chrome
    gives p0 and p1 cells whose widths become `after` once the action ran (a spring landing over `polls` reads)."""

    def __init__(self, before, after, error=None, polls=2):
        self.widths, self.after, self.error, self.polls, self.calls, self.ran = list(before), list(after), error, polls, [], False

    def rpc(self, method, params=None, timeout=None):
        self.calls.append(method)
        if method == "action.run":
            self.ran = True
            if self.error:
                raise D.StepError(self.error)
            return {"action": "equalizeSplits", "ran": True, "waited": True}
        if method == "debug.pane_chrome":
            if self.ran:
                self.polls -= 1
                if self.polls <= 0:
                    self.widths = list(self.after)
            return {"windows": [{"panes": [{"pane": "pane-a", "cell": [208, 0, self.widths[0], 792]},
                                           {"pane": "pane-b", "cell": [208 + self.widths[0], 0, self.widths[1], 792]}]}]}
        raise AssertionError(method)


class EqualizeTests(unittest.TestCase):
    TIMEOUT = ("action.run: {'code': 'timeout', 'data': {'deadline_ms': 1999, 'method': 'action.run', 'state': 'in_progress', "
               "'waiting_on': ['handler@0', 'daemon done@7', 'snapshot@7']}, 'message': 'action.run did not finish within 1999 ms'}")

    def run_step(self, app, **step):
        return X.step_px_equalize(FakeJourney(app, tempfile.mkdtemp()), dict({"panes": ["p0", "p1"]}, **step))

    def test_the_action_equalizes_and_the_widths_are_read_back(self):
        out = self.run_step(EqualizeApp([200, 952], [576, 576.5]))
        self.assertEqual(out["widths"], {"p0": 576, "p1": 576.5})
        self.assertNotIn("action_timeout", out)

    def test_a_timeout_whose_work_finished_does_not_fail_the_film_and_is_recorded(self):
        out = self.run_step(EqualizeApp([576, 576], [576, 576], error=self.TIMEOUT))
        self.assertIn("did not finish within 1999 ms", out["action_timeout"])
        self.assertEqual(out["widths"], {"p0": 576, "p1": 576})

    def test_widths_still_unequal_fail_the_step(self):
        with self.assertRaises(D.StepError) as caught:
            self.run_step(EqualizeApp([200, 952], [200, 952], error=self.TIMEOUT), timeout=0.2)
        self.assertIn("not equal", str(caught.exception))

    def test_another_action_error_is_not_swallowed(self):
        with self.assertRaises(D.StepError) as caught:
            self.run_step(EqualizeApp([576, 576], [576, 576], error="action.run: equalizeSplits refused: the screen has no splits"))
        self.assertIn("refused", str(caught.exception))


# -- px-keys-held-2-tabclose (stage S1B 1b, frame-owner-s1b) --------------------------------------------------------------
TAB_OUTLINE = "motion.frameOwner.tabOutline"  # TabFrameFixture: a 1 device-px #FFFF00 border on every tab cell (#33874)
STANDARD_FINALLY = ["px_springs", "px_tunable", "px_agent_css", "settings_file"]


def gen(*args):
    done = subprocess.run([sys.executable, str(HERE / "video-cases" / "gen_pixel.py"), *args], capture_output=True, text=True,
                          timeout=120)
    if done.returncode != 0:
        raise AssertionError(done.stderr)
    return done.stdout


class TabPaneApp(FakeApp):
    """p0 (pane-a) with terminal tabs, its control snapshot (snapshot.get) and the pane it shows (debug.surfaces) apart.
    newSurface (a tab target, the run's focus) adds a terminal tab that the snapshot lists `lag` s later, selected when
    `selects`; tab.focus selects a listed tab (not_found before); closeTab removes a listed tab (refused with
    `refuse_close`; with `keeps` the snapshot keeps listing it). `now`: the clock of the lag and of the close times."""

    def __init__(self, now, tabs=("t1",), lag=0.0, selects=True, refuse_close=False, keeps=False):
        super().__init__(switches=[TAB_OUTLINE])
        self.now, self.lag, self.selects, self.refuse_close, self.keeps = now, lag, selects, refuse_close, keeps
        self.tabs = [{"id": t, "kind": "terminal", "terminal": f"term-{t}", "listed_at": -1e9} for t in tabs]
        self.selected = self.tabs[-1]["id"]
        self.closes, self.made = [], 0

    def listed(self):
        return [t for t in self.tabs if t["listed_at"] <= self.now()]

    def rpc(self, method, params=None, timeout=None):
        params = params or {}
        if method == "snapshot.get":
            self.calls.append((method, params))
            tabs = [{k: t[k] for k in ("id", "kind", "terminal")} for t in self.listed()]
            pane = {"id": "pane-a", "handle": "1", "selected_tab": self.selected, "tabs": tabs, "tab_groups": []}
            other = {"id": "pane-b", "handle": "2", "selected_tab": "tab-b", "tabs": [{"id": "tab-b", "kind": "browser"}]}
            return {"topology": {"loaded": True, "workspaces": [{"id": "ws", "screens": [{"id": "s", "panes": [pane, other]}]}]}}
        if method == "action.run" and params.get("action") in ("newSurface", "tab.focus", "closeTab"):
            self.calls.append((method, params))
            wanted = str(params.get("target", ""))[len("tab:"):]
            if wanted not in [t["id"] for t in self.listed()]:
                raise D.StepError(f"action.run: {{'code': 'not_found', 'message': 'No tab matches {wanted}'}}")
            if params["action"] == "newSurface":
                self.made += 1
                tab = {"id": f"tnew{self.made}", "kind": "terminal", "terminal": f"term-tnew{self.made}",
                       "listed_at": self.now() + self.lag}
                self.tabs.append(tab)
                if self.selects:
                    self.selected = tab["id"]
                return {"action": "newSurface", "ran": True, "created": []}
            if params["action"] == "tab.focus":
                self.selected = wanted
                return {"action": "tab.focus", "ran": True}
            self.closes.append((self.now(), params["target"]))
            if self.refuse_close:
                raise D.StepError("action.run: {'code': 'unavailable', 'message': 'closeTab unavailable: busy'}")
            if not self.keeps:
                self.tabs = [t for t in self.tabs if t["id"] != wanted]
            return {"action": "closeTab", "ran": True}
        if method == "debug.surfaces":
            self.calls.append((method, params))
            shown = self.selected if any(t["id"] == self.selected for t in self.listed()) else None
            return {"windows": [{"window": 1, "panes": [
                {"pane": "pane-a", "focused": True, "kind": "terminal", "selected_tab": shown, "shown_tab": shown, "host_pid": 77},
                {"pane": "pane-b", "focused": False, "kind": "browser", "selected_tab": "tab-b", "shown_tab": "tab-b"}]}]}
        return super().rpc(method, params, timeout)

    def screen(self, term):
        return {"text": "J> "}


class RequiredTunableTests(unittest.TestCase):
    """px_tunable `required`: a fixture tunable a case cannot film without (the tab outline) that does not take makes the
    journey "not run" with the reason; without `required` it is only recorded, as before (the page backdrop)."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ext-pixel-req-")

    def test_a_required_tunable_that_does_not_take_is_not_run(self):
        j = FakeJourney(FakeApp(), self.tmp)  # a build without the outline: "debug.tunables: unknown key"
        with self.assertRaises(D.NotRun) as caught:
            X.step_px_tunable(j, {"key": TAB_OUTLINE, "value": True, "required": True})
        self.assertIn(TAB_OUTLINE, str(caught.exception))
        self.assertIn("unknown key", str(caught.exception))

    def test_a_required_tunable_that_takes(self):
        j = FakeJourney(FakeApp(switches=[TAB_OUTLINE]), self.tmp)
        self.assertTrue(X.step_px_tunable(j, {"key": TAB_OUTLINE, "value": True, "required": True})["applied"])

    def test_without_required_it_is_recorded_only(self):
        j = FakeJourney(FakeApp(), self.tmp)
        rec = X.step_px_tunable(j, {"key": TAB_OUTLINE, "value": True})
        self.assertFalse(rec["applied"])
        self.assertEqual(j.px["tunables"][TAB_OUTLINE], rec)


class TabNewTests(unittest.TestCase):
    """px_tab_new: a new terminal tab in the named pane (newSurface aimed at the pane's selected tab, with the run's focus),
    found in snapshot.get (the snapshot action.run resolves targets against), selected (tab.focus unless the pane shows
    it), shown by debug.surfaces, its shell drawn; then it is the journey's terminal and the pane's named terminal, so
    rk_focus, neutral_prompt, the fixture's expect and the after check read the tab the pane shows."""

    def setUp(self):
        self.clock = FakeClock()
        self.saved = (X.D.now, X.time)
        X.D.now, X.time = self.clock.monotonic, self.clock

    def tearDown(self):
        X.D.now, X.time = self.saved

    def run_step(self, app, **step):
        j = FakeJourney(app, tempfile.mkdtemp())
        return j, X.step_px_tab_new(j, dict({"pane": "p0"}, **step))

    def runs(self, app, action):
        return [p for m, p in app.calls if m == "action.run" and p.get("action") == action]

    def test_the_new_tab_is_selected_and_adopted(self):
        app = TabPaneApp(self.clock.monotonic, lag=0.3)
        j, out = self.run_step(app)
        self.assertEqual(self.runs(app, "newSurface"), [{"action": "newSurface", "target": "tab:t1", "focus": True}])
        self.assertEqual(self.runs(app, "tab.focus"), [])
        self.assertEqual((out["tab"], out["terminal"]), ("tnew1", "term-tnew1"))
        self.assertEqual((j.pane, j.term, j.host_pid), ("pane-a", "term-tnew1", 77))
        self.assertEqual(j.ext_panes["p0"]["term"], "term-tnew1")
        self.assertEqual(out["tabs"], ["t1", "tnew1"])

    def test_a_tab_the_app_did_not_select_is_selected_once_listed(self):
        app = TabPaneApp(self.clock.monotonic, lag=0.3, selects=False)
        j, out = self.run_step(app)
        self.assertEqual(self.runs(app, "tab.focus"), [{"action": "tab.focus", "target": "tab:tnew1"}])
        self.assertEqual(j.term, "term-tnew1")

    def test_a_tab_never_listed_fails_without_a_select(self):
        app = TabPaneApp(self.clock.monotonic, lag=1e9)
        with self.assertRaises(D.StepError) as caught:
            self.run_step(app, timeout=20)
        self.assertEqual(self.runs(app, "tab.focus"), [])
        self.assertIn("p0", str(caught.exception))
        self.assertGreaterEqual(self.clock.t - 1000.0, 20.0)


class FakeHoldJourney(FakeJourney):
    """The hold as ext_rkeys rk_hold plays it (ext_spam hold_key): the first key-down at `start_at` (the app's clock),
    then the held key until `seconds` later."""

    def __init__(self, app, config_dir):
        super().__init__(app, config_dir)
        self.holds = []
        self.video = {"notes": {"pixel": {}}, "hid": []}

    def before_keys(self):
        return None

    def step_rk_hold(self, step):
        self.holds.append(dict(step, called_at=X.S.uptime()))
        time.sleep(max(0.0, float(step["start_at"]) + float(step.get("seconds", 1.5)) - X.S.uptime()))
        return {"sent": 10, "ran": 10}


class TabCloseHoldTests(unittest.TestCase):
    """px_hold_tab_close: the held key (rk_hold) with its first key-down at a time the step fixes, and on its own thread
    a script's closeTab of the pane's middle tab (from snapshot.get) AFTER_MS after that key-down. The film's pixel note
    gets `tab_close`: which tab, its index, the tabs before and after, the first key-down and the close's send and
    return times on the host clock (the trace's t0_s and the scan's frame times), so the judge finds the first frame
    after the close."""

    def setUp(self):
        self.saved = X.S.uptime
        X.S.uptime = time.monotonic  # CLOCK_UPTIME_RAW on the minis; this VM has no such clock

    def tearDown(self):
        X.S.uptime = self.saved

    def step(self, **close):
        return {"do": "px_hold_tab_close", "key": "l", "modifiers": ["control", "shift"], "seconds": 0.3, "mark": "hold",
                "close": dict({"pane": "p0", "which": "middle", "after_ms": 50}, **close), "timeout": 2}

    def test_closes_the_middle_tab_50_ms_after_the_first_key_down(self):
        app = TabPaneApp(time.monotonic, tabs=("t1", "t2", "t3"))
        j = FakeHoldJourney(app, tempfile.mkdtemp())
        out = X.step_px_hold_tab_close(j, self.step())
        self.assertEqual(len(j.holds), 1)
        hold = j.holds[0]
        self.assertEqual((hold["key"], hold["modifiers"], hold["seconds"], hold["mark"]), ("l", ["control", "shift"], 0.3, "hold"))
        self.assertGreater(hold["start_at"], hold["called_at"])  # the first key-down is ahead of the hold's own start
        self.assertEqual([t for _, t in app.closes], ["tab:t2"])
        note = j.video["notes"]["pixel"]["tab_close"]
        self.assertEqual((note["tab"], note["index"], note["pane"], note["label"]), ("t2", 1, "pane-a", "p0"))
        self.assertEqual((note["tabs_before"], note["tabs_after"]), (["t1", "t2", "t3"], ["t1", "t3"]))
        self.assertEqual(note["first_key_host"], hold["start_at"])
        self.assertEqual(note["planned_after_ms"], 50)
        self.assertAlmostEqual(note["t_sent_host"] - hold["start_at"], 0.05, delta=0.03)
        self.assertAlmostEqual(app.closes[0][0], note["t_sent_host"], delta=0.02)
        self.assertGreaterEqual(note["t_returned_host"], note["t_sent_host"])
        self.assertAlmostEqual(note["after_ms"], 50, delta=30)
        self.assertEqual([h["kind"] for h in j.video["hid"]], ["tab_close"])
        self.assertEqual(out["tab_close"]["tab"], "t2")

    def test_a_pane_with_fewer_than_three_tabs_fails_before_any_key(self):
        app = TabPaneApp(time.monotonic, tabs=("t1", "t2"))
        j = FakeHoldJourney(app, tempfile.mkdtemp())
        with self.assertRaises(D.StepError) as caught:
            X.step_px_hold_tab_close(j, self.step())
        self.assertIn("2 tab", str(caught.exception))
        self.assertEqual((j.holds, app.closes), ([], []))

    def test_a_refused_close_fails_after_the_hold(self):
        app = TabPaneApp(time.monotonic, tabs=("t1", "t2", "t3"), refuse_close=True)
        j = FakeHoldJourney(app, tempfile.mkdtemp())
        with self.assertRaises(D.StepError) as caught:
            X.step_px_hold_tab_close(j, self.step())
        self.assertIn("closeTab unavailable", str(caught.exception))
        self.assertEqual(len(j.holds), 1)
        self.assertIn("error", j.video["notes"]["pixel"]["tab_close"])

    def test_a_close_the_snapshot_never_shows_fails(self):
        app = TabPaneApp(time.monotonic, tabs=("t1", "t2", "t3"), keeps=True)
        j = FakeHoldJourney(app, tempfile.mkdtemp())
        with self.assertRaises(D.StepError) as caught:
            X.step_px_hold_tab_close(j, self.step())
        self.assertIn("t2", str(caught.exception))


class HoldStartAtTests(unittest.TestCase):
    """ext_spam hold_key `start_at`: the first key-down at that time (the app's clock), so another thread can act a fixed
    time after it; without it the hold starts 50 ms after the step, as before."""

    class J:
        def __init__(self, app):
            self.app, self.marks, self.key_window = app, {}, "w1"

        def before_keys(self):
            return None

        def window_for(self, ref):
            return None

    def schedule(self, **step):
        import ext_spam as S
        captured = {}

        def play(j, key, modifiers, schedule, window):
            captured["schedule"] = schedule
            return [], []

        saved = (S._play, S.counts, S.uptime)
        S._play, S.counts, S.uptime = play, (lambda j, cache=None: {}), time.monotonic
        try:
            before = time.monotonic()
            S.step_hold_key(self.J(FakeApp()), dict({"key": "l", "modifiers": ["control", "shift"], "seconds": 0.1, "as": "hold"}, **step))
        finally:
            S._play, S.counts, S.uptime = saved
        return before, captured["schedule"]

    def test_the_first_key_down_is_start_at(self):
        at = time.monotonic() + 0.08
        _, schedule = self.schedule(start_at=at)
        self.assertEqual(schedule[0], (at, False))
        self.assertTrue(all(t > at and repeat for t, repeat in schedule[1:]))

    def test_without_start_at_the_hold_starts_50_ms_after_the_step(self):
        before, schedule = self.schedule()
        self.assertAlmostEqual(schedule[0][0] - before, 0.05, delta=0.02)


class TabCloseCaseTests(unittest.TestCase):
    """gen_pixel.py px-keys-held-2-tabclose (stage S1B 1b): px-keys-held-2's panes (p0 terminal | p1 page) with p0 in 3
    terminal tabs, each the TUI fixture, and every tab outlined (motion.frameOwner.tabOutline, required, set again in
    each film after the speed: the outline is in the springs section, which the Reduce Motion film resets). Each film: the
    held Ctrl-Shift-L with p0's middle tab closed 50 ms after its first key-down, then Ctrl-Shift-H x30; after each film
    but the last, one tab back in p0 with the fixture. p0's fill is not the outline's #FFFF00."""

    CID = "px-keys-held-2-tabclose"
    # rk_focus, equalizeSplits and its settle: every held film starts with p0 at half the pane area (gen_pixel held_start).
    FILM = ["rk_focus", "px_equalize", "wait", "px_tunable", "wait", "px_record_start", "px_hold_tab_close", "wait", "rk_press", "wait",
            "video_stop"]
    REBUILD = ["rk_focus", "px_tab_new", "neutral_prompt", "type", "expect", "wait"]

    def specs(self, *extra):
        out = tempfile.mkdtemp(prefix="gen-tabclose-")
        gen("--out", out, "--only", self.CID, *extra)
        return {p.stem: json.loads(p.read_text()) for p in sorted(Path(out).glob("*.json"))}

    def check_films(self, spec, labels):
        films = [st for st in spec["steps"] if st["do"] == "px_film"]
        self.assertEqual([f["name"].rsplit("-", 1)[1] for f in films], labels, spec["id"])
        for n, f in enumerate(films):
            dos = [st["do"] for st in f["steps"]]
            self.assertEqual(dos, self.FILM, f["name"])
            self.assertEqual(f["steps"][dos.index("px_equalize")]["panes"], ["p0", "p1"])  # every film starts alike
            outline = f["steps"][dos.index("px_tunable")]
            self.assertEqual((outline["key"], outline["value"], outline["required"]), (TAB_OUTLINE, True, True))
            hold = f["steps"][dos.index("px_hold_tab_close")]
            self.assertEqual((hold["key"], hold["modifiers"], hold["seconds"]), ("l", ["control", "shift"], 1.5))
            self.assertEqual(hold["close"], {"pane": "p0", "which": "middle", "after_ms": 50})
            burst = f["steps"][dos.index("rk_press")]
            self.assertEqual((burst["key"], burst["count"], burst["gap_ms"]), ("h", 30, 33))
            start = f["steps"][dos.index("px_record_start")]
            self.assertTrue(start["input"].startswith("held keys ("), start["input"])  # judge_pixel: input-driven
            self.assertEqual(start["fixture"]["p0"], {"kind": "tui", "fill": "#0000FF"})  # never the outline's #FFFF00
            if n == len(films) - 1:
                self.assertEqual(f["after"], [], "the last film needs no tab back")
            else:
                self.assertEqual([st["do"] for st in f["after"]], self.REBUILD, f["name"])
                self.assertEqual((f["after"][0]["pane"], f["after"][1]["pane"]), ("p0", "p0"))
                self.assertIn("--fill 0000FF", f["after"][3]["text"])
        return films

    def test_the_case_and_its_s1r(self):
        import run as R
        specs = self.specs()
        self.assertEqual(sorted(specs), [self.CID, f"{self.CID}-s1r"])
        for jid, spec in specs.items():
            self.assertEqual(R.validate(spec), [], jid)
            self.assertLessEqual(spec["budget_seconds"], 250, jid)
            self.assertEqual([st["do"] for st in spec["finally"]], ["px_tunable"] + STANDARD_FINALLY)
            self.assertEqual((spec["finally"][0]["key"], spec["finally"][0]["value"]), (TAB_OUTLINE, None))
            # Set-up: the outline (required: a build without it is not run), then p0's two more tabs, each its fixture.
            first_film = next(i for i, st in enumerate(spec["steps"]) if st["do"] == "px_film")
            setup = spec["steps"][:first_film]
            outline = [st for st in setup if st["do"] == "px_tunable" and st["key"] == TAB_OUTLINE]
            self.assertEqual([(st["value"], st["required"]) for st in outline], [(True, True)])
            new = [i for i, st in enumerate(setup) if st["do"] == "px_tab_new"]
            self.assertEqual([setup[i]["pane"] for i in new], ["p0", "p0"])
            for i in new:
                self.assertEqual([st["do"] for st in setup[i + 1:i + 4]], ["neutral_prompt", "type", "expect"])
                self.assertIn("--fill 0000FF", setup[i + 2]["text"])
        self.check_films(specs[self.CID], ["s025", "s05", "s1", "s2", "s4", "reduce"])
        self.check_films(specs[f"{self.CID}-s1r"], ["s1", "reduce"])

    def test_only_matches_whole_case_ids(self):
        held = [line.split()[0] for line in gen("--list", "--only", "px-keys-held-2").splitlines()]
        self.assertTrue(held)
        self.assertFalse([i for i in held if "tabclose" in i], held)
        tab = [line.split()[0] for line in gen("--list", "--only", self.CID).splitlines()]
        self.assertEqual(sorted(tab), [self.CID, f"{self.CID}-s1r"])

    def test_switch_variant_sets_the_switch_after_the_launch(self):
        specs = self.specs("--switch", SWITCH)
        self.assertTrue(specs)
        self.assertTrue(all(jid.startswith(f"{self.CID}-sw-terminals") for jid in specs), sorted(specs))
        labels = []
        for jid, spec in specs.items():
            launch = next(i for i, st in enumerate(spec["steps"]) if st["do"] == "smoke_ready")
            films = [i for i, st in enumerate(spec["steps"]) if st["do"] == "px_film"]
            self.assertTrue(films and all(i > launch for i in films), jid)
            for i in films:
                f = spec["steps"][i]
                # px_film sets the switch after the speed and before its steps: the outline (a step) after both.
                self.assertEqual(f["switch"]["key"], SWITCH)
                labels.append(f["name"].split("-sw-terminals")[1].lstrip("-abc").lstrip("-"))
            self.check_films(spec, [spec["steps"][i]["name"].rsplit("-", 1)[1] for i in films])
            self.assertEqual([st["do"] for st in spec["finally"]][:2], ["px_tunable", "px_tunable"])
            self.assertEqual([spec["finally"][0]["key"], spec["finally"][1]["key"]], [SWITCH, TAB_OUTLINE])
        self.assertEqual(labels, ["off-s1", "on-s1", "off-reduce", "on-reduce"])



# -- px-keys-then-drag-3 and px-keys-then-split-drag-2s (stage S2b, frame-owner-s2) ----------------------------------------
SHARED = "motion.frameOwner.sharedEdges"
HIT_WIDTH = "metrics.dividerHitWidth"


def spring_fraction(t, response):
    """The share of its travel a critically damped spring has made t s after it starts (omega0 = 2 pi / response)."""
    if t <= 0:
        return 0.0
    w = 2 * math.pi / response
    return 1 - (1 + w * t) * math.exp(-w * t)


class SpringApp(FakeApp):
    """Three strip columns at rest (vertical dividers at x 641.5 and 1075.5, a split divider in column 2 at y 300), the
    trace (debug.motion trace_read with path, the host clock) and the input journal of one key spring and one drag. The
    key-down reaches the app `key_ms` after the key is sent and starts the move spring (`response`) of every edge right of
    p0 by S = 5% of the 1304 pt viewport. The drag's mouse-down reaches it `latency_s` after its call starts; it grabs the
    vertical divider within half of `hit_pt` of the press (or the split divider), which then follows the pointer."""

    S = round(0.05 * 1304, 2)

    def __init__(self, clock, offset, response=0.6, key_ms=25, latency_s=0.40, hit_pt=24.0, drag_ms=400, vsplit=False,
                 trade=False):
        super().__init__()
        self.clock, self.offset, self.response, self.key_ms, self.latency_s = clock, offset, response, key_ms, latency_s
        self.hit_pt, self.drag_ms = hit_pt, drag_ms
        # vsplit: a vertical split divider x in column 2 (between the two column edges: vertical divider 1). It slides with
        # the key's spring; grabbed ("vsplit") it holds where the press found it and moves with the pointer.
        self.vsplit = vsplit
        # trade: the key trades width between the first two columns (KEYS #34123): column:c1 stays where it rests.
        self.trade = trade
        self.key_down = self.mouse_down = None
        self.grabbed = None  # "column" | "split" | None
        self.by = (0.0, 0.0)
        self.journal = []

    def host(self):
        return self.clock.t + self.offset

    def edge(self, rest, t):
        k = 0.0 if self.key_down is None else self.S * spring_fraction(t - self.key_down, self.response)
        return rest + k

    def dividers(self, t):
        d0 = self.edge(641.5, t)
        d1 = 1075.5 if self.trade else self.edge(1075.5, t)
        split_y = 300.0  # not the vertical dividers' middle (428.5): a column press that misses is no split press
        if self.mouse_down is not None and t >= self.mouse_down:
            share = min(1.0, (t - self.mouse_down) / (self.drag_ms / 1000.0))
            if self.grabbed == "column":
                d1 += self.by[0] * share
            elif self.grabbed == "split":
                split_y += self.by[1] * share
        w = 24.0 if self.hit_pt >= 24 else 7.0
        out = [["column:c0", d0 - w / 2, 0, w, 857, 1, 2], ["column:c1", d1 - w / 2, 0, w, 857, 1, 3],
               ["split:s1", d0 + 4, split_y - 3.5, 430, 7, 1, 4]]
        if self.vsplit:
            x = self.edge(857.5, t)
            if self.grabbed == "vsplit" and self.mouse_down is not None and t >= self.mouse_down:
                x = self.edge(857.5, self.mouse_down) + self.by[0] * min(1.0, (t - self.mouse_down) / (self.drag_ms / 1000.0))
            out.append(["split:x", x - w / 2, 0, w, 857, 1, 5])
        return out

    def samples(self, until):
        t0 = 9000.0
        out, t = [], t0
        while t <= until:
            out.append({"t": round((t - t0) * 1000, 3), "window": [1512, 857], "dividers": self.dividers(t)})
            t += 1 / 120
        return {"t0_s": t0, "refresh_ms": 8.333, "samples": out}

    def rpc(self, method, params=None, timeout=None):
        params = params or {}
        if method == "debug.motion" and params.get("action") == "trace_read":
            self.calls.append((method, params))
            Path(params["path"]).write_text(json.dumps(self.samples(self.host())))
            return {"path": params["path"], "writing": True}
        if method == "debug.journal":
            return {"entries": list(self.journal[-int(params.get("last", 40)):])}
        if method == "debug.pane_chrome":
            return {"windows": [{"id": "w1", "scale": 2.0, "main_pane": [208, 0, 1304, 857], "panes": []}]}
        return super().rpc(method, params, timeout)

    # what the journey's real-input steps do to this app
    def press_key(self):
        self.key_down = self.host() + self.key_ms / 1000.0
        self.journal.append({"seq": len(self.journal) + 1, "uptimeNanos": int(self.key_down * 1e9),
                             "kind": {"key": {"_0": {"phase": "down", "key": "l", "keyClass": "character"}}}})

    def drag(self, point, by):
        self.mouse_down = self.host() + self.latency_s
        self.focus_on_miss = getattr(self, "focus_on_miss", False)
        self.by = (float(by[0]), float(by[1]))
        d = {k[0]: k for k in self.dividers(self.mouse_down)}
        c1 = d["column:c1"]
        sp = d["split:s1"]
        vx = d.get("split:x")
        if vx is not None and abs(point[0] - (vx[1] + vx[3] / 2)) <= vx[3] / 2 and abs(by[1]) < 1e-9:
            self.grabbed = "vsplit"
        elif abs(point[0] - (c1[1] + c1[3] / 2)) <= c1[3] / 2 and abs(by[1]) < 1e-9:
            self.grabbed = "column"
        elif sp[1] <= point[0] <= sp[1] + sp[3] and abs(point[1] - (sp[2] + sp[4] / 2)) <= sp[4] / 2:
            self.grabbed = "split"
        self.journal.append({"seq": len(self.journal) + 1, "uptimeNanos": int(self.mouse_down * 1e9),
                             "kind": {"mouse": {"_0": {"phase": "down", "x": point[0], "y": point[1]}}}})
        if self.grabbed is None and self.focus_on_miss:
            # A press beside the divider lands in the pane under it, which takes the focus (as the app's journal shows it).
            self.journal.append({"seq": len(self.journal) + 1, "uptimeNanos": int(self.mouse_down * 1e9) + 100_000,
                                 "kind": {"focus": {"_0": {"focusPane": {"_0": "pane-b1", "source": "mouse"}}}}})


class SpringJourney(FakeJourney):
    """rk_press and hid_drag as CuaDriver plays them on one session: a key call takes `key_call_s`, a drag call returns
    when its drag ends (latency + duration)."""

    def __init__(self, app, config_dir, clock, key_call_s=0.075):
        super().__init__(app, config_dir)
        self.clock, self.key_call_s = clock, key_call_s
        self.video = {"notes": {"pixel": {}}, "hid": []}
        self.log = []
        self.out.mkdir(parents=True, exist_ok=True)

    def step_rk_press(self, step):
        self.log.append(("key", self.clock.t, dict(step)))
        self.app.press_key()
        self.clock.t += self.key_call_s
        return {"count": 1}

    def step_hid_drag(self, step):
        self.log.append(("drag", self.clock.t, dict(step)))
        self.app.drag(step["target"]["window_point"], step["by"])
        self.clock.t += self.app.latency_s + float(step["duration_ms"]) / 1000.0
        return {"mode": "desktop"}


class KeyThenDragTests(unittest.TestCase):
    """px_key_then_drag: one real HID key, then a real HID drag on the journey's one CuaDriver session, its call 60 ms after
    the key-down. A HID drag's mouse-down reaches the app 260-400 ms after its call starts (12 drags, cmux22 sweeps), so
    at x0.25 (the move spring's response 0.6 s) the key's spring is still running then. The press goes where the edge will
    be: its rest place plus the key's step (5% of the viewport) times the spring's progress at the expected mouse-down;
    a split divider spans its column, so its middle is pressed. After the drag the step reads the journal (the key-down,
    the drag's mouse-down) and the trace: the springing column edge (vertical divider 0) still moving at the mouse-down,
    and the dragged edge following the pointer. Else the film is "not run" (no overlap; the press missed the edge)."""

    def setUp(self):
        self.clock = FakeClock()
        self.saved = (X.D.now, X.time, X.V._host_offset_s, X.V.R.require_input_clear)
        X.D.now, X.time = self.clock.monotonic, self.clock
        X.V._host_offset_s = lambda: 8000.0
        self.guard_points = []
        X.V.R.require_input_clear = lambda j, point=None: self.guard_points.append(point)

    def tearDown(self):
        X.D.now, X.time, X.V._host_offset_s, X.V.R.require_input_clear = self.saved

    def run_step(self, app, target, by, response=0.6):
        j = SpringJourney(app, tempfile.mkdtemp(), self.clock)
        j.px = {"speed": 0.25, "reduce": False, "springs": {"move": {"response": response, "damping": 1.0}},
                "springs_source": "overrides", "tunables": {}, "films": []}
        out = X.step_px_key_then_drag(j, {"key": "l", "modifiers": ["control", "shift"], "after_ms": 60,
                                          "drag": {"target": target, "by": by, "duration_ms": 400},
                                          "spring_default": {"response": 0.15, "damping": 1.0}, "mark": "kd"})
        return j, out

    def test_the_column_edge_is_pressed_where_the_spring_has_it(self):
        app = SpringApp(self.clock, 8000.0)
        j, out = self.run_step(app, {"divider": 1}, [150, 0])
        (_, k_at, key), (_, d_at, drag) = j.log
        self.assertEqual((key["key"], key["modifiers"], key["count"]), ("l", ["control", "shift"], 1))
        # The drag call 60 ms after the key-down (the key-down 25 ms after its send).
        self.assertAlmostEqual(d_at - k_at, 0.085, delta=0.003)
        self.assertEqual((drag["by"], drag["duration_ms"], drag["hold_ms"]), ([150, 0], 400, 0))
        # The input guard ran once, before the key, for the drag's press point; the drag does not check again.
        self.assertEqual(self.guard_points, [drag["target"]["window_point"]])
        self.assertTrue(drag["cover_checked"])
        note = j.video["notes"]["pixel"]["key_then_drag"]
        self.assertEqual(note["verdict"], "overlap")
        self.assertTrue(note["edge_moving_at_down"])
        self.assertTrue(note["grabbed"])
        self.assertEqual(app.grabbed, "column")
        # The press is near where divider 1 shows at the mouse-down (within a few points), not at its rest place.
        shown = 1075.5 + app.S * spring_fraction(app.mouse_down - app.key_down, 0.6)
        self.assertLess(abs(drag["target"]["window_point"][0] - shown), 4.0)
        self.assertGreater(drag["target"]["window_point"][0] - 1075.5, 30)
        self.assertAlmostEqual(note["key_down_host"], app.key_down, places=6)
        self.assertAlmostEqual(note["mouse_down_host"], app.mouse_down, places=6)
        self.assertAlmostEqual(note["mouse_down_after_key_ms"], (app.mouse_down - app.key_down) * 1000, delta=0.5)
        self.assertGreater(note["spring_left_pt"], 1.0)
        self.assertIn("CLOCK_UPTIME_RAW", note["clock"])
        self.assertNotIn("film_not_run", j.px)
        self.assertEqual(out["key_then_drag"], note)

    def test_the_hit_width_is_in_the_note(self):
        """The case's divider hit width (metrics.dividerHitWidth 24 pt, px_tunable) goes in the note: the press tolerance
        the verdict depends on. It changes no pane frame (only the hit bands read it)."""
        app = SpringApp(self.clock, 8000.0)
        j = SpringJourney(app, tempfile.mkdtemp(), self.clock)
        rec = {"key": HIT_WIDTH, "wanted": 24, "value": 24, "default": 7, "applied": True, "store_active": True, "why": ""}
        j.px = {"speed": 0.25, "reduce": False, "springs": {"move": {"response": 0.6, "damping": 1.0}}, "springs_source": "overrides",
                "tunables": {HIT_WIDTH: rec}, "films": []}
        X.step_px_key_then_drag(j, {"key": "l", "modifiers": ["control", "shift"], "after_ms": 60,
                                    "drag": {"target": {"divider": 1}, "by": [150, 0], "duration_ms": 400}})
        note = j.video["notes"]["pixel"]["key_then_drag"]
        self.assertEqual(note["hit_width"], {"key": HIT_WIDTH, "pt": 24, "default_pt": 7, "applied": True,
                                             "frames": "none: only the divider hit bands read it"})

    def test_without_the_hit_width_the_note_says_default(self):
        app = SpringApp(self.clock, 8000.0)
        j, _ = self.run_step(app, {"row_divider": 0}, [0, 120])
        self.assertEqual(j.video["notes"]["pixel"]["key_then_drag"]["hit_width"], {"key": HIT_WIDTH, "pt": None,
                                                                                   "default_pt": None, "applied": False,
                                                                                   "frames": "none: only the divider hit bands read it"})

    def test_the_split_divider_is_pressed_in_its_middle(self):
        app = SpringApp(self.clock, 8000.0)
        j, out = self.run_step(app, {"row_divider": 0}, [0, 120])
        point = j.log[1][2]["target"]["window_point"]
        self.assertEqual(app.grabbed, "split")
        self.assertAlmostEqual(point[1], 300.0, places=3)
        self.assertEqual(j.video["notes"]["pixel"]["key_then_drag"]["verdict"], "overlap")

    def test_a_spring_that_landed_before_the_mouse_down_is_no_overlap(self):
        app = SpringApp(self.clock, 8000.0, response=0.15)  # x1: the key's spring lands in about 0.18 s
        j, _ = self.run_step(app, {"divider": 1}, [150, 0], response=0.15)
        note = j.video["notes"]["pixel"]["key_then_drag"]
        self.assertFalse(note["edge_moving_at_down"])
        self.assertEqual(note["verdict"], "no overlap")
        self.assertIn("no overlap", j.px["film_not_run"])

    def test_a_press_off_the_edge_is_a_miss(self):
        # A far later mouse-down on a slow (x0.125) spring: the edge is 17 pt past the press, off a 7 pt hit band.
        app = SpringApp(self.clock, 8000.0, response=1.2, latency_s=0.9, hit_pt=7.0)
        j, _ = self.run_step(app, {"divider": 1}, [150, 0], response=1.2)
        note = j.video["notes"]["pixel"]["key_then_drag"]
        self.assertFalse(note["grabbed"])
        self.assertIsNone(app.grabbed)
        self.assertIn("missed the edge", j.px["film_not_run"])


    def test_an_edge_the_key_does_not_move_is_pressed_at_its_rest_place(self):
        """Since KEYS (#34123) a resize key trades width between the two columns of its divider: the next column edge stays.
        With share 0 the press goes to that edge's rest place and grabs it; with the old share (1) it went 45 pt past it
        (round ab-s2bd-sw-813ac15: "the press missed the edge")."""
        for share, grabs in ((0.0, True), (1.0, False)):
            app = SpringApp(self.clock, 8000.0, trade=True, hit_pt=24.0)
            j = SpringJourney(app, tempfile.mkdtemp(), self.clock)
            j.px = {"speed": 0.25, "reduce": False, "springs": {"move": {"response": 0.6, "damping": 1.0}},
                    "springs_source": "overrides", "tunables": {}, "films": []}
            X.step_px_key_then_drag(j, {"key": "l", "modifiers": ["control", "shift"], "after_ms": 60,
                                        "drag": {"target": {"divider": 1}, "by": [150, 0], "duration_ms": 400, "share": share}})
            note = j.video["notes"]["pixel"]["key_then_drag"]
            self.assertEqual(note["drag"]["share"], share)
            self.assertEqual(note["grabbed"], grabs, (share, note))
            if grabs:
                self.assertAlmostEqual(note["drag"]["press"][0], 1075.5, places=6)
                self.assertEqual(note["verdict"], "overlap")
                self.assertEqual(app.grabbed, "column")

    def test_a_press_that_focuses_a_pane_is_a_miss(self):
        """The app's journal decides: a press that focused a pane by the mouse at its mouse-down went into the pane, not to the
        divider (ab-s2bdc-813ac15: 4.1 pt off a split, inside the trace's band, and the pane took the focus)."""
        app = SpringApp(self.clock, 8000.0, response=1.2, latency_s=0.9, hit_pt=7.0, drag_ms=1500, vsplit=True)
        app.focus_on_miss = True
        j, note = self.still_drag(app)
        self.assertIsNone(app.grabbed)
        self.assertEqual(note["press_focused_pane"], "pane-b1")
        self.assertFalse(note["grabbed"])
        self.assertIn("it focused pane pane-b1", j.px["film_not_run"])

    def test_less_pt_takes_the_divider_s_shorter_travel(self):
        """drag.less_pt: the split travels the key's step less b1's room (59 of 65 pt); the press plans that."""
        app = SpringApp(self.clock, 8000.0, response=1.2, drag_ms=1500, vsplit=True)
        j = SpringJourney(app, tempfile.mkdtemp(), self.clock)
        j.px = {"speed": 0.125, "reduce": False, "springs": {"move": {"response": 1.2, "damping": 1.0}},
                "springs_source": "overrides", "tunables": {}, "films": []}
        X.step_px_key_then_drag(j, {"key": "l", "modifiers": ["control", "shift"], "after_ms": 60,
                                    "drag": {"target": {"divider": 1}, "by": [1, 0], "duration_ms": 1500, "less_pt": 6}})
        note = j.video["notes"]["pixel"]["key_then_drag"]
        # The step's own plan: the key's step (KEY_STEP of the main pane, rounded to half a point) less 6 pt, times the
        # spring's progress at the planned mouse-down (after_ms + DRAG_DOWN_S).
        step = round(X.KEY_STEP * 1304 * 2) / 2
        frac = spring_fraction(0.06 + X.DRAG_DOWN_S, 1.2)
        self.assertAlmostEqual(note["drag"]["press"][0] - note["drag"]["rest"][0], (step - 6) * frac, places=3)
        self.assertAlmostEqual(note["planned"]["moved_pt"], round((step - 6) * frac, 3), places=3)
        self.assertEqual(note["drag"]["less_pt"], 6.0)

    def still_drag(self, app):
        j = SpringJourney(app, tempfile.mkdtemp(), self.clock)
        j.px = {"speed": 0.125, "reduce": False, "springs": {"move": {"response": 1.2, "damping": 1.0}},
                "springs_source": "overrides", "tunables": {}, "films": []}
        X.step_px_key_then_drag(j, {"key": "l", "modifiers": ["control", "shift"], "after_ms": 60,
                                    "drag": {"target": {"divider": 1}, "by": [1, 0], "duration_ms": 1500}, "mark": "kc"})
        return j, j.video["notes"]["pixel"]["key_then_drag"]

    def test_a_still_drag_is_a_grab_when_its_edge_leaves_the_next_dividers_slide(self):
        """S2B clamp case (gen_pixel px-keys-then-clamp-3x): the split x in column 2 pressed during a x0.125 key spring, 1 pt
        right, then held. Grabbed, it moves its 1 pt while the column edge right of it slides on (about 20 pt). Its own
        travel against the drag's 1 pt cannot tell a grab: a missed press leaves it sliding too."""
        app = SpringApp(self.clock, 8000.0, response=1.2, drag_ms=1500, vsplit=True)
        j, note = self.still_drag(app)
        self.assertEqual(app.grabbed, "vsplit")
        self.assertEqual(note["drag"]["divider"], "split:x")
        self.assertTrue(note["grabbed"])
        self.assertEqual(note["still_drag"]["next_divider"], "column:c1")
        self.assertGreater(note["still_drag"]["next_travel_pt"], 10)
        # Its 1 pt, plus at most one refresh of slide (the trace sample at the mouse-down is the tick before it).
        self.assertLess(abs(note["dragged_travel_pt"] - 1.0), 0.5)
        self.assertEqual(note["verdict"], "overlap")
        self.assertNotIn("film_not_run", j.px)

    def test_a_still_drag_whose_edge_slides_on_is_a_miss(self):
        """The same press on a 7 pt hit band after a later mouse-down: it misses x, which slides on with its column, as the
        next divider does; the travel share alone (20 pt of a 1 pt drag) would have called it a grab."""
        app = SpringApp(self.clock, 8000.0, response=1.2, latency_s=0.9, hit_pt=7.0, drag_ms=1500, vsplit=True)
        j, note = self.still_drag(app)
        self.assertIsNone(app.grabbed)
        self.assertGreater(note["dragged_travel_pt"] / 1.0, X.GRAB_SHARE)
        self.assertLess(abs(note["dragged_travel_pt"] - note["still_drag"]["next_travel_pt"]), 0.01)
        self.assertFalse(note["grabbed"])
        self.assertIn("missed the edge", j.px["film_not_run"])
        self.assertIn("a still drag", j.px["film_not_run"])


class InputGuardTests(unittest.TestCase):
    """ext_realkey's input guard (R-HARNESS 2026-11-04, cmux24): a password prompt on screen, or a window of another process
    above the app at the input point, gives "not run" with the window; CuaDriver's list is frontmost first."""

    APP = 4242

    def rows(self):
        R = X.V.R
        return [
            {"app": "SecurityAgent", "pid": 90, "layer": 1000, "title": "", "bounds": [740, 232, 439, 154]},
            {"app": "UserNotificationCenter", "pid": 91, "layer": 8, "title": "", "bounds": [830, 189, 318, 406]},
            {"app": "cmux", "pid": self.APP, "layer": 0, "title": "main", "bounds": [0, 49, 1512, 883]},
            {"app": "Finder", "pid": 92, "layer": 0, "title": "behind", "bounds": [100, 100, 400, 400]},
        ]

    def test_a_password_prompt_is_found(self):
        self.assertEqual([r["app"] for r in X.V.R.prompt_rows(self.rows())], ["SecurityAgent"])
        self.assertEqual(X.V.R.prompt_rows(self.rows()[1:]), [])

    def test_a_window_above_the_app_covers_its_point(self):
        R = X.V.R
        self.assertEqual([r["app"] for r in R.covering_rows(self.rows(), self.APP, (900, 300))],
                         ["SecurityAgent", "UserNotificationCenter"])
        # A window behind the app's (later in the list, layer 0) does not cover it; nor does anything off the point.
        self.assertEqual(R.covering_rows(self.rows(), self.APP, (200, 200)), [])
        self.assertEqual(R.covering_rows(self.rows(), self.APP, (1400, 800)), [])

    def test_another_app_s_normal_window_in_front_covers_the_point(self):
        """A layer-0 window of another process BEFORE the app's in the list (in front of it) covers the point; the same
        window after the app's (behind it) does not (R-HARNESS: the order rule had no test)."""
        R = X.V.R
        front = {"app": "TextEdit", "pid": 93, "layer": 0, "title": "front", "bounds": [800, 250, 300, 300]}
        app = {"app": "cmux", "pid": self.APP, "layer": 0, "title": "main", "bounds": [0, 49, 1512, 883]}
        self.assertEqual([r["app"] for r in R.covering_rows([front, app], self.APP, (900, 300))], ["TextEdit"])
        self.assertEqual(R.covering_rows([app, dict(front, title="behind")], self.APP, (900, 300)), [])

    def test_window_points_flip_to_screen_points(self):
        """window_to_screen: window points from the window's top-left to screen points from the screen's top-left, with
        debug.layers' bottom-left frame and the primary screen's top (R-HARNESS: the flip had no test)."""
        R = X.V.R
        saved = R._layers_window
        try:
            R._layers_window = lambda j: {"frame": [100, 50, 1200, 800], "primary_max_y": 982}
            self.assertEqual(R.window_to_screen(None, (10, 20)), (110.0, 982 - (50 + 800) + 20.0))
            R._layers_window = lambda j: None
            self.assertIsNone(R.window_to_screen(None, (10, 20)))
        finally:
            R._layers_window = saved

    def guard_env(self, rows, frame=(0, 50, 1512, 883)):
        R = X.V.R
        saved = (R._window_rows, R._layers_window, R.D.now)
        R._window_rows = lambda j: list(rows)
        R._layers_window = lambda j: {"frame": list(frame), "primary_max_y": 982}
        R.D.now = lambda: 100.0
        self.addCleanup(lambda: setattr(R, "_window_rows", saved[0]) or setattr(R, "_layers_window", saved[1])
                        or setattr(R.D, "now", saved[2]))

        class J:
            class app:
                pid = self.APP
        return J()

    def test_the_guard_refuses_a_prompt_and_a_covered_point(self):
        R = X.V.R
        rows = self.rows()
        j = self.guard_env(rows)
        with self.assertRaisesRegex(R.D.NotRun, "password prompt"):
            R.require_input_clear(j)
        rows.pop(0)
        # window point (900, 251) is screen (900, 300) on a window whose top is at 982 - 933 = 49
        with self.assertRaisesRegex(R.D.NotRun, "UserNotificationCenter window .* covers the input point"):
            R.require_input_clear(j, (900, 251))
        rows.pop(0)
        R.require_input_clear(j, (900, 251))
        self.assertEqual(j.input_clear_at, 100.0)
        self.assertEqual(j.input_rows_at["screen"], [900.0, 300.0])
        self.assertEqual([r["app"] for r in j.input_rows_at["rows"]], ["cmux"])

    def test_the_guard_fails_closed_without_the_app_s_window(self):
        """An unreadable list ([]), or one with no layer-0 window of the app, gives not run: it proves nothing."""
        R = X.V.R
        for rows in ([], [r for r in self.rows()[1:] if r["pid"] != self.APP]):
            j = self.guard_env(rows)
            with self.assertRaisesRegex(R.D.NotRun, "does not show the app's window"):
                R.require_input_clear(j)

    def test_the_units_check_refuses_a_list_in_pixels(self):
        """Once per journey the app's window in the list must match debug.layers' frame (points); a 2x list is refused."""
        R = X.V.R
        app2x = {"app": "cmux", "pid": self.APP, "layer": 0, "title": "main", "bounds": [0, 98, 3024, 1766]}
        j = self.guard_env([app2x])
        R.require_input_clear(j)  # a key places no point: no units check
        self.assertFalse(getattr(j, "input_units_ok", False))
        with self.assertRaisesRegex(R.D.NotRun, "disagree on the app's window"):
            R.require_input_clear(j, (900, 251))
        j = self.guard_env([{"app": "cmux", "pid": self.APP, "layer": 0, "title": "main", "bounds": [0, 49, 1512, 883]}])
        R.require_input_clear(j, (900, 251))
        self.assertTrue(j.input_units_ok)


class FilmNotRunTests(unittest.TestCase):
    """px_film: a film step that judged the film not run (px_key_then_drag's verdict) makes the film's line "not run" with
    its reason; the rest of the film and its rebuild still play (the layout changed), and the next film starts clean."""

    def test_the_verdict_makes_the_film_not_run_and_the_rebuild_plays(self):
        class J(FakeJourney):
            def step_kd(self, step):
                self.px["film_not_run"] = "not run: no overlap: the key's spring had landed at the mouse-down"
                return {}

        j = J(FakeApp(), tempfile.mkdtemp())
        f = film("f-s1", 1.0)
        f["steps"] = [{"do": "kd"}] + f["steps"]
        line = X.step_px_film(j, f)
        self.assertEqual(line["status"], "not run")
        self.assertIn("no overlap", line["reason"])
        self.assertEqual(j.played, ["f-s1 play", "f-s1 rebuild"])
        self.assertEqual(j.px["films"][-1]["status"], "not run")
        self.assertNotIn("film_not_run", j.px)
        self.assertEqual(X.step_px_film(j, film("f-s2", 1.0))["status"], "recorded")


class SharedEdgeCaseTests(unittest.TestCase):
    """gen_pixel.py, the two S2b cases, both at x0.25 only (a HID drag's mouse-down comes 260-400 ms after its call: at x1
    and under Reduce Motion the key's spring has landed by then, so there is no overlap to film). px-keys-then-drag-3: 3
    strip columns p0 T | p1 P | p2 T (newColumn, each a third of the viewport, a full-width window), the divider hit width
    24 pt (required); Ctrl-Shift-L on p0, then the p1|p2 column edge (divider 1) 150 pt right in 400 ms.
    px-keys-then-split-drag-2s: 2 strip columns p0 T | (p1 T / p2 P), p1 over p2 (splitDown); Ctrl-Shift-L on p0, then the
    p1/p2 divider (row_divider 0) 120 pt down in 400 ms. After each film but the last: the edge dragged back, then
    Ctrl-Shift-H on p0. Journeys: <case> (one film at x0.25) and <case>-sw-<short> (OFF and ON at x0.25)."""

    def specs(self, cid, *extra):
        out = tempfile.mkdtemp(prefix="gen-s2b-")
        gen("--out", out, "--only", cid, *extra)
        return {p.stem: json.loads(p.read_text()) for p in sorted(Path(out).glob("*.json"))}

    def check(self, spec, drag, hit_width):
        films = [st for st in spec["steps"] if st["do"] == "px_film"]
        for n, f in enumerate(films):
            self.assertEqual(f.get("speed"), 0.25, f["name"])
            dos = [st["do"] for st in f["steps"]]
            want = ["rk_focus"] + (["px_tunable"] if hit_width else []) + ["wait", "px_record_start", "px_key_then_drag", "wait",
                                                                           "video_stop"]
            self.assertEqual(dos, want, f["name"])
            if hit_width:
                tun = f["steps"][1]
                self.assertEqual((tun["key"], tun["value"], tun["required"]), (HIT_WIDTH, 24, True))
            kd = next(st for st in f["steps"] if st["do"] == "px_key_then_drag")
            self.assertEqual((kd["key"], kd["modifiers"], kd["after_ms"]), ("l", ["control", "shift"], 60))
            self.assertEqual(kd["drag"], drag)
            self.assertEqual(kd["spring_default"], {"response": 0.15, "damping": 1.0})
            start = next(st for st in f["steps"] if st["do"] == "px_record_start")
            self.assertEqual((start["input"], start["spring"]), ("key then drag", "move"))
            if n == len(films) - 1:
                self.assertEqual(f["after"], [])
            else:
                self.assertEqual([st["do"] for st in f["after"]], ["hid_drag", "wait", "rk_focus", "rk_press", "wait"], f["name"])
                self.assertEqual((f["after"][0]["target"], f["after"][0]["by"]), (drag["target"], [-v for v in drag["by"]]))
                self.assertEqual((f["after"][3]["key"], f["after"][3]["modifiers"]), ("h", ["control", "shift"]))
        return films

    def check_case(self, cid, drag, columns, splits, hit_width):
        import run as R
        specs = self.specs(cid)
        self.assertEqual(sorted(specs), [cid], "one journey: x0.25 only")
        spec = specs[cid]
        self.assertEqual(R.validate(spec), [])
        self.assertLessEqual(spec["budget_seconds"], 250)
        films = self.check(spec, drag, hit_width)
        self.assertEqual([f["name"] for f in films], [f"{cid}-s025"])
        acts = [st.get("action") for st in spec["steps"] if st["do"] == "action"]
        self.assertEqual((acts.count("newColumn"), acts.count("splitDown")), (columns, splits))
        self.assertIn("column.widthOneThird", [st.get("action") for st in spec["steps"] if st["do"] == "try_action"])
        place = next(st for st in spec["steps"] if st["do"] == "window_place")
        self.assertEqual(place["fraction"], [0.0, 0.05, 1.0, 0.9])
        fixture = [st for st in spec["steps"] if st["do"] == "px_tunable" and st["key"] == HIT_WIDTH]
        self.assertEqual(len(fixture), 1 if hit_width else 0)  # the set-up's; each film sets it again (check)
        self.assertEqual(HIT_WIDTH in [st.get("key") for st in spec["finally"]], hit_width)
        return spec

    def test_keys_then_column_edge_drag(self):
        # share 0: since KEYS (#34123) the key trades p0's and p1's widths, so the p1|p2 edge stays where it rests.
        spec = self.check_case("px-keys-then-drag-3", {"target": {"divider": 1}, "by": [150, 0], "duration_ms": 400, "share": 0.0}, 2, 0, True)
        self.assertEqual([st["do"] for st in spec["steps"]].count("px_page"), 1)

    def test_keys_then_split_drag(self):
        self.check_case("px-keys-then-split-drag-2s", {"target": {"row_divider": 0}, "by": [0, 120], "duration_ms": 400, "share": 1.0}, 1, 1,
                        False)

    def test_shared_edge_switch_variants(self):
        for cid, drag, hit in (("px-keys-then-drag-3", {"target": {"divider": 1}, "by": [150, 0], "duration_ms": 400, "share": 0.0}, True),
                               ("px-keys-then-split-drag-2s", {"target": {"row_divider": 0}, "by": [0, 120], "duration_ms": 400, "share": 1.0},
                                False)):
            specs = self.specs(cid, "--switch", SHARED)
            self.assertEqual(sorted(specs), [f"{cid}-sw-sharededges"])
            spec = specs[f"{cid}-sw-sharededges"]
            films = self.check(spec, drag, hit)
            self.assertEqual([f["name"] for f in films], [f"{cid}-sw-sharededges-off-s025", f"{cid}-sw-sharededges-on-s025"])
            self.assertEqual([f["switch"] for f in films], [{"key": SHARED, "value": False}, {"key": SHARED, "value": True}])
            self.assertEqual(spec["finally"][0], {"do": "px_tunable", "key": SHARED, "value": None,
                                                  "title": f"clean-up: {SHARED} back to its default"})



class LiveResizeSwitchTests(unittest.TestCase):
    """gen_pixel.py --switch motion.frameOwner.liveResize --only px-window-resize-4 (stage S7, frame-owner-s7-live-resize):
    the switch is latched per resize, read at its first held drag (LiveResizeDragInput), so px_film sets it before any
    step of the film (px_film: speed, then switch, then the steps), and the film's first window drag (px_window_frame)
    comes after. OFF then ON at x1 and under Reduce Motion; the switch back to its default in finally."""

    KEY = "motion.frameOwner.liveResize"

    def test_the_switch_is_set_before_the_films_first_drag(self):
        out = tempfile.mkdtemp(prefix="gen-s7-")
        gen("--out", out, "--switch", self.KEY, "--only", "px-window-resize-4")
        specs = {p.stem: json.loads(p.read_text()) for p in sorted(Path(out).glob("*.json"))}
        self.assertTrue(specs)
        self.assertTrue(all(jid.startswith("px-window-resize-4-sw-liveresize") for jid in specs), sorted(specs))
        labels = []
        for jid, spec in specs.items():
            for f in [st for st in spec["steps"] if st["do"] == "px_film"]:
                self.assertEqual(f["switch"]["key"], self.KEY)
                dos = [st["do"] for st in f["steps"]]
                self.assertIn("px_window_frame", dos)
                # No window drag before the recorder: the first drag of the film is the first held drag of its resize.
                self.assertLess(dos.index("px_record_start"), dos.index("px_window_frame"), f["name"])
                labels.append(f["name"].split("-sw-liveresize")[1].lstrip("-abc").lstrip("-"))
            self.assertEqual(spec["finally"][0], {"do": "px_tunable", "key": self.KEY, "value": None,
                                                  "title": f"clean-up: {self.KEY} back to its default"})
        self.assertEqual(labels, ["off-s1", "on-s1", "off-reduce", "on-reduce"])

    def test_px_film_sets_the_switch_before_its_first_step(self):
        order = []

        class App(FakeApp):
            def rpc(self, method, params=None, timeout=None):
                if method == "debug.tunables" and (params or {}).get("key") == LiveResizeSwitchTests.KEY:
                    order.append(("switch", (params or {}).get("value")))
                return super().rpc(method, params, timeout)

        class J(FakeJourney):
            def step_px_window_frame(self, step):
                order.append(("drag", step["by"]))
                return {}

        app = App(switches=[self.KEY])
        j = J(app, tempfile.mkdtemp())
        f = film("w-on-s1", 1.0)
        f["steps"] = [{"do": "px_window_frame", "by": [-300, -150]}] + f["steps"]
        f["switch"] = {"key": self.KEY, "value": True}
        self.assertEqual(X.step_px_film(j, f)["status"], "recorded")
        self.assertEqual([o[0] for o in order if o[0] in ("switch", "drag")][:2], ["switch", "drag"])



class ResizeKeyboardFixtureTests(unittest.TestCase):
    """cmux-ad m6 (d), the film check of the resize-keyboard journey (frame-owner-s4): the judge's m6 contract (each
    terminal's content edge within 1 device px of its pane's edge in every frame, or the previous frame clipped and anchored
    top-left) reads only fixture films (judge_pixel's notes.pixel; R-HARNESS). gen_pixel.py px-keys-rk-3t is the
    open-P0 journey resize-keyboard's presses (read from its journey file) on a fixture layout of three terminals in the
    same places, p0 | (p1 / p2): the six speeds, x1 and Reduce Motion (-s1r), and the switch variant (-sw-terminals)."""

    CASE = "px-keys-rk-3t"

    @staticmethod
    def presses(steps):
        out = []
        for st in steps:
            if st["do"] == "rk_press":
                out.append((st["key"], tuple(st["modifiers"]), st.get("count", 1)))
            out += ResizeKeyboardFixtureTests.presses(st.get("steps") or [])
        return out

    def journeys(self, *extra):
        with tempfile.TemporaryDirectory() as out:
            gen("--out", out, "--only", self.CASE, *extra)
            return {p.stem: json.loads(p.read_text()) for p in sorted(Path(out).glob("*.json"))}

    def test_the_open_p0_journeys_presses_on_three_terminal_fixtures(self):
        import run as R
        rk = json.loads((HERE / "journeys" / "video" / "resize-keyboard.json").read_text())
        want = self.presses(rk["steps"])
        self.assertEqual(len(want), 8, want)
        specs = self.journeys()
        self.assertIn(f"{self.CASE}-s1r", specs)
        self.assertTrue(any(jid == self.CASE or jid.startswith(self.CASE + "-") and jid[-2:-1] == "-" for jid in specs), sorted(specs))
        for jid, spec in specs.items():
            self.assertEqual(R.validate(spec), [], jid)
            self.assertLessEqual(spec["budget_seconds"], 250, jid)
            films = [st for st in spec["steps"] if st["do"] == "px_film"]
            self.assertTrue(films, jid)
            for film in films:
                self.assertEqual(self.presses(film["steps"]), want, film["name"])
                focus = [st for st in film["steps"] if st["do"] == "rk_focus"]
                self.assertEqual([st["pane"] for st in focus], ["p1"], film["name"])
                start = next(st for st in film["steps"] if st["do"] == "px_record_start")
                self.assertEqual({name: f["kind"] for name, f in start["fixture"].items()},
                                 {"p0": "tui", "p1": "tui", "p2": "tui"}, film["name"])
                self.assertEqual(start["spring"], "move", film["name"])
            # p0 | (p1 / p2): p1 by splitRight from p0, p2 by splitDown from p1, as in resize-keyboard.
            self.assertEqual([st["action"] for st in spec["steps"] if st["do"] == "action" and st["action"].startswith("split")],
                             ["splitRight", "splitDown"], jid)

    def test_the_switch_variant(self):
        specs = self.journeys("--switch", SWITCH)
        self.assertEqual(sorted(specs), [f"{self.CASE}-sw-terminals"])
        films = [st for st in specs[f"{self.CASE}-sw-terminals"]["steps"] if st["do"] == "px_film"]
        self.assertEqual([(f["switch"]["value"], f.get("speed"), f.get("reduce")) for f in films],
                         [(False, 1.0, None), (True, 1.0, None), (False, None, True), (True, None, True)])

    def test_each_film_records_long_enough_for_its_eight_presses(self):
        specs = self.journeys()
        self.assertTrue(specs, "gen_pixel.py made no journey of the case")
        for jid, spec in specs.items():
            for film in [st for st in spec["steps"] if st["do"] == "px_film"]:
                start = next(st for st in film["steps"] if st["do"] == "px_record_start")
                played = sum(st["seconds"] for st in film["steps"] if st["do"] == "wait")
                self.assertGreater(start["seconds"], played + 2.0, film["name"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
