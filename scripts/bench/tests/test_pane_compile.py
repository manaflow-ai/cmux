"""pane-compile bench: pane-compile-ab.mjs's cold and warm outputs into rows.

Fixture (fixtures/pane_compile/pane-compile.json): {"cold": ..., "warm": ...}, the harness's two outputs from
a Linux VM (2026-11-23, headless Chrome 158, 3 runs per side): A is the pane as shipped (ES modules), B the
same code bundled as one classic script. A's warm loads compile as much as its cold ones (the page's small classic
scripts deserialize, the modules never do); B's warm loads compile almost nothing.
"""
from __future__ import annotations

import json
import statistics
import sys
import tempfile
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benchlib.registry import load_all  # noqa: E402

FIX = Path(__file__).resolve().parent / "fixtures" / "pane_compile" / "pane-compile.json"


def ingest(path: Path) -> Context:
    bench = load_all()["pane-compile"]
    ctx = Context(bench=bench, build={"channel": "sha", "version": None, "sha": "e" * 40},
                  host_role="anywhere", host={"name": "linux-vm", "role": "anywhere", "os": "Linux",
                                              "chip": "x86_64"})
    bench.ingest(ctx, path)
    return ctx


def find(ctx: Context, metric: str, **labels: str) -> dict:
    hits = [r for r in ctx.rows if r["metric"] == metric and r["labels"] == labels]
    if len(hits) != 1:
        raise AssertionError(f"{metric} {labels}: {len(hits)} rows")
    return hits[0]


class PaneCompileBenchTest(unittest.TestCase):
    def setUp(self):
        self.doc = json.loads(FIX.read_text())
        self.ctx = ingest(FIX)

    def loads(self, mode: str) -> list[dict]:
        return [r for side in ("A", "B") for r in self.doc[mode][side]["runs"]]

    def test_rows_per_mode_are_the_median_of_every_load(self):
        for mode in ("cold", "warm"):
            for field, metric in (("fcpMs", "fcp"), ("mainCompileMs", "main_compile"),
                                  ("mainCompiles", "main_compiles"), ("backgroundParseMs", "background_parse"),
                                  ("cacheConsumed", "cache_consumed")):
                row = find(self.ctx, metric, mode=mode)
                vals = [r[field] for r in self.loads(mode) if r[field] is not None]
                self.assertEqual(row["n"], len(vals))
                self.assertAlmostEqual(row["value"], statistics.median(vals), places=6)

    def test_directions(self):
        self.assertEqual(find(self.ctx, "cache_consumed", mode="warm")["better"], "higher")
        self.assertEqual(find(self.ctx, "fcp", mode="warm")["better"], "lower")
        self.assertEqual(find(self.ctx, "main_compiles", mode="cold")["unit"], "count")

    def test_fixture_shows_the_module_cache_unread(self):
        # The finding the bench exists to track: warm ES-module loads compile as much as cold ones; classic does not.
        cold_a = {r["mainCompiles"] for r in self.doc["cold"]["A"]["runs"]}
        self.assertEqual({r["mainCompiles"] for r in self.doc["warm"]["A"]["runs"]}, cold_a)
        self.assertTrue(all(r["mainCompiles"] < 100 for r in self.doc["warm"]["B"]["runs"]))

    def test_one_mode_alone_ingests(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "cold-only.json"
            path.write_text(json.dumps({"cold": self.doc["cold"]}))
            ctx = ingest(path)
        self.assertTrue(ctx.rows)
        self.assertTrue(all(r["labels"] == {"mode": "cold"} for r in ctx.rows))

    def test_bad_input_raises(self):
        with tempfile.TemporaryDirectory() as tmp:
            empty = Path(tmp) / "empty.json"
            empty.write_text("{}")
            with self.assertRaises(BenchError):
                ingest(empty)
            with self.assertRaises(BenchError):
                ingest(Path(tmp) / "missing.json")


if __name__ == "__main__":
    unittest.main()
