"""ext-reload: an ext-reload-nightly.sh fleet log (its EXT_RELOAD_NIGHTLY receipt) -> rows."""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benches.ext_reload import BENCH  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "ext-reload"


def find(rows, metric, **labels):
    got = [r for r in rows if r["metric"] == metric and all(r["labels"].get(k) == v for k, v in labels.items())]
    assert len(got) == 1, (metric, labels, len(got))
    return got[0]


def ingest(path):
    ctx = Context(bench=BENCH, build={"channel": "nightly", "version": None, "sha": None}, host_role="fleet",
                  timestamp="2026-11-20T00:00:00Z")
    BENCH.ingest(ctx, path)
    return ctx


class ExtReloadTest(unittest.TestCase):
    def test_rows_from_the_last_receipt(self):
        ctx = ingest(FIXTURES / "fleet.log")
        rows = ctx.rows
        self.assertEqual(find(rows, "save_to_reload", case="activity")["value"], 1840.0)
        self.assertEqual(find(rows, "checks_failed", case="activity")["value"], 0.0)
        self.assertEqual(find(rows, "save_to_shown", case="extension", bound="upper")["value"], 240.5)
        self.assertEqual(find(rows, "save_to_shown", case="extension", bound="lower")["value"], 215.0)
        self.assertEqual(find(rows, "missed", case="extension")["value"], 0.0)
        # A case with no round seen: its misses, and no time rows.
        self.assertEqual(find(rows, "missed", case="command")["value"], 10.0)
        self.assertFalse([r for r in rows if r["metric"] == "save_to_shown" and r["labels"]["case"] == "command"])
        self.assertEqual(ctx.host.get("name"), "cmux-mini-3")
        self.assertTrue(any("not ok" in note for note in ctx.notes))

    def test_a_receipt_json(self):
        line = (FIXTURES / "fleet.log").read_text().splitlines()[3]
        receipt = json.loads(line.split(" ", 1)[1])
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "receipt.json"
            path.write_text(json.dumps(receipt, indent=2))
            rows = ingest(path).rows
        self.assertEqual(find(rows, "save_to_reload", case="activity")["value"], 1840.0)

    def test_not_a_log(self):
        ctx = Context(bench=BENCH, build={"channel": "local"}, host_role="fleet")
        with self.assertRaises(BenchError):
            BENCH.ingest(ctx, Path(__file__))

    def test_needs_a_published_app(self):
        ctx = Context(bench=BENCH, build={"channel": "sha", "sha": "d" * 40}, host_role="fleet")
        with self.assertRaises(BenchError):
            BENCH.harness_args(ctx)
        ctx = Context(bench=BENCH, build={"channel": "nightly"}, host_role="fleet", args={"rounds": "3"})
        self.assertEqual(BENCH.harness_args(ctx), ["rounds=3"])
        ctx = Context(bench=BENCH, build={"channel": "sha", "sha": "d" * 40}, host_role="fleet",
                      args={"dmg": "https://example.invalid/a.dmg"})
        self.assertEqual(BENCH.harness_args(ctx), ["dmg=https://example.invalid/a.dmg"])


if __name__ == "__main__":
    unittest.main()
