"""acpmux-watch-bytes: real `cmux-ci test` logs of stream_tell_tests (Linux CI, PR 47984) -> rows."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benches.acpmux_watch_bytes import BENCH  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "acpmux-watch-bytes"


def ingest(name):
    ctx = Context(bench=BENCH, build={"channel": "sha", "version": None, "sha": "d" * 40}, host_role="fleet",
                  timestamp="2026-11-20T00:00:00Z")
    BENCH.ingest(ctx, FIXTURES / name)
    return {r["metric"]: r for r in ctx.rows}


class AcpmuxWatchBytesTest(unittest.TestCase):
    def test_before_and_after(self):
        before, after = ingest("before.log"), ingest("after.log")
        self.assertEqual(before["rows_told"]["value"], 1200)  # every read told all 20 chats
        self.assertEqual(after["rows_told"]["value"], 20)  # once per chat in the window
        self.assertGreater(before["watcher_bytes"]["value"], 40 * after["watcher_bytes"]["value"])
        self.assertEqual(before["watcher_bytes"]["labels"], {"chats": "20", "reads": "60"})
        self.assertTrue(all(r["better"] == "lower" for r in after.values()))

    def test_not_a_log(self):
        ctx = Context(bench=BENCH, build={"channel": "local"}, host_role="fleet")
        with self.assertRaises(BenchError):
            BENCH.ingest(ctx, Path(__file__))


if __name__ == "__main__":
    unittest.main()
