"""Import contract for tool-transport: a BENCH line becomes rows; a run with no tool steps publishes none."""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from benchlib.bench import BenchError, Context
from benches.tool_transport import BENCH


class ToolTransportImportTest(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.path = Path(self.folder.name) / "run.log"
        self.ctx = Context(bench=BENCH, build={"channel": "sha", "sha": "a" * 40}, host_role="local-readonly")

    def write(self, steps):
        # Synthetic contract values, not performance evidence.
        line = {"bench": "tool-transport", "transcripts": {
            "steps": steps, "calls_per_step": 1.3, "calls_in_multi_call_steps_pct": 40.0, "think_p50_ms": 6000,
            "think_p90_ms": 150000, "tools": {"Read": {"n": 9, "p50_ms": 500, "p90_ms": 6000}},
            "reads": 9, "read_named_in_previous_result_pct": 41.0},
            "gateway": {"requests": 3, "fresh_request_p50_us": 220, "fresh_request_p90_us": 300,
                        "connect_p50_us": 65, "connect_p90_us": 86}}
        self.path.write_text("noise\n2026-11-25T00:00:00Z BENCH " + json.dumps(line) + "\n")

    def test_rows(self):
        self.write(10)
        BENCH.ingest(self.ctx, self.path)
        rows = {(r["metric"], r["labels"].get("tool")): r for r in self.ctx.rows}
        self.assertEqual(rows[("tool_exec", "Read")]["p95"], 6000)
        self.assertEqual(rows[("gateway_connect", None)]["value"], 65)
        self.assertEqual(rows[("calls_per_step", None)]["better"], "higher")

    def test_empty_run_publishes_nothing(self):
        self.write(0)
        with self.assertRaises(BenchError):
            BENCH.ingest(self.ctx, self.path)
        self.assertEqual(self.ctx.rows, [])


if __name__ == "__main__":
    unittest.main()
