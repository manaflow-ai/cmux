#!/usr/bin/env python3
"""idle-budget.py's pure parts: process kinds, per-kind sums, the v2 budget check (sessions, sums, ratios,
assertions), the perf cron rows, the session table, energy per kind and tree, power assertions and the
saver/thermal guard; procs.py's counters (interrupt and package-idle wakeups apart, billed energy, GPU time,
the coalition); and the chrome-static reference (Chrome kinds, uBlock Origin parity, the reference browser
refusal, ratio rows and their noise floor; xbench's Chrome switches); and the shipping measurement mode (launch
env, Debug refusal under --gate, the five report fields). Runs on any host (libproc loads only to measure)."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile
import types
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
CHROME = "/Applications/Chromium.app"
CHROME_HELPERS = f"{CHROME}/Contents/Frameworks/Chromium Framework.framework/Versions/154.0.8037.58/Helpers"


def row(kind, threads, wakeups, cpu=0.0, cpu_mw=0.0, billed_mw=0.0):
    return {"kind": kind, "threads": threads, "threads_ran": 0, "wakeups_per_s": wakeups, "csw_per_s": 0.0, "cpu_pct": cpu,
            "energy_mw_cpu": cpu_mw, "energy_mw_billed": billed_mw}


PMSET = """Assertion status system-wide:
   BackgroundTask                 0
   PreventUserIdleSystemSleep     1
Listed by owning process:
   pid 501(cmux DEV t): [0x0000a1b200018c3d] 00:01:10 PreventUserIdleSystemSleep named: "cmux keep awake"
   pid 88(powerd): [0x0000a1b200018c40] 00:00:05 PreventUserIdleDisplaySleep named: "Powerd - Prevent sleep while display is on"
   pid 120(coreaudiod): [0x0000a1b200018c41] 00:00:30 PreventUserIdleSystemSleep named: "com.apple.audio.context123.preventuseridlesleep"
\tCreated for PID: 777.
\tResources: audio-out builtin-speaker
   pid 900(Google Chrome Helper (Renderer)): [0x0000a1b200018c42] 00:00:01 PreventUserIdleSystemSleep named: "x"
Kernel Assertions: 0x4=USB
   id=500  level=255 0x4=USB mod=1/1/26, 9:00 AM description=com.apple.usb.externaldevice.14100000 owner=AppleUSB
