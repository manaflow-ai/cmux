#!/usr/bin/env python3
"""idle-budget.py's pure parts: process kinds, per-kind sums, the budget check, the perf cron rows, the session
table, energy aggregation, power assertions and the saver/thermal guard."""

from __future__ import annotations

import ctypes
import importlib.util
import sys
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "perf-bench"))
spec = importlib.util.spec_from_file_location("idle_budget", HERE / "idle-budget.py")
ib = importlib.util.module_from_spec(spec)
if sys.platform == "darwin":
    spec.loader.exec_module(ib)
else:  # the pure parts run anywhere; libproc and libSystem exist only on macOS
    with mock.patch.object(ctypes, "CDLL", mock.MagicMock()):
        spec.loader.exec_module(ib)

APP = "/Users/x/DerivedData/cmux-t/Build/Products/Debug/cmux DEV t.app"


def row(kind, threads, wakeups, cpu=0.0, energy=0.0):
    return {"kind": kind, "threads": threads, "threads_ran": 0, "wakeups_per_s": wakeups, "csw_per_s": 0.0, "cpu_pct": cpu,
            "energy_mw": energy}


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


def ends(saver_start, saver_end, thermal_start="nominal", thermal_end="nominal", assertions=(), anim=None):
    start = {"saver": saver_start, "saver_reason": "setting" if saver_start else None, "thermal": thermal_start,
             "assertions": list(assertions)}
    end = {"saver": saver_end, "saver_reason": "setting" if saver_end else None, "thermal": thermal_end,
           "assertions": list(assertions)}
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


class SessionTableTests(unittest.TestCase):
    def test_tab_sessions_shape(self):
        tabs = ib.SESSIONS["tabs-static"]["tabs"]
        self.assertEqual((tabs["webkit_hidden"], tabs["chromium_hidden"]), (5, 10))
        self.assertEqual(tabs["shown"], "/static/shown")
        self.assertEqual(ib.SESSIONS["tabs-static"]["config"]["browser"]["freezeHiddenTabs"], ib.FREEZE_HIDDEN_TABS_S)
        saver = ib.SESSIONS["energy-saver"]
        self.assertEqual(saver["config"]["energy"], {"saver": "always"})
        self.assertEqual(saver["tabs"]["shown"], ib.ANIM_PATH)
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

    def test_page_handler_serves_static_and_animated_pages(self):
        import http.server
        import threading
        import urllib.request
        requested = set()
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), ib.page_handler(requested))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            base = f"http://127.0.0.1:{server.server_address[1]}"
            static = urllib.request.urlopen(base + "/static/c3", timeout=5).read().decode()
            anim = urllib.request.urlopen(base + ib.ANIM_PATH, timeout=5).read().decode()
        finally:
            server.shutdown()
            server.server_close()
        self.assertNotIn("<script", static)
        self.assertIn("idle page 3", static)
        self.assertIn("requestAnimationFrame", anim)
        self.assertIn("__rafCount", anim)
        self.assertEqual(requested, {"/static/c3", ib.ANIM_PATH})


class EnergyTests(unittest.TestCase):
    def test_process_row_turns_rusage_energy_into_milliwatts(self):
        # counters: (energy nJ, cpu ns, wakeups, footprint); overhead: (disk, threads, msgs, syscalls, csw)
        first = ((1_000_000_000, 0, 10, 0), (0, 4, 0, 0, 100), {})
        last = ((4_000_000_000, 600_000_000, 70, 0), (0, 4, 0, 0, 160), {})
        out = ib.process_row(1, f"{APP}/Contents/MacOS/cmux DEV", first, last, 60.0)
        self.assertEqual(out["energy_mw"], 50.0)  # 3 J over 60 s
        self.assertEqual(out["wakeups_per_s"], 1.0)
        self.assertEqual(out["cpu_pct"], 1.0)
        self.assertEqual(out["kind"], "app")
        self.assertFalse(out["partial"])
        started = ib.process_row(2, "/bin/zsh", None, ((120_000_000, 0, 0, 0), (0, 1, 0, 0, 0), {}), 60.0)
        self.assertTrue(started["partial"])
        self.assertEqual(started["energy_mw"], 2.0)

    def test_energy_sums_per_kind_and_tree(self):
        kinds = ib.aggregate({"processes": [row("cef-renderer", 10, 0.1, energy=1.25), row("cef-renderer", 10, 0.0, energy=0.75),
                                            row("app", 40, 0.5, energy=8.0), row("daemon", 9, 0.2, energy=0.5)]})
        self.assertEqual(kinds["cef-renderer"]["energy_mw"], 2.0)
        summary = ib.energy_summary(kinds)
        self.assertEqual(summary["per_kind"], {"cef-renderer": 2.0, "app": 8.0, "daemon": 0.5})
        self.assertEqual(summary["tree"], 10.5)

    def test_energy_cron_rows_are_milliwatts(self):
        report = {"sessions": {"tabs-static": {"kinds": {"app": {"energy_mw": 3.2}}}}}
        rows = ib.cron_rows(report, {"kinds": {}})
        self.assertEqual(rows["idle_budget.tabs-static.app.energy_mw"]["unit"], "mW")


class PowerAssertionTests(unittest.TestCase):
    def test_assertions_of_the_pid_set(self):
        found = ib.procs.power_assertions({501, 777, 900}, PMSET)
        self.assertEqual([(a["pid"], a.get("created_for")) for a in found], [(501, None), (120, 777), (900, None)])
        self.assertEqual(found[0]["type"], "PreventUserIdleSystemSleep")
        self.assertEqual(found[0]["name"], "cmux keep awake")
        self.assertEqual(found[0]["process"], "cmux DEV t")
        self.assertEqual(found[2]["process"], "Google Chrome Helper (Renderer)")
        self.assertEqual(ib.procs.power_assertions({4242}, PMSET), [])


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
        held = ib.procs.power_assertions({501}, PMSET)
        result = {"processes": [row("app", 40, 0.2, energy=4.0), row("daemon", 9, 0.1, energy=1.0)],
                  "ends": ends(False, False, assertions=held)}
        entry = ib.summarize("tabs-static", result, {"kinds": {}})
        for key in ("assertions", "energy_mw", "saver", "thermal"):
            self.assertIn(key, entry)
        self.assertEqual(len(entry["assertions"]), 1)  # the same assertion at both ends is listed once
        self.assertEqual(entry["energy_mw"]["per_kind"]["app"], 4.0)
        self.assertEqual(entry["energy_mw"]["tree"], 5.0)
        self.assertNotIn("anim", entry)

    def test_animated_page_rate(self):
        reads = ({"count": 100, "t_ms": 1000, "visibility": "visible"}, {"count": 1900, "t_ms": 61000, "visibility": "visible"})
        entry = ib.summarize("energy-saver", {"processes": [], "ends": ends(True, True, anim=reads)}, {"kinds": {}})
        self.assertEqual(entry["anim"]["raf_per_s"], 30.0)
        self.assertEqual(entry["anim"]["visibility"], ["visible", "visible"])
        self.assertIn("error", ib.anim_rate({"error": "no target"}, {"count": 1, "t_ms": 2}))


if __name__ == "__main__":
    unittest.main()
