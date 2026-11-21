"""bundle bench: bundle-size.py tree's JSON into kind and duplicate rows.

Fixture (fixtures/bundle/tree.json): the shape `bundle-size.py tree --json` writes, with the 2026-11-16
nightly's headline numbers (cmuxterm-hq docs/perf/bundle-size.md) and its kinds trimmed to four.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import Context  # noqa: E402
from benchlib.registry import load_all  # noqa: E402

FIX = Path(__file__).resolve().parent / "fixtures" / "bundle"


class TreeJson(unittest.TestCase):
    def test_kinds_and_duplicates(self):
        bench = load_all()["bundle"]
        ctx = Context(bench=bench, build={"channel": "nightly", "version": "1.0.0-nightly.1", "sha": "a" * 40},
                      host_role="anywhere", host={"name": "linux", "role": "anywhere", "os": "Linux", "chip": "x86_64"})
        bench.ingest(ctx, FIX / "tree.json")
        kinds = {r["labels"]["kind"]: r["value"] for r in ctx.rows if r["metric"] == "kind"}
        self.assertEqual(kinds, {"Mach-O code and data": 560.0, "localizations": 54.6, "Mach-O unwind tables": 43.4})
        dup = [r for r in ctx.rows if r["metric"] == "duplicate_extra"]
        self.assertEqual([r["value"] for r in dup], [1.3])
        self.assertTrue(all(r["labels"]["app"] == "cmux" for r in ctx.rows))


if __name__ == "__main__":
    unittest.main()
