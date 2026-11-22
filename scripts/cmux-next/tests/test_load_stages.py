"""load_stages.py on synthetic frames: a cold load's stages, the 1-frame opaque flash Leo saw (Leo, 2026-11-22: "dont
have stupid multi stage loading"), a page painting progressively as one stage, and capture noise as no stage."""
import os
import random
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import load_stages as ls  # noqa: E402
import tab_switch_cold as cold  # noqa: E402
import tab_switch_frames as frames_mod  # noqa: E402
import tab_switch_judge as judge  # noqa: E402

W, H = 64, 48
FRAME_MS = 1000 / 60
THEME = 0x1D  # #1d1d2d's gray, about 31


def gray_of(hex_rgb):
    r, g, b = (int(hex_rgb[i:i + 2], 16) for i in (1, 3, 5))
    return (299 * r + 587 * g + 114 * b) // 1000


def flat(level):
    return bytes([level]) * (W * H)


def textured(seed, lo, hi):
    rng = random.Random(seed)
    return bytes(rng.randrange(lo, hi) for _ in range(W * H))


def page(background, foreground, seed=3):
    """A page: its background with 'text' rows of the foreground."""
    rng = random.Random(seed)
    out = bytearray([background]) * (W * H)
    for y in range(4, H - 4, 6):
        for x in range(4, W - 4):
            if rng.random() < 0.6:
                out[y * W + x] = foreground
                out[(y + 1) * W + x] = foreground
    return bytes(out)


def noisy(frame, seed, amount=2):
    rng = random.Random(seed)
    return bytes(min(255, max(0, v + rng.randint(-amount, amount))) for v in frame)


def timeline(pictures, mark=10.0):
    """[(seconds, frame)] one display frame apart, the first at the mark (the frame before the action)."""
    return [(mark + i * FRAME_MS / 1000, p) for i, p in enumerate(pictures)]


TERMINAL = textured(1, 0, 60)
GLASS = textured(2, 40, 70)  # the translucent ground: the desktop blurred through the pane
DARK_PAGE = page(0, 230)
LIGHT_PAGE = page(255, 30)
FLASH = flat(gray_of("#1d1d2d"))


def stages(pictures, **kw):
    frames = timeline(pictures)
    return ls.count_stages(frames, W, mark=frames[0][0], frame_ms=FRAME_MS, **kw)


class ColdLoads(unittest.TestCase):
    def test_ground_then_page_is_two_stages(self):
        got = stages([TERMINAL, GLASS, GLASS, GLASS] + [LIGHT_PAGE] * 6)
        self.assertEqual([s["kind"] for s in got], ["ground", "page"])
        self.assertTrue(ls.verdict(got))
        self.assertEqual(got[0]["frames"], 3)
        self.assertAlmostEqual(ls.first_paint_ms(got), 4 * FRAME_MS, places=1)

    def test_one_flat_theme_frame_between_grounds_is_four_stages(self):
        # Leo's NIGHTLY: glass, ONE opaque #1d1d2d frame at the commit, glass again, the page.
        for final in (LIGHT_PAGE, DARK_PAGE):
            got = stages([TERMINAL, GLASS, GLASS, FLASH, GLASS, GLASS] + [final] * 6)
            self.assertEqual([s["kind"] for s in got], ["ground", "flat", "ground", "page"])
            self.assertEqual(got[1]["frames"], 1)
            self.assertFalse(ls.verdict(got))
            self.assertEqual(got[1]["mean_rgb"][0], float(gray_of("#1d1d2d")))

    def test_progressive_paint_over_ten_frames_is_one_page_stage(self):
        frames = [TERMINAL, GLASS, GLASS]
        for k in range(1, 11):  # the page paints top down, a tenth more each frame
            rows = H * k // 10
            frames.append(LIGHT_PAGE[:rows * W] + GLASS[rows * W:])
        frames += [LIGHT_PAGE] * 4
        got = stages(frames)
        self.assertEqual([s["kind"] for s in got], ["ground", "page"])
        self.assertTrue(ls.verdict(got))

    def test_white_flash_before_a_dark_page_is_three_stages(self):
        got = stages([TERMINAL, GLASS, GLASS, flat(255)] + [DARK_PAGE] * 6)
        self.assertEqual([s["kind"] for s in got], ["ground", "flat", "page"])
        self.assertFalse(ls.verdict(got))

    def test_restored_last_frame_then_live_page_is_two_stages(self):
        stale = LIGHT_PAGE[:W * 20] + page(255, 90, seed=9)[W * 20:]  # the snapshot: the page as it was left
        got = stages([TERMINAL, stale, stale, stale] + [LIGHT_PAGE] * 4)
        self.assertEqual(len(got), 2)
        self.assertTrue(ls.verdict(got))

    def test_restored_frame_equal_to_the_page_is_one_stage(self):
        got = stages([TERMINAL] + [LIGHT_PAGE] * 6)
        self.assertEqual([s["kind"] for s in got], ["page"])

    def test_capture_noise_splits_no_stage(self):
        pictures = [TERMINAL] + [noisy(GLASS, i) for i in range(4)] + [noisy(LIGHT_PAGE, 10 + i) for i in range(6)]
        got = stages(pictures)
        self.assertEqual([s["kind"] for s in got], ["ground", "page"])
        flash = [TERMINAL] + [noisy(GLASS, i) for i in range(3)] + [noisy(FLASH, 5, 1)] + \
            [noisy(GLASS, 7 + i) for i in range(2)] + [noisy(LIGHT_PAGE, 20 + i) for i in range(4)]
        self.assertEqual(len(stages(flash)), 4)


