#!/usr/bin/env python3
"""power_attribution.py (p14-energy-096) and its idle-budget.py sessions: billed energy per process, the per-thread
split, owners that sum to the coalition total within 10%, naming from a stack sample, POWER-OVER against Chrome's
owners, the FrameClients that ticked, PowerWindow's read order around the window (fake counters), and the
power-visible / chrome-power-visible sessions. Runs on any host (libproc loads only to measure)."""

from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "perf-bench"))
import power_attribution as pa  # noqa: E402
import procs  # noqa: E402

spec = importlib.util.spec_from_file_location("idle_budget", HERE / "idle-budget.py")
ib = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ib)

MS = 1_000_000  # 1 mW over 1 s = 1e6 nJ
APP = "/Apps/cmux DEV t.app/Contents/MacOS/cmux DEV"
RENDERER = "/Apps/cmux DEV t.app/Contents/Frameworks/cmux Helper (Renderer).app/Contents/MacOS/x --type=renderer"
GPU = "/Apps/cmux DEV t.app/Contents/Frameworks/cmux Helper (GPU).app/Contents/MacOS/x --type=gpu-process"


def usage(energy=0, billed=0, serviced=0, cpu=0):
    return procs.Usage(energy_nj=energy, billed_energy_nj=billed, serviced_energy_nj=serviced, cpu_ns=cpu)


def coalition(energy=0, to_me=0, to_others=0):
    return procs.CoalitionUsage(energy_nj=energy, energy_billed_to_me_nj=to_me, energy_billed_to_others_nj=to_others,
                                gpu_ns=0, cpu_ns=0, interrupt_wakeups=0, platform_idle_wakeups=0)


class ProcessPowerTests(unittest.TestCase):
    def test_billed_moves_energy_to_the_client(self):
        got = pa.process_power(usage(), usage(energy=10 * MS, billed=4 * MS, serviced=1 * MS, cpu=5), 2.0)
        self.assertEqual((got["own_mw"], got["billed_mw"], got["serviced_mw"], got["mw"]), (5.0, 2.0, 0.5, 6.5))

    def test_a_process_started_in_the_window_counts_from_zero(self):
        self.assertEqual(pa.process_power(None, usage(energy=3 * MS), 1.0)["mw"], 3.0)


class ThreadSplitTests(unittest.TestCase):
    def test_own_energy_splits_by_cpu_and_the_main_thread_is_named(self):
        before = {5: (100, ""), 9: (0, "Chrome_IOThread"), 12: (0, "")}
        after = {5: (400, ""), 9: (100, "Chrome_IOThread"), 12: (100, "")}
        rows = pa.thread_split(10.0, 500, before, after, 1.0)
        self.assertEqual([(r["name"], r["mw"], r["named"]) for r in rows],
                         [("main", 6.0, True), ("Chrome_IOThread", 2.0, True), ("", 2.0, False)])

    def test_cpu_of_exited_threads_is_its_own_unnamed_row(self):
        rows = pa.thread_split(8.0, 400, {5: (0, "")}, {5: (300, "")}, 1.0)
        exited = [r for r in rows if r["tid"] is None]
        self.assertEqual((exited[0]["name"], exited[0]["mw"], exited[0]["named"]), ("exited threads", 2.0, False))
        self.assertAlmostEqual(sum(r["mw"] for r in rows), 8.0)