"""


def ends(saver_start, saver_end, thermal_start="nominal", thermal_end="nominal", assertions=(), anim=None,
         assertions_end=None):
    start = {"saver": saver_start, "saver_reason": "setting" if saver_start else None, "thermal": thermal_start,
             "assertions": list(assertions)}
    end = {"saver": saver_end, "saver_reason": "setting" if saver_end else None, "thermal": thermal_end,
           "assertions": list(assertions if assertions_end is None else assertions_end)}
    if anim:
        start["anim"], end["anim"] = anim
    return {"start": start, "end": end}


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
        # The Chromium Host is a second executable of the app (Contents/MacOS), not the app.
        self.assertEqual(ib.kind(f"{APP}/Contents/MacOS/cmux Chromium Host --framework=/x/Chromium Embedded Framework.framework"),
                         "cef-host")
        self.assertEqual(ib.kind(f"{APP}/Contents/MacOS/cmux Chromium Host"), "cef-host")
        # Older builds' Chromium Host app in Contents/Frameworks.
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
        self.assertEqual(sessions["light-webkit"]["sums"]["tree"], {"energy_mw_cpu": 1.0})  # D2: tree CPU energy
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
        chrome = {f"{r['of']}/{r['vs']}.{r['field']}": r["max_ratio"] for r in budget["ratio_to_chrome"]}
        xbench = {(r["browser"], r["row"]): r.get("max_ratio", r.get("max")) for r in budget["xbench"]}
        self.assertEqual(xbench[("cmux-chromium", "idle-wakeups-20")], 0.5)
        self.assertEqual(xbench[("cmux-chromium", "idle-wakeups-1")], 0.5)
        self.assertEqual(xbench[("cmux-chromium", "power-idle-visible")], 1.0)
        self.assertEqual(xbench[("cmux-chromium", "power-idle-hidden")], 1.0)
        self.assertEqual(xbench[("cmux-terminal", "idle-wakeups-home")], 1.0)
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
        self.assertEqual(ib.over_budget("light", {}, budget, facts={"assertions": held, "settings": off}), [over])
        self.assertEqual(ib.over_budget("light", {}, budget, facts={"assertions": held}), [over])
        self.assertEqual(ib.over_budget("light", {}, budget, facts={"assertions": [], "settings": off}), [])
        # The shipping default (pluggedIn) with no agent at work: the assertion is a leak, and the run did not
        # have the settings the session asked for (off).
        shipping = {"sessions.keepAwake": "pluggedIn", "phone.keepAwake": "pluggedIn"}
        overs = ib.over_budget("light", {}, budget, facts={"assertions": held, "settings": shipping})
        self.assertIn(over, overs)
        self.assertIn(("session", "sessions.keepAwake", "pluggedIn", "off"), overs)
        self.assertIn(("session", "phone.keepAwake", "pluggedIn", "off"), overs)
        # Only a session that itself turns keep-awake on may hold one; busy and reference sessions are not judged.
        asks = {"sessions": {"keep-awake": {"settings": {"sessions.keepAwake": "always"}}},
                "assertions_allowed_when": budget["assertions_allowed_when"]}
        self.assertEqual(ib.over_budget("keep-awake", {}, asks,
                                        facts={"assertions": held, "settings": {"sessions.keepAwake": "always"}}), [])
        for name in ("agent-working-visible", "busy-hidden", "chrome-static"):
            self.assertEqual(ib.over_budget(name, {}, budget, facts={"assertions": held, "settings": shipping}), [])
        # STRESS has no agent at work: judged.
        self.assertIn(over, ib.over_budget("stress", {}, budget, facts={"assertions": held}))

    def test_every_session_runs_with_keep_awake_off(self):
        for session in ib.SESSIONS:
            config = ib.session_config(session)
            self.assertEqual((config["sessions"]["keepAwake"], config["phone"]["keepAwake"]), ("off", "off"))
            self.assertEqual(config["appearance"], {"backgroundOpacity": 1})
        self.assertEqual(ib.session_config("light-webkit")["browser"], {"defaultEngine": "webkit"})

    def test_relative_and_chrome_ratios(self):
        budget = ib.load_budget(ib.BUDGET_FILE)
        light = {"app": {"wakeups_per_s": 0.2, "main_wakes_per_s": 0.05}}
        hidden = {"app": {"wakeups_per_s": 0.25, "main_wakes_per_s": 0.0}}
        # light-hidden measured before light: judged all the same once both are measured.
        overs, notes = ib.cross_overs(budget, {"light-hidden": hidden, "light": light})
        self.assertEqual(overs, [("light-hidden", ("app", "wakeups_per_s/light", 1.25, 1.0))])
        self.assertEqual(notes, [])
        overs, notes = ib.cross_overs(budget, {"light-hidden": hidden})
        self.assertEqual(overs, [])
        self.assertIn("light-hidden app wakeups_per_s/light: not judged: reference session light not measured", notes)
        # 40/s vs Chrome's 63.5/s at 0.5 (task 004's fixture) and a Chromium Host above Chrome's browser process,
        # with tabs-static measured before chrome-static (task 004's --sessions tabs-static,chrome-static).
        cmux = {"app": {"wakeups_per_s": 30.0, "main_wakes_per_s": 0.4, "energy_mw_billed": 5.0},
                "daemon": {"wakeups_per_s": 0.0, "energy_mw_billed": 1.0},
                "cef-gpu": {"wakeups_per_s": 6.0, "energy_mw_billed": 2.0},
                "cef-host": {"wakeups_per_s": 4.0, "energy_mw_billed": 1.0}}
        chrome = {"browser": {"wakeups_per_s": 3.5, "energy_mw_billed": 20.0},
                  "gpu": {"wakeups_per_s": 60.0, "energy_mw_billed": 20.0}}
        overs, notes = ib.cross_overs(budget, {"tabs-static": cmux, "chrome-static": chrome})
        got = [over for session, over in overs if session == "tabs-static"]
        self.assertIn(("tree", "wakeups_per_s/chrome:tree", 0.63, 0.5), got)
        self.assertIn(("cef-host", "wakeups_per_s/chrome:browser", 1.143, 1.0), got)
        self.assertNotIn("cef-gpu", [o[0] for o in got])
        self.assertEqual(notes, [])
        # Without chrome-static, every ratio_to_chrome row says it was not judged.
        _, notes = ib.cross_overs(budget, {"tabs-static": cmux})
        self.assertEqual(len([n for n in notes if "chrome-static not measured" in n]), len(budget["ratio_to_chrome"]))
        # A partial tree is no value: an unknown part makes the ratio not judged, not a pass.
        partial = {**cmux, "cef-gpu": {"wakeups_per_s": 6.0, "energy_mw_billed": None}}
        overs, notes = ib.cross_overs(budget, {"tabs-static": partial, "chrome-static": chrome})
        self.assertNotIn("energy_mw_billed/chrome:tree", [o[1] for _, o in overs])
        self.assertIn("tabs-static tree energy_mw_billed/chrome:tree: not judged: tree energy_mw_billed unknown", notes)

    def test_a_sum_with_an_unknown_part_is_no_value(self):
        budget = ib.load_budget(ib.BUDGET_FILE)
        kinds = {"app": {"energy_mw_cpu": 0.6, "wakeups_per_s": 0.1, "main_wakes_per_s": 0},
                 "cef-gpu": {"energy_mw_cpu": None, "wakeups_per_s": 0.1}}
        self.assertIsNone(ib.selector_value(kinds, "tree", "energy_mw_cpu"))
        self.assertTrue(ib.unknown_sum(kinds, "tree", "energy_mw_cpu"))
        self.assertEqual(ib.over_budget("light-webkit", kinds, budget), [])
        self.assertEqual(ib.sum_notes("light-webkit", kinds, budget), ["light-webkit tree energy_mw_cpu: not judged: unknown"])
        # A kind that lacks a field another kind carries is unknown too; a kind that did not run is skipped.
        self.assertIsNone(ib.selector_value({"app": {"x": 1.0}, "daemon": {}}, "tree", "x"))
        self.assertEqual(ib.selector_value({"app": {"x": 1.0}}, "app+daemon", "x"), 1.0)
        self.assertIsNone(ib.selector_value({}, "app+daemon", "x"))
        known = {"app": {"energy_mw_cpu": 0.6}, "daemon": {"energy_mw_cpu": 0.5}}
        self.assertEqual(ib.over_budget("light-webkit", known, budget), [("tree", "energy_mw_cpu", 1.1, 1.0)])
        rows = ib.cron_rows({"sessions": {"light-webkit": {"kinds": known}}}, budget)
        self.assertEqual(rows["idle_budget.light-webkit.tree.energy_mw_cpu"]["budget"], 1.0)
        self.assertEqual(rows["idle_budget.light-webkit.tree.energy_mw_cpu"]["unit"], "mW")

    def test_disk_and_log_reported_by_some_processes_only_are_unknown(self):
        processes = [{**row("daemon", 4, 0.0), "disk_bytes_per_s": 0.0}, row("daemon", 4, 0.0),
                     {**row("app", 30, 0.0), "disk_bytes_per_s": 0.0, "log_lines": 0}, row("holder", 2, 0.0)]
        kinds = ib.aggregate({"processes": processes})
        self.assertIsNone(kinds["daemon"]["disk_bytes_per_s"])
        self.assertEqual((kinds["app"]["disk_bytes_per_s"], kinds["app"]["log_lines"]), (0.0, 0))
        self.assertNotIn("disk_bytes_per_s", kinds["holder"])

    def test_stress_keeps_the_v1_limits_outside_its_busy_pages(self):
        budget = ib.load_budget(ib.BUDGET_FILE)
        kinds = {"holder": {"wakeups_max": 0.5}, "terminal-host": {"wakeups_max": 0.0},
                 "daemon": {"wakeups_per_s": 1.5}, "app": {"wakeups_per_s": 0.5, "main_wakes_per_s": 0},
                 "cef-renderer": {"wakeups_max": 60.0, "disk_bytes_per_s": 4096.0},
                 "webkit-webcontent": {"disk_bytes_per_s": 10.0}}
        self.assertEqual(ib.over_budget("stress", kinds, budget),
                         [("daemon", "wakeups_per_s", 1.5, 1.0), ("holder", "wakeups_max", 0.5, 0)])
        self.assertEqual(ib.limit_for(budget, "stress", "app", "main_wakes_per_s"), 0)
        self.assertEqual(ib.limit_for(budget, "stress", "terminal-host", "wakeups_max"), 0)
        self.assertIsNone(ib.limit_for(budget, "stress", "cef-renderer", "disk_bytes_per_s"))
        rows = ib.cron_rows({"sessions": {"stress": {"kinds": kinds}}}, budget)
        self.assertEqual(rows["idle_budget.stress.holder.wakeups_max"]["budget"], 0)
        self.assertEqual(rows["idle_budget.stress.daemon.wakeups_per_s"]["budget"], 1.0)

    def test_xbench_rows(self):
        budget = ib.load_budget(ib.BUDGET_FILE)
        result = {"rows": {"idle-wakeups-20": {"cmux-chromium": {"median": 40.0}, "chrome": {"median": 63.5}},
                           "idle-wakeups-1": {"cmux-chromium": {"median": 20.0}, "chrome": {"median": 44.8}},
                           "power-idle-visible": {"cmux-chromium": {"median": 90.0}, "chrome": {"median": 100.0}},
                           "idle-wakeups-home": {"cmux-terminal": {"median": 8.6}}}}
        overs, notes = ib.xbench_overs(budget, result)
        self.assertEqual(overs, [("cmux-chromium", "idle-wakeups-20/chrome", 0.63, 0.5),
                                 ("cmux-terminal", "idle-wakeups-home", 8.6, 1.0)])
        self.assertEqual(notes, ["xbench cmux-chromium power-idle-hidden: not judged: not measured"])
        self.assertEqual(ib.over_line("xbench", overs[1]),
                         "IDLE-BUDGET-OVER xbench cmux-terminal idle-wakeups-home 8.6 > 1.0")

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


class SessionTableTests(unittest.TestCase):
    def test_tab_sessions_shape(self):
        tabs = ib.SESSIONS["tabs-static"]["tabs"]
        self.assertEqual((tabs["webkit_hidden"], tabs["chromium_hidden"], tabs["shown"]), (5, 10, "static"))
        self.assertEqual(ib.SESSIONS["tabs-static"]["config"]["browser"]["freezeHiddenTabs"], ib.FREEZE_HIDDEN_TABS_S)
        saver = ib.SESSIONS["energy-saver"]
        self.assertEqual(saver["config"]["energy"], {"saver": "always"})
        self.assertEqual(saver["tabs"]["shown"], "anim")
        self.assertEqual((saver["tabs"]["webkit_hidden"], saver["tabs"]["chromium_hidden"]), (5, 10))
        self.assertTrue(saver["saver"] and saver["anim"])
        self.assertTrue(ib.SESSIONS["minimized"]["minimize"])
        for name, entry in ib.SESSIONS.items():
            self.assertEqual(bool(entry.get("saver")), name == "energy-saver", name)

    def test_tab_sessions_settle_past_the_hidden_tab_freeze(self):
        for name in ("tabs-static", "energy-saver"):
            self.assertGreater(ib.settle_seconds(name, 5), ib.FREEZE_HIDDEN_TABS_S, name)
            self.assertEqual(ib.settle_seconds(name, 120), 120)
        self.assertEqual(ib.settle_seconds("light", 5), 5)

    def test_unknown_session_refused_before_any_launch(self):
        with self.assertRaises(SystemExit) as raised:
            ib.parse_sessions("light,tabs-statik")
        self.assertIn("unknown session tabs-statik", str(raised.exception))
        self.assertEqual(ib.parse_sessions("tabs-static,energy-saver,minimized"), ["tabs-static", "energy-saver", "minimized"])
        self.assertEqual(ib.parse_sessions("all"), list(ib.SESSIONS))

    def test_tab_plan_hides_every_tab_behind_the_shown_one(self):
        with ib.IdlePages() as pages:
            plan = ib.tab_plan(pages, ib.SESSIONS["energy-saver"]["tabs"])
            static = ib.tab_plan(pages, ib.SESSIONS["tabs-static"]["tabs"])
        self.assertEqual([engine for engine, _, _ in plan], ["webkit"] * 5 + ["chromium"] * 11)
        self.assertEqual(plan[0][1:], (pages.origin + "/static-w0", "w0"))
        self.assertEqual(plan[-1][1:], (pages.origin + ib.ANIM_PATH, "anim"))
        self.assertEqual(static[-1][1:], (pages.origin + "/static-shown", "shown"))
        self.assertEqual(len({key for _, _, key in plan}), len(plan))

    def test_idle_pages_serve_the_shared_static_page_and_the_animated_page(self):
        import urllib.request
        with ib.IdlePages() as pages:
            static = urllib.request.urlopen(pages.url("static", "c3"), timeout=5).read().decode()
            anim = urllib.request.urlopen(pages.origin + ib.ANIM_PATH, timeout=5).read().decode()
            urllib.request.urlopen(urllib.request.Request(pages.origin + "/loaded/anim", method="POST"), timeout=5).read()
            self.assertTrue(pages.wait_loaded("anim", 5))
            self.assertFalse(pages.wait_loaded("c3", 0))
        self.assertEqual(static, ib.tab_pages.TabPages.body(pages, "/static-c3").decode())
        self.assertNotIn("requestAnimationFrame", static)
        self.assertIn("requestAnimationFrame", anim)
        self.assertIn("__rafCount", anim)
        self.assertIn("/loaded/anim", anim)
        self.assertIn(ib.ANIM_READ_PATH, anim)
        self.assertIn(ib.ANIM_COUNT_PATH, anim)

    def test_read_anim_answers_the_held_read_and_returns_the_posted_count(self):
        """The page's read path, played by a thread as the page's script does it: a held GET, then the POST."""
        import threading
        import urllib.request
        with ib.IdlePages() as pages:
            def page():
                urllib.request.urlopen(pages.origin + ib.ANIM_READ_PATH, timeout=10).read()
                urllib.request.urlopen(urllib.request.Request(
                    pages.origin + ib.ANIM_COUNT_PATH + "/1800/61000.25/visible", method="POST"), timeout=5).read()
            held = threading.Thread(target=page)
            held.start()
            got = pages.read_anim(5)  # answered whether the GET arrived before or after this ask
            held.join(5)
            self.assertEqual(got, {"count": 1800, "t_ms": 61000.25, "visibility": "visible"})
            self.assertIn("error", pages.read_anim(0.2))  # no page asks again: an error, not a hang
            again = threading.Thread(target=page)
            again.start()  # the late GET answers the read that timed out at once
            again.join(5)
            self.assertFalse(again.is_alive())
        self.assertIn("error", ib.parse_anim_count(ib.ANIM_COUNT_PATH + "/x/1/visible"))

    def test_the_anim_page_needs_no_devtools(self):
        source = (HERE / "idle-budget.py").read_text()
        self.assertNotIn("CMUX_NEXT_CEF_EXTRA_SWITCHES", source)
        self.assertNotIn("remote-debugging-port", source)


class FakeApp:
    """An app whose control socket records each method in `calls`, shared with the fake usage reads."""

    def __init__(self, calls):
        self.calls = calls

    def rpc(self, method, params=None, timeout=30):
        self.calls.append(method)
        if method == "debug.hangs":
            return {"main_wakes": 10 * sum(1 for c in self.calls if c == "debug.hangs")}
        if method == "debug.energy":
            return {"policy": {"isSaver": True, "reason": "setting"}}
        return {}


class MeasureOrderTests(unittest.TestCase):
    def test_window_end_reads_sit_outside_every_counter_bracket(self):
        calls = []
        app = FakeApp(calls)
        instance = type("Instance", (), {"pid": 1})()
        saved = (ib.process_set, ib.threads, procs.usage, procs.overhead, procs.gpu_ns_by_pid, procs.coalition_of,
                 procs.thermal_state, procs.power_assertions, ib.time.sleep)
        ib.process_set = lambda _instance: {1: f"{APP}/Contents/MacOS/cmux DEV"}
        ib.threads = lambda _pid: {}
        procs.usage = lambda _pid: calls.append("usage") or procs.usage_from_words(rusage_words(), 1, 1)
        procs.overhead = lambda _pid: (0, 30, 0, 0, 0)
        procs.gpu_ns_by_pid = lambda: {}
        procs.coalition_of = lambda _pid: None
        procs.thermal_state = lambda: "nominal"
        procs.power_assertions = lambda _pids: calls.append("pmset") or []
        ib.time.sleep = lambda seconds: calls.append(f"sleep {seconds:g}")
        try:
            result = ib.measure(app, instance, 60, read_anim=lambda: calls.append("anim") or {"count": 0, "t_ms": 0})
        finally:
            (ib.process_set, ib.threads, procs.usage, procs.overhead, procs.gpu_ns_by_pid, procs.coalition_of,
             procs.thermal_state, procs.power_assertions, ib.time.sleep) = saved
        probes = {"debug.energy", "pmset", "anim"}
        counters = [i for i, c in enumerate(calls) if c in ("debug.hangs", "debug.wakeups", "debug.cef", "debug.layers", "usage")]
        start_probes = [i for i, c in enumerate(calls) if c in probes and i < counters[0]]
        end_probes = [i for i, c in enumerate(calls) if c in probes and i > counters[-1]]
        self.assertEqual(len(start_probes) + len(end_probes), sum(1 for c in calls if c in probes))
        self.assertEqual((len(start_probes), len(end_probes)), (3, 3))
        self.assertEqual(calls[start_probes[-1] + 1], f"sleep {ib.QUIET_GAP_S:g}")  # a quiet gap before the counters
        self.assertEqual(result["ends"]["start"]["saver"], True)
        self.assertIn("anim", result["ends"]["end"])


class EnergyTests(unittest.TestCase):
    def test_energy_sums_per_kind_and_tree(self):
        kinds = ib.aggregate({"processes": [row("cef-renderer", 10, 0.1, cpu_mw=1.25, billed_mw=1.5),
                                            row("cef-renderer", 10, 0.0, cpu_mw=0.75, billed_mw=0.5),
                                            row("app", 40, 0.5, cpu_mw=8.0, billed_mw=9.0),
                                            row("daemon", 9, 0.2, cpu_mw=0.5, billed_mw=0.5)]})
        summary = ib.energy_summary(kinds)
        self.assertEqual(summary["per_kind"], {"cef-renderer": {"cpu": 2.0, "billed": 2.0}, "app": {"cpu": 8.0, "billed": 9.0},
                                               "daemon": {"cpu": 0.5, "billed": 0.5}})
        self.assertEqual(summary["tree"], {"cpu": 10.5, "billed": 11.5})

    def test_energy_from_fixture_rusage_to_mw(self):
        """rusage words (ri_energy_nj, ri_billed_energy, ri_serviced_energy) through process_row, aggregate and
        energy_summary over a 2 s window."""
        zero = procs.usage_from_words(rusage_words(), 1, 1)
        def process(pid, cmd, energy, billed, serviced):
            last = procs.usage_from_words(rusage_words(energy=energy, billed=billed, serviced=serviced), 1, 1)
            return ib.process_row(pid, cmd, zero, last, 2.0, gpu=0.0, threads_now=4, csw=0, ran=[])
        rows = [process(1, f"{APP}/Contents/MacOS/cmux DEV", 8_000_000, 3_000_000, 1_000_000),
                process(2, f"{APP}/Contents/Frameworks/cmux Helper (Renderer).app/x --type=renderer", 2_500_000, 0, 500_000),
                process(3, f"{APP}/Contents/Frameworks/cmux Helper (Renderer).app/x --type=renderer", 1_500_000, 1_000_000, 0)]
        self.assertEqual((rows[0]["energy_mw_cpu"], rows[0]["energy_mw_billed"]), (4.0, 5.0))  # (8 + 3 - 1) mJ / 2 s
        summary = ib.energy_summary(ib.aggregate({"processes": rows}))
        self.assertEqual(summary["per_kind"], {"app": {"cpu": 4.0, "billed": 5.0},
                                               "cef-renderer": {"cpu": 2.0, "billed": 2.25}})  # 1.0 + 1.25
        self.assertEqual(summary["tree"], {"cpu": 6.0, "billed": 7.25})


class PowerAssertionTests(unittest.TestCase):
    def test_assertions_of_the_pid_set(self):
        found = procs.power_assertions({501, 777, 900}, PMSET)
        self.assertEqual([(a["pid"], a.get("created_for")) for a in found], [(501, None), (120, 777), (900, None)])
        self.assertEqual(found[0]["type"], "PreventUserIdleSystemSleep")
        self.assertEqual(found[0]["name"], "cmux keep awake")
        self.assertEqual(found[0]["process"], "cmux DEV t")
        self.assertEqual((found[0]["id"], found[0]["age"]), ("0x0000a1b200018c3d", "00:01:10"))
        self.assertNotIn("held", found[0])
        self.assertEqual(found[2]["process"], "Google Chrome Helper (Renderer)")
        self.assertEqual(procs.power_assertions({4242}, PMSET), [])

    def test_an_assertion_read_at_both_ends_is_listed_once(self):
        start = procs.power_assertions({501}, PMSET)
        end = procs.power_assertions({501}, PMSET.replace("00:01:10", "00:02:10"))
        self.assertNotEqual(start[0]["line"], end[0]["line"])  # only the age differs
        got = ib.window_assertions(start, end)
        self.assertEqual(len(got), 1)
        self.assertEqual(got[0]["age"], "00:02:10")  # the latest read
        other = procs.power_assertions({501}, PMSET.replace("0x0000a1b200018c3d", "0x0000a1b200018c99"))
        self.assertEqual(len(ib.window_assertions(start, other)), 2)  # a new assertion with the same name counts


class SaverAndThermalTests(unittest.TestCase):
    def test_saver_state_from_debug_energy(self):
        self.assertEqual(ib.saver_state({"policy": {"isSaver": True, "reason": "setting"}}), (True, "setting"))
        self.assertEqual(ib.saver_state({"policy": {"isSaver": True}, "inputs": {"reason": "battery"}}), (True, "battery"))
        self.assertEqual(ib.saver_state({"policy": {"isSaver": False}}), (False, None))
        self.assertEqual(ib.saver_state({}), (None, None))

    def test_saver_mismatch(self):
        self.assertIsNone(ib.saver_mismatch(True, [True, True]))
        self.assertIn("asked energy saver on", ib.saver_mismatch(True, [True, False]))
        self.assertIn("asked energy saver on", ib.saver_mismatch(True, [None, None]))  # no debug.energy: not proven
        self.assertIsNone(ib.saver_mismatch(False, [False, None]))
        self.assertIn("asked energy saver off", ib.saver_mismatch(False, [False, True]))

    def test_gate_refuses_a_saver_mismatch(self):
        result = {"processes": [row("app", 40, 0.2)], "ends": ends(False, False)}
        entry = ib.summarize("energy-saver", result, {"kinds": {}})
        self.assertTrue(entry["saver"]["asked"])
        self.assertEqual(entry["saver"]["observed"], [False, False])
        self.assertIsNotNone(entry["saver"]["mismatch"])
        self.assertEqual(entry["over"], [])
        self.assertEqual(ib.exit_code(True, [], ["energy-saver"]), 1)
        self.assertEqual(ib.exit_code(False, [], ["energy-saver"]), 0)
        self.assertEqual(ib.exit_code(True, [], []), 0)
        matched = ib.summarize("energy-saver", {"processes": [], "ends": ends(True, True)}, {"kinds": {}})
        self.assertIsNone(matched["saver"]["mismatch"])
        self.assertEqual(matched["saver"]["reason"], "setting")

    def test_thermal_serious_marks_the_rows(self):
        self.assertEqual(ib.worst_thermal(["fair", "serious"]), "serious")
        self.assertEqual(ib.worst_thermal([None, "nominal"]), "nominal")
        self.assertIsNone(ib.worst_thermal([None, None]))
        hot = ib.summarize("light", {"processes": [row("app", 40, 0.2)], "ends": ends(False, False, "fair", "serious")},
                           {"kinds": {}})
        self.assertEqual(hot["thermal"], {"start": "fair", "end": "serious", "worst": "serious", "marked": True})
        self.assertTrue(hot["kinds"]["app"]["thermal_marked"])
        cool = ib.summarize("light", {"processes": [row("app", 40, 0.2)], "ends": ends(False, False, "fair", "fair")},
                            {"kinds": {}})
        self.assertFalse(cool["thermal"]["marked"])
        self.assertNotIn("thermal_marked", cool["kinds"]["app"])

    def test_report_entry_has_assertions_energy_saver_thermal(self):
        held = procs.power_assertions({501}, PMSET)
        later = procs.power_assertions({501}, PMSET.replace("00:01:10", "00:02:11"))
        result = {"processes": [row("app", 40, 0.2, cpu_mw=4.0, billed_mw=5.0), row("daemon", 9, 0.1, cpu_mw=1.0, billed_mw=1.0)],
                  "ends": ends(False, False, assertions=held, assertions_end=later)}
        entry = ib.summarize("tabs-static", result, {"kinds": {}})
        for key in ("assertions", "energy_mw", "saver", "thermal"):
            self.assertIn(key, entry)
        self.assertEqual(len(entry["assertions"]), 1)  # the same assertion at both ends is listed once
        self.assertEqual(entry["energy_mw"]["per_kind"]["app"], {"cpu": 4.0, "billed": 5.0})
        self.assertEqual(entry["energy_mw"]["tree"], {"cpu": 5.0, "billed": 6.0})
        self.assertNotIn("anim", entry)
        text = ib.table("tabs-static", entry["kinds"], [], entry)
        self.assertIn("energy 5.0 mW CPU, 6.0 mW billed (tree)", text)
        self.assertIn("1 power assertion(s)", text)

    def test_animated_page_rate(self):
        reads = ({"count": 100, "t_ms": 1000, "visibility": "visible"}, {"count": 1900, "t_ms": 61000, "visibility": "visible"})
        entry = ib.summarize("energy-saver", {"processes": [], "ends": ends(True, True, anim=reads)}, {"kinds": {}})
        self.assertEqual(entry["anim"]["raf_per_s"], 30.0)
        self.assertEqual(entry["anim"]["visibility"], ["visible", "visible"])
        self.assertEqual(ib.refusals(entry), [])

    def test_gate_refuses_energy_saver_without_a_raf_rate(self):
        unread = ({"error": "the page posted no rAF count in 10 s"}, {"count": 1, "t_ms": 2})
        entry = ib.summarize("energy-saver", {"processes": [], "ends": ends(True, True, anim=unread)}, {"kinds": {}})
        self.assertEqual([what for what, _ in ib.refusals(entry)], ["anim"])
        light = ib.summarize("light", {"processes": [], "ends": ends(False, False)}, {"kinds": {}})
        self.assertEqual(ib.refusals(light), [])
        self.assertIn("error", ib.anim_rate({"error": "no target"}, {"count": 1, "t_ms": 2}))

    def test_window_facts_reach_the_v2_session_rows(self):
        budget = ib.load_budget(ib.BUDGET_FILE)
        fast = ({"count": 0, "t_ms": 0, "visibility": "visible"}, {"count": 3600, "t_ms": 60000, "visibility": "visible"})
        entry = ib.summarize("energy-saver", {"processes": [], "ends": ends(True, True, anim=fast)}, budget)
        self.assertEqual(ib.window_facts(entry)["page_raf_per_s"], 60.0)
        self.assertIn(["session", "page_raf_per_s", 60.0, 31], entry["over"])
        capped = ({"count": 0, "t_ms": 0, "visibility": "visible"}, {"count": 1800, "t_ms": 60000, "visibility": "visible"})
        ok = ib.summarize("energy-saver", {"processes": [], "ends": ends(True, True, anim=capped)}, budget)
        self.assertEqual(ok["over"], [])
        off = ib.summarize("energy-saver", {"processes": [], "ends": ends(False, False, anim=capped)}, budget)
        self.assertIn(["session", "saver", False, True], off["over"])
        unknown = ib.summarize("energy-saver", {"processes": [], "ends": ends(None, None, anim=capped)}, budget)
        self.assertNotIn("saver", ib.window_facts(unknown))  # no debug.energy: refused (saver mismatch), not an over
        held = procs.power_assertions({501}, PMSET)
        light = ib.summarize("light", {"processes": [], "ends": ends(False, False, assertions=held)}, budget)
        self.assertIn(["assertions", "held", 1, 0], light["over"])


def ratio_rule(of, vs, field, max_ratio, session="tabs-static"):
    return {"session": session, "of": of, "vs": vs, "field": field, "max_ratio": max_ratio}


def chrome_entry(kinds, running=True, chrome_version="1.75.0", cmux_version="1.75.0", shape=None):
    """A measured chrome-static session entry (run_chrome_static's block plus its kinds)."""
    return {"exit": 0, "kinds": kinds, "over": [],
            "chrome": {"app": CHROME, "version": "154.0.8037.58",
                       "ublock": {"cmux_version": cmux_version, "chrome_version": chrome_version, "running": running},
                       "unequal": list(shape or [])}}


# A tabs-static cmux tree with uBlock Origin's extension renderer, and a Chrome tree with its own.
CMUX_KINDS = {"app": {"n": 1, "wakeups_per_s": 10.0}, "cef-renderer": {"n": 11, "wakeups_per_s": 28.0},
              "cef-extension": {"n": 1, "wakeups_per_s": 2.0}}
CHROME_KINDS = {"browser": {"n": 1, "wakeups_per_s": 20.0}, "renderer": {"n": 16, "wakeups_per_s": 41.5},
                "extension": {"n": 1, "wakeups_per_s": 2.0}}
TREE_RULE = {"ratio_to_chrome": [ratio_rule("tree", "tree", "wakeups_per_s", 0.5)]}


class ChromeReferenceTests(unittest.TestCase):
    """The chrome-static reference (p14-energy-004): a Chromium that runs MV2, tabs-static's pages, uBlock Origin."""

    def judge(self, sessions, budget, asked=True):
        report = {"sessions": sessions}
        overs, notes, refused = ib.judge_across(report, budget, asked)
        return report, overs, notes, refused

    def test_chrome_kinds(self):
        self.assertEqual(ib.chrome_kind(f"{CHROME}/Contents/MacOS/Chromium --user-data-dir=/p/data"), "browser")
        self.assertEqual(ib.chrome_kind(f"{CHROME_HELPERS}/Chromium Helper (Renderer).app/Contents/MacOS/"
                                        "Chromium Helper (Renderer) --type=renderer --renderer-client-id=7"), "renderer")
        self.assertEqual(ib.chrome_kind(f"{CHROME_HELPERS}/Chromium Helper (Renderer).app/Contents/MacOS/"
                                        "Chromium Helper (Renderer) --type=renderer --extension-process"), "extension")
        self.assertEqual(ib.chrome_kind(f"{CHROME_HELPERS}/Chromium Helper (GPU).app/Contents/MacOS/"
                                        "Chromium Helper (GPU) --type=gpu-process"), "gpu")
        self.assertEqual(ib.chrome_kind(f"{CHROME_HELPERS}/Chromium Helper.app/Contents/MacOS/Chromium Helper "
                                        "--type=utility --utility-sub-type=network.mojom.NetworkService"), "utility")
        self.assertEqual(ib.chrome_kind(f"{CHROME_HELPERS}/chrome_crashpad_handler --monitor-self"), "crashpad")
        self.assertEqual(ib.chrome_kind(f"{CHROME_HELPERS}/Chromium Helper.app/Contents/MacOS/Chromium Helper "
                                        "--type=ppapi"), "other")

    def test_forty_against_sixty_three_and_a_half_at_half_is_over(self):
        # The acceptance case: cmux's tree 40/s against Chrome's 63.5/s at max_ratio 0.5, both running uBlock Origin;
        # tabs-static measured before chrome-static, judged all the same.
        report, overs, notes, refused = self.judge(
            {"tabs-static": {"kinds": CMUX_KINDS, "over": []}, ib.CHROME_SESSION: chrome_entry(CHROME_KINDS)}, TREE_RULE)
        self.assertEqual(overs, [("tabs-static", ("tree", "wakeups_per_s/chrome:tree", 0.63, 0.5))])
        self.assertEqual((notes, refused), ([], []))
        row = report["ratio_to_chrome"][0]
        self.assertEqual((row["cmux_value"], row["chrome_value"], row["verdict"]), (40.0, 63.5, "over"))
        self.assertEqual(report["sessions"]["tabs-static"]["over"], [["tree", "wakeups_per_s/chrome:tree", 0.63, 0.5]])
        self.assertTrue(report["chrome"]["parity"]["tabs-static"]["equal"])
        self.assertEqual(report["chrome"]["kinds"], CHROME_KINDS)
        self.assertIn("**over**", ib.ratio_table(report["ratio_to_chrome"]))
        # Below the ratio: no over.
        quiet = {**CMUX_KINDS, "cef-renderer": {"n": 11, "wakeups_per_s": 19.0}}
        _, overs, _, _ = self.judge({"tabs-static": {"kinds": quiet, "over": []},
                                     ib.CHROME_SESSION: chrome_entry(CHROME_KINDS)}, TREE_RULE)
        self.assertEqual(overs, [])

    def test_the_budget_file_rows_are_judged_once(self):
        # The budget's own ratio_to_chrome rows go through one path: one over per row, not one per judge.
        budget = ib.load_budget(ib.BUDGET_FILE)
        chrome = {**CHROME_KINDS, "gpu": {"n": 1, "wakeups_per_s": 4.0}}
        cmux = {**CMUX_KINDS, "cef-gpu": {"n": 1, "wakeups_per_s": 6.0}, "cef-host": {"n": 1, "wakeups_per_s": 1.0}}
        _, overs, _, _ = self.judge({ib.CHROME_SESSION: chrome_entry(chrome), "tabs-static": {"kinds": cmux, "over": []}},
                                    budget)
        fields = [over[1] for _, over in overs]
        self.assertEqual(len(fields), len(set(fields)))
        self.assertIn("wakeups_per_s/chrome:gpu", fields)

    def test_without_ublock_in_chrome_ratios_are_unequal_not_judged_and_refused(self):
        report, overs, notes, refused = self.judge(
            {"tabs-static": {"kinds": CMUX_KINDS, "over": []},
             ib.CHROME_SESSION: chrome_entry(CHROME_KINDS, chrome_version=None, running=False)}, TREE_RULE)
        self.assertEqual(overs, [])
        row = report["ratio_to_chrome"][0]
        self.assertEqual(row["verdict"], "not judged")
        self.assertEqual(row["unequal"], ["no uBlock Origin was loaded into Chrome"])
        self.assertIn("tabs-static tree wakeups_per_s/chrome:tree: not judged: unequal: no uBlock Origin was loaded "
                      "into Chrome", notes)
        self.assertEqual(refused, ["tabs-static: no uBlock Origin was loaded into Chrome"])
        self.assertIn("unequal: no uBlock Origin was loaded into Chrome", ib.ratio_table(report["ratio_to_chrome"]))

    def test_parity_comes_from_the_measured_sessions(self):
        # uBlock Origin bundled but not run in the cmux session (built-in ad blocker off, a person's own copy
        # found): no cef-extension process, so unequal although the bundle has the folder.
        no_ext = {name: values for name, values in CMUX_KINDS.items() if name != "cef-extension"}
        report, overs, _, refused = self.judge({"tabs-static": {"kinds": no_ext, "over": []},
                                                ib.CHROME_SESSION: chrome_entry(CHROME_KINDS)}, TREE_RULE)
        self.assertEqual(overs, [])
        self.assertEqual(report["ratio_to_chrome"][0]["unequal"],
                         ["uBlock Origin 1.75.0 did not run in the cmux session (no cef-extension process)"])
        self.assertTrue(refused)
        # Chrome listed uBlock Origin's target but measured no extension renderer: not running either.
        no_chrome_ext = {name: values for name, values in CHROME_KINDS.items() if name != "extension"}
        report, _, _, _ = self.judge({"tabs-static": {"kinds": CMUX_KINDS, "over": []},
                                      ib.CHROME_SESSION: chrome_entry(no_chrome_ext)}, TREE_RULE)
        self.assertEqual(report["ratio_to_chrome"][0]["unequal"],
                         ["uBlock Origin 1.75.0 did not run in Chrome (no extension target or process)"])

    def test_ublock_parity_needs_the_same_version_running(self):
        self.assertTrue(ib.ublock_parity("1.75.0", True, "1.75.0", True)["equal"])
        self.assertEqual(ib.ublock_parity("1.75.0", True, "1.75.0", False)["unequal"],
                         ["uBlock Origin 1.75.0 did not run in Chrome (no extension target or process)"])
        self.assertEqual(ib.ublock_parity("1.75.0", True, "1.74.0", True)["unequal"],
                         ["uBlock Origin 1.74.0 in Chrome, 1.75.0 in cmux"])
        self.assertIn("the cmux app bundles no uBlock Origin", ib.ublock_parity(None, False, "1.75.0", True)["unequal"])

    def test_a_reference_that_cannot_run_mv2_is_refused(self):
        mv2 = {"manifest_version": 2, "version": "1.75.0"}
        self.assertIn("ignores --load-extension", ib.reference_refusal("com.google.Chrome", "155.0.7400.12", mv2))
        self.assertIn("ignores --load-extension", ib.reference_refusal("com.google.Chrome.canary", "137.0.1.0", mv2))
        self.assertIsNone(ib.reference_refusal("com.google.Chrome", "136.0.7103.2", mv2))
        self.assertIn("no Manifest V2", ib.reference_refusal(ib.CHROME_FOR_TESTING_ID, "154.0.8037.92", mv2))
        self.assertIsNone(ib.reference_refusal(ib.CHROME_FOR_TESTING_ID, "154.0.8037.92", {"manifest_version": 3}))
        # ungoogled-chromium (org.chromium.Chromium) may: whether uBlock Origin started is checked in the run.
        self.assertIsNone(ib.reference_refusal("org.chromium.Chromium", "154.0.8037.58", mv2))

    def test_a_failed_chrome_static_is_refused_only_when_asked(self):
        failed = {"exit": 1, "error": "RuntimeError: chrome-static: branded Google Chrome 155 ignores --load-extension"}
        _, overs, notes, refused = self.judge({"tabs-static": {"kinds": CMUX_KINDS, "over": []},
                                               ib.CHROME_SESSION: failed}, TREE_RULE)
        self.assertEqual(overs, [])
        self.assertEqual(notes, ["tabs-static tree wakeups_per_s/chrome:tree: not judged: reference session "
                                 "chrome-static not measured"])
        self.assertEqual(len(refused), 1)
        self.assertIn("branded Google Chrome 155", refused[0])
        _, _, _, refused = self.judge({"tabs-static": {"kinds": CMUX_KINDS, "over": []}}, TREE_RULE, asked=False)
        self.assertEqual(refused, [])

    def test_chrome_pages_out_of_shape_are_unequal(self):
        # tabs-static's own plan: 5 hidden WebKit and 10 hidden Chromium pages, then the shown one.
        pages = ib.IdlePages()
        try:
            keys = [key for _engine, _url, key in ib.tab_plan(pages, ib.TABS_STATIC)]
        finally:
            pages.close()
        self.assertEqual((len(keys), keys[-1]), (16, "shown"))
        good = {key: "visible" if key == "shown" else "hidden" for key in keys}
        self.assertEqual(ib.chrome_shape_unequal(16, good, keys), [])
        self.assertEqual(ib.chrome_shape_unequal(17, good, keys), ["Chrome had 17 page targets, tabs-static has 16"])
        behind = {**good, "shown": "hidden"}
        self.assertEqual(ib.chrome_shape_unequal(16, behind, keys),
                         ["Chrome's tab visibility is not 1 shown, 15 hidden: shown=hidden"])
        self.assertEqual(ib.chrome_shape_unequal(16, {}, keys[:1]),
                         ["Chrome had 16 page targets, tabs-static has 1",
                          "Chrome's tab visibility is not 1 shown, 0 hidden: w0=None"])
        reason = ib.chrome_shape_unequal(16, behind, keys)[0]
        report, overs, _, refused = self.judge({"tabs-static": {"kinds": CMUX_KINDS, "over": []},
                                                ib.CHROME_SESSION: chrome_entry(CHROME_KINDS, shape=[reason])}, TREE_RULE)
        self.assertEqual(overs, [])
        self.assertEqual(report["ratio_to_chrome"][0]["unequal"], [reason])
        self.assertEqual(refused, [f"tabs-static: {reason}"])

    def test_chrome_at_zero_counts_as_the_floor(self):
        # Chrome's GPU process at 0 wakeups and cmux's at 1 in a minute is noise: the floor (0.5/s), no over.
        budget = {"ratio_to_chrome": [ratio_rule("cef-gpu", "gpu", "wakeups_per_s", 1.0),
                                      ratio_rule("cef-host", "browser", "wakeups_per_s", 1.0)]}
        chrome = {**CHROME_KINDS, "gpu": {"n": 1, "wakeups_per_s": 0.0}}
        cmux = {**CMUX_KINDS, "cef-gpu": {"n": 1, "wakeups_per_s": 0.017}}
        report, overs, notes, _ = self.judge({"tabs-static": {"kinds": cmux, "over": []},
                                              ib.CHROME_SESSION: chrome_entry(chrome)}, budget)
        self.assertEqual(overs, [])
        gpu, host = report["ratio_to_chrome"]
        self.assertEqual((gpu["ratio"], gpu["floor"], gpu["verdict"]), (0.034, 0.5, "ok"))
        self.assertEqual(host["verdict"], "not judged")
        self.assertIn("tabs-static cef-host wakeups_per_s/chrome:browser: not judged: cmux ran no cef-host", notes)
        # cmux at 3/s against the floor is over, and the printed field says the floor was the reference.
        cmux["cef-gpu"] = {"n": 1, "wakeups_per_s": 3.0}
        _, overs, _, _ = self.judge({"tabs-static": {"kinds": cmux, "over": []},
                                     ib.CHROME_SESSION: chrome_entry(chrome)}, budget)
        self.assertEqual(overs, [("tabs-static", ("cef-gpu", "wakeups_per_s/chrome:gpu:floor", 6.0, 1.0))])
        self.assertEqual(ib.over_line("tabs-static", overs[0][1]),
                         "IDLE-BUDGET-OVER tabs-static cef-gpu wakeups_per_s/chrome:gpu:floor 6.0 > 1.0")
        # A field with no floor and a reference of 0 judges nothing (ratio_over's rule).
        self.assertEqual(ib.ratio_of(2.0, 0.0), (None, None))
        self.assertEqual(ib.ratio_over("a", "x", {"a": {"x": 2.0}}, "b", {"b": {"x": 0.0}}, 1.0, "/c"), [])

    def test_template_key_follows_the_browser_and_ublock(self):
        base = ib.template_key("/A/Chromium.app", "154.0", "/u", "1.75.0")
        self.assertEqual(base, ib.template_key("/A/Chromium.app", "154.0", "/u", "1.75.0"))
        self.assertNotEqual(base, ib.template_key("/A/Chromium.app", "155.0", "/u", "1.75.0"))
        self.assertNotEqual(base, ib.template_key("/A/Chromium.app", "154.0", "/u", "1.76.0"))
        self.assertNotEqual(base, ib.template_key("/A/Chromium.app", "154.0", None, None))

    def test_a_template_build_that_fails_leaves_no_template(self):
        class Failing:
            def launch(self, profile, url):
                Path(profile, "data").mkdir()

            def ready(self):
                raise RuntimeError("no DevTools endpoint")

            def quit(self):
                pass

        with tempfile.TemporaryDirectory() as folder:
            template = str(Path(folder, "template-k"))
            with self.assertRaises(RuntimeError):
                ib.build_template(Failing(), template, 0)
            self.assertEqual(list(Path(folder).iterdir()), [])

    def test_chrome_static_settles_as_long_as_the_tab_sessions(self):
        self.assertEqual(ib.settle_seconds(ib.CHROME_SESSION, 10), ib.FREEZE_HIDDEN_TABS_S + ib.FREEZE_GRACE_S)
        self.assertEqual(ib.settle_seconds(ib.CHROME_SESSION, 90), 90)
        self.assertEqual(ib.settle_seconds("light", 10), 10)

    def test_manifest_version(self):
        with tempfile.TemporaryDirectory() as folder:
            self.assertIsNone(ib.manifest_version(folder))
            Path(folder, "manifest.json").write_text(json.dumps({"version": "1.75.0", "manifest_version": 2}))
            self.assertEqual(ib.manifest_version(folder), "1.75.0")
            self.assertEqual(ib.read_manifest(folder)["manifest_version"], 2)

    def test_chrome_rows_count_like_cmux_rows(self):
        cmd = f"{CHROME}/Contents/MacOS/Chromium"
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
        self.assertEqual([s for s in switches if s.startswith("--disable-features=")], ["--disable-features=ChromeWhatsNewUI"])
        plain = xbench.ChromiumBrowser("chrome", CHROME, None, None).switches()
        self.assertEqual([s for s in plain if s.startswith("--disable-features=")], ["--disable-features=ChromeWhatsNewUI"])
        self.assertFalse(any(s.startswith("--load-extension") for s in plain))


def bundle(folder, debug):
    """A `cmux DEV t.app` with an empty main executable; `debug` adds Xcode's `.debug.dylib` beside it."""
    macos = os.path.join(folder, "cmux DEV t.app", "Contents", "MacOS")
    os.makedirs(macos)
    open(os.path.join(macos, "cmux DEV"), "wb").close()
    if debug:
        open(os.path.join(macos, "cmux DEV.debug.dylib"), "wb").close()
    return os.path.dirname(os.path.dirname(macos))


SHIPPING_KEYS = {"CMUX_NEXT_BENCH_SHIPPING_DRAW": "1", "CMUX_NEXT_DEV_SENTRY": "1", "CMUX_NEXT_DEV_HANG_REPORTS": "1"}


class ShippingModeTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="idle-budget-test-")
        self.addCleanup(shutil.rmtree, self.folder, True)

    def test_launch_env_holds_the_three_keys_and_drops_no_activate(self):
        env = ib.launch_env()
        for key, value in SHIPPING_KEYS.items():
            self.assertEqual(env[key], value)
        self.assertIn("CMUX_NEXT_NO_ACTIVATE", env)
        self.assertIsNone(env["CMUX_NEXT_NO_ACTIVATE"])  # None removes BASE_ENV's value
        self.assertNotIn("CMUX_NEXT_BENCH_SHIPPING_DRAW", ib.launch_env(shipping_draw=False))

    def test_the_app_is_started_with_the_three_keys(self):
        import bench_launch
        app = bench_launch.BenchApp(bundle(self.folder, debug=False), out=os.path.join(self.folder, "out"),
                                    teardown=False, env=ib.launch_env())
        env = app.environment()
        for key, value in SHIPPING_KEYS.items():
            self.assertEqual(env.get(key), value)
        self.assertNotIn("CMUX_NEXT_NO_ACTIVATE", env)
        self.assertEqual(env["CMUX_NEXT_SOCKET_MODE"], "automation")  # the bench still reaches the socket

    def test_activate_refuses_a_no_activate_launch(self):
        import bench_launch
        app = bench_launch.BenchApp(bundle(self.folder, debug=False), out=os.path.join(self.folder, "out"),
                                    teardown=False)
        app.process = types.SimpleNamespace(poll=lambda: None)
        app.launched_env = app.environment()
        result = app.activate()
        self.assertFalse(result["activated"])
        self.assertIn("CMUX_NEXT_NO_ACTIVATE=1", result["error"])

    def test_gate_on_a_debug_bundle_exits_non_zero_with_the_reason(self):
        app = bundle(self.folder, debug=True)
        self.assertEqual(ib.bundle_build_config(app), "debug")
        out = io.StringIO()
        with contextlib.redirect_stdout(out), self.assertRaises(SystemExit) as raised:
            ib.main(["--app", app, "--gate", "--out", os.path.join(self.folder, "out")])
        self.assertNotEqual(raised.exception.code, 0)
        self.assertIn("IDLE-BUDGET-REFUSED build_config=debug", out.getvalue())
        self.assertIn("refuses a Debug build", out.getvalue())
        self.assertFalse(os.path.exists(os.path.join(self.folder, "out")))  # refused before any launch or output

    def test_gate_accepts_release_and_bench_hooks_and_no_gate_accepts_debug(self):
        self.assertEqual(ib.bundle_build_config(bundle(self.folder, debug=False)), "release")
        self.assertIsNone(ib.gate_refusal("release", True))
        self.assertIsNone(ib.gate_refusal("bench-hooks", True))
        self.assertIsNone(ib.gate_refusal("debug", False))

    def test_the_five_fields(self):
        import bench_launch
        env = {**bench_launch.BASE_ENV, **{k: v for k, v in ib.launch_env().items() if v is not None}}
        env.pop("CMUX_NEXT_NO_ACTIVATE", None)
        fields = ib.shipping_fields("bench-hooks", env, ["main", "SentryCrash Exception Handler (Primary)"],
                                    {"installed": True}, {"activated": True, "error": ""})
        self.assertEqual(tuple(fields), ib.SHIPPING_FIELDS)
        self.assertEqual(set(ib.SHIPPING_FIELDS),
                         {"build_config", "sentry_started", "hang_reports", "draws_when_occluded", "activated"})
        self.assertEqual(fields["build_config"], "bench-hooks")
        self.assertTrue(fields["sentry_started"])
        self.assertEqual(fields["hang_reports"], {"dev_opt_in": True, "watchdog": True})
        self.assertFalse(fields["draws_when_occluded"])
        self.assertTrue(fields["activated"]["activated"])
        quiet = ib.shipping_fields("debug", {}, ["main"], {}, {"activated": False, "error": "x"})
        self.assertFalse(quiet["sentry_started"])
        self.assertEqual(quiet["hang_reports"], {"dev_opt_in": False, "watchdog": False})

    def test_draws_when_occluded_follows_window_draw_policy(self):
        automation = {"CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation"}
        self.assertTrue(ib.draws_when_occluded("debug", automation))
        self.assertFalse(ib.draws_when_occluded("debug", {**automation, "CMUX_NEXT_BENCH_SHIPPING_DRAW": "1"}))
        self.assertFalse(ib.draws_when_occluded("bench-hooks", automation))
        self.assertFalse(ib.draws_when_occluded("release", automation))
        self.assertFalse(ib.draws_when_occluded("debug", {}))


if __name__ == "__main__":
    unittest.main()
