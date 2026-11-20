"""wallpaper_cost: wallpaper-cost.sh's WALLPAPER-COST lines -> rows (a hand-written sample of its output)."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benches.wallpaper_cost import BENCH  # noqa: E402

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "wallpaper_cost" / "wallpaper-cost.log"


def find(rows, metric, **labels):
    got = [r for r in rows if r["metric"] == metric and all(r["labels"].get(k) == v for k, v in labels.items())]
    assert len(got) == 1, (metric, labels, len(got))
    return got[0]


class WallpaperCostTest(unittest.TestCase):
    def setUp(self):
        self.ctx = Context(bench=BENCH, build={"channel": "sha", "version": None, "sha": "d" * 40}, host_role="fleet",
                           timestamp="2026-11-17T00:00:00Z")
        BENCH.ingest(self.ctx, FIXTURE)
        self.rows = self.ctx.rows

    def test_every_phase_has_its_rows(self):
        for phase, ident in (("picture", "van-gogh-starry-night"), ("live", "blueprint"), ("live", "orbits"),
                             ("idle", "blueprint"), ("occluded", "blueprint"), ("minimized", "blueprint"),
                             ("low-power", "blueprint")):
            for metric in ("cpu", "gpu", "footprint", "frames"):
                find(self.rows, metric, phase=phase, id=ident)
        self.assertEqual(len(self.rows), 7 * 4)

    def test_values_and_units(self):
        gpu = find(self.rows, "gpu", phase="live", id="orbits")
        self.assertEqual((gpu["value"], gpu["unit"]), (1.8, "%"))
        self.assertEqual(find(self.rows, "footprint", phase="picture", id="van-gogh-starry-night")["unit"], "MB")
        self.assertEqual(find(self.rows, "frames", phase="idle", id="blueprint")["value"], 0.0)
        self.assertTrue(all(r["better"] == "lower" for r in self.rows))

    def test_host(self):
        self.assertEqual(self.ctx.host["name"], "cmux19")
        self.assertEqual(self.ctx.host["os"], "macOS 27.0")

    def test_not_a_log(self):
        c = Context(bench=BENCH, build={"channel": "local"}, host_role="fleet")
        with self.assertRaises(BenchError):
            BENCH.ingest(c, Path(__file__))


if __name__ == "__main__":
    unittest.main()