class OwnerTests(unittest.TestCase):
    def processes(self):
        return [
            {"pid": 1, "kind": "app", "power": pa.process_power(usage(), usage(energy=6 * MS, billed=3 * MS, cpu=300), 1.0),
             "threads": pa.thread_split(6.0, 300, {}, {10: (200, ""), 11: (100, "")}, 1.0)},
            {"pid": 2, "kind": "cef-renderer", "power": pa.process_power(usage(), usage(energy=2 * MS, billed=1 * MS, cpu=100), 1.0),
             "threads": pa.thread_split(2.0, 100, {}, {20: (100, "")}, 1.0)},
            {"pid": 3, "kind": "cef-gpu", "power": pa.process_power(usage(), usage(energy=4 * MS, serviced=1 * MS, cpu=0), 1.0),
             "threads": []},
        ]

    def test_owners_sum_to_the_processes(self):
        processes = self.processes()
        entries = pa.owners(processes)
        self.assertAlmostEqual(sum(e["mw"] for e in entries), sum(p["power"]["mw"] for p in processes))
        by = {e["owner"]: e for e in entries}
        self.assertEqual(by["app/main"]["mw"], 4.0)
        self.assertEqual(by["app/billed"]["mw"], 3.0)
        self.assertEqual(by["cef-gpu/process"]["mw"], 4.0)  # no thread read: the process is the owner
        self.assertEqual(by["cef-gpu/serviced"]["mw"], -1.0)
        self.assertFalse(by["app/thread 11"]["named"])
        self.assertEqual(by["app/thread 11"]["tid"], 11)

    def test_one_kind_sums_its_processes(self):
        two = self.processes()[1:2] * 2
        two[1] = {**two[1], "pid": 4}
        by = {e["owner"]: e for e in pa.owners(two)}
        self.assertEqual((by["cef-renderer/main"]["mw"], by["cef-renderer/main"]["pids"]), (4.0, [2, 4]))

    def test_unnamed_owners_over_the_floor_and_naming_them_from_a_sample(self):
        entries = pa.owners(self.processes())
        self.assertEqual([e["owner"] for e in pa.unnamed(entries)], ["app/thread 11"])
        pa.name_threads(entries, 1, {11: "com.cmux.vsync"})
        self.assertEqual(pa.unnamed(entries), [])
        self.assertIn("app/thread 11 (com.cmux.vsync)", [e["owner"] for e in entries])

    def test_another_pids_sample_names_nothing(self):
        entries = pa.owners(self.processes())
        pa.name_threads(entries, 2, {11: "wrong process"})
        self.assertEqual([e["owner"] for e in pa.unnamed(entries)], ["app/thread 11"])


SAMPLE = """Call graph:
    2000 Thread_11   DispatchQueue_7: com.cmux.vsync  (serial)
    + 2000 start_wqthread  (in libsystem_pthread.dylib) + 8
    +   1500 VSyncHub.fire()  (in cmux DEV) + 40
    +     1400 FrameScheduler.tick()  (in cmux DEV) + 12
    +   500 __workq_kernreturn  (in libsystem_kernel.dylib) + 8
    2000 Thread_12
    + 2000 thread_start  (in libsystem_pthread.dylib) + 8
    +   1800 GlassBackdropFeed.frame()  (in cmux DEV) + 80
    +     1800 CA::Transaction::commit()  (in QuartzCore) + 10
    +   200 mach_msg2_trap  (in libsystem_kernel.dylib) + 8

Total number in stack (recursive counted multiple times):
"""


class SampleLabelTests(unittest.TestCase):
    def test_queue_name_or_the_busiest_deepest_frame(self):
        labels = pa.sample_labels(SAMPLE)
        self.assertEqual(labels[11], "com.cmux.vsync")
        self.assertEqual(labels[12], "top CA::Transaction::commit() (QuartzCore)")


class BreakdownTests(unittest.TestCase):
    def test_within_ten_percent_of_the_coalition_less_outside_plus_foreign(self):
        coalition_rates = {"energy_mw_billed": 110.0}
        got = pa.breakdown(95.0, coalition_rates, outside_mw=10.0, foreign_mw=5.0)
        self.assertEqual((got["total_mw"], got["ratio"], got["within"]), (105.0, 0.905, True))
        self.assertFalse(pa.breakdown(80.0, coalition_rates, 10.0, 5.0)["within"])

    def test_no_coalition_is_no_verdict(self):
        got = pa.breakdown(10.0, None, 0.0, 0.0)
        self.assertIsNone(got["within"])
        self.assertEqual(got["note"], "no coalition total")


