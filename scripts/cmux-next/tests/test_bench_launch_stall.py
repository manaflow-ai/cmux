#!/usr/bin/env python3
"""bench-launch-stall.py's verdict on a `debug.hangs` reply (p08-startup-088): a pass needs a stall of the asked length
listed with the main-phase startup tag of `bench.launch_stall`; a watchdog started after main() lists none.

No app, build or GUI session.

    python3 scripts/cmux-next/tests/test_bench_launch_stall.py
"""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "bench-launch-stall.py"


def load_bench():
    spec = importlib.util.spec_from_file_location("bench_launch_stall", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FindLaunchStallTests(unittest.TestCase):
    def setUp(self):
        self.bench = load_bench()

    def test_a_tagged_stall_of_the_length_passes(self):
        reply = {"installed": True, "records": [
            {"kind": "stall", "duration_ms": 52.0},
            {"kind": "stall", "duration_ms": 301.4, "startup_phase": "main", "startup_task": "bench.launch_stall"},
        ]}
        result = self.bench.find_launch_stall(reply, 300)
        self.assertTrue(result["ok"])
        self.assertEqual(result["startup_task"], "bench.launch_stall")
        self.assertEqual(result["stalls"], 2)

    def test_a_watchdog_started_after_main_lists_no_stall(self):
        result = self.bench.find_launch_stall({"installed": True, "records": [{"kind": "stall", "duration_ms": 60}]}, 300)
        self.assertFalse(result["ok"])
        self.assertIn("not running in main()", result["reason"])

    def test_an_untagged_stall_of_the_length_fails(self):
        reply = {"installed": True, "records": [{"kind": "stall", "duration_ms": 320, "startup_phase": "critical"}]}
        result = self.bench.find_launch_stall(reply, 300)
        self.assertFalse(result["ok"])
        self.assertEqual(result["startup_phase"], "critical")
        self.assertIn("without the main-phase startup tag", result["reason"])

    def test_busy_records_are_not_stalls(self):
        reply = {"installed": True, "records": [{"kind": "busy", "duration_ms": 900, "startup_phase": "main",
                                                 "startup_task": "bench.launch_stall"}]}
        self.assertFalse(self.bench.find_launch_stall(reply, 300)["ok"])

    def test_no_reply_is_a_miss(self):
        result = self.bench.find_launch_stall(None, 300)
        self.assertFalse(result["ok"])
        self.assertFalse(result["installed"])


if __name__ == "__main__":
    unittest.main()
