from __future__ import annotations

import sys
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import Context  # noqa: E402
from benches.stress import BENCH  # noqa: E402

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "stress" / "report.json"


class StressTest(unittest.TestCase):
    def test_ingest_records_all_shared_metrics(self):
        ctx = Context(bench=BENCH, build={"channel": "nightly", "version": "n", "sha": None}, host_role="fleet",
                      timestamp="2026-11-21T00:00:00Z")
        BENCH.ingest(ctx, FIXTURE)
        values = {(row["metric"], row["labels"]["scenario"], row["labels"]["ramp"]): row["value"] for row in ctx.rows}
        self.assertEqual(values[("frame_rate_fps", "terminals", "flood")], 48.5)
        self.assertEqual(values[("input_to_paint_p95", "terminals", "flood")], 22.0)
        self.assertEqual(values[("hangs_count", "terminals", "flood")], 2.0)
        self.assertEqual(values[("disk_growth_mb", "terminals", "flood")], 2.0)
        self.assertEqual(values[("recovered", "terminals", "flood")], 1.0)
        self.assertTrue(any("main-thread hangs" in note for note in ctx.notes))

    def test_rejects_wrong_report(self):
        ctx = Context(bench=BENCH, build={"channel": "local"}, host_role="fleet")
        with self.assertRaises(Exception):
            BENCH.ingest(ctx, Path(__file__))


if __name__ == "__main__":
    unittest.main()