class PowerOverTests(unittest.TestCase):
    def test_groups_by_chrome_role_and_lists_only_what_spends_more(self):
        mine = [{"owner": "app/main", "mw": 30.0}, {"owner": "cef-host/main", "mw": 5.0},
                {"owner": "cef-renderer/main", "mw": 3.0}, {"owner": "app/thread 9 (top GlassBackdropFeed.frame() (cmux))", "mw": 12.0},
                {"owner": "cef-gpu/CrGpuMain", "mw": 1.0}]
        chrome = [{"owner": "browser/main", "mw": 20.0}, {"owner": "renderer/main", "mw": 4.0},
                  {"owner": "gpu/CrGpuMain", "mw": 0.5}]
        rows = pa.power_over(mine, chrome)
        self.assertEqual([(r["owner"], r["mw"], r["reference_mw"]) for r in rows],
                         [("browser/main", 35.0, 20.0), ("app/thread 9 (top GlassBackdropFeed.frame() (cmux))", 12.0, None)])
        self.assertEqual(pa.over_lines(rows)[0], "POWER-OVER browser/main 35.0 mW chrome=20.0 from=app/main,cef-host/main")

    def test_no_reference_is_no_rows(self):
        self.assertEqual(pa.power_over([{"owner": "app/main", "mw": 30.0}], None), [])


class FrameClientTests(unittest.TestCase):
    def test_frame_owners_that_ticked_and_schedulers_that_made_frames(self):
        before = {"ledger": [{"owner": "GlassBackdropFeed", "reason": "frame", "count": 100},
                             {"owner": "DemandTimer.x", "reason": "deadline", "count": 5}],
                  "frame_schedulers": [{"name": "window-1", "frames": 1000}], "active_frame_clients": ["GlassBackdropFeed"]}
        after = {"ledger": [{"owner": "GlassBackdropFeed", "reason": "frame", "count": 700},
                            {"owner": "NightSky", "reason": "frame", "count": 60},
                            {"owner": "DemandTimer.x", "reason": "deadline", "count": 9}],
                 "frame_schedulers": [{"name": "window-1", "frames": 1600, "active_clients": ["GlassBackdropFeed"]},
                                      {"name": "budgeted", "frames": 3}],
                 "active_frame_clients": ["GlassBackdropFeed"]}
        got = pa.frame_clients(before, after, 10.0)
        self.assertEqual(got["ticked"], [{"owner": "GlassBackdropFeed", "per_s": 60.0}, {"owner": "NightSky", "per_s": 6.0}])
        self.assertEqual(got["schedulers"], [{"name": "window-1", "frames_per_s": 60.0, "active_clients": ["GlassBackdropFeed"]}])
        self.assertEqual(got["active_end"], ["GlassBackdropFeed"])


class FakeCounters:
    """A Mac with the app (1, renderer 2) in coalition 7 with the bench (99), a WebKit-like process 3 of the
    instance outside it, and WindowServer (50) read as root. Each counter grows by its mW per second of clock."""

    def __init__(self):
        self.now = 0.0
        self.calls = []
        self.mw = {1: 20.0, 2: 6.0, 3: 2.0, 99: 1.0, 50: 40.0}
        self.coalition_members = {1, 2, 99}
        self.reader = pa.Reader(usage=self.usage, threads=self.threads, coalition_id=self.cid,
                                coalition_usage=self.coalition, process_table=self.table, root_usage=self.root,
                                clock=lambda: self.now)

    def usage(self, pid):
        self.calls.append("usage")
        mw = self.mw.get(pid)
        return None if mw is None else usage(energy=int(mw * MS * self.now), cpu=int(1e6 * self.now))

    def threads(self, pid):
        return {pid * 10: (int(1e6 * self.now), "")}

    def cid(self, pid):
        return 7 if pid in self.coalition_members else 8

    def coalition(self, cid):
        self.calls.append("coalition")
        return coalition(energy=int(sum(self.mw[p] for p in self.coalition_members) * MS * self.now))

    def table(self):
        self.calls.append("ps")
        return [(1, 99, APP), (2, 1, RENDERER), (3, 1, "/System/x/com.apple.WebKit.WebContent"), (99, 0, "python3 bench"),
                (50, 1, "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer -daemon")]

    def root(self, pid):
        self.calls.append("sudo")
        return usage(energy=int(self.mw[pid] * MS * self.now), cpu=int(2e6 * self.now))


