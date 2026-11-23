"""xbench: results.json (a real cmux-budget run), the checked-in gate baselines and a tab-switch-matrix report."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
REPO = BENCH_DIR.parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import Context  # noqa: E402
from benches.xbench import BENCH, metric_of, unit_of  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "xbench"
BASELINE = REPO / "scripts" / "perf-bench" / "baseline"


def ctx(**args: str) -> Context:
    return Context(bench=BENCH, build={"channel": "nightly", "version": None, "sha": None}, host_role="fleet",
                   args=dict(args), timestamp="2026-11-16T00:00:00Z")


def find(rows, metric, **labels):
    got = [r for r in rows if r["metric"] == metric and all(r["labels"].get(k) == v for k, v in labels.items())]
    assert len(got) == 1, (metric, labels, len(got))
    return got[0]


class XBenchTest(unittest.TestCase):
    def test_budget_results(self):
        c = ctx()
        BENCH.ingest(c, FIXTURES / "results-budget.json")
        total = find(c.rows, "budget_memory_total", browser="cmux-budget")
        self.assertEqual((total["value"], total["unit"], total["n"]), (1525.2, "MB", 1))
        self.assertEqual(find(c.rows, "budget_idle_wakeups", browser="cmux-budget")["unit"], "per_s")
        self.assertEqual(find(c.rows, "budget_processes", browser="cmux-budget")["unit"], "count")
        disk = find(c.rows, "budget_idle_disk_writes_home", browser="cmux-budget")
        self.assertEqual(disk["unit"], "kbps")
        self.assertAlmostEqual(disk["value"], 2224.251 * 8.192, places=3)
        self.assertEqual(find(c.rows, "budget_spinners_20_cpu", browser="cmux-budget")["unit"], "%")
        self.assertEqual(len(c.rows), 26)
        self.assertTrue(all(r["better"] == "lower" for r in c.rows))
        # the document's own machine, build and date
        self.assertEqual(c.host["name"], "cmux22")
        self.assertEqual(c.build["sha"], "2667136414e398ac2be40cad35459fdcd0c994bb")
        self.assertEqual(c.rows[0]["timestamp"], "2026-11-15T00:00:00Z")
        self.assertTrue(any("the app did not hide" in n for n in c.notes))

    def test_checked_in_baseline_imports(self):
        c = ctx()
        BENCH.ingest(c, BASELINE / "apple-m6-macos27.json")
        mem = find(c.rows, "memory_20", browser="cmux-chromium")
        self.assertEqual((mem["value"], mem["unit"], mem["n"]), (1528.8, "MB", 3))
        self.assertEqual(find(c.rows, "power_idle_hidden", browser="cmux-terminal")["unit"], "mW")
        sw = find(c.rows, "tab_switch_e2e", browser="cmux-debug", kind="chromium", tabs="30", input="click")
        self.assertEqual(sw["value"], 29.009)
        # other browsers are rows too, named as the document names them
        self.assertGreater(len({r["labels"]["browser"] for r in c.rows}), 4)
        self.assertEqual(c.build, {"channel": "nightly", "version": "1.0.0-nightly.3944134600801",
                                   "sha": "3330ea7facf055addb18846e75fcde6311db7b7a"})
        self.assertEqual((c.host["name"], c.host["chip"], c.host["os"]), ("cmux20", "Apple M6", "macOS 27.0"))
        self.assertEqual(c.timestamp, "2026-10-20T00:00:00Z")

    def test_tab_switch_report(self):
        c = ctx()
        BENCH.ingest(c, BASELINE / "tab-switch-apple-m6-macos27.json")
        rows = [r for r in c.rows if r["metric"] == "tab_switch_e2e"]
        self.assertEqual(len(rows), 36)
        self.assertTrue(all(r["p95"] is not None and r["p95"] >= r["value"] for r in rows))

    def test_names_and_units(self):
        self.assertEqual(metric_of("idle-wakeups-20"), ("idle_wakeups_20", {}))
        self.assertEqual(metric_of("palette-open-terminal-cmd-p"), ("palette_open", {"surface": "terminal-cmd-p"}))
        self.assertEqual(unit_of("budget-idle-csw-app-hidden"), ("per_s", 1.0))
        self.assertIsNone(unit_of("no-such-row"))

    def test_harness_args(self):
        args, ref = BENCH.harness_args(ctx())
        self.assertIsNone(ref)
        self.assertIn("cmux=nightly", args)
        self.assertIn("browsers=cmux-chromium,cmux-budget", args)
        c = Context(bench=BENCH, build={"channel": "sha", "version": None, "sha": "a" * 40}, host_role="fleet",
                    args={"rounds": "3", "nonsense": "x"})
        args, ref = BENCH.harness_args(c)
        self.assertEqual(ref, "a" * 40)
        self.assertIn("cmux=build", args)
        self.assertIn("rounds=3", args)
        self.assertFalse(any(a.startswith("nonsense") for a in args))


if __name__ == "__main__":
    unittest.main()
