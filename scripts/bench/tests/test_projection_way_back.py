"""projection-way-back: a real a_bench_of_bring_back log (Linux fleet pool, cmux PR 45832 at 6da03373d572) -> rows."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benches.projection_way_back import BENCH  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "projection-way-back"


def ingest(path):
    ctx = Context(bench=BENCH, build={"channel": "sha", "version": None, "sha": "d" * 40}, host_role="fleet",
                  timestamp="2026-11-18T00:00:00Z")
    BENCH.ingest(ctx, path)
    return ctx


class ProjectionWayBackTest(unittest.TestCase):
    def test_both_paths_and_the_plan(self):
        rows = ingest(FIXTURES / "bench.log").rows
        got = {(r["metric"], r["labels"]["path"]): r["value"] for r in rows}
        self.assertEqual(got[("bring_back", "copy (today)")], 61133)
        self.assertEqual(got[("bring_back", "projected")], 213)
        self.assertEqual(got[("plan", "projected")], 0)
        self.assertEqual(got[("plan_only", "plan only (in memory)")], 24)
        self.assertTrue(all(r["labels"]["files"] == "100000" for r in rows))

    def test_a_log_without_rows_is_refused(self):
        with self.assertRaises(BenchError):
            ingest(Path(__file__))

if __name__ == "__main__":
    unittest.main()
