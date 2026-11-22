"""agent-turn: a real turn_overhead.rs run (lane VM, 100 turns, 2026-11-19) -> rows."""
from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benches.agent_turn import BENCH  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "agent-turn"


def ingest(path):
    ctx = Context(bench=BENCH, build={"channel": "sha", "version": None, "sha": "d" * 40}, host_role="fleet",
                  timestamp="2026-11-19T00:00:00Z")
    BENCH.ingest(ctx, path)
    return ctx


class AgentTurnTest(unittest.TestCase):
    def test_every_stage_in_ms(self):
        rows = {r["metric"]: r for r in ingest(FIXTURES / "agent-turn.log").rows}
        self.assertEqual(list(rows), ["send", "harness", "store", "deliver", "render", "turn", "shown"])
        self.assertEqual(rows["deliver"]["n"], 100)
        self.assertEqual(rows["deliver"]["unit"], "ms")
        self.assertAlmostEqual(rows["deliver"]["p50"], 3.77, places=2)
        self.assertAlmostEqual(rows["turn"]["p50"], 4.52, places=2)

    def test_an_actions_log_line_keeps_its_time_stamp(self):
        line = next(l for l in (FIXTURES / "agent-turn.log").read_text().splitlines() if l.startswith("AGENT-TURN "))
        with tempfile.TemporaryDirectory() as d:
            log = Path(d) / "job.log"
            log.write_text(f"2026-11-19T10:00:00.1234567Z {line}\n")
            self.assertEqual(len(ingest(log).rows), 7)

    def test_a_log_without_the_line_says_so(self):
        with tempfile.TemporaryDirectory() as d:
            log = Path(d) / "empty.log"
            log.write_text("error: could not compile\n")
            with self.assertRaises(BenchError):
                ingest(log)


if __name__ == "__main__":
    unittest.main()