class Details(unittest.TestCase):
    def test_flat_runs_of_two_colors_are_two_stages(self):
        got = stages([TERMINAL, GLASS, flat(255), flat(128), DARK_PAGE, DARK_PAGE])
        self.assertEqual([s["kind"] for s in got], ["ground", "flat", "flat", "page"])

    def test_page_background_before_its_text_is_the_page(self):
        got = stages([TERMINAL, GLASS, flat(255), LIGHT_PAGE, LIGHT_PAGE])
        self.assertEqual([s["kind"] for s in got], ["ground", "page"])

    def test_old_tab_coming_back_is_a_stage(self):
        got = stages([TERMINAL, GLASS, TERMINAL, GLASS, LIGHT_PAGE])
        self.assertEqual([s["kind"] for s in got], ["ground", "before", "ground", "page"])

    def test_a_long_frame_counts_its_display_frames(self):
        frames = [(10.0, TERMINAL), (10.001, GLASS), (10.001 + 3 * FRAME_MS / 1000, LIGHT_PAGE)]
        got = ls.count_stages(frames, W, mark=10.0, frame_ms=FRAME_MS)
        self.assertEqual(got[0]["frames"], 3)

    def test_rgb_and_buffer_frames(self):
        rgb = lambda g: bytes(v for x in g for v in (x, x, x))  # noqa: E731
        theme = bytes(v for _ in range(W * H) for v in (0x1D, 0x1D, 0x2D))
        frames = timeline([rgb(TERMINAL), rgb(GLASS), theme, rgb(GLASS), bytearray(rgb(LIGHT_PAGE))])
        got = ls.count_stages(frames, W, mark=frames[0][0], channels=3)
        self.assertEqual(len(got), 4)
        self.assertEqual(got[1]["mean_rgb"], [29.0, 29.0, 45.0])
        frames = timeline([memoryview(TERMINAL), memoryview(GLASS), memoryview(LIGHT_PAGE)])
        self.assertEqual(len(ls.count_stages(frames, W, mark=frames[0][0])), 2)

    def test_rect_reads_only_the_pane(self):
        # A flash outside the rect (the sidebar) is not the load's.
        outside = bytearray(GLASS)
        for y in range(H):
            outside[y * W:y * W + 16] = bytes([255]) * 16
        got = stages([TERMINAL, GLASS, bytes(outside), GLASS, LIGHT_PAGE], rect=(16, 0, W, H))
        self.assertEqual(len(got), 2)

    def test_measure_fields(self):
        frames = timeline([TERMINAL, GLASS, FLASH, GLASS, LIGHT_PAGE])
        out = ls.measure(frames, W, mark=frames[0][0], frame_ms=FRAME_MS)
        self.assertEqual(out["load_stages"], 4)
        self.assertIsNotNone(out["first_paint_ms"])
        self.assertIn("flat", out["stages_summary"])

    def test_nothing_after_the_old_tab_is_no_stage(self):
        self.assertEqual(stages([TERMINAL, TERMINAL]), [])
        self.assertEqual(ls.count_stages([], W), [])


