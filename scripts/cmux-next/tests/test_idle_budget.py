#!/usr/bin/env python3
"""idle-budget.py's pure parts: process kinds, per-kind sums, the budget check, the perf cron rows, the session
table, energy per kind and tree, power assertions and the saver/thermal guard; and procs.py's counters
(interrupt and package-idle wakeups apart, billed energy, GPU time, the coalition)."""

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


if __name__ == "__main__":
    unittest.main()
