"""Import contract: partial or failed sweeps must never enter the benchmark ledger."""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from benchlib.bench import BenchError, Context
from benches.chat_size import BENCH, TIMINGS, SCALARS

SHA = "a" * 40


class ChatSizeImportTest(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.path = Path(self.folder.name) / "sweep.log"
        self.ctx = Context(bench=BENCH, build={"channel": "sha", "sha": SHA}, host_role="fleet")

    def log(self, error=None):
        # Synthetic contract values, not performance evidence.
        rows = []
        for size, byte_count in (("1M", 1048576), ("100M", 104857600)):
            row = {"size": size, "bytes": byte_count, "source": "coord-sim"}
            row.update({k: {"p50": 100, "p95": 200, "n": 20} for k in TIMINGS})
            row.update({k: 100 for k in SCALARS})
            rows.append(row)
        if error:
            rows[1][error] = {"timeoutMs": 120000}
        return "\n".join([
            f"CHAT-SIZE-HEAD {SHA}", "CHAT-SIZE-HOST test-runner Linux x86_64",
            *("CHAT-SIZE " + json.dumps(row) for row in rows),
            'CHAT-SIZE-RATIO {"size":"100M","vs":"1M","ratios":{"/rssIdle":1}}',
            "infinite_chat_size_ratio_max 1 /rssIdle 100M", "CHAT-SIZE-TABLE-END",
        ])

    def test_complete_run_preserves_distribution_and_identity(self):
        self.path.write_text(self.log())
        BENCH.ingest(self.ctx, self.path)
        row = next(r for r in self.ctx.rows if r["metric"] == "attachUs")
        self.assertEqual((row["value"], row["p95"], row["n"]), (100, 200, 20))
        self.assertEqual(row["host"]["name"], "test-runner")
        self.assertEqual(row["build"]["sha"], SHA)

    def test_failures_publish_no_partial_rows(self):
        for error in ("sendError", "coldAllLogsError", "restartAllLogsError", "initialStateError"):
            with self.subTest(error=error):
                self.path.write_text(self.log(error))
                with self.assertRaises(BenchError):
                    BENCH.ingest(self.ctx, self.path)
                self.assertEqual(self.ctx.rows, [])

    def test_truncated_log_and_wrong_head_are_not_evidence(self):
        for log in (self.log().replace("CHAT-SIZE-TABLE-END", ""), self.log().replace(SHA, "b" * 40)):
            self.path.write_text(log)
            with self.assertRaises(BenchError):
                BENCH.ingest(self.ctx, self.path)
            self.assertEqual(self.ctx.rows, [])
