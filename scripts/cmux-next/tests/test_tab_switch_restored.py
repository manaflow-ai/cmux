"""tab_switch_restored.py without an app: the switch plan visits every restored tab, the fixture server counts each
load and each mp4 body, hits land in the right switch's window, and the desktop and omnibar frame counts."""
import os
import sys
import unittest
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import tab_switch_judge as judge  # noqa: E402
import tab_switch_restored as restored  # noqa: E402

W, H = 8, 4
CONTENT = (0, 0, W, H)


def flat(v):
    return bytes([v]) * (W * H)


def striped(a, b):
    return bytes(a if (i // W) % 2 else b for i in range(W * H))


class PlanTests(unittest.TestCase):
    def test_every_tab_is_visited_first_then_revisited(self):
        for start in range(10):
            plan = restored.switch_plan(10, start)
            self.assertEqual(len(plan), restored.SWITCHES)
            self.assertEqual(sorted(t for _, t in plan[:9]), sorted(i for i in range(10) if i != start))
            current = start
            for kind, target in plan:
                self.assertNotEqual(target, current)
                if kind == "next":
                    self.assertEqual(target, (current + 1) % 10)
                current = target

    def test_ctrl_tab_steps_and_jumps_both_used(self):
        kinds = {kind for kind, _ in restored.switch_plan(10, 9)}
        self.assertEqual(kinds, {"next", "jump"})

    def test_plan_is_deterministic(self):
        self.assertEqual(restored.switch_plan(10, 3), restored.switch_plan(10, 3))


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.server = restored.FixtureServer()
        self.addCleanup(self.server.close)

    def get(self, path, headers=None):
        request = urllib.request.Request(self.server.url(path), headers=headers or {})
        try:
            with urllib.request.urlopen(request, timeout=10) as answer:
                return answer.status, answer.headers, answer.read()
        except urllib.error.HTTPError as error:
            return error.code, error.headers, b""

    def test_pages_are_no_store_and_counted(self):
        status, headers, body = self.get("/p/dark-text")
        self.assertEqual(status, 200)
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertIn(b"dark-text", body)
        self.get("/p/dark-text")
        self.assertEqual([h[1:3] for h in self.server.snapshot()], [("/p/dark-text", 200)] * 2)

    def test_mp4_ranges_and_revalidation(self):
        status, _, body = self.get(restored.MP4_PATH, {"Range": "bytes=0-99"})
        self.assertEqual((status, len(body)), (206, 100))
        status, headers, _ = self.get(restored.MP4_PATH, {"If-None-Match": '"clip-1"'})
        self.assertEqual(status, 304)
        hits = self.server.snapshot()
        windows = [(hits[0][0] - 1, hits[-1][0] + 1)]
        # One body (the 206); the 304 is the cache keeping the bytes, no download.
        self.assertEqual(restored.attribute(hits, windows, [None]), [(None, 1)])

    def test_urls_hold_ten_tabs_with_the_mp4(self):
        for real in (True, False):
            urls = restored.tab_urls(self.server, real)
            self.assertEqual(len(urls), restored.CHROMIUM_TABS)
            self.assertEqual(sum(u.endswith(restored.MP4_PATH) for u in urls), 1)
            self.assertEqual(any(u.startswith("https://") for u in urls), real)
            self.assertEqual(len(set(urls)), len(urls))


class AttributeTests(unittest.TestCase):
    def test_hits_land_in_their_switch_window(self):
        hits = [(1.5, "/p/a", 200, 10), (2.2, "/p/b", 200, 10), (2.4, "/p/a", 200, 10),
                (3.1, restored.MP4_PATH, 200, 99), (3.2, restored.MP4_PATH, 304, 0)]
        walls = {"s1:leave": 1.0, "s2:leave": 2.0, "s3:leave": 3.0}
        windows = restored.windows_of(walls, ["s1", "s2", "s3"], 4.0)
        self.assertEqual(windows, [(1.0, 2.0), (2.0, 3.0), (3.0, 4.0)])
        # s2's target is /p/b: /p/a's load in its window is another tab's (an eager restore), not s2's reload.
        self.assertEqual(restored.attribute(hits, windows, ["/p/a", "/p/b", None]), [(1, 0), (1, 0), (None, 1)])


class FrameTests(unittest.TestCase):
    def setUp(self):
        judge.QUANT = bytes(v >> 4 for v in range(256))

    def test_desktop_frames_count_the_wallpaper_not_the_old_or_new_tab(self):
        before, desktop, ref = flat(20), striped(200, 120), flat(240)
        frames = [(0.0, before), (0.010, desktop), (0.020, desktop), (0.030, ref)]
        n = restored.desktop_frames(frames, 0.005, W, CONTENT, desktop, ref, before, 10.0, 0.01)
        self.assertEqual(n, 2)
        self.assertEqual(restored.desktop_frames(frames, 0.005, W, CONTENT, None, ref, before, 10.0, 0.01), 0)

    def test_omnibar_frames_until_the_band_settles(self):
        band = (0, 0, W, 2)
        before, empty, ref = flat(20), flat(128), flat(240)
        frames = [(0.0, before), (0.01, before), (0.02, empty), (0.03, empty), (0.04, ref), (0.05, ref)]
        self.assertEqual(restored.omnibar_frames(frames, 0.005, W, band, ref, before, 0.01), 2)
        self.assertEqual(restored.omnibar_frames([(0.0, before), (0.01, ref)], 0.005, W, band, ref, before, 0.01), 0)


class BudgetTests(unittest.TestCase):
    def base(self, **over):
        switch = {"to_content_ms": 5.0, "display_frame_ms": 8.33, "blank_frames": 0, "wrong_frames": 0,
                  "shift_px": 0, "reloads": 0, "downloads_restarted": 0, "omnibar_frames": 0, "url": "u"}
        switch.update(over)
        return switch

    def test_counts_fail_and_null_does_not(self):
        self.assertEqual(judge.budget_fails(self.base(), "x"), [])
        self.assertEqual(judge.budget_fails(self.base(reloads=None), "x"), [])
        self.assertIn("x: the tab loaded again 1 times (u)", judge.budget_fails(self.base(reloads=1), "x"))
        self.assertIn("x: 2 downloads restarted", judge.budget_fails(self.base(downloads_restarted=2), "x"))
        self.assertIn("x: 3 frames of a wrong or empty omnibar", judge.budget_fails(self.base(omnibar_frames=3), "x"))

    def test_row_budget(self):
        self.assertEqual(restored.row_budget_fails("chromium-restored", "idle", {"downloads_restarted": 0}), [])
        self.assertEqual(len(restored.row_budget_fails("chromium-restored", "idle", {"downloads_restarted": 1})), 1)

    def test_default_scenarios_hold_both(self):
        for name in restored.SCENARIOS:
            self.assertIn(name, judge.SCENARIOS)


if __name__ == "__main__":
    unittest.main()
