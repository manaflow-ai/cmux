#!/usr/bin/env python3
"""Fast deterministic checks for the perf gate's incomplete-data contract."""
import importlib.util
import json
import re
import sys
import tempfile
import types
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


pb = load("perf_budgets", ROOT / "scripts/cmux-next/perf-budgets.py")
# The gate itself is pure, but importing the full xbench module normally loads
# macOS's libproc counters. Keep this Linux fast-tier test independent of that
# optional measurement backend.
# The stub is for this load only: left in sys.modules, a later suite's `import procs` gets it (#41653 review).
# Only the entry this file added comes back out, so xbench's real imports (budget, pages) stay registered.
_PROCS_STUB = types.SimpleNamespace()
sys.modules.setdefault("procs", _PROCS_STUB)
try:
    xbench = load("xbench", ROOT / "scripts/perf-bench/xbench.py")
finally:
    if sys.modules.get("procs") is _PROCS_STUB:
        del sys.modules["procs"]


class XbenchGateTests(unittest.TestCase):
    def write(self, directory, name, payload):
        path = Path(directory, name)
        path.write_text(json.dumps(payload))
        return str(path)

    def test_missing_current_cell_is_incomplete(self):
        row = "launch-window"
        baseline = {"rows": {row: {"cmux-chromium": {"median": 100}}}}
        current = {"rows": {}}
        with tempfile.TemporaryDirectory() as directory:
            baseline_path = self.write(directory, "baseline.json", baseline)
            current_path = self.write(directory, "current.json", current)
            self.assertEqual(xbench.gate(current_path, baseline_path, 0.15), 1)

    def test_missing_baseline_is_incomplete(self):
        current = {"rows": {"launch-window": {"cmux-chromium": {"median": 100}}}}
        with tempfile.TemporaryDirectory() as directory:
            baseline_path = self.write(directory, "baseline.json", {"rows": {}})
            current_path = self.write(directory, "current.json", current)
            self.assertEqual(xbench.gate(current_path, baseline_path, 0.15), 1)

    def test_allowlisted_unsupported_cell_is_green(self):
        row = "launch-window"
        browsers = [*xbench.CMUX, xbench.TAB_SWITCH_BROWSER]
        baseline = {"rows": {row: {browser: {"median": 100} for browser in browsers}},
                    "unsupported": [{"key": f"{row}|cmux-webkit", "reason": "WebKit unavailable"}]}
        current = {"rows": {row: {browser: {"median": 100} for browser in browsers if browser != "cmux-webkit"}}}
        with tempfile.TemporaryDirectory() as directory:
            baseline_path = self.write(directory, "baseline.json", baseline)
            current_path = self.write(directory, "current.json", current)
            self.assertEqual(xbench.gate(current_path, baseline_path, 0.15), 0)

    def test_new_dynamic_row_is_not_expected_until_baselined(self):
        row = "tab-switch-terminal-10-ctrl_tab"
        baseline = {"rows": {"launch-window": {"cmux-chromium": {"median": 100}}}}
        current = {"rows": {"launch-window": {"cmux-chromium": {"median": 100}},
                              row: {"cmux-debug": {"median": 12}}}}
        with tempfile.TemporaryDirectory() as directory:
            baseline_path = self.write(directory, "baseline.json", baseline)
            current_path = self.write(directory, "current.json", current)
            self.assertEqual(xbench.gate(current_path, baseline_path, 0.15), 0)

    def test_complete_matrix_still_passes(self):
        browsers = (*xbench.CMUX, xbench.TAB_SWITCH_BROWSER)
        row = "launch-window"
        baseline = {"rows": {row: {browser: {"median": 100} for browser in browsers}}}
        current = {"rows": {row: {browser: {"median": 100} for browser in browsers}}}
        with tempfile.TemporaryDirectory() as directory:
            baseline_path = self.write(directory, "baseline.json", baseline)
            current_path = self.write(directory, "current.json", current)
            self.assertEqual(xbench.gate(current_path, baseline_path, 0.15), 0)

    def test_checked_in_baseline_is_a_valid_self_comparison(self):
        baseline = ROOT / "scripts/perf-bench/baseline/apple-m6-macos27.json"
        self.assertEqual(xbench.gate(str(baseline), str(baseline), 0.15), 0)


