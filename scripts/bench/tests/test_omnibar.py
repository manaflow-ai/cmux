"""omnibar bench: the omnibar-preload.py harness's output into rows.

Fixtures (fixtures/omnibar/): omnibar-preload.json is the harness's report from cmux-lawrence-2 (2026-11-17,
build omnibar-preload-gate-v2, 2 URLs x 8 rounds per arm); omnibar.log is that run's printed lines (samples and
the OMNIBAR summary line).
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

FIX = Path(__file__).resolve().parent / "fixtures" / "omnibar"


def ingest(name: str | Path) -> Context:
    bench = load_all()["omnibar"]
    ctx = Context(bench=bench, build={"channel": "sha", "version": None, "sha": "f" * 40},
                  host_role="anywhere", host={"name": "cmux-lawrence-2", "role": "anywhere", "os": "macOS 27.0",
                                                     "chip": "Apple M4"})
    bench.ingest(ctx, Path(name) if Path(name).is_absolute() else FIX / name)
    return ctx


def find(ctx: Context, metric: str, **labels: str) -> dict:
    hits = [r for r in ctx.rows if r["metric"] == metric and r["labels"] == labels]
    if len(hits) != 1:
        raise AssertionError(f"{metric} {labels}: {len(hits)} rows")
    return hits[0]


class OmnibarBenchTest(unittest.TestCase):
    def setUp(self):
        self.doc = json.loads((FIX / "omnibar-preload.json").read_text())
        self.ctx = ingest("omnibar-preload.json")

    def counted(self, arm: str, url: str | None = None, metric: str = "enter_to_fcp_ms") -> list[float]:
        return [s[metric] for s in self.doc["samples"] if s["arm"] == arm and (url is None or s["url"] == url)
                and s.get(metric) is not None and bool(s["activated"]) == (arm == "prerendered")]

    def test_medians_by_arm_and_url(self):
        for arm in ("cold", "prerendered"):
            for metric in ("enter_to_fcp_ms", "enter_to_nav_ms"):
                row = find(self.ctx, metric, arm=arm)
                self.assertEqual(row["unit"], "ms")
                self.assertEqual(row["n"], len(self.counted(arm, metric=metric)))
                self.assertAlmostEqual(row["value"], statistics.median(self.counted(arm, metric=metric)), places=6)
                for url in {s["url"] for s in self.doc["samples"] if s["arm"] == arm}:
                    vals = self.counted(arm, url, metric)
                    if vals:
                        self.assertAlmostEqual(find(self.ctx, metric, arm=arm, url=url)["value"],
                                               statistics.median(vals), places=6)

    def test_prerendered_is_faster_and_counted(self):
        self.assertLess(find(self.ctx, "enter_to_fcp_ms", arm="prerendered")["value"],
                        find(self.ctx, "enter_to_fcp_ms", arm="cold")["value"])
        pre = [s for s in self.doc["samples"] if s["arm"] == "prerendered"]
        self.assertEqual(find(self.ctx, "prerender_tried")["value"], len(pre))
        self.assertEqual(find(self.ctx, "prerender_activated")["value"], sum(bool(s["activated"]) for s in pre))
        self.assertEqual(find(self.ctx, "prerender_activated")["better"], "higher")

    def test_a_sample_that_was_not_prerendered_is_left_out_of_its_arm(self):
        doc = json.loads(json.dumps(self.doc))
        first = next(s for s in doc["samples"] if s["arm"] == "prerendered")
        first["activated"], first["enter_to_fcp_ms"] = False, 99999.0
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "omnibar-preload.json"
            path.write_text(json.dumps(doc))
            ctx = ingest(path)
        self.assertLess(find(ctx, "enter_to_fcp_ms", arm="prerendered")["value"], 99999.0)
        self.assertEqual(find(ctx, "enter_to_fcp_ms", arm="prerendered")["n"],
                         find(self.ctx, "enter_to_fcp_ms", arm="prerendered")["n"] - 1)

    def test_the_summary_line_alone_gives_the_medians(self):
        ctx = ingest("omnibar.log")
        summary = self.doc["summary"]
        for arm in ("cold", "prerendered"):
            self.assertEqual(find(ctx, "enter_to_fcp_ms", arm=arm)["value"], summary[arm]["median_ms"])
            self.assertEqual(find(ctx, "enter_to_nav_ms", arm=arm)["value"], summary[arm]["nav_median_ms"])
        self.assertEqual(find(ctx, "prerender_activated")["value"], summary["prerender_activated"])
        self.assertTrue(any("OMNIBAR line" in note for note in ctx.notes))

    def test_a_file_with_neither_is_refused(self):
        with self.assertRaises(BenchError):
            ingest(FIX.parent.parent / "test_omnibar.py")

    def test_run_points_at_the_harness(self):
        with self.assertRaises(BenchError) as err:
            load_all()["omnibar"].run(self.ctx)
        self.assertIn("omnibar-preload.py", str(err.exception))


if __name__ == "__main__":
    unittest.main()
