#!/usr/bin/env python3
"""idle-budget.py's hidden main wake attribution (p14-energy-095): run-loop callout owners from a /usr/bin/sample
report, repeating timer fires between two main run loop descriptions, and the HIDDEN-WAKE lines."""

from __future__ import annotations

import ctypes
import importlib.util
import json
import sys
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "perf-bench"))


def load():
    """idle-budget.py; off macOS libproc does not exist, so its loader is stubbed (only pure parts run here)."""
    spec = importlib.util.spec_from_file_location("idle_budget_hidden_wake", HERE / "idle-budget.py")
    module = importlib.util.module_from_spec(spec)
    if sys.platform == "darwin":
        spec.loader.exec_module(module)
    else:
        with mock.patch.object(ctypes, "CDLL", lambda *_a, **_k: mock.MagicMock()):
            sys.modules.pop("procs", None)
            spec.loader.exec_module(module)
    return module


ib = load()

# A /usr/bin/sample call graph in the tool's own layout: two columns of indent per level, `+ ! : |` guides.
SAMPLE = """\
Analysis of sampling cmux DEV (pid 4242) every 1 millisecond
Call graph:
    1000 Thread_77   DispatchQueue_1: com.apple.main-thread  (serial)
    + 1000 start  (in dyld) + 2840  [0x18c3b0274]
    +   1000 main  (in cmux DEV) + 36  [0x100a0]
    +     1000 NSApplicationMain  (in AppKit) + 880  [0x1]
    +       1000 -[NSApplication run]  (in AppKit) + 480  [0x2]
    +         1000 CFRunLoopRunSpecific  (in CoreFoundation) + 588  [0x3]
    +           1000 __CFRunLoopRun  (in CoreFoundation) + 1996  [0x4]
    +             900 __CFRunLoopServiceMachPort  (in CoreFoundation) + 160  [0x5]
    +             ! 900 mach_msg  (in libsystem_kernel.dylib) + 24  [0x6]
    +             60 __CFRunLoopDoTimers  (in CoreFoundation) + 284  [0x7]
    +             ! 60 __CFRunLoopDoTimer  (in CoreFoundation) + 1000  [0x8]
    +             !   60 __CFRUNLOOP_IS_CALLING_OUT_TO_A_TIMER_CALLBACK_FUNCTION__  (in CoreFoundation) + 32  [0x9]
    +             !     40 __NSFireTimer  (in Foundation) + 104  [0xa]
    +             !     : 40 thunk for @escaping @callee_guaranteed (@guaranteed NSTimer) -> ()  (in cmux DEV) + 28  [0xb]
    +             !     :   40 closure #1 in StatusPoller.start()  (in cmux DEV) + 60  [0xc]
    +             !     20 WebCore::ThreadTimers::sharedTimerFiredInternal()  (in WebCore) + 200  [0xd]
    +             30 __CFRunLoopDoSources0  (in CoreFoundation) + 244  [0xe]
    +             ! 30 __CFRunLoopDoSource0  (in CoreFoundation) + 156  [0xf]
    +             !   30 __CFRUNLOOP_IS_CALLING_OUT_TO_A_SOURCE0_PERFORM_FUNCTION__  (in CoreFoundation) + 28  [0x10]
    +             !     30 base::MessagePumpCFRunLoopBase::RunWorkSource(void*)  (in Chromium Embedded Framework) + 92  [0x11]
    +             8 _dispatch_main_queue_callback_4CF  (in libdispatch.dylib) + 44  [0x12]
    +             ! 8 __CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__  (in CoreFoundation) + 16  [0x13]
    +             !   8 _dispatch_main_queue_drain  (in libdispatch.dylib) + 980  [0x14]
    +             !     5 swift_job_run  (in libswift_Concurrency.dylib) + 72  [0x15]
    +             !     | 5 (1) await resume partial function for WorkspaceSync.flush()  (in cmux DEV) + 1  [0x16]
    +             !     3 _dispatch_client_callout  (in libdispatch.dylib) + 20  [0x17]
    +             !       3 -[NSDistributedNotificationCenter _deliver]  (in Foundation) + 30  [0x18]
    +             2 __CFRunLoopDoObservers  (in CoreFoundation) + 532  [0x19]
    +               2 __CFRUNLOOP_IS_CALLING_OUT_TO_AN_OBSERVER_CALLBACK_FUNCTION__  (in CoreFoundation) + 36  [0x1a]
    +                 2 CA::Transaction::observer_callback(__CFRunLoopObserver*, unsigned long, void*)  (in QuartzCore) + 96  [0x1b]
    1000 Thread_78: com.apple.NSEventThread
    + 1000 thread_start  (in libsystem_pthread.dylib) + 8  [0x30]

Total number in stack (recursive counted multiple times):
"""


def timer(fire, interval=1.0, callout="__NSFireTimer (0x1 / 0x2) (/System/Library/Frameworks/Foundation.framework/Foundation)"):
    return (f"<CFRunLoopTimer 0x600 [0x1f]>{{valid = Yes, firing = No, interval = {interval}, tolerance = 0.1, "
            f"next fire date = {fire} (-0.5 @ 99), callout = {callout}, context = <CFRunLoopTimer context 0x7>}}")


