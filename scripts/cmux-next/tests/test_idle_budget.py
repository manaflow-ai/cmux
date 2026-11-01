#!/usr/bin/env python3
"""idle-budget.py's pure parts: process kinds, per-kind sums, the budget check and the perf cron rows."""

from __future__ import annotations

import importlib.util
import os
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "perf-bench"))
spec = importlib.util.spec_from_file_location("idle_budget", HERE / "idle-budget.py")
ib = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ib)

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

    def test_display_link_clients_names_what_the_link_calls(self):
        # A /usr/bin/sample report: the CVDisplayLink thread's own frames are CoreVideo's; its owner is the
        # client its callback reaches (here a Chromium frame), which the bench must name.
        report = """Call graph:
    2417 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
    + 2417 CmuxNextApp.main()  (in cmux DEV.debug.dylib) + 8  [0x1]
    4490 Thread_2: CVDisplayLink
    + 4490 thread_start  (in libsystem_pthread.dylib) + 8  [0x2]
    +   4490 CVDisplayLink::runIOThread()  (in CoreVideo) + 600  [0x3]
    +     4400 CVDisplayLink::waitUntil(unsigned long long)  (in CoreVideo) + 20  [0x4]
    +     90 CVDisplayLink::performIO(CVTimeStamp*)  (in CoreVideo) + 230  [0x5]
    +       90 ui::DisplayLinkMac::DisplayLinkCallback(__CVDisplayLink*)  (in Chromium Embedded Framework) + 40  [0x6]
    +         12 base::TaskRunner::PostTask  (in Chromium Embedded Framework) + 4  [0x7]
Total number in stack
"""
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "sample-app.txt")
            with open(path, "w") as handle:
                handle.write(report)
            clients = ib.display_link_clients(path)
        self.assertEqual(clients[0], ("ui::DisplayLinkMac::DisplayLinkCallback(__CVDisplayLink*) (Chromium Embedded Framework)", 90))
        self.assertNotIn("CmuxNextApp.main() (cmux DEV.debug.dylib)", dict(clients), "a frame of another thread")
        self.assertTrue(all("CoreVideo" not in frame for frame, _ in clients))

    def test_bundle_is_one_regular_file_cmux_ci_can_upload(self):
        with tempfile.TemporaryDirectory() as out:
            os.makedirs(os.path.join(out, "stress"))
            with open(os.path.join(out, "stress", "sample-app.txt"), "w") as handle:
                handle.write("sample")
            with open(os.path.join(out, "idle-budget.json"), "w") as handle:
                handle.write("{}")
            with open(os.path.join(out, "idle-budget.md"), "w") as handle:
                handle.write("# table")
            # What split-spring keeps beside the run (the tagged app, the virtual display) stays out.
            os.makedirs(os.path.join(out, "app", "cmux DEV split-spring.app"))
            os.makedirs(os.path.join(out, "vdisplay"))
            path = ib.bundle(out, ["stress"], os.path.join(out, "idle-budget.json"))
            self.assertEqual(path, os.path.join(out, "idle-budget.tgz"))
            self.assertTrue(os.path.isfile(path))
            with tarfile.open(path) as archive:
                self.assertEqual(sorted(archive.getnames()),
                                 ["idle-budget.json", "idle-budget.md", "stress", "stress/sample-app.txt"])

    def test_checked_in_budget_parses(self):
        budget = ib.json.load(open(ib.BUDGET_FILE))
        self.assertEqual(budget["kinds"]["app"]["main_wakes_per_s"], 0)


if __name__ == "__main__":
    unittest.main()
