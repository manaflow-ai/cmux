#!/usr/bin/env python3
"""idle-budget.py's pure parts: process kinds, per-kind sums, the budget check and the perf cron rows; procs.py's
counters (interrupt and package-idle wakeups apart, billed energy, GPU time, the coalition); and the chrome-static
reference (Chrome kinds, uBlock Origin parity, ratio rows; xbench's Chrome switches)."""

from __future__ import annotations

import importlib.util
import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "perf-bench"))
spec = importlib.util.spec_from_file_location("idle_budget", HERE / "idle-budget.py")
ib = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ib)
procs = ib.procs

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
        self.assertEqual(ib.kind(f"{APP}/Contents/Frameworks/cmux Helper (Renderer).app/x --type=renderer --extension-process"),
                         "cef-extension")
        self.assertEqual(ib.kind(f"{APP}/Contents/Frameworks/cmux Helper.app/x --type=utility --utility-sub-type=n"), "cef-utility")
        self.assertEqual(ib.kind(f"{APP}/Contents/Frameworks/cmux Helper.app/Contents/MacOS/cmux Helper"), "cef-helper")
        self.assertEqual(ib.kind(f"{APP}/Contents/Frameworks/cmux Chromium Host.app/Contents/MacOS/cmux Chromium Host --x"),
                         "cef-host")
        # A --type process outside a Helper app is not a Chromium helper: the app binary is the app.
        self.assertEqual(ib.kind(f"{APP}/Contents/MacOS/cmux DEV --type=renderer"), "app")
        self.assertEqual(ib.kind("/bin/zsh -l"), "other:zsh")

    def test_every_chromium_kind_has_a_budget_row(self):
        with open(ib.BUDGET_FILE) as handle:
            budget = json.load(handle)
        for name in ("cef-gpu", "cef-renderer", "cef-extension", "cef-utility", "cef-host"):
            self.assertIn(name, budget["kinds"])

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
        self.assertIn("energy_mw_billed", budget["kinds"]["app"])
        self.assertIn("gpu_ms_per_s", budget["kinds"]["app"])


def rusage_words(pkg_idle=0, interrupt=0, energy=0, billed=0, serviced=0, user=0, system=0, footprint=0):
    """An rusage_info_v6 as proc_pid_rusage fills it (64 words), with the words procs reads."""
    words = [0] * 64
    words[2], words[3], words[4], words[5], words[9] = user, system, pkg_idle, interrupt, footprint
    words[33], words[34], words[42] = billed, serviced, energy
    return words


