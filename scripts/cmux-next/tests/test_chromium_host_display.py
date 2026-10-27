#!/usr/bin/env python3
"""chromium_host_display.py, the --modes display row of chromium-host-bench.py (p01-process-221), against a fake app
and fake displays: a page that follows the window's display passes, both ways and with slow RPCs; a page whose rAF
stays at the old display's rate after a move (the host's page window left on the first display), whose
devicePixelRatio stays at the old scale, that takes too many frames to switch, or that is slow only on the 1x to 2x
move fails its row; one display leaves the move not measurable; a build without the host backend does not run. Runs
anywhere (no app, no CoreGraphics).
Run: python3 -I scripts/cmux-next/tests/test_chromium_host_display.py"""
import math, os, sys, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import chromium_host_display as display  # noqa: E402

# A 120 Hz 2x laptop panel (the main display) and a 60 Hz 1x external display to its right.
PANEL = {"id": 1, "bounds": [0, 0, 1512, 982], "hz": 120.0, "scale": 2.0}
EXTERNAL = {"id": 2, "bounds": [1512, 0, 1920, 1080], "hz": 60.0, "scale": 1.0}


def appkit(d, main=PANEL):
    """`d`'s frame as AppKit gives it (bottom left of the main display)."""
    x, y, w, h = d["bounds"]
    return [x, main["bounds"][3] - (y + h), w, h]


class FakeApp:
    """The page's animation frames on a fake clock. `lag_frames`: frames after a move still at the old display's
    period and scale; `stuck`: the page never leaves the first display's rate; `stale_scale`: its devicePixelRatio
    never changes; `scale_up_lag`: more frames with the old devicePixelRatio after a move to a higher scale;
    `latency_ms`: each request leg of a `debug.window_frame` (the window moves at its end) and each leg of a page
    eval; `start`: the index of the display the window starts on."""

    WALL_MS = 1_790_000_000_000.0  # the wall clock at the page's time origin

    def __init__(self, displays, backend="host", lag_frames=0, stuck=False, stale_scale=False, scale_up_lag=0,
                 latency_ms=0.0, start=0):
        self.displays, self.backend = displays, backend
        self.lag_frames, self.stuck, self.stale_scale = lag_frames, stuck, stale_scale
        self.scale_up_lag, self.latency_ms = scale_up_lag, latency_ms
        self.now = 0.0
        self.frames = []
        self.start_display = displays[start]
        self.on = self.start_display
        self.rate_of, self.scale_of = self.on, self.on
        self.rate_lag = self.scale_lag = 0
        self.next_frame = 1000 / self.on["hz"]
        self.start_frame = [self.on["bounds"][0] + 100, 100, 800, 600]
        self.frame = self.start_frame
        self.moves = []

    def sleep(self, seconds):
        end = self.now + seconds * 1000
        while self.next_frame <= end:
            self.now = self.next_frame
            self.frames.append([round(self.now, 3), self.scale_of["scale"]])
            if self.rate_lag:
                self.rate_lag -= 1
                if not self.rate_lag:
                    self.follow_rate()
            if self.scale_lag:
                self.scale_lag -= 1
                if not self.scale_lag:
                    self.follow_scale()
            self.next_frame = self.now + 1000 / self.rate_of["hz"]
        self.now = end

    def clock(self):
        return (self.WALL_MS + self.now) / 1000

    def follow_rate(self):
        if not self.stuck:
            self.rate_of = self.on

    def follow_scale(self):
        if not self.stale_scale:
            self.scale_of = self.on

    def move(self, to):
        up = to["scale"] > self.on["scale"]
        self.moves.append((self.on["id"], to["id"]))
        self.on = to
        self.rate_lag = self.lag_frames
        self.scale_lag = self.lag_frames + (self.scale_up_lag if up else 0)
        if not self.rate_lag:
            self.follow_rate()
        if not self.scale_lag:
            self.follow_scale()

    def rpc(self, method, params=None, timeout=60):
        params = params or {}
        if method == "debug.cef":
            return {"backend": self.backend}
        if method == "action.run":
            return {"ok": True}
        if method == "debug.window_frame":
            if "screen" in params:
                self.sleep(self.latency_ms / 1000)
                self.move(self.displays[params["screen"]])
                self.frame = [self.on["bounds"][0] + 100, 100, 800, 600]
            if "frame" in params:
                self.sleep(self.latency_ms / 1000)
                self.frame = params["frame"]
                if self.frame == self.start_frame and self.on is not self.start_display:
                    self.move(self.start_display)
            return {"frame": self.frame, "screen_frame": appkit(self.on)}
        raise AssertionError(f"unexpected method {method}")

    def page_eval(self, script):
        self.sleep(self.latency_ms / 1000)
        value = self.evaluate(script)
        self.sleep(self.latency_ms / 1000)
        return value

    def evaluate(self, script):
        if script.startswith("document.title"):
            return True
        if script == "performance.now()":
            return self.now
        if script == "[Date.now(), performance.now()]":
            return [math.floor(self.WALL_MS + self.now), self.now]
        if script.startswith("__framesSince("):
            at = float(script[len("__framesSince("):-1])
            return [f for f in self.frames if f[0] >= at]
        raise AssertionError(f"unexpected script {script}")

    def run(self):
        return display.run(self.rpc, lambda check, *_: check(), self.page_eval, "file:///display.html", self.sleep,
                           displays=lambda: self.displays, clock=self.clock)


