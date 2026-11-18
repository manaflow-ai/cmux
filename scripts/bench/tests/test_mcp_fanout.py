"""mcp-fanout: a real mcp-fanout.py output (a Linux dry run with a local acpmux, claude and codex, N=1,2) -> rows."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benches.mcp_fanout import BENCH  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "mcp-fanout"


def find(rows, metric, **labels):
    got = [r for r in rows if r["metric"] == metric and all(r["labels"].get(k) == v for k, v in labels.items())]
    assert len(got) == 1, (metric, labels, len(got))
    return got[0]


def ingest(name):
    ctx = Context(bench=BENCH, build={"channel": "nightly", "version": None, "sha": None}, host_role="fleet",
                  timestamp="2026-11-17T00:00:00Z")
    BENCH.ingest(ctx, FIXTURES / name)
    return ctx


class McpFanoutTest(unittest.TestCase):
    def test_rows_per_kind_and_total(self):
        ctx = ingest("linux-dry-run.log")
        rows = ctx.rows
        serve = find(rows, "processes", harness="claude", count="2", phase="awake", kind="cmux-mcp-serve")
        self.assertEqual(serve["value"], 3.0)
        self.assertEqual(find(rows, "rss", harness="claude", count="2", phase="awake", kind="cmux-mcp-serve")["value"], 117.4)
        total = find(rows, "processes", harness="codex", count="2", phase="awake", kind="TOTAL-tool-servers")
        self.assertEqual(total["value"], 7.0)
        # The idle phase has no CPU column (cpu_pct=None): no cpu row.
        self.assertFalse([r for r in rows if r["metric"] == "cpu" and r["labels"]["phase"].startswith("idle")])
        self.assertEqual(ctx.host.get("name"), "gcp-agent-lane-2")

    def test_first_call_latency(self):
        rows = ingest("linux-dry-run.log").rows
        self.assertEqual(find(rows, "first_call", harness="claude", count="2", chat="fresh")["value"], 57.1)
        self.assertEqual(find(rows, "first_call", harness="claude", count="2", chat="idle")["value"], 93.1)
        # Codex made no call against the stand-in (p50_ms=None): no row.
        self.assertFalse([r for r in rows if r["metric"] == "first_call" and r["labels"]["harness"] == "codex"])

    def test_not_a_log(self):
        ctx = Context(bench=BENCH, build={"channel": "local"}, host_role="fleet")
        with self.assertRaises(BenchError):
            BENCH.ingest(ctx, Path(__file__))

    def test_needs_a_published_app(self):
        ctx = Context(bench=BENCH, build={"channel": "sha", "sha": "d" * 40}, host_role="fleet")
        with self.assertRaises(BenchError):
            BENCH.harness_args(ctx)
        ctx = Context(bench=BENCH, build={"channel": "nightly"}, host_role="fleet", args={"counts": "1,5"})
        self.assertEqual(sorted(BENCH.harness_args(ctx)), ["app=nightly", "counts=1,5"])


if __name__ == "__main__":
    unittest.main()
