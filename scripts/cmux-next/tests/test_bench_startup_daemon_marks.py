#!/usr/bin/env python3
"""bench-startup.py's daemon connect milestones (p08-startup-066).

1. MARKS lists daemon.connect_started, daemon.spawned, daemon.identified and daemon.snapshot_received once each,
   in launch order.
2. The table gives each a row with its p50 gap from the row before, in the order the marks landed; a warm run
   (no daemon spawned) has no daemon.spawned row.

Runs on any host (Linux included): no app, no fleet.

    python3 scripts/cmux-next/tests/test_bench_startup_daemon_marks.py
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

MILESTONES = ["daemon.connect_started", "daemon.spawned", "daemon.identified", "daemon.snapshot_received"]


def cold_run(offset=0.0):
    return {"main_start": 20.0 + offset, "daemon.connect_started": 30.0 + offset, "main.prestart": 31.0 + offset,
            "daemon.ensure_end": 400.0 + offset, "daemon.spawned": 401.0 + offset,
            "daemon.handshake_end": 420.0 + offset, "daemon.identified": 421.0 + offset,
            "daemon.snapshot_end": 450.0 + offset, "daemon.snapshot_received": 451.0 + offset}


class MarksTests(unittest.TestCase):
    def test_each_milestone_is_listed_once_in_launch_order(self):
        names = [mark for mark, _ in bench.MARKS]
        for name in MILESTONES:
            self.assertEqual(names.count(name), 1, name)
        positions = [names.index(name) for name in MILESTONES]
        self.assertEqual(positions, sorted(positions))
        self.assertLess(names.index("daemon.connect_started"), names.index("daemon.connect_start"))
        self.assertLess(names.index("daemon.ensure_end"), names.index("daemon.spawned"))
        self.assertLess(names.index("daemon.handshake_end"), names.index("daemon.identified"))
        self.assertLess(names.index("daemon.snapshot_end"), names.index("daemon.snapshot_received"))


class TableTests(unittest.TestCase):
    def test_cold_runs_report_a_gap_for_each_milestone(self):
        rows = bench.table([cold_run(offset) for offset in range(10)])
        marks = [mark for _, mark, _, _, _ in rows]
        self.assertEqual([mark for mark in marks if mark in MILESTONES], MILESTONES)
        gaps = {mark: gap for _, mark, _, gap, _ in rows}
        self.assertAlmostEqual(gaps["daemon.spawned"], 1.0)
        self.assertAlmostEqual(gaps["daemon.identified"], 1.0)
        self.assertAlmostEqual(gaps["daemon.snapshot_received"], 1.0)
        self.assertTrue(all(count == 10 for _, mark, _, _, count in rows if mark in MILESTONES))

    def test_a_warm_run_has_no_spawn_row(self):
        warm = cold_run()
        del warm["daemon.spawned"]
        marks = [mark for _, mark, _, _, _ in bench.table([warm])]
        self.assertNotIn("daemon.spawned", marks)
        self.assertIn("daemon.identified", marks)


if __name__ == "__main__":
    unittest.main()