class DisplayRowTests(unittest.TestCase):
    def test_a_page_that_follows_the_display_passes(self):
        app = FakeApp([PANEL, EXTERNAL])
        row, ok = app.run()
        self.assertTrue(ok)
        self.assertTrue(row["start"]["pass"], row["start"])
        self.assertAlmostEqual(row["start"]["raf_per_s"], 120, delta=1)
        self.assertEqual(row["start"]["dpr"], 2.0)
        move = row["move"]
        self.assertEqual(move["landed"], 2)
        self.assertLessEqual(move["frames_to_rate"], display.MOVE_FRAMES)
        self.assertLessEqual(move["frames_to_scale"], display.SCALE_FRAMES)
        self.assertAlmostEqual(move["there"]["raf_per_s"], 60, delta=1)
        self.assertEqual(row["back"]["landed"], 1)
        self.assertAlmostEqual(row["back"]["there"]["raf_per_s"], 120, delta=1)
        self.assertTrue(row["pass"], row)
        self.assertEqual(app.frame, app.start_frame, "the window goes back")
        self.assertEqual(app.moves, [(1, 2), (2, 1)])

    def test_slow_rpcs_do_not_count_against_the_page(self):
        # Each RPC leg takes 5 frames at 120 Hz: the frames before the window moves are not the page's.
        row, ok = FakeApp([PANEL, EXTERNAL], latency_ms=5 * 1000 / 120).run()
        self.assertTrue(ok)
        self.assertLessEqual(row["move"]["frames_to_rate"], display.MOVE_FRAMES, row["move"])
        self.assertLessEqual(row["move"]["frames_to_scale"], display.SCALE_FRAMES, row["move"])
        self.assertTrue(row["pass"], row)

    def test_slow_rpcs_still_catch_a_slow_switch(self):
        row, _ = FakeApp([PANEL, EXTERNAL], latency_ms=5 * 1000 / 120, lag_frames=6).run()
        self.assertGreater(row["move"]["frames_to_rate"], display.MOVE_FRAMES)
        self.assertFalse(row["pass"])

    def test_both_directions_are_measured_and_1x_to_2x_is_its_own_field(self):
        # The window starts on the 2x panel: the 1x to 2x move is the way back.
        row, _ = FakeApp([PANEL, EXTERNAL]).run()
        up = row["scale_up"]
        self.assertEqual(up["move"], "back")
        self.assertEqual((up["from_scale"], up["to_scale"]), (1.0, 2.0))
        self.assertLessEqual(up["frames_to_scale"], display.SCALE_FRAMES)
        self.assertTrue(up["pass"])

        # It starts on the 1x external display: the first move is the 1x to 2x one.
        row, _ = FakeApp([PANEL, EXTERNAL], start=1).run()
        self.assertEqual(row["move"]["to"], 1)
        self.assertEqual(row["scale_up"]["move"], "move")
        self.assertTrue(row["pass"], row)

    def test_a_page_slow_only_going_to_2x_fails(self):
        row, _ = FakeApp([PANEL, EXTERNAL], scale_up_lag=3).run()
        self.assertTrue(row["move"]["pass"], "2x to 1x is on time")
        self.assertFalse(row["back"]["pass"])
        self.assertGreater(row["scale_up"]["frames_to_scale"], display.SCALE_FRAMES)
        self.assertFalse(row["scale_up"]["pass"])
        self.assertFalse(row["pass"])

    def test_displays_at_one_scale_have_no_scale_up_move(self):
        external_2x = dict(EXTERNAL, scale=2.0)
        row, _ = FakeApp([PANEL, external_2x]).run()
        self.assertIn("not_measurable", row["scale_up"])
        self.assertTrue(row["pass"], row)

    def test_a_page_left_on_the_first_display_fails(self):
        row, ok = FakeApp([PANEL, EXTERNAL], stuck=True).run()
        self.assertTrue(ok)
        self.assertFalse(row["move"]["pass"])
        self.assertFalse(row["move"]["there"]["pass"])
        self.assertFalse(row["pass"])

    def test_a_stale_device_pixel_ratio_fails(self):
        row, _ = FakeApp([PANEL, EXTERNAL], stale_scale=True).run()
        self.assertIsNone(row["move"]["frames_to_scale"])
        self.assertFalse(row["move"]["pass"])

    def test_a_slow_switch_fails(self):
        row, _ = FakeApp([PANEL, EXTERNAL], lag_frames=6).run()
        self.assertGreater(row["move"]["frames_to_rate"], display.MOVE_FRAMES)
        self.assertFalse(row["move"]["pass"])
        self.assertTrue(row["move"]["there"]["pass"], "it does get there")

    def test_one_display_leaves_the_move_not_measurable(self):
        row, ok = FakeApp([PANEL]).run()
        self.assertTrue(ok)
        self.assertIn("not_measurable", row["move"])
        self.assertTrue(row["pass"])

    def test_without_the_host_backend_the_row_does_not_run(self):
        row, ok = FakeApp([PANEL, EXTERNAL], backend="inproc").run()
        self.assertFalse(ok)
        self.assertIn("not_run", row)

    def test_a_display_with_no_reported_rate_is_judged_on_scale_only(self):
        builtin = dict(PANEL, hz=0.0)
        frames = [[i * 1000 / 120, 2.0] for i in range(121)]
        row = display.judge(frames, builtin)
        self.assertTrue(row["pass"])
        self.assertIn("rate_not_judged", row)

    def test_display_of_maps_appkit_frames_to_coregraphics_bounds(self):
        self.assertEqual(display.display_of(appkit(EXTERNAL), [PANEL, EXTERNAL]), EXTERNAL)
        self.assertEqual(display.display_of(appkit(PANEL), [PANEL, EXTERNAL]), PANEL)
        self.assertIsNone(display.display_of([5, 5, 10, 10], [PANEL, EXTERNAL]))
        self.assertIsNone(display.display_of(None, [PANEL]))


if __name__ == "__main__":
    unittest.main()
