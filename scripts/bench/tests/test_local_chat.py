"""local-chat: a local-chat-first-reply.sh log -> one run's rows."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benches.local_chat import BENCH  # noqa: E402

LOG = Path(__file__).resolve().parent / "fixtures" / "local-chat" / "local-chat.log"


def ingest(path=LOG):
    ctx = Context(bench=BENCH, build={"channel": "sha", "version": None, "sha": None}, host_role="fleet",
                  args={}, timestamp="2026-11-25T00:00:00Z")
    BENCH.ingest(ctx, path)
    return {r["metric"]: r for r in ctx.rows}


class LocalChatTest(unittest.TestCase):
    def test_rows(self):
        rows = ingest()
        self.assertEqual(rows["select_to_first_text"]["value"], 4000)
        self.assertEqual(rows["select_to_first_text"]["n"], 2)
        self.assertEqual(rows["stage.before_turn"]["value"], 900)
        self.assertEqual(rows["stage.turn"]["value"], 2900)
        self.assertEqual(rows["mark.first_model"]["value"], 1800)
        self.assertEqual(rows["failed_rounds"]["value"], 1)

    def test_a_log_without_the_line_is_refused(self):
        with self.assertRaises(BenchError):
            ingest(Path(__file__))


if __name__ == "__main__":
    unittest.main()