class PowerWindowTests(unittest.TestCase):
    def test_the_owners_match_the_coalition_and_subprocesses_sit_outside_the_bracket(self):
        fake = FakeCounters()
        window = pa.PowerWindow(1, lambda: {1: APP, 2: RENDERER, 3: "/System/x/com.apple.WebKit.WebContent"},
                                ib.kind, reader=fake.reader)
        window.begin()
        fake.now = 10.0
        fake.calls.append("window")
        got = pa.attribute(window.end())
        # No ps or sudo between the two coalition reads (a subprocess exiting there would be unowned energy).
        first, last = fake.calls.index("coalition"), len(fake.calls) - 1 - fake.calls[::-1].index("coalition")
        self.assertFalse({"ps", "sudo"} & set(fake.calls[first:last + 1]))
        # 1 + 2 + 3 = 28 mW: coalition 27 less the bench 1, plus the WebKit process outside the coalition 2.
        self.assertEqual((got["breakdown"]["sum_mw"], got["breakdown"]["total_mw"], got["breakdown"]["within"]),
                         (28.0, 28.0, True))
        self.assertEqual(got["window_server"]["own_mw"], 40.0)
        self.assertIn("app/main", [e["owner"] for e in got["owners"]])
        self.assertIn("cef-renderer/main", [e["owner"] for e in got["owners"]])

    def test_without_root_windowserver_is_null(self):
        fake = FakeCounters()
        reader = pa.Reader(**{**fake.reader.__dict__, "root_usage": lambda pid: None})
        window = pa.PowerWindow(1, lambda: {1: APP}, ib.kind, reader=reader)
        window.begin()
        fake.now = 5.0
        self.assertIsNone(pa.attribute(window.end())["window_server"])


class IdleBudgetSessionTests(unittest.TestCase):
    def test_power_sessions_are_one_shown_tab_on_both_sides(self):
        mine, chrome = ib.SESSIONS[ib.POWER_SESSION], ib.SESSIONS[ib.CHROME_POWER_SESSION]
        self.assertEqual(mine["tabs"], chrome["tabs"])
        self.assertEqual(len(ib.tab_plan(type("P", (), {"url": lambda self, k, key: key, "origin": ""})(), mine["tabs"])), 1)
        self.assertTrue(mine["power"] and chrome["power"] and chrome["chrome"])
        self.assertEqual(ib.SESSIONS[ib.CHROME_SESSION]["tabs"], ib.TABS_STATIC)
        self.assertEqual(ib.parse_sessions("power-visible,chrome-power-visible"), [ib.POWER_SESSION, ib.CHROME_POWER_SESSION])

    def test_power_over_needs_both_sessions(self):
        report = {"sessions": {ib.POWER_SESSION: {"power": {"owners": [{"owner": "app/main", "mw": 30.0}]}}}}
        self.assertIsNone(ib.power_overs(report))
        report["sessions"][ib.CHROME_POWER_SESSION] = {"power": {"owners": [{"owner": "browser/main", "mw": 10.0}]}}
        self.assertEqual([(r["owner"], r["reference_mw"]) for r in ib.power_overs(report)], [("app/main", 10.0)])

    def test_naming_samples_only_processes_with_unnamed_owners(self):
        power = {"owners": [{"owner": "app/thread 11", "mw": 5.0, "named": False, "pids": [1], "tid": 11},
                            {"owner": "cef-renderer/thread 12", "mw": 3.0, "named": False, "pids": [2], "tid": 12},
                            {"owner": "cef-gpu/thread 13", "mw": 0.5, "named": False, "pids": [3], "tid": 13}]}
        sampled = []

        def sampler(pid, seconds, path):
            sampled.append(pid)
            return SAMPLE

        with tempfile.TemporaryDirectory() as folder:
            ib.name_power_owners(power, 10, folder, samples={1: SAMPLE}, sampler=sampler)
        self.assertEqual(sampled, [2])  # 1 came with the app's sample; 3 is under the floor
        self.assertEqual(pa.unnamed(power["owners"]), [])
        self.assertTrue(power["owners"][1]["owner"].endswith("(top CA::Transaction::commit() (QuartzCore))"))

    def test_judge_across_gives_no_parity_to_a_reference_session(self):
        chrome_kinds = {"browser": {"n": 1, "wakeups_per_s": 1.0}}
        report = {"sessions": {ib.CHROME_SESSION: {"kinds": chrome_kinds, "chrome": {"ublock": {}, "unequal": []}},
                               ib.CHROME_POWER_SESSION: {"kinds": chrome_kinds}}}
        ib.judge_across(report, {})
        self.assertNotIn(ib.CHROME_POWER_SESSION, report["chrome"]["parity"])


if __name__ == "__main__":
    unittest.main()
