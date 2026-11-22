"""idle: a real perf-10x-idle.sh fleet log (cmux19, counts 1,10,50, agents=20) -> rows."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benches.idle import BENCH  # noqa: E402

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "idle" / "perf-10x-idle.log"


def find(rows, metric, **labels):
    got = [r for r in rows if r["metric"] == metric and all(r["labels"].get(k) == v for k, v in labels.items())]
    assert len(got) == 1, (metric, labels, len(got))
    return got[0]


class IdleTest(unittest.TestCase):
    def setUp(self):
        self.ctx = Context(bench=BENCH, build={"channel": "sha", "version": None, "sha": "d" * 40}, host_role="fleet",
                           timestamp="2026-11-15T00:00:00Z")
        BENCH.ingest(self.ctx, FIXTURE)
        self.rows = self.ctx.rows

    def test_app_kinds(self):
        r = find(self.rows, "footprint", scope="app", sample="idle-50", count="50", kind="app")
        self.assertEqual(r["unit"], "MB")
        self.assertGreater(r["value"], 0)
        cpu = find(self.rows, "cpu", scope="app", sample="idle-launch", count="1", kind="cef-renderer")
        self.assertEqual(cpu["unit"], "%")
        self.assertEqual(find(self.rows, "wakeups", scope="agents", sample="idle-20", count="20", kind="app")["unit"],
                         "per_s")

    def test_totals_sum_kinds(self):
        for sample, count in (("idle-1", "1"), ("idle-10", "10"), ("idle-50", "50")):
            kinds = [r for r in self.rows if r["metric"] == "footprint" and r["labels"].get("sample") == sample
                     and r["labels"]["scope"] == "app" and r["labels"]["kind"] != "total"]
            total = find(self.rows, "footprint", scope="app", sample=sample, count=count, kind="total")
            self.assertAlmostEqual(total["value"], sum(r["value"] for r in kinds), places=6)
            self.assertEqual(len(kinds), 16)

    def test_daemon(self):
        r = find(self.rows, "footprint_each", scope="daemon", count="10", role="daemon")
        self.assertEqual(r["value"], 57.89)
        self.assertEqual(find(self.rows, "processes", scope="daemon", count="50", role="shells")["unit"], "count")

    def test_host_and_better(self):
        self.assertEqual(self.ctx.host["name"], "cmux19")
        self.assertEqual(self.ctx.host["os"], "macOS 27.0")
        self.assertTrue(all(r["better"] == "lower" for r in self.rows))

    def test_not_a_log(self):
        c = Context(bench=BENCH, build={"channel": "local"}, host_role="fleet")
        with self.assertRaises(BenchError):
            BENCH.ingest(c, Path(__file__))

    def test_harness_args(self):
        c = Context(bench=BENCH, build={"channel": "sha", "version": None, "sha": "e" * 40}, host_role="fleet",
                    args={"agents": "10", "config": "bench"})
        args, ref = BENCH.harness_args(c)
        self.assertEqual(ref, "e" * 40)
        self.assertEqual(args, ["counts=1,10", "measure=60", "agents=10", "--config=bench"])


    def test_page_axis_lines(self):
        import tempfile
        lines = [
            "PERF-IDLE-MACHINE host=cmux21 macos=27.0",
            'PERF-IDLE-PAGES page-hidden items-10 items=10 frames={"hidden":{"pages":10,"frames_per_s":0.0,'
            '"max_page_frames_per_s":0.0,"reporting":10}} renderer_cpu_pct=0.31 '
            'renderer_priorities={"47":{"n":2,"cpu_pct":0.3},"28":{"n":10,"cpu_pct":0.01}}',
            'PERF-IDLE-PAGES page-hidden show_latency=[{"page":0,"first_frame_ms":40.0},{"page":1,"first_frame_ms":60.0},'
            '{"page":2,"first_frame_ms":null,"timeout_s":10}]',
        ]
        with tempfile.NamedTemporaryFile("w", suffix=".log", delete=False) as handle:
            handle.write("\n".join(lines) + "\n")
        c = Context(bench=BENCH, build={"channel": "sha", "version": None, "sha": "d" * 40}, host_role="fleet")
        BENCH.ingest(c, Path(handle.name))
        Path(handle.name).unlink()
        hidden = find(c.rows, "frames", scope="pages", axis="page-hidden", sample="items-10", visibility="hidden")
        self.assertEqual((hidden["value"], hidden["unit"]), (0.0, "per_s"))
        self.assertEqual(find(c.rows, "renderer_cpu", scope="pages", sample="items-10")["value"], 0.31)
        low = find(c.rows, "renderers", scope="pages", sample="items-10", priority="28")
        self.assertEqual((low["value"], low["better"]), (10, "none"))
        show = find(c.rows, "show_latency", scope="pages", axis="page-hidden")
        self.assertEqual((show["n"], show["p50"]), (2, 50.0))


if __name__ == "__main__":
    unittest.main()
