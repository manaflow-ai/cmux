"""glass-perf bench: glass-perf.py's report (report.json) and its GLASS-PERF log lines into rows and table lines.

Fixture (fixtures/glass-perf/report.json): the shape glass-perf.py writes, one run per state.
"""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benchlib.registry import load_all  # noqa: E402

FIX = Path(__file__).resolve().parent / "fixtures" / "glass-perf"


def ingest(path: Path) -> Context:
    bench = load_all()["glass-perf"]
    ctx = Context(bench=bench, build={"channel": "sha", "version": None, "sha": "f" * 40}, host_role="fleet",
                  host={"name": "cmux20", "role": "fleet", "os": "macOS 26", "chip": "Apple M4"})
    bench.ingest(ctx, path)
    return ctx


def find(ctx: Context, metric: str, **labels: str) -> dict:
    hits = [r for r in ctx.rows if r["metric"] == metric and r["labels"] == labels]
    if len(hits) != 1:
        raise AssertionError(f"{metric} {labels}: {len(hits)} rows")
    return hits[0]


class GlassPerfTest(unittest.TestCase):
    def test_report_rows(self):
        ctx = ingest(FIX / "report.json")
        idle = {"state": "idle", "mode": "plain", "surfaces": "10"}
        self.assertEqual(find(ctx, "rss_mb", **idle)["value"], 1012.4)
        self.assertEqual(find(ctx, "cpu_pct", **idle, component="web")["value"], 0.4)
        self.assertEqual(find(ctx, "gpu_pct", **idle)["value"], 1.2)
        # Idle has no frame probe (its display link would wake the app): no frame rows.
        self.assertFalse([r for r in ctx.rows if r["metric"].startswith("frame_") and r["labels"]["state"] == "idle"])
        load = {"state": "load", "mode": "plain", "surfaces": "10"}
        self.assertEqual(find(ctx, "frame_p95_ms", **load)["value"], 18.2)
        lens = {"state": "composer-scroll", "mode": "lens", "surfaces": "0"}
        self.assertEqual(find(ctx, "frame_p50_ms", **lens)["value"], 8.3)
        tables = [n for n in ctx.notes if n.startswith("table: ")]
        self.assertEqual(len(tables), 3)
        self.assertIn("composer-scroll (lens: wallpaper still)", tables[2])
        self.assertIn("| idle | plain | 10 | 1012 | 0.9 | 1.2 / 0.20 | - / - | 85 |", tables[0])
        self.assertIn("glass-perf: glass.lens=spectrum: unknown", ctx.notes)

    def test_log_lines(self):
        doc = json.loads((FIX / "report.json").read_text())
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "step.log"
            log.write_text("noise\n" + "".join("GLASS-PERF " + json.dumps(r) + "\n" for r in doc["runs"]))
            ctx = ingest(log)
        self.assertEqual(find(ctx, "energy_mw", state="load", mode="plain", surfaces="10")["value"], 912.0)

    def test_no_runs_is_an_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "step.log"
            log.write_text("glass-perf: no shown chat page\n")
            with self.assertRaises(BenchError):
                ingest(log)


class FakeApp:
    """The two Debug socket methods as the app answers them: `enabled` sets the override, null clears it."""

    def __init__(self, system: bool):
        self.system, self.override, self.calls = system, {}, []

    def call(self, method, params=None):
        params = params or {}
        self.calls.append((method, dict(params)))
        if "enabled" in params:
            self.override[method] = params["enabled"]
        override = self.override.get(method)
        return {"enabled": self.system if override is None else override, "override": override, "system": self.system}


class PinFullGlassTest(unittest.TestCase):
    """glass-perf pins Reduce Transparency and Low Power Mode off (pages draw plain glass under either), then
    puts the Mac's own state back."""

    @staticmethod
    def load():
        import importlib.util
        import types
        from unittest import mock
        path = BENCH_DIR.parent / "cmux-next" / "glass-perf.py"
        spec = importlib.util.spec_from_file_location("glass_perf_script", path)
        module = importlib.util.module_from_spec(spec)
        # bench_memory opens macOS's libproc at import; these tests use none of it.
        with mock.patch.dict(sys.modules, {"bench_memory": types.ModuleType("bench_memory")}):
            spec.loader.exec_module(module)
        return module

    def test_pins_off_and_restores(self):
        gp = self.load()
        run = gp.Run.__new__(gp.Run)
        run.app = FakeApp(system=True)
        before = run.pin_full_glass()
        for method in gp.Run.FULL_GLASS_METHODS:
            self.assertEqual(before[method]["system"], True)
            self.assertEqual(before[method]["override"], None)
            self.assertEqual(before[method]["now"], False)
        run.unpin_full_glass(before)
        self.assertEqual(run.app.override, {m: None for m in gp.Run.FULL_GLASS_METHODS})

    def test_keeps_an_earlier_override(self):
        gp = self.load()
        run = gp.Run.__new__(gp.Run)
        run.app = FakeApp(system=False)
        run.app.override["debug.reduce_transparency"] = True
        before = run.pin_full_glass()
        run.unpin_full_glass(before)
        self.assertEqual(run.app.override["debug.reduce_transparency"], True)
        self.assertEqual(run.app.override["debug.low_power_mode"], None)


if __name__ == "__main__":
    unittest.main()
