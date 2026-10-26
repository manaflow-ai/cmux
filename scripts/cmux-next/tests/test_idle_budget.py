#!/usr/bin/env python3
"""idle-budget.py's pure parts: process kinds, per-kind sums, the v2 budget check (sessions, sums, ratios,
assertions) and the perf cron rows; and procs.py's counters (interrupt and package-idle wakeups apart,
billed energy, GPU time, the coalition). Runs on any host (libproc loads only to measure)."""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
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
        budget = ib.load_budget(ib.BUDGET_FILE)
        self.assertEqual(budget["version"], 2)
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

    # -- v2 (p14-energy-002) ------------------------------------------------------------------------------

    def test_v2_kinds(self):
        frameworks = f"{APP}/Contents/Frameworks"
        host = f"{frameworks}/cmux DEV t Chromium Host.app/Contents/MacOS/cmux DEV t Chromium Host"
        self.assertEqual(ib.kind(host), "cef-host")
        self.assertEqual(ib.kind(f"{host} --remote-debugging-port=0"), "cef-host")
        helper = f"{frameworks}/cmux Helper.app/Contents/MacOS/cmux Helper"
        self.assertEqual(ib.kind(f"{helper} --type=renderer --extension-process"), "cef-extension")
        self.assertEqual(ib.kind(f"{helper} --type=utility --utility-sub-type=network.mojom.NetworkService"), "cef-network")
        self.assertEqual(ib.kind(f"{helper} --type=utility --utility-sub-type=storage.mojom.StorageService"), "cef-storage")
        self.assertEqual(ib.kind(f"{helper} --type=utility --utility-sub-type=audio.mojom.AudioService"), "cef-audio")
        self.assertEqual(ib.kind(f"{helper} --type=utility --utility-sub-type=data_decoder.mojom.DataDecoderService"),
                         "cef-utility")
        self.assertEqual(ib.kind(f"{helper} --type=crashpad-handler --database=x"), "crashpad")
        self.assertEqual(ib.kind(f"{APP}/Contents/MacOS/cmux DEV"), "app")

    def test_app_plus_daemon_sum_is_an_over(self):
        budget = ib.load_budget(ib.BUDGET_FILE)
        kinds = {"app": {"wakeups_per_s": 0.7, "main_wakes_per_s": 0.2}, "daemon": {"wakeups_per_s": 0.4}}
        overs = ib.over_budget("tabs-static", kinds, budget)
        self.assertIn(("app+daemon", "wakeups_per_s", 1.1, 1.0), overs)
        self.assertEqual(ib.over_line("tabs-static", ("app+daemon", "wakeups_per_s", 1.1, 1.0)),
                         "IDLE-BUDGET-OVER tabs-static app+daemon wakeups_per_s 1.1 > 1.0")
        # Each alone is within its own kind limit: only the sum is over.
        self.assertEqual([o for o in overs if o[0] in ("app", "daemon")], [])
        rows = ib.cron_rows({"sessions": {"tabs-static": {"kinds": kinds}}}, budget)
        self.assertEqual(rows["idle_budget.tabs-static.app+daemon.wakeups_per_s"]["p50"], 1.1)
        self.assertEqual(rows["idle_budget.tabs-static.app+daemon.wakeups_per_s"]["budget"], 1.0)
        self.assertIn("idle_budget.tabs-static.tree.wakeups_per_s", rows)

    def test_v1_file_still_loads_and_judges(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "v1.json"
            path.write_text(json.dumps({"kinds": {"app": {"main_wakes_per_s": 0, "wakeups_per_s": 1.0},
                                                  "holder": {"wakeups_max": {"light": 0}}}}))
            budget = ib.load_budget(str(path))
        self.assertEqual(budget["version"], 1)
        self.assertEqual(budget["sessions"], {})
        kinds = {"app": {"main_wakes_per_s": 0.2, "wakeups_per_s": 1.5}, "holder": {"wakeups_max": 0.5}}
        self.assertEqual(ib.over_budget("light", kinds, budget),
                         [("app", "main_wakes_per_s", 0.2, 0), ("app", "wakeups_per_s", 1.5, 1.0),
                          ("holder", "wakeups_max", 0.5, 0)])
        rows = ib.cron_rows({"sessions": {"light": {"kinds": kinds}}}, budget)
        self.assertEqual(rows["idle_budget.light.app.wakeups_per_s"]["budget"], 1.0)

    def test_d2_to_d7_sessions_and_numbers(self):
        budget = ib.load_budget(ib.BUDGET_FILE)
        sessions = budget["sessions"]

        def limit(session, name, field):
            return ib.limit_for(budget, session, name, field)

        # D2: light-webkit keeps the owner's zeros and tightens; light takes D4's Chromium limits.
        self.assertEqual(limit("light-webkit", "app", "main_wakes_per_s"), 0)
        self.assertEqual(limit("light-webkit", "holder", "wakeups_max"), 0)
        self.assertEqual(limit("light-webkit", "terminal-host", "wakeups_max"), 0)
        self.assertEqual(limit("light-webkit", "app", "wakeups_per_s"), 0.5)
        self.assertEqual(limit("light-webkit", "daemon", "wakeups_per_s"), 0.2)
        self.assertEqual(limit("light-webkit", "acpmux", "wakeups_max"), 0.1)
        self.assertEqual(sessions["light-webkit"]["sums"]["tree"]["energy_mw_billed"], 1.0)
        self.assertEqual(limit("light", "app", "wakeups_per_s"), 1.0)
        self.assertEqual(limit("light", "app", "main_wakes_per_s"), 0.5)
        # D3: hidden, minimized, occluded, each no higher than light on the same run, and napped.
        for name in ("light-hidden", "minimized", "occluded"):
            self.assertEqual(limit(name, "app", "wakeups_per_s"), 0.3)
            self.assertEqual(limit(name, "app", "main_wakes_per_s"), 0.1)
            self.assertEqual(limit(name, "app", "role"), "napped")
            self.assertEqual({(r["to"], r["max_ratio"]) for r in sessions[name]["relative"]}, {("light", 1.0)})
        # D4 tabs-static.
        self.assertEqual(sessions["tabs-static"]["sums"]["app+daemon"]["wakeups_per_s"], 1.0)
        self.assertEqual(limit("tabs-static", "app", "main_wakes_per_s"), 0.5)
        self.assertEqual(limit("tabs-static", "cef-renderer", "hidden_wakeups_max"), 0.1)
        self.assertEqual(limit("tabs-static", "cef-extension", "wakeups_max"), 0.1)
        self.assertEqual(limit("tabs-static", "cef-network", "wakeups_per_s"), 0.2)
        self.assertEqual(limit("tabs-static", "webkit-webcontent", "hidden_wakeups_max"), 0.5)
        # D5 stress-static.
        self.assertEqual(sessions["stress-static"]["sums"]["app+daemon"]["wakeups_per_s"], 1.0)
        self.assertEqual(limit("stress-static", "app", "main_wakes_per_s"), 0.5)
        # D6 Chrome ratios.
        chrome = {(r.get("row") or f"{r['of']}/{r['vs']}.{r['field']}"): r["max_ratio"] for r in budget["ratio_to_chrome"]}
        self.assertEqual(chrome["idle-wakeups-20"], 0.5)
        self.assertEqual(chrome["idle-wakeups-1"], 0.5)
        self.assertEqual(chrome["power-idle-visible"], 1.0)
        self.assertEqual(chrome["power-idle-hidden"], 1.0)
        self.assertEqual(chrome["cef-host/browser.wakeups_per_s"], 1.0)
        self.assertEqual(chrome["cef-gpu/gpu.wakeups_per_s"], 1.0)
        # D7 energy saver.
        for name, reason in (("energy-saver", "setting"), ("energy-saver-auto", "battery")):
            self.assertEqual(sessions[name]["limits"]["page_raf_per_s"], 31)
            self.assertEqual(sessions[name]["expect"], {"saver": True, "saver_reason": reason})
            self.assertEqual(sessions[name]["relative"],
                             [{"to": "tabs-static", "of": "tree", "field": "wakeups_per_s", "max_ratio": 0.6}])
        self.assertEqual(sessions["energy-saver-auto"]["simulate"], {"on_battery": True, "percent": 15})

    def test_assertion_with_keep_awake_off_is_an_over(self):
        budget = ib.load_budget(ib.BUDGET_FILE)
        held = [{"pid": 4242, "type": "PreventUserIdleSystemSleep", "name": "cmux keep awake"}]
        off = {"sessions.keepAwake": "off", "phone.keepAwake": "off"}
        over = ("assertions", "held", 1, 0)
        self.assertIn(over, ib.over_budget("light", {}, budget, facts={"assertions": held, "settings": off}))
        self.assertIn(over, ib.over_budget("light", {}, budget, facts={"assertions": held}))
        for key in ("sessions.keepAwake", "phone.keepAwake"):
            on = {**off, key: "always"}
            self.assertEqual(ib.over_budget("light", {}, budget, facts={"assertions": held, "settings": on}), [])
        self.assertEqual(ib.over_budget("light", {}, budget, facts={"assertions": [], "settings": off}), [])

    def test_relative_and_chrome_ratios(self):
        budget = ib.load_budget(ib.BUDGET_FILE)
        light = {"app": {"wakeups_per_s": 0.2, "main_wakes_per_s": 0.05}}
        hidden = {"app": {"wakeups_per_s": 0.25, "main_wakes_per_s": 0.0}}
        self.assertEqual(ib.over_budget("light-hidden", hidden, budget, others={"light": light}),
                         [("app", "wakeups_per_s/light", 1.25, 1.0)])
        self.assertEqual(ib.over_budget("light-hidden", hidden, budget), [])  # light not measured in this run
        # 40/s vs Chrome's 63.5/s at 0.5 (task 004's fixture), and a Chromium Host above Chrome's browser process.
        cmux = {"app": {"wakeups_per_s": 30.0, "main_wakes_per_s": 0.4}, "daemon": {"wakeups_per_s": 0.0},
                "cef-gpu": {"wakeups_per_s": 6.0}, "cef-host": {"wakeups_per_s": 4.0}}
        chrome = {"browser": {"wakeups_per_s": 3.5}, "gpu": {"wakeups_per_s": 60.0}}
        overs = ib.over_budget("tabs-static", cmux, budget, others={"chrome-static": chrome})
        self.assertIn(("tree", "wakeups_per_s/chrome:tree", 0.63, 0.5), overs)
        self.assertIn(("cef-host", "wakeups_per_s/chrome:browser", 1.143, 1.0), overs)
        self.assertNotIn("cef-gpu", [o[0] for o in overs])

    def test_session_limits_expectations_roles_and_busy_sessions(self):
        budget = ib.load_budget(ib.BUDGET_FILE)
        facts = {"page_raf_per_s": 60.0, "saver": True, "saver_reason": "setting"}
        self.assertEqual(ib.over_budget("energy-saver", {}, budget, facts=facts),
                         [("session", "page_raf_per_s", 60.0, 31)])
        self.assertEqual(ib.over_budget("energy-saver-auto", {}, budget, facts={**facts, "page_raf_per_s": 30}),
                         [("session", "saver_reason", "setting", "battery")])
        self.assertEqual(ib.over_line("x", ("session", "saver_reason", "setting", "battery")),
                         "IDLE-BUDGET-OVER x session saver_reason setting != battery")
        napped = {"app": {"wakeups_per_s": 0.1, "main_wakes_per_s": 0.0, "roles": ["foreground"]}}
        self.assertEqual(ib.over_budget("minimized", napped, budget), [("app", "role", "foreground", "napped")])
        # Idle sessions write nothing: all_kinds applies to every kind; busy and reference sessions take only
        # their own limits.
        self.assertEqual(ib.over_budget("light", {"other:zsh": {"disk_bytes_per_s": 12.0}}, budget),
                         [("other:zsh", "disk_bytes_per_s", 12.0, 0)])
        busy = {"app": {"wakeups_per_s": 1.5, "main_wakes_per_s": 30.0, "disk_bytes_per_s": 100.0}}
        self.assertEqual(ib.over_budget("busy-hidden", busy, budget), [])
        self.assertEqual(ib.over_budget("chrome-static", busy, budget), [])

    def test_aggregate_hidden_max_roles_and_energy(self):
        processes = [{**row("cef-renderer", 10, 0.05), "hidden": True, "energy_mw_billed": 0.25, "role": "best-effort"},
                     {**row("cef-renderer", 12, 3.0), "energy_mw_billed": 1.0, "role": "foreground"},
                     {**row("cef-renderer", 11, 0.3), "hidden": True, "role": "best-effort"}]
        entry = ib.aggregate({"processes": processes})["cef-renderer"]
        self.assertEqual(entry["hidden_wakeups_max"], 0.3)
        self.assertEqual(entry["wakeups_max"], 3.0)
        self.assertEqual(entry["energy_mw_billed"], 1.25)
        self.assertEqual(entry["roles"], ["best-effort", "foreground"])

    def test_allowed_periodic_fits_wakeup_audit_limits(self):
        entries = ib.load_budget(ib.BUDGET_FILE)["allowed_periodic"]
        self.assertLessEqual(len(entries), 6)
        for entry in entries:
            self.assertTrue(entry["owner"] and entry["why"])
            self.assertGreaterEqual(entry["period_s"], 15)


if __name__ == "__main__":
    unittest.main()
