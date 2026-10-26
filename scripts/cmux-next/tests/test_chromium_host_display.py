#!/usr/bin/env python3
"""chromium_host_display.py, the --modes display row of chromium-host-bench.py (p01-process-221), against a fake app
and fake displays: a page that follows the window's display passes; a page whose rAF stays at the old display's rate
after a move (the host's page window left on the first display), whose devicePixelRatio stays at the old scale, or that
takes too many frames to switch fails its row; one display leaves the move not measurable; a build without the host
backend does not run. Runs anywhere (no app, no CoreGraphics).
Run: python3 -I scripts/cmux-next/tests/test_chromium_host_display.py"""
import os, sys, unittest

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
    never changes."""

    def __init__(self, displays, backend="host", lag_frames=0, stuck=False, stale_scale=False):
        self.displays, self.backend = displays, backend
        self.lag_frames, self.stuck, self.stale_scale = lag_frames, stuck, stale_scale
        self.now = 0.0
        self.frames = []
        self.on = displays[0]
        self.rate_of, self.scale_of = displays[0], displays[0]
        self.lag = 0
        self.frame = [100, 100, 800, 600]

    def sleep(self, seconds):
        end = self.now + seconds * 1000
        while True:
            period = 1000 / self.rate_of["hz"]
            if self.now + period > end:
                break
            self.now += period
            self.frames.append([round(self.now, 3), self.scale_of["scale"]])
            if self.lag:
                self.lag -= 1
                if not self.lag:
                    self.follow()
        self.now = end

    def follow(self):
        if not self.stuck:
            self.rate_of = self.on
        if not self.stale_scale:
            self.scale_of = self.on

    def rpc(self, method, params=None, timeout=60):
        params = params or {}
        if method == "debug.cef":
            return {"backend": self.backend}
        if method == "action.run":
            return {"ok": True}
        if method == "debug.window_frame":
            if "screen" in params:
                self.on = self.displays[params["screen"]]
                self.lag = self.lag_frames
                if not self.lag:
                    self.follow()
            if "frame" in params:
                self.frame = params["frame"]
            return {"frame": self.frame, "screen_frame": appkit(self.on)}
        raise AssertionError(f"unexpected method {method}")

    def page_eval(self, script):
        if script.startswith("document.title"):
            return True
        if script == "performance.now()":
            return self.now
        if script.startswith("__framesSince("):
            at = float(script[len("__framesSince("):-1])
            return [f for f in self.frames if f[0] >= at]
        raise AssertionError(f"unexpected script {script}")

    def run(self):
        return display.run(self.rpc, lambda check, *_: check(), self.page_eval, "file:///display.html", self.sleep,
                           displays=lambda: self.displays)


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
        self.assertTrue(row["pass"], row)
        self.assertEqual(app.frame, [100, 100, 800, 600], "the window goes back")

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
