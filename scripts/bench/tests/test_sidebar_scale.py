"""sidebar-scale: a SidebarScaleWorkTests step log -> rows. Fixtures: before.log and after.log are the fleet step logs'
SIDEBAR-SCALE lines from this bench's PR (base and fixed heads, same harness)."""
from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benches.sidebar_scale import BENCH  # noqa: E402

FIX = Path(__file__).resolve().parent / "fixtures" / "sidebar-scale"


def ingest(name: str) -> list[dict]:
    ctx = Context(bench=BENCH, build={"channel": "sha", "version": None, "sha": "d" * 40}, host_role="fleet",
                  timestamp="2026-11-19T00:00:00Z")
    BENCH.ingest(ctx, FIX / name)
    return ctx.rows


def find(rows, metric, **labels):
    got = [r for r in rows if r["metric"] == metric and r["labels"] == labels]
    assert len(got) == 1, (metric, labels, len(got))
    return got[0]


class SidebarScaleTest(unittest.TestCase):
    def test_every_op_and_size_has_its_counts(self):
        for name in ("before.log", "after.log"):
            rows = ingest(name)
            for op in ("change", "follow"):
                for n in ("50", "200", "2000"):
                    self.assertGreater(find(rows, "total", op=op, n=n)["value"], 0)
                self.assertIn("ratio", {r["metric"] for r in rows if r["labels"] == {"op": op}})

    def test_after_is_flat_and_before_is_not(self):
        before, after = ingest("before.log"), ingest("after.log")
        for op in ("change", "follow"):
            self.assertGreater(find(before, "ratio", op=op)["value"], 1.2)
            self.assertLessEqual(find(after, "ratio", op=op)["value"], 1.2)

    def test_a_log_with_no_lines_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "empty.log"
            p.write_text("Test run with 3 tests passed\n")
            ctx = Context(bench=BENCH, build={"channel": "sha", "version": None, "sha": "d" * 40}, host_role="fleet")
            with self.assertRaises(BenchError):
                BENCH.ingest(ctx, p)


if __name__ == "__main__":
    unittest.main()
