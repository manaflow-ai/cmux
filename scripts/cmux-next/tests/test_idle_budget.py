#!/usr/bin/env python3
"""idle-budget.py's pure parts: process kinds, per-kind sums, the budget check, the perf cron rows, and the
chrome-static reference (Chrome kinds, uBlock Origin parity, ratio rows; xbench's Chrome switches)."""

from __future__ import annotations

import importlib.util
import sys
import types
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "perf-bench"))
if sys.platform != "darwin":
    # procs reads macOS's libproc at import; the pure parts tested here need only its two helpers.
    sys.modules.setdefault("procs", types.SimpleNamespace(MB=1048576.0, _delta32=lambda last, first: (last - first) % 2**32))
spec = importlib.util.spec_from_file_location("idle_budget", HERE / "idle-budget.py")
ib = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ib)

APP = "/Users/x/DerivedData/cmux-t/Build/Products/Debug/cmux DEV t.app"
CHROME = "/Applications/Google Chrome.app"
CHROME_HELPERS = f"{CHROME}/Contents/Frameworks/Google Chrome Framework.framework/Versions/141.0.0.0/Helpers"
UBO_TARGET = {"type": "background_page", "url": f"chrome-extension://{ib.UBLOCK_ID}/background.html"}


def row(kind, threads, wakeups, cpu=0.0):
    return {"kind": kind, "threads": threads, "threads_ran": 0, "wakeups_per_s": wakeups, "csw_per_s": 0.0, "cpu_pct": cpu}


class IdleBudgetTests(unittest.TestCase):
    def test_kinds(self):
        self.assertEqual(ib.kind(f"{APP}/Contents/MacOS/cmux DEV"), "app")
        self.assertEqual(ib.kind(f"{APP}/Contents/Resources/bin/cmux-tui server --socket s"), "daemon")
        self.assertEqual(ib.kind(f"{APP}/Contents/Resources/bin/cmux-tui __holder --socket s"), "holder")
        self.assertEqual(ib.kind(f"{APP}/Contents/Resources/bin/cmux-tui __terminal-host --owner a@1"), "terminal-host")
        self.assertEqual(ib.kind(f"{APP}/Contents/Resources/bin/acpmux daemon"), "acpmux")
        self.assertEqual(ib.kind(f"{APP}/Contents/Frameworks/cmux Helper (Renderer).app/x --type=renderer"), "cef-renderer")
        self.assertEqual(ib.kind(f"{APP}/Contents/Frameworks/cmux Helper (GPU).app/x --type=gpu-process"), "cef-gpu")
        self.assertEqual(ib.kind("/bin/zsh -l"), "other:zsh")

    def test_aggregate_sums_and_maxes_per_kind(self):
        kinds = ib.aggregate({"processes": [row("terminal-host", 3, 0.0), row("terminal-host", 5, 0.5), row("app", 40, 2.0)],
                              "main_wakes_per_s": 1.5})
        self.assertEqual(kinds["terminal-host"]["n"], 2)
        self.assertEqual(kinds["terminal-host"]["threads"], 8)
        self.assertEqual(kinds["terminal-host"]["threads_max"], 5)
        self.assertEqual(kinds["terminal-host"]["wakeups_max"], 0.5)
        self.assertEqual(kinds["app"]["main_wakes_per_s"], 1.5)

    def test_over_budget_names_each_value_over_its_limit(self):
        budget = {"kinds": {"app": {"main_wakes_per_s": 0, "wakeups_per_s": 1.0, "threads_max": None},
                            "holder": {"wakeups_max": {"light": 0, "stress": 1}}}}
        kinds = {"app": {"main_wakes_per_s": 0.2, "wakeups_per_s": 0.9, "threads_max": 99},
                 "holder": {"wakeups_max": 0.5}}
        self.assertEqual(ib.over_budget("light", kinds, budget), [("app", "main_wakes_per_s", 0.2, 0), ("holder", "wakeups_max", 0.5, 0)])
        self.assertEqual(ib.over_budget("stress", kinds, budget), [("app", "main_wakes_per_s", 0.2, 0)])

    def test_cron_rows(self):
        report = {"sessions": {"light": {"kinds": {"app": {"wakeups_per_s": 0.4, "threads_max": 30, "main_wakes_per_s": 0}}}}}
        rows = ib.cron_rows(report, {"kinds": {"app": {"wakeups_per_s": 1.0}}})
        self.assertEqual(rows["idle_budget.light.app.wakeups_per_s"],
                         {"p50": 0.4, "p95": 0.4, "unit": "/s", "budget": 1.0, "floor": 0.5})
        self.assertEqual(rows["idle_budget.light.app.threads_max"]["unit"], "threads")
        self.assertIsNone(rows["idle_budget.light.app.threads_max"]["budget"])

    def test_checked_in_budget_parses(self):
        budget = ib.json.load(open(ib.BUDGET_FILE))
        self.assertEqual(budget["kinds"]["app"]["main_wakes_per_s"], 0)


