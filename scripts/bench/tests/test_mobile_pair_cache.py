"""Synthetic parser fixtures validate receipt integrity, not performance claims."""
from __future__ import annotations

import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))
from benchlib.bench import BenchError, Context
from benches.mobile_pair_cache import BENCH, PREFIX, parse

FIXTURE = BENCH_DIR / "tests/fixtures/mobile-pair-cache/synthetic.log"


class MobilePairCacheTests(unittest.TestCase):
    def test_metrics_keep_sources_and_cache_state(self):
        ctx = Context(bench=BENCH, build={"channel": "local", "sha": "c" * 40}, host_role="anywhere")
        BENCH.ingest(ctx, FIXTURE)
        self.assertEqual(len(ctx.rows), 8)
        row = next(r for r in ctx.rows if r["metric"] == "cpu" and r["labels"]["arm"] == "binary-hit")
        self.assertAlmostEqual(row["value"], 0.3)
        self.assertEqual(row["labels"]["host_sha"], "a" * 40)
        self.assertEqual(row["labels"]["dial_sha"], "b" * 40)
        self.assertEqual(row["labels"]["cargo_cache"], "preexisting")

    def test_invalid_receipts_never_add_rows(self):
        original = parse(FIXTURE.read_text())
        changes = [
            ("valid", False), ("exit_code", 1), ("hits", 0), ("host_sha", "d" * 40),
            ("dial_sha", "short"), ("wall_s", -1), ("user_s", float("nan")),
            ("system_s", True), ("cargo_cache", "cold"), ("schema", "unknown"),
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "receipt"
            for key, value in changes:
                rows = copy.deepcopy(original)
                rows[1][key] = value
                path.write_text("\n".join(PREFIX + json.dumps(row) for row in rows))
                ctx = Context(bench=BENCH, build={"channel": "local"}, host_role="anywhere")
                with self.subTest(key=key), self.assertRaises(BenchError):
                    BENCH.ingest(ctx, path)
                self.assertFalse(ctx.rows)

    def test_incomplete_or_duplicate_window_is_rejected(self):
        text = FIXTURE.read_text()
        for bad in ("", text.splitlines()[0], text + text):
            with self.subTest(text=bad), self.assertRaises(BenchError):
                parse(bad)


if __name__ == "__main__":
    unittest.main()
