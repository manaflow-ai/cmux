"""agent-quota bench: the agent-quota.sh harness's lines into rows.

Fixture (fixtures/agent-quota/agent-quota.log): the rows of the first run (gcp lane VM, 2026-11-18, Claude Opus 5.5
at medium effort, ci_seconds=300, 3 single-agent trials per arm and one 6-agent trial per arm).
"""
from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benchlib.registry import load_all  # noqa: E402

FIX = Path(__file__).resolve().parent / "fixtures" / "agent-quota" / "agent-quota.log"


def ingest(path: Path) -> Context:
    bench = load_all()["agent-quota"]
    ctx = Context(bench=bench, build={"channel": "sha", "version": None, "sha": "f" * 40}, host_role="anywhere")
    bench.ingest(ctx, path)
    return ctx


def find(ctx: Context, metric: str, **labels: str) -> dict:
    hits = [r for r in ctx.rows if r["metric"] == metric and r["labels"] == labels]
    if len(hits) != 1:
        raise AssertionError(f"{metric} {labels}: {len(hits)} rows")
    return hits[0]


class AgentQuotaTests(unittest.TestCase):
    def test_rows_per_arm_and_agent_count(self):
        ctx = ingest(FIX)
        without = find(ctx, "github_calls", arm="without", agents="1")
        self.assertEqual((without["value"], without["n"]), (21.0, 3))
        self.assertEqual(find(ctx, "github_calls", arm="shipped", agents="1")["value"], 15.0)
        self.assertEqual(find(ctx, "github_calls", arm="without", agents="6")["value"], 134.0)
        self.assertEqual(find(ctx, "github_calls", arm="shipped", agents="6")["value"], 15.0)
        self.assertEqual(find(ctx, "wall", arm="shipped", agents="6")["unit"], "s")
        correct = find(ctx, "correct", arm="shipped", agents="6")
        self.assertEqual((correct["value"], correct["better"]), (6.0, "higher"))

    def test_prefixed_log_lines_and_no_rows(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "run.log"
            log.write_text("12:00:01 AGENT-QUOTA row arm=shipped agents=1 trial=1 calls=15 wall_s=315 correct=1/1\n")
            self.assertEqual(find(ingest(log), "github_calls", arm="shipped", agents="1")["value"], 15.0)
            log.write_text("nothing here\n")
            with self.assertRaises(BenchError):
                ingest(log)


if __name__ == "__main__":
    unittest.main()
