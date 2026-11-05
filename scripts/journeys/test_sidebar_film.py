#!/usr/bin/env python3
"""ext_sidebar_film.measure: missed refreshes by the display link and rebuilt rows during the motion (no app).

    python3 -I scripts/journeys/test_sidebar_film.py
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ext_sidebar_film as film  # noqa: E402

P = 1 / 120


def frames(gap_at=None, gap_periods=4, rebuild_at=None, still=False, ids=True):
    """40 display ticks at 120 Hz; row b moves 2 pt a frame from tick 10 to 24 unless `still`."""
    out, late = [], 0.0
    for i in range(40):
        if gap_at is not None and i == gap_at:
            late += (gap_periods - 1) * P
        t = 1000 + i * P + late
        y = 0 if still or i < 10 else min(28, (i - 10) * 2)
        frame = {"t": t + 0.001, "link": t, "target": t + P, "refresh": P, "scroll": 0,
                 "views": {"workspace(a)": [0, 0, 200, 28, 1.0], "workspace(b)": [0, 28 + y, 200, 28, 1.0]}}
        if ids:
            frame["ids"] = {"workspace(a)": "1", "workspace(b)": "3" if rebuild_at is not None and i >= rebuild_at else "2"}
        out.append(frame)
    return out


class MeasureTests(unittest.TestCase):
    def test_smooth_motion_has_no_miss_and_no_rebuild(self):
        m = film.measure(frames())
        self.assertEqual(m["hz"], 120.0)
        self.assertEqual(m["clock"], "link")
        self.assertEqual(m["window"]["missed_refreshes"], 0)
        self.assertEqual(m["rebuilt_frames"], 0)
        self.assertEqual(m["motion_frames"], 14)

    def test_a_four_period_gap_in_the_motion_misses_three_refreshes(self):
        m = film.measure(frames(gap_at=15))
        self.assertEqual(m["window"]["missed_refreshes"], 3)
        self.assertEqual(m["window"]["long_intervals"], 1)
        self.assertAlmostEqual(m["window"]["worst_ms"], 4 * P * 1000, places=1)

    def test_a_gap_after_the_motion_counts_in_the_whole_film_only(self):
        m = film.measure(frames(gap_at=35))
        self.assertEqual(m["window"]["missed_refreshes"], 0)
        self.assertEqual(m["whole"]["missed_refreshes"], 3)

    def test_a_new_view_for_a_listed_row_during_the_motion_is_a_rebuild(self):
        m = film.measure(frames(rebuild_at=15))
        self.assertEqual(m["rebuilt_frames"], 1)
        self.assertEqual(m["rebuilt"][0]["keys"], ["workspace(b)"])

    def test_an_older_build_without_ids_reports_rebuilds_as_unknown(self):
        m = film.measure(frames(ids=False))
        self.assertFalse(m["ids_known"])
        self.assertIsNone(m["rebuilt_frames"])

    def test_no_motion_gives_an_empty_window(self):
        m = film.measure(frames(still=True))
        self.assertEqual(m["motion_frames"], 0)
        self.assertEqual(m["window"]["missed_refreshes"], 0)


if __name__ == "__main__":
    unittest.main()
