"""web-vitals bench: vitals.mjs output into rows.

Fixture (fixtures/web_vitals/vitals.json): /docs's medians are run 44462539468's (cmux-ci, 2026-11-19); its two
samples are reconstructed around them, one with no interaction (inp null). /blog is a page with no sample.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import Context  # noqa: E402
from benchlib.registry import load_all  # noqa: E402

FIX = Path(__file__).resolve().parent / "fixtures" / "web_vitals"


def ingest() -> Context:
    bench = load_all()["web-vitals"]
    ctx = Context(bench=bench, build={"channel": "local", "version": "", "sha": "a" * 40},
                  host_role="anywhere", host={"name": "linux", "role": "anywhere", "os": "Linux", "chip": ""})
    bench.ingest(ctx, FIX / "vitals.json")
    return ctx


class WebVitalsTests(unittest.TestCase):
    def test_rows_per_page_from_samples(self) -> None:
        ctx = ingest()
        docs = {r["metric"]: r for r in ctx.rows if r["labels"] == {"url": "https://cmux.com/docs"}}
        self.assertEqual(set(docs), {"ttfb", "lcp", "inp", "js_wire", "js_decoded", "js_files"})
        self.assertEqual(docs["lcp"]["value"], 2432)
        self.assertEqual(docs["lcp"]["n"], 2)
        self.assertEqual(docs["inp"]["n"], 1)
        self.assertEqual(docs["js_wire"]["unit"], "KB")

    def test_page_without_samples_adds_no_rows(self) -> None:
        ctx = ingest()
        self.assertFalse([r for r in ctx.rows if r["labels"] == {"url": "https://cmux.com/blog"}])


if __name__ == "__main__":
    unittest.main()