class Budgets(unittest.TestCase):
    def test_a_cold_load_is_judged_on_its_stages_alone(self):
        ok = {"cold_load": True, "load_stages": 2, "to_content_ms": None, "wrong_frames": 9, "blank_frames": 1}
        self.assertEqual(judge.budget_fails(ok, "x"), [])
        bad = dict(ok, load_stages=4, stages_summary="ground > flat > ground > page")
        fails = judge.budget_fails(bad, "x")
        self.assertEqual(len(fails), 1)
        self.assertIn("4 visual stages, budget 2", fails[0])

    def test_stages_on_a_switch_add_to_its_frame_budgets(self):
        s = {"to_content_ms": 5.0, "display_frame_ms": 8.3, "blank_frames": 0, "wrong_frames": 0, "shift_px": 0,
             "load_stages": 3}
        self.assertEqual(len(judge.budget_fails(s, "x")), 1)
        self.assertEqual(judge.budget_fails(dict(s, load_stages=None), "x"), [])

    def test_scenarios_are_known_to_the_harness(self):
        self.assertIn("chromium-cold", judge.SCENARIOS)
        self.assertIn("chromium-reload", judge.MORE_SCENARIOS)
        self.assertIn("chromium-navigate", judge.MORE_SCENARIOS)
        self.assertEqual(set(cold.ALL) - set(judge.ALL_SCENARIOS), set())


class ColdHarness(unittest.TestCase):
    def test_fixtures_alternate_light_and_dark(self):
        order = cold.fixture_order()
        self.assertEqual(len(order), 9)
        self.assertTrue(all(a.split("-")[0] != b.split("-")[0] for a, b in zip(order[:8:2], order[1:8:2])))

    def test_a_load_is_judged_from_its_window(self):
        class Rec:
            w, h, frame_ms, scale = W, H, FRAME_MS, 1.0

        class Args:
            tolerance, out = 0.01, "/nonexistent"

        class FakeHarness:
            rec, args, content = Rec(), Args(), (0, 0, W, H)
            at, between = staticmethod(frames_mod.Harness.at), staticmethod(frames_mod.Harness.between)

            def foreign_over(self, label):
                return []

            def judge(self, window, mark, reference=None, strip=None):
                return judge.judge_switch(window, mark, W, self.content, FRAME_MS, reference=reference)

            def add_settle(self, switch, *a):
                switch["settled"] = True

            def keep_sheet(self, *a):
                pass

        c = cold.Cold.__new__(cold.Cold)
        c.h = FakeHarness()
        label = "chromium-cold/idle round 1 page 1"
        pictures = [TERMINAL, TERMINAL, GLASS, FLASH, GLASS] + [LIGHT_PAGE] * 5
        recorded = timeline(pictures, mark=10.0)
        flips = {f"{label}:leave": 10.0, f"{label}:mark": 10.001, f"{label}:end": recorded[-1][0] + 0.2}
        switch = c.judge({"label": label, "page": "light-text"}, recorded, flips)
        self.assertEqual(switch["load_stages"], 4)
        self.assertTrue(switch["cold_load"])
        self.assertTrue(switch["settled"])
        self.assertTrue(judge.budget_fails(switch, label))
        self.assertEqual(c.judge({"label": label, "error": "openBrowser.chromium: no"}, recorded, flips)["error"],
                         "openBrowser.chromium: no")


if __name__ == "__main__":
    unittest.main()
