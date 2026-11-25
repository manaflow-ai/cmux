"""session-benches: a published-benches-linux.sh log (fixtures/session-benches) -> rows."""
from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benches.session_benches import BENCH  # noqa: E402

LOG = Path(__file__).resolve().parent / "fixtures" / "session-benches" / "published-benches-linux.log"


def ctx():
    return Context(bench=BENCH, build={"channel": "sha", "version": None, "sha": "e" * 40}, host_role="fleet",
                   timestamp="2026-11-24T00:00:00Z")


def find(rows, metric):
    got = [r for r in rows if r["metric"] == metric]
    assert len(got) == 1, (metric, len(got))
    return got[0]


class SessionBenchesTest(unittest.TestCase):
    def test_every_part_gives_its_rows(self):
        c = ctx()
        BENCH.ingest(c, LOG)
        self.assertEqual(find(c.rows, "resume_ms")["p95"], 260.1)
        self.assertEqual(find(c.rows, "fork_ms")["labels"], {"history_turns": "20"})
        self.assertEqual(find(c.rows, "move_ms")["p50"], 900.0)
        self.assertEqual(find(c.rows, "build.cold_s")["value"], 412.3)
        soak = find(c.rows, "soak.input_ms")
        self.assertEqual((soak["p95"], soak["labels"]["duration_s"]), (14.2, "600"))
        self.assertEqual(find(c.rows, "soak.rss_growth_mb")["value"], 12.5)
        self.assertEqual(find(c.rows, "soak.zombies_max")["value"], 0)
        # A window line is progress, not a result.
        self.assertFalse([r for r in c.rows if r["metric"].startswith("soak-window")])

    def test_a_log_without_results_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "x.log"
            p.write_text("test result: FAILED\n")
            with self.assertRaises(BenchError):
                BENCH.ingest(ctx(), p)


if __name__ == "__main__":
    unittest.main()
