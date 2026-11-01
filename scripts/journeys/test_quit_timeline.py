#!/usr/bin/env python3
"""quit_speed reads the app's own per-terminal launch timeline from main(), no fleet, no app.

    python3 scripts/journeys/test_quit_timeline.py

`debug.timings` `launch_terminals` gives, per terminal a pane showed at launch, when its saved frame and its
first live content committed and when its link to the daemon went live, on the launch marks' clock. A
terminal's first frame is the earlier frame; it is interactive once that frame is up and its link is live.
The cycle's numbers are the slowest terminal's; one terminal with no mark censors them (never dropped).
"""
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE.parent / "cmux-next")]
import ext_quit  # noqa: E402

MAIN = 1000.0


def sub(mark):
    return round(mark - MAIN, 1) if isinstance(mark, (int, float)) else None


def entry(key, held=None, live=None, link=None, shown=1100.0):
    return {"key": key, "shown_ms": shown, "held_frame_ms": held, "live_frame_ms": live, "link_live_ms": link}


class AppTimeline(unittest.TestCase):
    def test_the_slowest_terminal_gives_the_cycle_numbers(self):
        got = ext_quit.app_timeline([entry("tab_a", held=1150, live=1300, link=1250),
                                     entry("tab_b", live=1200, link=1400)], sub)
        self.assertEqual(got["app_terminals"], 2)
        self.assertEqual([x["frame_ms"] for x in got["app_timeline"]], [150.0, 200.0])
        self.assertEqual([x["interactive_ms"] for x in got["app_timeline"]], [250.0, 400.0])
        self.assertEqual((got["app_all_frames_ms"], got["app_interactive_ms"], got["app_censored"]), (200.0, 400.0, False))

    def test_a_terminal_with_no_live_link_censors_the_cycle(self):
        got = ext_quit.app_timeline([entry("tab_a", held=1150, link=1250), entry("tab_b", held=1160)], sub)
        self.assertEqual((got["app_all_frames_ms"], got["app_interactive_ms"], got["app_censored"]), (160.0, None, True))

    def test_an_app_without_the_timeline_reports_none(self):
        got = ext_quit.app_timeline(None, sub)
        self.assertIsNone(got["app_terminals"])
        self.assertIsNone(got["app_censored"])


if __name__ == "__main__":
    unittest.main()
