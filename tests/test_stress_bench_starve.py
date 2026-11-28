#!/usr/bin/env python3
"""stress-bench.py's starve angle: the stall counts it reads from debug.hangs and its recovery clock (no app)."""
import importlib.util
import os
import sys
import tempfile
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "cmux-next", "stress-bench.py")


def load():
    out = tempfile.mkdtemp(prefix="stress-starve-test-")
    argv = sys.argv
    sys.argv = [SCRIPT, "--app", "/nonexistent.app", "--tag", "t", "--out", out, "--angles", "starve"]
    try:
        spec = importlib.util.spec_from_file_location("stress_bench_starve", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    finally:
        sys.argv = argv
    return module


class StarveAngle(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bench = load()

    def test_starve_is_opt_in(self):
        self.assertNotIn("starve", self.bench.ANGLES)
        self.assertIn("starve", self.bench.OPT_IN_ANGLES)

    def test_stalls_counted_at_spin_and_not_responding(self):
        hangs = {"count": 4, "max_ms": 6100.0,
                 "records": [{"duration_ms": 120}, {"duration_ms": 2400}, {"duration_ms": 6100}, {"other": 1}]}
        got = self.bench.stall_counts(hangs)
        self.assertEqual((got["stalls"], got["stalls_listed"], got["stalls_over_2s"], got["stalls_over_5s"]), (4, 3, 2, 1))

    def test_unreadable_hangs_is_unknown_not_zero(self):
        self.assertIsNone(self.bench.stall_counts({"error": "x"})["stalls"])
        self.assertIsNone(self.bench.stall_counts(None)["stalls"])

    def test_recovery_needs_keys_in_a_row(self):
        trips = iter([400.0, 30.0, 30.0, None, 30.0, 30.0, 30.0])
        with mock.patch.object(self.bench, "key_trip_ms", lambda: next(trips)), \
                mock.patch.object(self.bench.time, "sleep", lambda s: None):
            seconds, seen = self.bench.recovery(50.0, 30.0, 3)
        self.assertIsNotNone(seconds)
        self.assertEqual(len(seen), 7)

    def test_never_recovering_reports_none(self):
        clock = iter(range(0, 10_000))
        with mock.patch.object(self.bench, "key_trip_ms", lambda: 900.0), \
                mock.patch.object(self.bench.time, "sleep", lambda s: None), \
                mock.patch.object(self.bench.time, "monotonic", lambda: float(next(clock))):
            seconds, seen = self.bench.recovery(50.0, 5.0, 3)
        self.assertIsNone(seconds)
        self.assertTrue(seen)


if __name__ == "__main__":
    unittest.main()
