"""coord-sim: `coord-sim report RUN_DIR --rows` output (fixture run dir in fixtures/coord-sim/run) -> rows."""
from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benches.coord_sim import BENCH, rows_of_report  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "coord-sim"


def ctx():
    return Context(bench=BENCH, build={"channel": "sha", "version": None, "sha": "d" * 40}, host_role="fleet",
                   timestamp="2026-11-19T00:00:00Z")


def find(rows, metric):
    got = [r for r in rows if r["metric"] == metric]
    assert len(got) == 1, (metric, len(got))
    return got[0]


class CoordSimTest(unittest.TestCase):
    def test_harness_log_rows(self):
        c = ctx()
        BENCH.ingest(c, FIXTURES / "coord-sim-linux.log")
        lost = find(c.rows, "events.lost")
        self.assertEqual((lost["value"], lost["unit"]), (2.0, "count"))  # coordinator 2 lost seqs 77 and 78
        self.assertEqual(find(c.rows, "events.duplicated")["value"], 0.0)
        self.assertEqual(find(c.rows, "daemon.rss_slope_mb_per_min")["unit"], "MB")
        delivery = find(c.rows, "delivery_ms")
        self.assertLessEqual(delivery["p95"], 40.5)
        self.assertEqual(delivery["labels"], {"coordinators": "3", "rate": "10"})
        self.assertTrue(all(r["better"] == "lower" for r in c.rows))

    def test_report_json_alone_gives_the_same_rows(self):
        a, b = ctx(), ctx()
        BENCH.ingest(a, FIXTURES / "coord-sim-linux.log")
        BENCH.ingest(b, FIXTURES / "report.json")
        key = lambda rows: sorted((r["metric"], r["value"], r["p95"], r["unit"]) for r in rows)  # noqa: E731
        self.assertEqual(key(a.rows), key(b.rows))

    def test_python_rows_match_the_rust_rows(self):
        lines = (FIXTURES / "coord-sim-linux.log").read_text().splitlines()
        report, rust = json.loads(lines[-2]), json.loads(lines[-1])["rows"]
        py = rows_of_report(report)
        self.assertEqual(sorted((r["name"], r["p95"]) for r in py), sorted((r["name"], r["p95"]) for r in rust))

    def test_fanin_rows_match_the_rust_rows(self):
        lines = (FIXTURES / "coord-sim-linux-fanin.log").read_text().splitlines()
        report, rust = json.loads(lines[-2]), json.loads(lines[-1])["rows"]
        py = rows_of_report(report)
        self.assertEqual(sorted((r["name"], r["p95"]) for r in py), sorted((r["name"], r["p95"]) for r in rust))
        c = ctx()
        BENCH.ingest(c, FIXTURES / "report-fanin.json")
        self.assertEqual(find(c.rows, "fanin.n200.attach_ms")["p95"], 10.0)
        self.assertEqual(find(c.rows, "fanin.n200.controller_rss_mb_per_session")["value"], 0.2)

    def test_not_a_log(self):
        with self.assertRaises(BenchError):
            BENCH.ingest(ctx(), Path(__file__))


if __name__ == "__main__":
    unittest.main()