class ChromeReferenceTests(unittest.TestCase):
    def chrome_block(self, kinds, ublock=None):
        return {"kinds": kinds, "ublock": ublock or ib.ublock_parity("1.75.0", "1.75.0", [UBO_TARGET])}

    def test_chrome_kinds(self):
        self.assertEqual(ib.chrome_kind(f"{CHROME}/Contents/MacOS/Google Chrome --user-data-dir=/p/data"), "browser")
        self.assertEqual(ib.chrome_kind(f"{CHROME_HELPERS}/Google Chrome Helper (Renderer).app/Contents/MacOS/"
                                        "Google Chrome Helper (Renderer) --type=renderer --renderer-client-id=7"), "renderer")
        self.assertEqual(ib.chrome_kind(f"{CHROME_HELPERS}/Google Chrome Helper (Renderer).app/Contents/MacOS/"
                                        "Google Chrome Helper (Renderer) --type=renderer --extension-process"), "extension")
        self.assertEqual(ib.chrome_kind(f"{CHROME_HELPERS}/Google Chrome Helper (GPU).app/Contents/MacOS/"
                                        "Google Chrome Helper (GPU) --type=gpu-process"), "gpu")
        self.assertEqual(ib.chrome_kind(f"{CHROME_HELPERS}/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper "
                                        "--type=utility --utility-sub-type=network.mojom.NetworkService"), "utility")
        self.assertEqual(ib.chrome_kind(f"{CHROME_HELPERS}/chrome_crashpad_handler --monitor-self"), "crashpad")

    def test_forty_against_sixty_three_and_a_half_at_half_is_over(self):
        kinds = {"app": {"wakeups_per_s": 10.0}, "cef-renderer": {"wakeups_per_s": 30.0}}
        chrome = self.chrome_block({"browser": {"wakeups_per_s": 20.0}, "renderer": {"wakeups_per_s": 43.5}})
        budget = {"ratio_to_chrome": [{"session": "tabs-static", "cmux": "tree", "chrome": "tree",
                                       "field": "wakeups_per_s", "limit": 0.5}]}
        self.assertEqual(ib.over_budget("tabs-static", kinds, budget, chrome),
                         [("tree:chrome-tree", "ratio_to_chrome.wakeups_per_s", 0.63, 0.5)])
        row = ib.ratio_to_chrome("tabs-static", kinds, chrome, budget)[0]
        self.assertEqual((row["cmux_value"], row["chrome_value"], row["over"]), (40.0, 63.5, True))
        self.assertEqual(ib.over_budget("tabs-static", {"app": {"wakeups_per_s": 31.0}}, budget, chrome), [])

    def test_without_ublock_in_chrome_ratios_are_unequal_and_not_judged(self):
        parity = ib.ublock_parity("1.75.0", None, [])
        self.assertFalse(parity["equal"])
        self.assertEqual(parity["unequal"], ["no uBlock Origin was loaded into Chrome"])
        chrome = self.chrome_block({"browser": {"wakeups_per_s": 63.5}}, parity)
        budget = {"ratio_to_chrome": [{"cmux": "tree", "chrome": "tree", "field": "wakeups_per_s", "limit": 0.5}]}
        kinds = {"app": {"wakeups_per_s": 40.0}}
        row = ib.ratio_to_chrome("tabs-static", kinds, chrome, budget)[0]
        self.assertTrue(row["over"])
        self.assertEqual(row["unequal"], ["no uBlock Origin was loaded into Chrome"])
        self.assertEqual(ib.over_budget("tabs-static", kinds, budget, chrome), [])

    def test_ublock_parity_needs_the_same_version_running(self):
        self.assertTrue(ib.ublock_parity("1.75.0", "1.75.0", [UBO_TARGET])["equal"])
        self.assertEqual(ib.ublock_parity("1.75.0", "1.75.0", [])["unequal"],
                         ["uBlock Origin 1.75.0 did not start in Chrome (no extension target)"])
        self.assertEqual(ib.ublock_parity("1.75.0", "1.74.0", [UBO_TARGET])["unequal"],
                         ["uBlock Origin 1.74.0 in Chrome, 1.75.0 in cmux"])
        self.assertIn("the cmux app bundles no uBlock Origin", ib.ublock_parity(None, "1.75.0", [UBO_TARGET])["unequal"])

    def test_chrome_at_zero_and_missing_sides(self):
        budget = {"ratio_to_chrome": [{"cmux": "cef-gpu", "chrome": "gpu", "field": "wakeups_per_s", "limit": 1.0},
                                      {"cmux": "cef-host", "chrome": "browser", "field": "wakeups_per_s", "limit": 1.0}]}
        chrome = self.chrome_block({"gpu": {"wakeups_per_s": 0.0}, "browser": {"wakeups_per_s": 2.0}})
        gpu, host = ib.ratio_to_chrome("tabs-static", {"cef-gpu": {"wakeups_per_s": 0.2}}, chrome, budget)
        self.assertEqual((gpu["ratio"], gpu["over"]), (None, True))
        self.assertEqual(host["missing"], ["cmux"])
        self.assertFalse(host["over"])
        self.assertEqual(ib.ratio_overs([gpu, host]), [("cef-gpu:chrome-gpu", "ratio_to_chrome.wakeups_per_s", 0.2, 1.0)])

    def test_report_gets_the_chrome_block_and_ratio_rows(self):
        report = {"sessions": {
            "tabs-static": {"kinds": {"app": {"wakeups_per_s": 40.0, "energy_mw": 5.0}}, "over": []},
            "light": {"kinds": {"app": {"wakeups_per_s": 1.0}}, "over": []},
            ib.CHROME_SESSION: {"chrome": {"app": CHROME, "version": "141.0",
                                           "ublock": ib.ublock_parity("1.75.0", "1.75.0", [UBO_TARGET])},
                                "kinds": {"browser": {"wakeups_per_s": 63.5, "energy_mw": 10.0}}}}}
        overs = ib.judge_against_chrome(report, {})
        self.assertEqual(report["chrome"]["version"], "141.0")
        self.assertEqual(report["chrome"]["kinds"]["browser"]["wakeups_per_s"], 63.5)
        fields = [(row["session"], row["cmux"], row["field"]) for row in report["ratio_to_chrome"]]
        self.assertEqual(fields, [(r["session"], r["cmux"], r["field"]) for r in ib.DEFAULT_RATIO_ROWS])
        self.assertEqual(overs, [("tabs-static", "tree:chrome-tree", "ratio_to_chrome.wakeups_per_s", 0.63, 0.5)])
        self.assertEqual(report["sessions"]["tabs-static"]["over"], [list(overs[0][1:])])
        self.assertEqual(report["sessions"]["light"]["over"], [])
        self.assertEqual(ib.judge_against_chrome({"sessions": {"light": {"kinds": {}}}}, {}), [])

    def test_process_rows_carry_energy(self):
        cmd = f"{CHROME}/Contents/MacOS/Google Chrome"
        first = {7: (cmd, (1_000_000_000, 0, 10, 0), (0, 30, 0, 0, 100), {})}
        last = {7: (cmd, (3_000_000_000, 500_000_000, 30, 1048576), (0, 31, 0, 0, 140), {}),
                8: (cmd, (2_000_000_000, 0, 4, 0), (0, 5, 0, 0, 2), {})}
        rows = ib.process_rows(first, last, 2.0, ib.chrome_kind)
        self.assertEqual([(r["pid"], r["energy_mw"], r["wakeups_per_s"], r["partial"]) for r in rows],
                         [(7, 1000.0, 10.0, False), (8, 1000.0, 2.0, True)])
        self.assertEqual(ib.aggregate({"processes": rows})["browser"]["energy_mw"], 2000.0)


class XbenchChromeSwitchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("xbench", HERE.parent / "perf-bench" / "xbench.py")
        cls.xbench = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.xbench)

    def test_extensions_load_with_one_disable_features(self):
        browser = self.xbench.ChromiumBrowser("chrome", CHROME, None, None, extensions=["/tmp/ubo"])
        switches = browser.switches()
        self.assertIn("--load-extension=/tmp/ubo", switches)
        features = [s for s in switches if s.startswith("--disable-features=")]
        self.assertEqual(len(features), 1)
        self.assertIn("DisableLoadExtensionCommandLineSwitch", features[0])
        self.assertIn("ChromeWhatsNewUI", features[0])
        plain = self.xbench.ChromiumBrowser("chrome", CHROME, None, None).switches()
        self.assertEqual([s for s in plain if s.startswith("--disable-features=")], ["--disable-features=ChromeWhatsNewUI"])
        self.assertFalse(any(s.startswith("--load-extension") for s in plain))


if __name__ == "__main__":
    unittest.main()
