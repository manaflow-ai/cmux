import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import cmux_next_ios_timing as t  # noqa: E402

COLD = [
    "2026 proc: timing launch first_frame (410ms)",
    "2026 proc: timing launch dial_start +120ms (530ms) websocket",
    "2026 proc: timing launch link_connected +900ms (1310ms) a=1",
    "2026 proc: timing launch terminal_ready (1500ms)",
]
WARM = [
    "x: timing foreground begin (40000 since process start)",
    "x: timing foreground link_alive +80ms (40080ms) 9 ms",
    "x: timing foreground terminal_frame +210ms",
]
BROWSER = [
    "x: timing event scenario_open_browser (900ms)",
    "x: timing event scenario_switch_to_terminal (4000ms)",
    "x: timing launch terminal_ready (4350ms)",
]


class TimingTests(unittest.TestCase):
    def test_cold(self):
        run = t.parse_run(COLD)
        self.assertEqual(t.metric("cold", run), 1500)
        self.assertEqual(run["stages"]["launch.link_connected"], 900)
        self.assertFalse(t.offline_shown(run))

    def test_warm(self):
        self.assertEqual(t.metric("warm", t.parse_run(WARM)), 210)

    def test_browser_is_measured_from_the_switch_and_offline_is_seen(self):
        run = t.parse_run(BROWSER + ["x: timing launch terminal_offline_shown +1200ms (2100ms)"])
        self.assertEqual(t.metric("browser", run), 350)
        self.assertTrue(t.offline_shown(run))

    def test_a_terminal_ready_before_the_switch_is_not_a_measurement(self):
        run = t.parse_run(["timing event scenario_switch_to_terminal (4000ms)", "timing launch terminal_ready (3000ms)"])
        self.assertIsNone(t.metric("browser", run))

    def test_summary_medians(self):
        runs = [t.parse_run(["timing launch terminal_ready (%dms)" % ms]) for ms in (900, 1500, 1200, 5000, 1100)]
        s = t.summarize({"cold": runs})["cold"]
        self.assertEqual(s["open_to_first_terminal_frame_ms"]["median"], 1200)
        self.assertEqual(s["measured"], 5)
        self.assertIn("cold launch", t.markdown({"cold": s}, {"runs": 5, "device": "d", "ref": "r", "background_seconds": 30}))

    def test_a_missing_run_is_none(self):
        s = t.summarize({"warm": [t.parse_run(WARM), t.parse_run([])]})["warm"]
        self.assertEqual(s["measured"], 1)
        self.assertEqual(s["open_to_first_terminal_frame_ms"]["median"], 210)


if __name__ == "__main__":
    unittest.main()
