#!/usr/bin/env python3
"""bench-startup.py's Chrome-parity startup milestones (p08-startup-002).

1. MARKS lists each milestone once, in launch order.
2. `--milestones` (check_milestones) passes a run that has every milestone in order, names each missing
   milestone, and names each MILESTONE_ORDER pair a run has out of order.
3. With `--milestones` a run that reached its first frames also waits for every milestone, only for the time
   left of its one timeout; a run that missed them, or one without the flag, ends there.
4. startup_complete is listed and order-checked when it lands, but not required (--startup-complete waits for it).

Runs on any host (Linux included): no app, no fleet.

    python3 scripts/cmux-next/tests/test_bench_startup_milestones.py
"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
SPEC = importlib.util.spec_from_file_location("bench_startup", HERE / "bench-startup.py")
bench = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bench)

NEW = ["run_loop_start", "first_idle", "window_display", "first_page_frame", "first_live_content_frame",
       "startup_complete"]


def good_run():
    return {"main_start": 20.0, "main.run": 40.0, "run_loop_start": 41.0, "did_finish_launching_end": 90.0,
            "window_display": 85.0, "launch_snapshot_shown": 86.0, "first_idle": 120.0, "first_window_frame_committed": 110.0,
            "first_live_content_frame": 300.0, "startup_complete": 800.0}


class MarksTests(unittest.TestCase):
    def test_each_new_milestone_is_listed_once(self):
        names = [mark for mark, _ in bench.MARKS]
        for name in NEW:
            self.assertEqual(names.count(name), 1, name)
        self.assertEqual(len(names), len(set(names)))

    def test_milestones_are_in_launch_order_in_marks(self):
        names = [mark for mark, _ in bench.MARKS]
        positions = [names.index(name) for name in bench.MILESTONES]
        self.assertEqual(positions, sorted(positions))
        self.assertLess(names.index("main.run"), names.index("run_loop_start"))
        self.assertLess(names.index("did_finish_launching_end"), names.index("first_idle"))
        self.assertLess(names.index(bench.FINAL_MARK), names.index("first_live_content_frame"))
        # LaunchSnapshotWindow marks launch_snapshot_shown after makeController presented the window.
        self.assertLess(names.index("window_display"), names.index("launch_snapshot_shown"))
        self.assertLess(names.index("first_live_content_frame"), names.index("startup_complete"))

    def test_order_pairs_name_listed_marks(self):
        names = {mark for mark, _ in bench.MARKS}
        for pair in bench.MILESTONE_ORDER:
            first, _, second = pair.partition("<")
            self.assertIn(first, names, pair)
            self.assertIn(second, names, pair)


class CheckMilestonesTests(unittest.TestCase):
    def test_complete_ordered_runs_pass(self):
        self.assertEqual(bench.check_milestones({"a": {"warm": [good_run(), good_run()]}}), [])

    def test_missing_milestone_is_named_once(self):
        run = good_run()
        del run["first_idle"]
        out = bench.check_milestones({"a": {"warm": [good_run(), run]}})
        self.assertEqual(out, ["a warm run 2: milestones missing: first_idle"])

    def test_startup_complete_is_not_required(self):
        self.assertNotIn("startup_complete", bench.MILESTONES)
        run = good_run()
        del run["startup_complete"]
        self.assertEqual(bench.check_milestones({"a": {"warm": [run]}}), [])

    def test_startup_complete_before_live_content_is_named(self):
        run = good_run()
        run["startup_complete"] = 200.0
        out = bench.check_milestones({"a": {"warm": [run]}})
        self.assertEqual(len(out), 1)
        self.assertIn("startup_complete at 200 ms, before first_live_content_frame", out[0])

    def test_out_of_order_pair_is_named(self):
        run = good_run()
        run["first_idle"] = 60.0  # before applicationDidFinishLaunching ended
        out = bench.check_milestones({"a": {"warm": [run]}})
        self.assertEqual(len(out), 1)
        self.assertIn("first_idle at 60 ms, before did_finish_launching_end", out[0])


class FakeLaunch:
    """Stands in for bench-startup's Launch: records what each run waited for, and how long."""
    waits = []
    reaches = True

    def __init__(self, tag, scratch, extra_env=None):
        self.marks = {**good_run(), "first_terminal_frame": 290.0}

    def wait_for(self, mark, timeout, any_of=False):
        FakeLaunch.waits.append(([mark] if isinstance(mark, str) else list(mark), any_of, timeout))
        return FakeLaunch.reaches

    def quit(self):
        pass


class OneRunWaitTests(unittest.TestCase):
    def setUp(self):
        self.saved = {name: getattr(bench, name) for name in ("Launch", "app_pids", "tag_pids", "WAIT_MILESTONES")}
        bench.Launch = FakeLaunch
        bench.app_pids = lambda tag: []
        bench.tag_pids = lambda tag: [4242]  # the daemon runs: a warm run needs no priming launch
        FakeLaunch.waits = []
        FakeLaunch.reaches = True

    def tearDown(self):
        for name, value in self.saved.items():
            setattr(bench, name, value)

    def test_milestones_flag_waits_for_every_milestone(self):
        bench.WAIT_MILESTONES = True
        bench.one_run("t", "warm", 5)
        self.assertEqual(len(FakeLaunch.waits), 3)
        marks, any_of, timeout = FakeLaunch.waits[1]
        self.assertEqual((marks, any_of), (bench.MILESTONES, False))
        self.assertLessEqual(timeout, 5, "the milestone wait shares the run's one timeout")
        self.assertEqual(FakeLaunch.waits[2], (list(bench.THREAD_MARKS), False, bench.THREAD_MARKS_WAIT_S),
                         "then p08-startup-068's thread census, sent after the first frame")

    def test_a_run_that_missed_its_first_frames_does_not_wait_again(self):
        bench.WAIT_MILESTONES = True
        FakeLaunch.reaches = False
        bench.one_run("t", "warm", 5)
        self.assertEqual(len(FakeLaunch.waits), 1)

    def test_without_the_flag_a_run_ends_at_its_first_frames(self):
        bench.WAIT_MILESTONES = False
        bench.one_run("t", "warm", 5)
        self.assertEqual(len(FakeLaunch.waits), 2, "the first frames, then the thread census (p08-startup-068)")
        self.assertNotIn("startup_complete", FakeLaunch.waits[0][0])
        self.assertEqual(FakeLaunch.waits[1][0], list(bench.THREAD_MARKS))


if __name__ == "__main__":
    unittest.main()
