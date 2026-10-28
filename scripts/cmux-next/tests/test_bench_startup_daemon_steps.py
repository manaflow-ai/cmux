#!/usr/bin/env python3
"""bench-startup.py's rows for the daemon's own start (p08-startup-093).

1. MARKS lists each daemon step (identify {startup_marks}) once, in the daemon's start order.
2. daemon_steps_summary names the step with the largest p50 gap from the step before it, and says nothing for runs
   without daemon steps (a warm run attaches to a running daemon; an older daemon reports none).

Runs on any host (Linux included): no app, no fleet.

    python3 scripts/cmux-next/tests/test_bench_startup_daemon_steps.py
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

STEPS = [
    "daemon.main_start",
    "daemon.config_loaded",
    "daemon.owner_prepared",
    "daemon.socket_bound",
    "daemon.mux_restored",
    "daemon.owner_event_loop",
    "daemon.websocket_ready",
    "daemon.launch_snapshot_writer_started",
    "daemon.lifecycle_ready",
    "daemon.first_identify_served",
]


def cold_run(restore_ms=40.0, offset=0.0):
    """A cold run whose daemon spends `restore_ms` restoring and 1 ms on every other step."""
    run = {"main_start": 20.0, "daemon.spawned": 400.0 + offset}
    at = 200.0 + offset
    for step in STEPS:
        at += restore_ms if step == "daemon.mux_restored" else 1.0
        run[step] = at
    return run


class MarksTests(unittest.TestCase):
    def test_each_daemon_step_is_listed_once_in_start_order(self):
        names = [mark for mark, _ in bench.MARKS]
        for name in STEPS:
            self.assertEqual(names.count(name), 1, name)
        self.assertEqual([name for name in names if name in STEPS], STEPS)


class SummaryTests(unittest.TestCase):
    def test_names_the_slowest_daemon_step(self):
        line = bench.daemon_steps_summary([cold_run(40.0, offset) for offset in range(10)])
        self.assertIn("slowest step daemon: registry and terminals restored (daemon.mux_restored) p50 40.0 ms", line)
        self.assertIn("n 10", line)
        self.assertIn("main() -> first identify p50 48.0 ms", line)

    def test_a_missing_step_measures_the_next_one_from_the_step_reached_before(self):
        run = cold_run(5.0)
        del run["daemon.websocket_ready"]
        run["daemon.launch_snapshot_writer_started"] += 30.0
        line = bench.daemon_steps_summary([run])
        self.assertIn("(daemon.launch_snapshot_writer_started) p50 32.0 ms", line)

    def test_runs_without_daemon_steps_have_no_line(self):
        warm = {"main_start": 20.0, "daemon.identified": 90.0}
        self.assertIsNone(bench.daemon_steps_summary([warm]))
        self.assertIsNone(bench.daemon_steps_summary([]))


if __name__ == "__main__":
    unittest.main()