class HiddenWakeTests(unittest.TestCase):
    def test_main_thread_tree_is_the_main_thread(self):
        tree = ib.main_thread_tree(SAMPLE)
        self.assertIn("com.apple.main-thread", tree["symbol"])
        self.assertEqual(tree["count"], 1000)
        self.assertIsNone(ib.main_thread_tree("no call graph here"))

    def test_callout_owners_name_the_first_owner_frame_below_each_callout(self):
        rows = {(r["kind"], r["owner"]): r["samples"] for r in ib.main_callouts_from_sample(SAMPLE)}
        self.assertEqual(rows, {
            # A Swift thunk in the app binary is skipped: the closure below it names the owner.
            ("timer", "closure #1 in StatusPoller.start() (cmux DEV)"): 40,
            ("timer", "WebCore::ThreadTimers::sharedTimerFiredInternal() (WebCore)"): 20,
            ("source0", "base::MessagePumpCFRunLoopBase::RunWorkSource(void*) (Chromium Embedded Framework)"): 30,
            ("main-queue", "(1) await resume partial function for WorkspaceSync.flush() (cmux DEV)"): 5,
            # No owner frame: the first OS frame past the dispatch trampolines on the heaviest path.
            ("main-queue", "-[NSDistributedNotificationCenter _deliver] (Foundation)"): 3,
            ("observer", "CA::Transaction::observer_callback(__CFRunLoopObserver*, unsigned long, void*) (QuartzCore)"): 2,
        })

    def test_timer_fires_counts_next_fire_date_advances(self):
        before = timer(100.0) + timer(50.0, interval=0.5, callout="cmuxTick") + timer(70.0, interval=0)
        after = timer(160.0) + timer(80.0, interval=0.5, callout="cmuxTick") + timer(75.0, interval=0)
        fires = ib.timer_fires(before, after, 60.0)
        self.assertEqual([(f["callout"][:13], f["interval_s"], f["per_s"]) for f in fires],
                         [("__NSFireTimer", 1.0, 1.0), ("cmuxTick", 0.5, 1.0)])  # same rate: by callout
        self.assertEqual(ib.timer_fires(before, before, 60.0), [])
        self.assertEqual(ib.timer_fires("", after, 60.0), [])

    def test_sources_above_the_floor_are_named_with_their_basis(self):
        result = {"main_wakes_per_s": 107.0, "main_callouts": ib.main_callouts_from_sample(SAMPLE),
                  "ledger": {"owners": [{"owner": "BusyWatchdog", "reason": "deadline", "per_s": 0.1},
                                        {"owner": "PresenceClient", "reason": "backoff", "per_s": 0.5}]},
                  "main_run_loop_timer_fires": [{"callout": "cmuxTick", "interval_s": 0.5, "timers": 1, "per_s": 2.0}]}
        report = ib.hidden_wake_sources(result)
        self.assertEqual(report["cause_samples"], 98)  # observers are not causes
        by_owner = {s["owner"]: s for s in report["sources"]}
        status = by_owner["closure #1 in StatusPoller.start() (cmux DEV)"]
        self.assertEqual((status["basis"], status["kind"], status["per_s"]), ("sample-share", "timer", round(107 * 40 / 98, 3)))
        self.assertEqual(by_owner["PresenceClient:backoff"]["basis"], "ledger")
        self.assertEqual(by_owner["cmuxTick"]["basis"], "run-loop-timer")
        self.assertNotIn("BusyWatchdog:deadline", by_owner)  # 0.1/s is the floor, not above it
        self.assertEqual([s["per_s"] for s in report["sources"]], sorted((s["per_s"] for s in report["sources"]), reverse=True))
        self.assertTrue(all(s["per_s"] > ib.HIDDEN_WAKE_FLOOR for s in report["sources"]))
        self.assertEqual(len(report["observers"]), 1)

    def test_sample_owners_stay_named_without_a_main_wake_count(self):
        report = ib.hidden_wake_sources({"main_callouts": ib.main_callouts_from_sample(SAMPLE)})
        self.assertEqual(len(report["sources"]), 5)
        self.assertTrue(all(s["per_s"] is None for s in report["sources"]))

    def test_hidden_wake_lines_carry_owner_rate_frame_sha_and_host(self):
        report = ib.hidden_wake_sources({"main_wakes_per_s": 10.0, "main_callouts": ib.main_callouts_from_sample(SAMPLE)})
        lines = ib.hidden_wake_lines("minimized", report, "a" * 40, "cmux20")
        wakes = [json.loads(line.split(" ", 1)[1]) for line in lines if line.startswith("HIDDEN-WAKE ")]
        self.assertEqual(len(wakes), 5)
        self.assertEqual({k for k in wakes[0]} >= {"session", "owner", "per_s", "top", "kind", "basis"}, True)
        total = json.loads(lines[-1].split(" ", 1)[1])
        self.assertTrue(lines[-1].startswith("HIDDEN-WAKE-TOTAL "))
        self.assertEqual((total["sha"], total["host"], total["sources"], total["main_wakes_per_s"]), ("a" * 40, "cmux20", 5, 10.0))
        self.assertEqual(sum(1 for line in lines if line.startswith("HIDDEN-WAKE-OBSERVER ")), 1)

    def test_hidden_sessions_launch_in_shipping_mode(self):
        for session in ("light-hidden", "minimized"):
            self.assertEqual(ib.session_env(session), {"CMUX_NEXT_BENCH_SHIPPING_DRAW": "1", "CMUX_NEXT_DEV_SENTRY": "1",
                                                       "CMUX_NEXT_DEV_HANG_REPORTS": "1"})
        self.assertEqual(ib.session_env("light"), {})
        self.assertTrue(ib.SESSIONS["minimized"]["minimize"])

    def test_threads_from_sample_skips_waits(self):
        threads = ib.threads_from_sample(SAMPLE)
        main = next(v for k, v in threads.items() if "main-thread" in k)
        frames = dict(main["frames"])
        self.assertNotIn("mach_msg (libsystem_kernel.dylib)", frames)
        self.assertEqual(frames["__CFRunLoopServiceMachPort (CoreFoundation)"], 900)
        self.assertEqual(threads["com.apple.NSEventThread (1000)"]["frames"], [])


if __name__ == "__main__":
    unittest.main()
