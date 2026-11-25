"""launch: launch-ready.sh's step log (a real NIGHTLY run on a fleet Mac) becomes one row per launch mark."""
from __future__ import annotations

import io
import json
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.registry import load_all  # noqa: E402
from benchlib.bench import Context  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "launch"
NIGHTLY = {"channel": "nightly", "version": "4377899541301", "sha": None}


def ingest(path: Path, **args: str) -> Context:
    bench = load_all()["launch"]
    ctx = Context(bench=bench, build=dict(NIGHTLY), host_role="fleet", args=dict(args))
    bench.ingest(ctx, path)
    return ctx


def by_metric(ctx: Context) -> dict[str, dict]:
    return {(r["metric"], r["labels"].get("arm")): r for r in ctx.rows}


class LaunchIngest(unittest.TestCase):
    def test_log_rows(self) -> None:
        ctx = ingest(FIXTURES / "launch-ready-nightly.log")
        rows = by_metric(ctx)
        # The harness's own LR-MEDIAN line: finished_launching 685.6, window_on_screen 1081.5, main_start 594.4,
        # first_window_frame_committed 1224.5, home.first_page 1222.2; five relaunches, the priming launch left out.
        for metric, median in (("finished_launching", 685.6), ("window_on_screen", 1081.5), ("active", 643.2),
                               ("request_to_start", 16.8), ("main_start", 594.4), ("main_nsapp", 652.2),
                               ("first_window_frame_committed", 1224.5), ("home_first_page", 1222.2),
                               ("launch_snapshot_shown", 1041.3)):
            row = rows[(metric, "head")]
            self.assertAlmostEqual(row["value"], median, places=1, msg=metric)
            self.assertEqual(row["n"], 5, metric)
            self.assertEqual(row["unit"], "ms")
            self.assertEqual(row["better"], "lower")
            self.assertGreaterEqual(row["p95"], row["p50"])
        self.assertEqual(rows[("failed_launches", "head")]["value"], 0)
        self.assertEqual(ctx.host["name"], "cmux14")
        self.assertEqual(ctx.host["chip"], "Apple M4 Pro")
        self.assertEqual(ctx.host["os"], "macOS 27.0.1")
        self.assertTrue(all(r["harness"]["name"] == "scripts/measure/launch-ready.sh" for r in ctx.rows))

    def test_report_tgz_and_ab_sides(self) -> None:
        # report.tgz's runs.jsonl, with a base side and a failed run: rows per arm, the failure counted.
        lines = []
        for side, offset in (("base", 100.0), ("head", 0.0)):
            for label in ("prime", "run1", "run2", "run3"):
                lines.append({"side": side, "label": label, "finished_launching": 600 + offset,
                              "window_on_screen": 1000 + offset, "active": 590 + offset, "request_to_start": 15,
                              "marks": {"main_start": 550 + offset}})
        lines.append({"side": "head", "label": "run4", "window_on_screen": None, "error": "no window in 30 s",
                      "marks": {}})
        data = "".join(json.dumps(x) + "\n" for x in lines).encode()
        with tempfile.TemporaryDirectory() as tmp:
            tgz = Path(tmp) / "report.tgz"
            with tarfile.open(tgz, "w:gz") as tar:
                info = tarfile.TarInfo("./runs.jsonl")
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
            rows = by_metric(ingest(tgz))
        self.assertEqual(rows[("window_on_screen", "base")]["value"], 1100.0)
        self.assertEqual(rows[("window_on_screen", "head")]["value"], 1000.0)
        self.assertEqual(rows[("main_start", "base")]["n"], 3)
        self.assertEqual(rows[("failed_launches", "head")]["value"], 1)
        self.assertEqual(rows[("failed_launches", "base")]["value"], 0)

    def test_premain_log(self) -> None:
        # launch-premain.sh's LP-RUN lines: only the measured launch (role B) of each arm is a sample.
        lines = ['LP host cmux23 chip="Apple M4 Pro" macOS 26.1 session Aqua']
        for rep, (fast, slow) in enumerate(((44.0, 980.0), (47.0, 640.0), (41.0, None))):
            for arm, value in (("z", fast), ("a", slow)):
                lines.append("LP-RUN " + json.dumps({"arm": arm, "rep": rep + 1, "role": "A", "main_start": 30.0}))
                row = {"arm": arm, "rep": rep + 1, "role": "B", "main_start": value, "pageins": 900 if value and value > 100 else 200,
                       "resident_before": 0.4, "user_ms": 20.0}
                if value is None:
                    row["error"] = "no window in 30 s"
                lines.append("LP-RUN " + json.dumps(row))
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "step.log"
            log.write_text("\n".join(lines) + "\n")
            ctx = ingest(log)
        rows = {(r["metric"], r["labels"]["arm"]): r for r in ctx.rows}
        self.assertEqual(rows[("main_start", "z")]["value"], 44.0)
        self.assertEqual(rows[("main_start", "z")]["n"], 3)
        self.assertEqual(rows[("main_start", "a")]["value"], 810.0)
        self.assertEqual(rows[("failed_launches", "a")]["value"], 1)
        self.assertEqual(rows[("pageins", "a")]["value"], 900)
        self.assertTrue(all(r["labels"]["mode"] == "premain" for r in ctx.rows))
        self.assertEqual(ctx.host["name"], "cmux23")

    def test_premain_bench_nightly(self) -> None:
        # The standing detector: launch-premain runs nightly with the 60 s arm, its control and the relink arm.
        bench = load_all()["launch-premain"]
        self.assertTrue(bench.nightly)
        self.assertEqual(bench.nightly_args["arms"], "h,a,k")
        self.assertEqual(bench.harness, "scripts/measure/launch-premain.sh")

    def test_engines_arg(self) -> None:
        # engines=chromium,webkit reaches the harness and gives the second side its own time.
        bench = load_all()["launch"]
        build = dict(NIGHTLY, url="https://example.com/a.dmg")
        ctx = Context(bench=bench, build=build, host_role="fleet", args={"runs": "10", "engines": "chromium,webkit"})
        args, timeout = bench.ready_args(ctx)
        self.assertIn("engines=chromium,webkit", args)
        self.assertEqual(timeout, 2700)
        args, timeout = bench.ready_args(Context(bench=bench, build=build, host_role="fleet", args={}))
        self.assertFalse(any(a.startswith("engines=") for a in args))
        self.assertEqual(timeout, 1800)

    def test_registered(self) -> None:
        bench = load_all()["launch"]
        self.assertTrue(bench.nightly)
        self.assertEqual(bench.hosts, ("fleet",))

    def test_workspace_scaling_args(self) -> None:
        bench = load_all()["launch"]
        ctx = Context(bench=bench, build=dict(NIGHTLY), host_role="fleet",
                      args={"session": "stress3", "workspaces": "120", "windows": "1"})
        args, _ = bench.ready_args(ctx)
        for arg in ("session=stress3", "workspaces=120", "windows=1"):
            self.assertIn(arg, args)


if __name__ == "__main__":
    unittest.main()
