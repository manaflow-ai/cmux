"""rivals: results.json (a synthetic two-app run written by `rivals.py report`) becomes rows per app."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import Context  # noqa: E402
from benches.rivals import BENCH, metric_of  # noqa: E402

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "rivals" / "results.json"


def ctx() -> Context:
    return Context(bench=BENCH, build={"channel": "nightly", "version": None, "sha": None}, host_role="fleet",
                   args={}, timestamp="2026-11-01T00:00:00Z")


def find(rows, metric, app):
    got = [r for r in rows if r["metric"] == metric and r["labels"].get("app") == app]
    assert len(got) == 1, (metric, app, len(got))
    return got[0]


class RivalsTest(unittest.TestCase):
    def test_rows_per_app(self):
        c = ctx()
        BENCH.ingest(c, FIXTURE)
        fresh = find(c.rows, "fresh_window", "claude")
        self.assertEqual((fresh["value"], fresh["unit"]), (2400.0, "ms"))
        warm = find(c.rows, "warm_window", "cmux")
        self.assertEqual((warm["value"], warm["n"]), (310.0, 2))
        self.assertEqual(find(c.rows, "fresh_cpu", "cmux")["unit"], "s")
        growth = find(c.rows, "soak_memory_growth_per_min", "claude")
        self.assertEqual((growth["value"], growth["unit"]), (1.2, "MB"))
        self.assertEqual(find(c.rows, "soak_wakeups", "cmux")["unit"], "per_s")
        self.assertAlmostEqual(find(c.rows, "soak_disk", "cmux")["value"], 3.0 * 8.192, places=3)
        self.assertEqual(find(c.rows, "soak_processes", "claude")["unit"], "count")
        self.assertEqual(len(c.rows), 18)
        self.assertEqual(c.host["name"], "cmux20")
        self.assertEqual(c.build["version"], "1.0.0-nightly.1")
        self.assertEqual(c.rows[0]["timestamp"], "2026-11-23T00:00:00Z")
        self.assertTrue(any("rex fresh-window: no bundle" in n for n in c.notes))

    def test_metric_names(self):
        self.assertEqual(metric_of("restart-memory-peak"), "restart_memory_peak")
        self.assertEqual(metric_of("soak-memory-growth"), "soak_memory_growth_per_min")


if __name__ == "__main__":
    unittest.main()