class CountersTests(unittest.TestCase):
    """procs.py's counters as Chrome defines them (base/process/process_metrics_apple.mm,
    components/power_metrics/resource_coalition_mac.mm)."""

    def test_interrupt_and_package_idle_wakeups_are_reported_apart(self):
        first = procs.usage_from_words(rusage_words(), 1, 1)
        last = procs.usage_from_words(rusage_words(pkg_idle=4, interrupt=10), 1, 1)
        got = procs.rates(first, last, 1.0)
        self.assertEqual(got["wakeups_per_s"], 10)  # not 14: package-idle wakeups are a subset
        self.assertEqual(got["pkg_idle_wakeups_per_s"], 4)

    def test_billed_energy_adds_billed_and_takes_off_serviced(self):
        first = procs.usage_from_words(rusage_words(energy=1_000_000, billed=500_000, serviced=0), 1, 1)
        last = procs.usage_from_words(rusage_words(energy=11_000_000, billed=6_500_000, serviced=2_000_000), 1, 1)
        got = procs.rates(first, last, 2.0)
        self.assertEqual(got["energy_mw_cpu"], 5.0)
        self.assertEqual(got["energy_mw_billed"], 7.0)  # (10 + 6 - 2) mJ over 2 s

    def test_cpu_time_uses_the_timebase(self):
        last = procs.usage_from_words(rusage_words(user=375, system=125), 125, 3)
        self.assertEqual(last.cpu_ns, 500 * 125 // 3)
        self.assertEqual(procs.rates(None, last, 1.0)["cpu_pct"], 100 * (500 * 125 // 3) / 1e9)

    def test_gpu_time_per_pid_from_the_registry(self):
        registry = [{"IORegistryEntryChildren": [
            {"IOUserClientCreator": "pid 42, cmux", "AppUsage": [{"accumulatedGPUTime": 3_000_000},
                                                                  {"accumulatedGPUTime": 1_000_000}]},
            {"IOUserClientCreator": "pid 42, cmux", "AppUsage": [{"accumulatedGPUTime": 2_000_000}]},
            {"IOUserClientCreator": "pid 7, WindowServer", "AppUsage": [{"accumulatedGPUTime": 9}]},
            {"IOUserClientCreator": "pid 8, idle"}]}]
        self.assertEqual(procs.gpu_ns_from_registry(registry), {42: 6_000_000, 7: 9})
        self.assertEqual(procs.gpu_ms_per_s({42: 1_000_000}, {42: 6_000_000}, 42, 2.0), 2.5)
        self.assertEqual(procs.gpu_ms_per_s({}, {}, 42, 2.0), 0)
        self.assertIsNone(procs.gpu_ms_per_s(None, {42: 1}, 42, 2.0))

    def test_coalition_rates(self):
        def words(energy, to_me, to_others, gpu_ns, cpu_ticks, interrupt, idle):
            w = [0] * procs._CRU_WORDS
            w[3], w[4], w[5], w[8], w[11], w[20], w[21] = cpu_ticks, interrupt, idle, gpu_ns, energy, to_me, to_others
            return w
        first = procs.coalition_from_words(words(0, 0, 0, 0, 0, 0, 0), 125, 3)
        last = procs.coalition_from_words(words(4_000_000, 3_000_000, 1_000_000, 8_000_000, 24_000_000, 20, 6), 125, 3)
        self.assertEqual(last.gpu_ns, 8_000_000)  # ns already, not timebase ticks
        self.assertEqual(last.cpu_ns, 1_000_000_000)
        got = procs.coalition_rates(first, last, 2.0)
        self.assertEqual(got, {"energy_mw_cpu": 2.0, "energy_mw_billed": 3.0, "gpu_ms_per_s": 4.0, "cpu_pct": 50.0,
                               "wakeups_per_s": 10.0, "pkg_idle_wakeups_per_s": 3.0})

    def test_a_coalition_read_failure_is_null_not_zero(self):
        last = procs.coalition_from_words([0] * procs._CRU_WORDS, 1, 1)
        self.assertIsNone(procs.coalition_rates(None, last, 1.0))
        self.assertIsNone(procs.coalition_rates(last, None, 1.0))
        self.assertEqual(ib.coalition_line(None), "app coalition: not readable")

    def test_report_has_cpu_and_billed_energy_and_gpu_per_kind(self):
        first = procs.usage_from_words(rusage_words(), 1, 1)
        last = procs.usage_from_words(rusage_words(pkg_idle=4, interrupt=10, energy=3_000_000, billed=1_000_000,
                                                   footprint=int(procs.MB)), 1, 1)
        app = ib.process_row(1, f"{APP}/Contents/MacOS/cmux DEV", first, last, 1.0, gpu=1.5, threads_now=30, csw=12, ran=[])
        daemon = ib.process_row(2, f"{APP}/Contents/Resources/bin/cmux-tui server", first, last, 1.0, gpu=None,
                                threads_now=4, csw=0, ran=[])
        started = ib.process_row(3, f"{APP}/Contents/MacOS/cmux DEV", None, last, 1.0, gpu=0.5, threads_now=1, csw=0, ran=[])
        self.assertEqual((app["wakeups_per_s"], app["pkg_idle_wakeups_per_s"]), (10, 4))
        self.assertTrue(started["partial"])
        self.assertFalse(app["partial"])
        kinds = ib.aggregate({"processes": [app, daemon, started]})
        self.assertEqual(kinds["app"]["energy_mw_cpu"], 6.0)
        self.assertEqual(kinds["app"]["energy_mw_billed"], 8.0)
        self.assertEqual(kinds["app"]["gpu_ms_per_s"], 2.0)
        self.assertEqual(kinds["app"]["wakeups_per_s"], 20)
        self.assertEqual(kinds["app"]["pkg_idle_wakeups_per_s"], 8)
        self.assertIsNone(kinds["daemon"]["gpu_ms_per_s"])  # no registry read: unknown, not 0
        self.assertIn("billed mW", ib.table("light", kinds, []))

    def test_cron_rows_carry_billed_energy_and_gpu(self):
        report = {"sessions": {"light": {"kinds": {"app": {"energy_mw_billed": 3.5, "gpu_ms_per_s": None}}}}}
        rows = ib.cron_rows(report, {"kinds": {"app": {"energy_mw_billed": None}}})
        self.assertEqual(rows["idle_budget.light.app.energy_mw_billed"]["unit"], "mW")
        self.assertNotIn("idle_budget.light.app.gpu_ms_per_s", rows)

    def test_instance_window_totals(self):
        rows = [{"kind": "main", "threads": 3, "mw": 1.0, "energy_mw_cpu": 1.0, "energy_mw_billed": 2.0,
                 "gpu_ms_per_s": 0.5, "wakeups_per_s": 10.0, "pkg_idle_wakeups_per_s": 4.0},
                {"kind": "gpu", "threads": 5, "mw": 2.0, "energy_mw_cpu": 2.0, "energy_mw_billed": 2.0,
                 "gpu_ms_per_s": None, "wakeups_per_s": 1.0, "pkg_idle_wakeups_per_s": 0.0}]
        got = procs.window_totals(rows)
        self.assertEqual((got["wakeups_per_s"], got["pkg_idle_wakeups_per_s"]), (11.0, 4.0))
        self.assertEqual(got["energy_mw_billed"], 4.0)
        self.assertIsNone(got["gpu_ms_per_s"])
        self.assertEqual(got["kinds"]["main"]["gpu_ms_per_s"], 0.5)
        self.assertEqual((got["threads"], got["processes"]), (8, 2))
        self.assertEqual(list(got["kinds"]), ["gpu", "main"])  # by CPU energy

    def test_xbench_records_companion_rows_from_the_same_window(self):
        sys.path.insert(0, str(HERE.parent / "perf-bench"))
        import xbench
        rows = xbench.window_rows({"power-idle-visible": "mw", "idle-cpu-20": "cpu_pct", "idle-wakeups-20": "wakeups_per_s"})
        self.assertEqual(rows["power-idle-visible-billed"], "energy_mw_billed")
        self.assertEqual(rows["power-idle-visible-gpu"], "gpu_ms_per_s")
        self.assertEqual(rows["idle-wakeups-20-pkg-idle"], "pkg_idle_wakeups_per_s")
        self.assertNotIn("idle-cpu-20-billed", rows)
        self.assertEqual(xbench.ROW_INFO["power-idle-visible-gpu"][1], "ms/s")
        self.assertEqual(xbench.fmt(2.25, "ms/s"), "2.2 ms/s")
        self.assertIn("ms/s", xbench.FLOORS)


def ratio_rule(of, vs, field, max_ratio, session="tabs-static"):
    return {"source": "idle-budget", "session": session, "of": of, "vs": vs, "field": field, "max_ratio": max_ratio}


class ChromeReferenceTests(unittest.TestCase):
    """The chrome-static reference (p14-energy-004): Google Chrome with tabs-static's pages and uBlock Origin."""

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
        self.assertEqual(ib.chrome_kind(f"{CHROME_HELPERS}/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper "
                                        "--type=ppapi"), "other")

    def test_forty_against_sixty_three_and_a_half_at_half_is_over(self):
        kinds = {"app": {"wakeups_per_s": 10.0}, "cef-renderer": {"wakeups_per_s": 30.0}}
        chrome = self.chrome_block({"browser": {"wakeups_per_s": 20.0}, "renderer": {"wakeups_per_s": 43.5}})
        budget = {"ratio_to_chrome": [ratio_rule("tree", "tree", "wakeups_per_s", 0.5)]}
        self.assertEqual(ib.over_budget("tabs-static", kinds, budget, chrome),
                         [("tree", "wakeups_per_s/chrome:tree", 0.63, 0.5)])
        row = ib.ratio_to_chrome("tabs-static", kinds, chrome, budget)[0]
        self.assertEqual((row["cmux_value"], row["chrome_value"], row["over"]), (40.0, 63.5, True))
        self.assertEqual(ib.over_budget("tabs-static", {"app": {"wakeups_per_s": 31.0}}, budget, chrome), [])
        self.assertEqual(ib.over_budget("light", kinds, budget, chrome), [])  # the row is tabs-static's

    def test_without_ublock_in_chrome_ratios_are_unequal_and_not_judged(self):
        parity = ib.ublock_parity("1.75.0", None, [])
        self.assertFalse(parity["equal"])
        self.assertEqual(parity["unequal"], ["no uBlock Origin was loaded into Chrome"])
        chrome = self.chrome_block({"browser": {"wakeups_per_s": 63.5}}, parity)
        budget = {"ratio_to_chrome": [ratio_rule("tree", "tree", "wakeups_per_s", 0.5)]}
        kinds = {"app": {"wakeups_per_s": 40.0}}
        row = ib.ratio_to_chrome("tabs-static", kinds, chrome, budget)[0]
        self.assertTrue(row["over"])
        self.assertEqual(row["unequal"], ["no uBlock Origin was loaded into Chrome"])
        self.assertEqual(ib.over_budget("tabs-static", kinds, budget, chrome), [])
        self.assertIn("unequal: no uBlock Origin was loaded into Chrome", ib.ratio_table([row]))

    def test_ublock_parity_needs_the_same_version_running(self):
        self.assertTrue(ib.ublock_parity("1.75.0", "1.75.0", [UBO_TARGET])["equal"])
        self.assertEqual(ib.ublock_parity("1.75.0", "1.75.0", [])["unequal"],
                         ["uBlock Origin 1.75.0 did not start in Chrome (no extension target)"])
        self.assertEqual(ib.ublock_parity("1.75.0", "1.74.0", [UBO_TARGET])["unequal"],
                         ["uBlock Origin 1.74.0 in Chrome, 1.75.0 in cmux"])
        self.assertIn("the cmux app bundles no uBlock Origin", ib.ublock_parity(None, "1.75.0", [UBO_TARGET])["unequal"])

    def test_manifest_version(self):
        import tempfile
        with tempfile.TemporaryDirectory() as folder:
            self.assertIsNone(ib.manifest_version(folder))
            Path(folder, "manifest.json").write_text(json.dumps({"version": "1.75.0"}))
            self.assertEqual(ib.manifest_version(folder), "1.75.0")

    def test_chrome_at_zero_and_missing_sides(self):
        budget = {"ratio_to_chrome": [ratio_rule("cef-gpu", "gpu", "wakeups_per_s", 1.0),
                                      ratio_rule("cef-host", "browser", "wakeups_per_s", 1.0)]}
        chrome = self.chrome_block({"gpu": {"wakeups_per_s": 0.0}, "browser": {"wakeups_per_s": 2.0}})
        gpu, host = ib.ratio_to_chrome("tabs-static", {"cef-gpu": {"wakeups_per_s": 0.2}}, chrome, budget)
        self.assertEqual((gpu["ratio"], gpu["over"]), (None, True))
        self.assertEqual(host["missing"], ["cmux"])
        self.assertFalse(host["over"])
        self.assertEqual(ib.ratio_overs([gpu, host]), [("cef-gpu", "wakeups_per_s/chrome:gpu", 0.2, 1.0)])

    def test_an_unknown_kind_makes_the_tree_unknown(self):
        kinds = {"app": {"gpu_ms_per_s": 1.0}, "daemon": {"gpu_ms_per_s": None}}
        self.assertIsNone(ib.kind_value(kinds, "tree", "gpu_ms_per_s"))
        self.assertEqual(ib.kind_value(kinds, "app", "gpu_ms_per_s"), 1.0)
        self.assertIsNone(ib.kind_value({}, "tree", "wakeups_per_s"))

    def test_budget_rows_replace_the_defaults_and_xbench_rows_are_skipped(self):
        xbench_row = {"source": "xbench", "browser": "cmux-chromium", "row": "idle-wakeups-20", "max_ratio": 0.5}
        self.assertEqual(ib.ratio_rules({"ratio_to_chrome": [xbench_row]}), ib.DEFAULT_RATIO_ROWS)
        own = ratio_rule("tree", "tree", "energy_mw_billed", 0.8)
        self.assertEqual(ib.ratio_rules({"ratio_to_chrome": [xbench_row, own]}), [own])
        self.assertEqual(ib.ratio_rules({}), ib.DEFAULT_RATIO_ROWS)

    def test_report_gets_the_chrome_block_and_ratio_rows(self):
        report = {"sessions": {
            "tabs-static": {"kinds": {"app": {"wakeups_per_s": 40.0, "energy_mw_billed": 5.0}}, "over": []},
            "light": {"kinds": {"app": {"wakeups_per_s": 1.0}}, "over": []},
            ib.CHROME_SESSION: {"chrome": {"app": CHROME, "version": "141.0",
                                           "ublock": ib.ublock_parity("1.75.0", "1.75.0", [UBO_TARGET])},
                                "kinds": {"browser": {"wakeups_per_s": 63.5, "energy_mw_billed": 10.0}}}}}
        overs = ib.judge_against_chrome(report, {})
        self.assertEqual(report["chrome"]["version"], "141.0")
        self.assertEqual(report["chrome"]["kinds"]["browser"]["wakeups_per_s"], 63.5)
        rows = [(row["session"], row["of"], row["field"]) for row in report["ratio_to_chrome"]]
        self.assertEqual(rows, [(r["session"], r["of"], r["field"]) for r in ib.DEFAULT_RATIO_ROWS])
        energy = report["ratio_to_chrome"][1]
        self.assertEqual((energy["ratio"], energy["over"]), (0.5, False))
        self.assertEqual(overs, [("tabs-static", "tree", "wakeups_per_s/chrome:tree", 0.63, 0.5)])
        self.assertEqual(report["sessions"]["tabs-static"]["over"], [list(overs[0][1:])])
        self.assertEqual(report["sessions"]["light"]["over"], [])
        self.assertEqual(report["sessions"]["tabs-static"]["ratio_to_chrome"], report["ratio_to_chrome"])
        self.assertEqual(ib.judge_against_chrome({"sessions": {"light": {"kinds": {}}}}, {}), [])

    def test_chrome_rows_count_like_cmux_rows(self):
        cmd = f"{CHROME}/Contents/MacOS/Google Chrome"
        start = procs.usage_from_words(rusage_words(interrupt=10, energy=1_000_000_000), 1, 1)
        end = procs.usage_from_words(rusage_words(interrupt=30, energy=3_000_000_000, billed=500_000_000), 1, 1)
        born = procs.usage_from_words(rusage_words(interrupt=4, energy=2_000_000_000), 1, 1)
        first = {7: (cmd, start, (0, 30, 0, 0, 100), {})}
        last = {7: (cmd, end, (0, 31, 0, 0, 140), {1: (2_000, "CrBrowserMain")}),
                8: (cmd, born, (0, 5, 0, 0, 2), {})}
        rows = ib.process_rows(first, last, 2.0, {7: 0}, {7: 4_000_000}, ib.chrome_kind)
        self.assertEqual([(r["pid"], r["kind"], r["energy_mw_cpu"], r["energy_mw_billed"], r["wakeups_per_s"], r["partial"])
                          for r in rows], [(7, "browser", 1000.0, 1250.0, 10.0, False), (8, "browser", 1000.0, 1000.0, 2.0, True)])
        self.assertEqual((rows[0]["gpu_ms_per_s"], rows[0]["csw_per_s"], rows[0]["threads_ran"]), (2.0, 20.0, 1))
        browser = ib.aggregate({"processes": rows})["browser"]
        self.assertEqual((browser["n"], browser["energy_mw_billed"], browser["wakeups_per_s"]), (2, 2250.0, 12.0))


class XbenchChromeSwitchTests(unittest.TestCase):
    def test_extensions_load_with_one_disable_features(self):
        import xbench
        browser = xbench.ChromiumBrowser("chrome", CHROME, None, None, extensions=["/tmp/ubo"])
        switches = browser.switches()
        self.assertIn("--load-extension=/tmp/ubo", switches)
        features = [s for s in switches if s.startswith("--disable-features=")]
        self.assertEqual(len(features), 1)
        self.assertIn("DisableLoadExtensionCommandLineSwitch", features[0])
        self.assertIn("ChromeWhatsNewUI", features[0])
        plain = xbench.ChromiumBrowser("chrome", CHROME, None, None).switches()
        self.assertEqual([s for s in plain if s.startswith("--disable-features=")], ["--disable-features=ChromeWhatsNewUI"])
        self.assertFalse(any(s.startswith("--load-extension") for s in plain))


if __name__ == "__main__":
    unittest.main()
