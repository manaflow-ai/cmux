"""Import contract for claude-vs-acpmux: a CLAUDE-VS-ACPMUX line becomes rows per arm and turn; nothing measured
publishes nothing. And the harness's own math: its stream-json turn marks and its guard."""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from benchlib.bench import BenchError, Context
from benches.claude_vs_acpmux import BENCH

HARNESS = Path(__file__).resolve().parents[2] / "measure" / "claude-vs-acpmux.py"
spec = importlib.util.spec_from_file_location("claude_vs_acpmux_harness", HARNESS)
harness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(harness)


class ImportTest(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.path = Path(self.folder.name) / "run.log"
        self.ctx = Context(bench=BENCH, build={"channel": "sha", "sha": "a" * 40}, host_role="anywhere")

    def write(self, rows):
        # Synthetic contract values, not performance evidence.
        line = {"bench": "claude-vs-acpmux", "rows": rows, "errors": [], "env": {}}
        self.path.write_text("| table |\nCLAUDE-VS-ACPMUX " + json.dumps(line) + "\n")

    def test_rows_per_arm_and_turn(self):
        self.write([
            {"arm": "stdio", "turn": "cold", "run": 1, "start_wait": 2, "total": 5000, "throughput": 150},
            {"arm": "stdio", "turn": "cold", "run": 2, "start_wait": 4, "total": 7000},
            {"arm": "acpmux", "turn": "cold", "run": 1, "start_wait": 1300, "cpu_s": 0.4},
            {"arm": "mcp", "turn": "cold", "run": 1, "first_list": 1260},
        ])
        BENCH.ingest(self.ctx, self.path)
        rows = {(r["metric"], r["labels"]["arm"], r["labels"]["turn"]): r for r in self.ctx.rows}
        self.assertEqual(rows[("start_wait", "stdio", "cold")]["n"], 2)
        self.assertEqual(rows[("start_wait", "acpmux", "cold")]["value"], 1300)
        self.assertEqual(rows[("throughput", "stdio", "cold")]["better"], "higher")
        self.assertEqual(rows[("cpu_s", "acpmux", "cold")]["unit"], "s")
        self.assertEqual(rows[("first_list", "mcp", "cold")]["unit"], "ms")

    def test_nothing_measured_publishes_nothing(self):
        self.write([{"arm": "acpmux", "turn": "cold", "run": 1}])
        with self.assertRaises(BenchError):
            BENCH.ingest(self.ctx, self.path)
        self.assertEqual(self.ctx.rows, [])


class HarnessMathTest(unittest.TestCase):
    def test_turn_marks(self):
        turn = harness.Turn(100.0)
        lines = [
            (100.01, {"type": "command_lifecycle", "state": "queued"}),
            (101.50, {"type": "command_lifecycle", "state": "started"}),
            (102.00, {"type": "stream_event", "event": {"type": "content_block_start",
                                                        "content_block": {"type": "tool_use"}}}),
            (102.10, {"type": "stream_event", "event": {"type": "content_block_delta",
                                                        "delta": {"type": "input_json_delta"}}}),
            (102.20, {"type": "assistant", "message": {"content": [{"type": "tool_use"}]}}),
            (102.30, {"type": "user", "message": {"content": [{"type": "tool_result"}]}}),
            (103.30, {"type": "stream_event", "event": {"type": "content_block_delta",
                                                        "delta": {"type": "text_delta", "text": "x" * 200}}}),
            (103.40, {"type": "result"}),
        ]
        for at, line in lines:
            done = turn.feed(line, at)
        self.assertTrue(done)
        m = turn.metrics()
        self.assertEqual(m["start_wait"], 1490)
        self.assertEqual(m["first_tool"], 2000)
        self.assertEqual(m["first_token"], 2100)
        self.assertEqual(m["tool_rt"], 100)
        self.assertEqual(m["model_after_tool"], 1000)
        self.assertEqual(m["throughput"], 200)
        self.assertEqual(m["total"], 3400)

    def test_guard(self):
        summary = {("acpmux", "cold", "start_wait"): [1300, 1400, 900], ("mcp", "cold", "first_list"): [90, 120],
                   ("acpmux", "warm", "tool_rt"): [400], ("stdio", "warm", "tool_rt"): [20]}
        failed = harness.guard(summary)
        self.assertTrue(any("acpmux cold start_wait" in f for f in failed))
        self.assertTrue(any("tool_rt_over_stdio" in f for f in failed))
        self.assertFalse(any("first_list" in f for f in failed))


if __name__ == "__main__":
    unittest.main()
