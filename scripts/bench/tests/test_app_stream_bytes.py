"""app-stream-bytes: a real app-stream-bytes.sh fleet log (both arms, three rounds) -> rows."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benches.app_stream_bytes import BENCH  # noqa: E402

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "app-stream-bytes" / "app-stream-bytes.log"


def find(rows, metric, **labels):
    got = [r for r in rows if r["metric"] == metric and all(r["labels"].get(k) == v for k, v in labels.items())]
    assert len(got) == 1, (metric, labels, len(got))
    return got[0]


class AppStreamBytesTest(unittest.TestCase):
    def setUp(self):
        self.ctx = Context(bench=BENCH, build={"channel": "sha", "version": None, "sha": "d" * 40}, host_role="fleet",
                           timestamp="2026-11-16T00:00:00Z")
        BENCH.ingest(self.ctx, FIXTURE)
        self.rows = self.ctx.rows

    def test_arms_and_rounds(self):
        before = find(self.rows, "total_bytes_per_s", arm="before")
        after = find(self.rows, "total_bytes_per_s", arm="after")
        self.assertEqual(before["n"], 3)
        self.assertEqual(after["n"], 3)
        self.assertEqual(before["unit"], "bytes")
        self.assertLess(after["value"], before["value"])
        self.assertEqual(find(self.rows, "daemon_cpu_ms_per_s", arm="before")["unit"], "ms")

    def test_hidden_panes_get_no_stream_after(self):
        before = find(self.rows, "hidden_bytes_per_s", arm="before")["value"]
        after = find(self.rows, "hidden_bytes_per_s", arm="after")["value"]
        self.assertLess(after, before * 0.6)
        hidden_after = [r["labels"]["kind"] for r in self.rows if r["metric"] == "kind_bytes_per_s"
                        and r["labels"]["arm"] == "after" and r["labels"]["scope"] == "hidden"]
        self.assertFalse([k for k in hidden_after if k.startswith(("_acpmux/event:agent_message", "session/update"))])

    def test_kinds(self):
        kinds = [r for r in self.rows if r["metric"] == "kind_bytes_per_s" and r["labels"]["arm"] == "before"
                 and r["labels"]["scope"] == "hidden"]
        self.assertTrue(any(r["labels"]["kind"].startswith("_acpmux/event") for r in kinds))
        self.assertTrue(all(r["better"] == "lower" for r in self.rows))

    def test_not_a_log(self):
        c = Context(bench=BENCH, build={"channel": "local"}, host_role="fleet")
        with self.assertRaises(BenchError):
            BENCH.ingest(c, Path(__file__))


if __name__ == "__main__":
    unittest.main()
