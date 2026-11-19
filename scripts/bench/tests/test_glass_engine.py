"""glass-engine bench: glass-engine.bench.ts's rows (its OUT JSON, the step's log) into rows.

Fixtures (fixtures/glass-engine/): gpu.log holds GLASS-ENGINE-FRAMES lines in the shape glass-engine-frames.sh prints,
with a GPU renderer (values made up); software.json is a real OUT file of a lane VM's smoke run on SwiftShader.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benchlib.registry import load_all  # noqa: E402

FIX = Path(__file__).resolve().parent / "fixtures" / "glass-engine"


def ingest(name: str) -> Context:
    bench = load_all()["glass-engine"]
    ctx = Context(bench=bench, build={"channel": "sha", "version": None, "sha": "0" * 40},
                  host_role="fleet", host={"name": "fleet-mini", "role": "fleet", "os": "macOS", "chip": "Apple M4"})
    bench.ingest(ctx, FIX / name)
    return ctx


def find(ctx: Context, metric: str, **labels: str) -> dict:
    hits = [r for r in ctx.rows if r["metric"] == metric and all(r["labels"].get(k) == v for k, v in labels.items())]
    if len(hits) != 1:
        raise AssertionError(f"{metric} {labels}: {len(hits)} rows")
    return hits[0]


class GlassEngineIngest(unittest.TestCase):
    def test_log_lines(self):
        ctx = ingest("gpu.log")
        cost = find(ctx, "cost_ms", renderer="engine", glass="32", viewport="1920x1080@2", run="headless")
        self.assertEqual(cost["p95"], 2.4)
        frame = find(ctx, "frame_interval_ms", renderer="lens", glass="3", viewport="1920x1080@2", run="headless")
        self.assertEqual(frame["p50"], 16.7)
        self.assertEqual(find(ctx, "dropped_frames", renderer="engine", glass="32", run="headless")["value"], 4)
        self.assertEqual(find(ctx, "fps", renderer="lens", glass="3", run="headless")["better"], "higher")

    def test_software_gl_is_refused(self):
        with self.assertRaises(BenchError):
            ingest("software.json")


if __name__ == "__main__":
    unittest.main()
