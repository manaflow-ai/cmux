"""workspace-factory: a workspace-factory.sh log -> rows. The fixture has the harness's line shapes with made-up
numbers; it is replaced by the first real fleet log."""
from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benches.workspace_factory import BENCH  # noqa: E402

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "workspace-factory" / "shape.log"


def find(rows, metric, **labels):
    got = [r for r in rows if r["metric"] == metric and all(r["labels"].get(k) == v for k, v in labels.items())]
    assert len(got) == 1, (metric, labels, len(got))
    return got[0]


class WorkspaceFactoryTest(unittest.TestCase):
    def setUp(self):
        self.ctx = Context(bench=BENCH, build={"channel": "sha", "version": None, "sha": "d" * 40}, host_role="fleet",
                           timestamp="2026-11-17T00:00:00Z")
        BENCH.ingest(self.ctx, FIXTURE)
        self.rows = self.ctx.rows

    def test_arms(self):
        self.assertEqual(find(self.rows, "build", arm="cold")["value"], 240.0)
        factory = find(self.rows, "build", arm="factory")
        self.assertEqual((factory["value"], factory["n"]), (6.8, 3))
        self.assertEqual(find(self.rows, "start", arm="factory")["value"], 850.0)

    def test_cache_hit_against_cold(self):
        self.assertEqual(find(self.rows, "cache_hit", arm="factory")["value"], 99.0)
        self.assertEqual(find(self.rows, "cache_hit", arm="slot")["value"], 100.0)
        self.assertEqual(find(self.rows, "cache_hit", arm="cold")["better"], "higher")

    def test_disk_left(self):
        self.assertEqual(find(self.rows, "left", arm="slot")["value"], 2048.0)
        self.assertEqual(find(self.rows, "left", arm="factory")["value"], 0.0)
        self.assertEqual(find(self.rows, "home_left", arm="cold")["value"], 50.0)
        self.assertEqual(find(self.rows, "run_left", arm="run")["value"], 50.0)
        self.assertEqual(find(self.rows, "seed", arm="seed")["value"], 2048.0)
        self.assertEqual(self.ctx.host["name"], "cmux14")

    def test_failed_run_has_no_summary(self):
        with tempfile.TemporaryDirectory() as tmp:
            bad = Path(tmp) / "no-summary.log"
            bad.write_text("WSFACTORY {\"arm\":\"cold\",\"job\":1}\n")
            with self.assertRaises(BenchError):
                BENCH.ingest(Context(bench=BENCH, build={"channel": "sha", "version": None, "sha": "d" * 40},
                                     host_role="fleet", timestamp="2026-11-17T00:00:00Z"), bad)


if __name__ == "__main__":
    unittest.main()