class PerfBudgetManifestTests(unittest.TestCase):
    def test_missing_baseline_is_not_silently_complete(self):
        self.assertEqual(pb.incomplete_rows([], {}, {"panes": [r"panes\..*\.frame"]}, ["panes"]),
                         [{"name": r"panes\..*\.frame", "reason": "manifest row not measured"}])

    def test_receipt_counts_expected_and_measured_rows(self):
        counts = pb.completeness_counts(
            [{"name": "panes.split.4x2.frame", "p95": 8.0}],
            {"panes.split.4x2.frame": 8.0},
            {"panes": [r"panes\..*\.frame"]},
            ["panes"],
            [],
            [],
        )
        self.assertEqual(counts, {"expected": 1, "measured": 1, "unsupported": 0, "failed": 0, "incomplete": 0})

    def test_receipt_counts_a_manifest_family_without_baseline(self):
        counts = pb.completeness_counts(
            [{"name": "panes.split.4x2.frame", "p95": 8.0}],
            {},
            {"panes": [r"panes\..*\.frame"], "home": [r"home\.scroll\.frame"]},
            ["panes", "home"],
            [{"name": r"home\.scroll\.frame", "reason": "manifest row not measured"}],
            [],
        )
        self.assertEqual(counts, {"expected": 2, "measured": 1, "unsupported": 0, "failed": 0, "incomplete": 1})

    def test_unmeasured_row_blocks_a_new_baseline(self):
        rows = [{"name": "panes.split.4x2.frame", "p95": None}]
        self.assertEqual(pb.incomplete_rows(rows, {}, {"panes": [r"panes\..*\.frame"]}, ["panes"]),
                         [{"name": r"panes\..*\.frame", "reason": "manifest row not measured"}])

    def test_sidebar_click_switch_is_an_expected_family(self):
        manifest = json.loads((ROOT / "scripts/cmux-next/perf-budgets.json").read_text())["expected"]
        row = "sidebar.400.workspace_switch.click_to_idle"
        self.assertTrue(any(re.fullmatch(pattern, row) for pattern in manifest["sidebar"]))
        self.assertIn({"name": row, "reason": "missing current p95"},
                      pb.incomplete_rows([], {row: 16.7}, manifest, ["sidebar"]))


class PerfBudgetBenchOutputTests(unittest.TestCase):
    """A bench whose --out is its report file (home-perf.py) gets that file, not a folder at its path (cmux#24569:
    every perf cron home-idle part since 2026-10-23 ended "manifest row not measured" for both home rows)."""

    HOME_BENCH = (
        "import json, sys\n"
        "out = sys.argv[sys.argv.index('--out') + 1]\n"
        "json.dump({'typing': {'key_dispatch_ms': {'count': 88, 'p50': 4.76, 'p95': 5.64}},\n"
        "           'scroll': {'p50_ms': 8.33, 'p95_ms': 8.33}}, open(out, 'w'))\n"
    )

    def run_home(self, out, leftover_dir=False):
        script = Path(out, "fake-home-perf.py")
        script.write_text(self.HOME_BENCH)
        report = Path(out, "home.json")
        if leftover_dir:
            report.mkdir()  # what an earlier run of the old runner left on a warm checkout
        plan = {"home": ([sys.executable, str(script), "--tag", "t", "--out", str(report)], "home.json", pb.rows_home)}
        opts = types.SimpleNamespace(out=out, bench_timeout=60)
        runs, values = {}, {}
        pb.run_phase("", ["home"], plan, opts, runs, values)
        return runs, values

    def check_home_rows(self, leftover_dir):
        with tempfile.TemporaryDirectory() as out:
            runs, values = self.run_home(out, leftover_dir)
            self.assertEqual(runs["home"]["exit"], 0, Path(runs["home"]["log"]).read_text())
            self.assertEqual(values["home.typing.key_dispatch"], (4.76, 5.64))
            self.assertEqual(values["home.scroll.frame"], (8.33, 8.33))
            rows = [{"name": name, "p95": p95} for name, (_, p95) in values.items()]
            manifest = json.loads((ROOT / "scripts/cmux-next/perf-budgets.json").read_text())["expected"]
            self.assertEqual(pb.incomplete_rows(rows, {}, manifest, ["home"]), [])

    def test_home_report_file_is_written_and_read(self):
        self.check_home_rows(leftover_dir=False)

    def test_empty_folder_left_at_the_report_path_is_replaced(self):
        self.check_home_rows(leftover_dir=True)

    def test_folder_outs_are_still_made(self):
        with tempfile.TemporaryDirectory() as out:
            folder = Path(out, "sidebar")
            pb.prepare_outputs(["py", "bench.py", "--out", str(folder)], str(folder / "results.json"))
            self.assertTrue(folder.is_dir())


if __name__ == "__main__":
    unittest.main()
