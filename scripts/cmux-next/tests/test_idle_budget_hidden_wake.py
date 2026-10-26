#!/usr/bin/env python3
"""idle-budget.py's hidden main wake attribution (p14-energy-095): run-loop callout owners from /usr/bin/sample
reports, the DTrace callout count, repeating timer fires between two main run loop descriptions, the HIDDEN-WAKE
lines, and main()'s hidden-wake session with a fake app."""

from __future__ import annotations

import contextlib
import ctypes
import importlib.util
import io
import itertools
import json
import os
import plistlib
import shutil
import sys
import tempfile
import types
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

# A /usr/bin/sample report in the tool's own layout: two columns of indent per level, `+ ! : |` guides, and the
# Binary Images part that gives each image's path.
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

Binary Images:
       0x100a00000 -        0x100bfffff +com.cmuxterm.app.debug.t (0.1 - 1) <0D3A6B1E-0000-0000-0000-000000000001> /Users/x/cmux DEV t.app/Contents/MacOS/cmux DEV
       0x110000000 -        0x11fffffff +org.cef.framework (1) <0D3A6B1E-0000-0000-0000-000000000002> /Users/x/cmux DEV t.app/Contents/Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework
       0x18c3a8000 -        0x18c42bfff  dyld (1.0.0 - 1160) <0D3A6B1E-0000-0000-0000-000000000003> /usr/lib/dyld
       0x18c500000 -        0x18c9fffff  com.apple.CoreFoundation (6.9 - 3423) <0D3A6B1E-0000-0000-0000-000000000004> /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation
       0x18d000000 -        0x18d9fffff  com.apple.Foundation (6.9 - 3423) <0D3A6B1E-0000-0000-0000-000000000005> /System/Library/Frameworks/Foundation.framework/Versions/C/Foundation
       0x18e000000 -        0x18e9fffff  com.apple.AppKit (6.9 - 2575) <0D3A6B1E-0000-0000-0000-000000000006> /System/Library/Frameworks/AppKit.framework/Versions/C/AppKit
       0x18f000000 -        0x18f0fffff  libdispatch.dylib (1477) <0D3A6B1E-0000-0000-0000-000000000007> /usr/lib/system/libdispatch.dylib
       0x18f100000 -        0x18f1fffff  libswift_Concurrency.dylib (6.2) <0D3A6B1E-0000-0000-0000-000000000008> /usr/lib/swift/libswift_Concurrency.dylib
       0x190000000 -        0x190ffffff  com.apple.WebCore (621) <0D3A6B1E-0000-0000-0000-000000000009> /System/Library/Frameworks/WebKit.framework/Versions/A/Frameworks/WebCore.framework/Versions/A/WebCore
       0x191000000 -        0x191ffffff  com.apple.QuartzCore (1.11) <0D3A6B1E-0000-0000-0000-00000000000a> /System/Library/Frameworks/QuartzCore.framework/Versions/A/QuartzCore
"""

# One main-queue callout with two OS handlers (30 + 20 samples), a Network handler with the app closure below it,
# and a callout blocked 50 samples in a nested wait.
SAMPLE_SPLIT = """\
Call graph:
    200 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
    + 200 __CFRunLoopRun  (in CoreFoundation) + 1  [0x1]
    +   100 __CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__  (in CoreFoundation) + 16  [0x2]
    +   ! 100 _dispatch_main_queue_drain  (in libdispatch.dylib) + 980  [0x3]
    +   !   50 _dispatch_client_callout  (in libdispatch.dylib) + 20  [0x4]
    +   !   : 30 -[NSDistributedNotificationCenter _deliver]  (in Foundation) + 30  [0x5]
    +   !   : 20 -[NSApplication _handleScreenChange:]  (in AppKit) + 30  [0x6]
    +   !   50 nw_path_monitor_deliver  (in Network) + 10  [0x7]
    +   !     50 closure #1 in NetworkWatch.start()  (in cmux DEV) + 4  [0x8]
    +   100 __CFRUNLOOP_IS_CALLING_OUT_TO_A_SOURCE0_PERFORM_FUNCTION__  (in CoreFoundation) + 28  [0x9]
    +     100 PresenceSource.perform()  (in cmux DEV) + 4  [0xa]
    +       50 __psynch_cvwait  (in libsystem_kernel.dylib) + 8  [0xb]

Total number in stack (recursive counted multiple times):

Binary Images:
       0x100a00000 -        0x100bfffff +com.cmuxterm.app (1) <0D3A6B1E-0000-0000-0000-000000000001> /Applications/cmux.app/Contents/MacOS/cmux DEV
       0x18c500000 -        0x18c9fffff  com.apple.Network (1) <0D3A6B1E-0000-0000-0000-000000000004> /System/Library/Frameworks/Network.framework/Versions/A/Network
       0x18d000000 -        0x18d9fffff  com.apple.Foundation (6.9) <0D3A6B1E-0000-0000-0000-000000000005> /System/Library/Frameworks/Foundation.framework/Versions/C/Foundation
       0x18e000000 -        0x18e9fffff  com.apple.AppKit (6.9) <0D3A6B1E-0000-0000-0000-000000000006> /System/Library/Frameworks/AppKit.framework/Versions/C/AppKit
"""

FIRE = "__NSFireTimer (0x18d0a1234 / 0x18d0a1234) (/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation)"


def timer(address, fire, interval=1.0, callout=FIRE, context="<CFRunLoopTimer context 0x600001>"):
    """One timer of a main run loop's CFCopyDescription, in its real layout."""
    return (f"<CFRunLoopTimer {address} [0x1f6c0e8d0]>{{valid = Yes, firing = No, interval = {interval}, "
            f"tolerance = 0.1, next fire date = {fire} (-0.5 @ 99), callout = {callout}, context = {context}}}\n")


class CalloutOwnerTests(unittest.TestCase):
    def test_main_thread_tree_is_the_main_thread(self):
        tree = ib.main_thread_tree(SAMPLE)
        self.assertIn("com.apple.main-thread", tree["symbol"])
        self.assertEqual(tree["count"], 1000)
        self.assertIsNone(ib.main_thread_tree("no call graph here"))

    def test_images_are_os_by_their_path(self):
        images = ib.binary_images(SAMPLE)
        self.assertEqual(images["cmux DEV"], "/Users/x/cmux DEV t.app/Contents/MacOS/cmux DEV")
        self.assertTrue(ib.is_system_image("WebCore", images))
        self.assertFalse(ib.is_system_image("Chromium Embedded Framework", images))
        self.assertFalse(ib.is_system_image("cmux DEV", images))
        self.assertTrue(ib.is_system_image("UserNotifications", {"UserNotifications": "/System/Library/Frameworks/UN"}))

    def test_callout_owners_name_the_first_owner_frame_below_each_callout(self):
        rows = {(r["kind"], r["callback"], r["owner"]): r["samples"] for r in ib.main_callouts_from_samples([SAMPLE])}
        fire = "__NSFireTimer (Foundation)"
        self.assertEqual(rows, {
            # A Swift thunk in the app binary is skipped: the closure below it names the owner.
            ("timer", fire, "closure #1 in StatusPoller.start() (cmux DEV)"): 40,
            # WebCore is an OS image by its path: its timer is an OS owner, keyed by itself as the callback.
            ("timer", "WebCore::ThreadTimers::sharedTimerFiredInternal() (WebCore)",
             "WebCore::ThreadTimers::sharedTimerFiredInternal() (WebCore)"): 20,
            ("source0", "base::MessagePumpCFRunLoopBase::RunWorkSource(void*) (Chromium Embedded Framework)",
             "base::MessagePumpCFRunLoopBase::RunWorkSource(void*) (Chromium Embedded Framework)"): 30,
            ("main-queue", None, "(1) await resume partial function for WorkspaceSync.flush() (cmux DEV)"): 5,
            ("main-queue", None, "-[NSDistributedNotificationCenter _deliver] (Foundation)"): 3,
            ("observer", "CA::Transaction::observer_callback(__CFRunLoopObserver*, unsigned long, void*) (QuartzCore)",
             "CA::Transaction::observer_callback(__CFRunLoopObserver*, unsigned long, void*) (QuartzCore)"): 2,
        })

    def test_two_os_handlers_under_one_callout_stay_two_owners_and_waits_take_nothing(self):
        rows = {(r["kind"], r["owner"]): r["samples"] for r in ib.main_callouts_from_samples([SAMPLE_SPLIT])}
        self.assertEqual(rows, {
            ("main-queue", "-[NSDistributedNotificationCenter _deliver] (Foundation)"): 30,
            ("main-queue", "-[NSApplication _handleScreenChange:] (AppKit)"): 20,
            # Network is an OS image by its path: the app closure below it is the owner.
            ("main-queue", "closure #1 in NetworkWatch.start() (cmux DEV)"): 50,
            # 50 of its 100 samples are blocked in a condition wait: not wake time.
            ("source0", "PresenceSource.perform() (cmux DEV)"): 50,
        })

    def test_samples_add_up_over_several_reports(self):
        rows = {(r["kind"], r["owner"]): r["samples"] for r in ib.main_callouts_from_samples([SAMPLE, SAMPLE, SAMPLE])}
        self.assertEqual(rows[("timer", "closure #1 in StatusPoller.start() (cmux DEV)")], 120)

    def test_threads_from_sample_skips_waits(self):
        threads = ib.threads_from_sample(SAMPLE)
        main = next(v for k, v in threads.items() if "main-thread" in k)
        frames = dict(main["frames"])
        self.assertNotIn("mach_msg (libsystem_kernel.dylib)", frames)
        self.assertEqual(frames["__CFRunLoopServiceMachPort (CoreFoundation)"], 900)
        self.assertEqual(threads["com.apple.NSEventThread (1000)"]["frames"], [])


class TimerFireTests(unittest.TestCase):
    def test_two_ns_timers_are_two_unnamed_rows(self):
        before = timer("0x6000a1", 100.0) + timer("0x6000b2", 50.0) + timer("0x6000c3", 70.0, interval=0)
        after = timer("0x6000a1", 160.0) + timer("0x6000b2", 110.0) + timer("0x6000c3", 75.0, interval=0)
        fires = ib.timer_fires(before, after, 60.0)
        self.assertEqual([(f["timer"], f["per_s"], f["named"]) for f in fires],
                         [("0x6000a1", 1.0, False), ("0x6000b2", 1.0, False)])
        self.assertTrue(fires[0]["owner"].startswith("unnamed NSTimer 0x6000a1 (context <CFRunLoopTimer context"))
        self.assertEqual(ib.timer_fires(before, before, 60.0), [])

    def test_a_named_callout_is_its_owner_and_a_timer_at_one_end_is_unpaired(self):
        before = timer("0x6000a1", 50.0, interval=0.5, callout="cmuxTick (0x1 / 0x2) (cmux DEV)")
        after = (timer("0x6000a1", 80.0, interval=0.5, callout="cmuxTick (0x1 / 0x2) (cmux DEV)")
                 + timer("0x6000d4", 90.0))
        rows = {f["timer"]: f for f in ib.timer_fires(before, after, 60.0)}
        self.assertEqual((rows["0x6000a1"]["owner"], rows["0x6000a1"]["per_s"]), ("cmuxTick (0x1 / 0x2) (cmux DEV)", 1.0))
        self.assertEqual((rows["0x6000d4"]["per_s"], rows["0x6000d4"]["unpaired"]), (None, "created in the window"))
        gone = ib.timer_fires(after, before, 60.0)
        self.assertEqual([f["unpaired"] for f in gone if f["timer"] == "0x6000d4"], ["gone at the end"])


STACK_TAIL = """\
              CoreFoundation`__CFRunLoopRun+0x7cc
              AppKit`-[NSApplication run]+0x1e0
              cmux DEV`main+0x24
              dyld`start+0xb18
"""

# A 30 s trace in dtrace's own output: two NSTimers on one callback (a cheap one at 10/s with few stack samples, a
# costly one at 1/s with many), a Chromium source0 that also runs on other wakes, two main-queue items, a drain that
# ran no item, a block under the floor, an observer and wakes no callout claimed. The FIRST rows add up to WAKES.
TRACE_OUT = f"""\
SPAN 30000000000
WAKES 3240
CALL 1 18d0a1234 6000a1 300
CALL 1 18d0a1234 6000b2 30
CALL 2 110000040 7000c0 1500
CALL 4 100a01000 0 600
CALL 4 100a02000 0 150
CALL 5 18d000001 0 2
CALL 6 191000010 6000f0 2400
FIRST 1 18d0a1234 6000a1 300
FIRST 1 18d0a1234 6000b2 30
FIRST 2 110000040 7000c0 1200
FIRST 4 100a01000 0 600
FIRST 4 100a02000 0 150
FIRST 4 0 0 30
FIRST 0 0 0 930
STACK 1 18d0a1234 6000a1 2
              cmux DEV`closure #1 in StatusPoller.start()+0x3c
              cmux DEV`thunk for @escaping @callee_guaranteed (@guaranteed NSTimer) -> ()+0x1c
              Foundation`__NSFireTimer+0x68
              CoreFoundation`__CFRUNLOOP_IS_CALLING_OUT_TO_A_TIMER_CALLBACK_FUNCTION__+0x20
              CoreFoundation`__CFRunLoopDoTimer+0x3e8
{STACK_TAIL}
END-STACK
STACK 1 18d0a1234 6000b2 500
              cmux DEV`HeartbeatTimer.fire()+0x10
              Foundation`__NSFireTimer+0x68
              CoreFoundation`__CFRUNLOOP_IS_CALLING_OUT_TO_A_TIMER_CALLBACK_FUNCTION__+0x20
{STACK_TAIL}
END-STACK
STACK 4 100a01000 0 7
              libsystem_kernel.dylib`__psynch_cvwait+0x8
              cmux DEV`closure #1 in WorkspaceSync.flush()+0x40
              libdispatch.dylib`_dispatch_call_block_and_release+0x20
              libdispatch.dylib`_dispatch_client_callout+0x14
              libdispatch.dylib`_dispatch_main_queue_drain+0x3d4
              CoreFoundation`__CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__+0x10
{STACK_TAIL}
END-STACK
"""

SYMBOLS = {0x18d0a1234: "__NSFireTimer (in Foundation) + 0",
           0x110000040: "base::MessagePumpCFRunLoopBase::RunWorkSource(void*) (in Chromium Embedded Framework) + 0",
           0x100a01000: "closure #1 in WorkspaceSync.flush() (in cmux DEV) + 0",
           0x100a02000: "(1) await resume partial function for Presence.poll() (in cmux DEV) + 0",
           0x18d000001: "__block_invoke (in Foundation) + 0",
           0x191000010: "CA::Transaction::observer_callback(__CFRunLoopObserver*, unsigned long, void*) (in QuartzCore) + 0"}
WORKSPACE_SYNC = "closure #1 in WorkspaceSync.flush() (cmux DEV)"
PRESENCE_POLL = "(1) await resume partial function for Presence.poll() (cmux DEV)"


def raw_trace():
    """count_main_callouts' result for TRACE_OUT (rpc bracket over 33 s, dtrace start and exit included)."""
    parsed = ib.parse_wake_trace(TRACE_OUT)
    return {"ok": True, "error": "", "seconds": 30.0, "main_wakes": parsed["wakes"],
            "main_wakes_per_s": round(parsed["wakes"] / 30.0, 3), "rpc_seconds": 33.0, "rpc_main_wakes_per_s": 97.0,
            "parsed": parsed}


def trace(symbols=SYMBOLS, sample=SAMPLE, raw=None):
    with mock.patch.object(ib, "symbolize", lambda _pid, _addresses: symbols), \
            mock.patch.object(ib, "demangle_stacks", lambda stacks: stacks):
        return ib.name_trace(raw or raw_trace(), 4242, sample)


class WakeTraceTests(unittest.TestCase):
    def test_script_measures_its_span_counts_wakes_and_keys_each_item(self):
        script = ib.wake_trace_script(1234, 30)
        self.assertIn("BEGIN { began = timestamp; }", script)
        self.assertIn('printf("SPAN %d\\n", timestamp - began)', script)
        self.assertIn("tick-30s { exit(0); }", script)
        self.assertNotRegex(script, r"tid == (?!1234\b)\d+")
        # A wake is the return from a wait that can block; the next such wait ends an unclaimed wake.
        self.assertIn("__CFRunLoopServiceMachPort:return /tid == 1234 && self->blk/ { @wakes = count(); self->wake = 1;",
                      script)
        self.assertIn("__CFRunLoopServiceMachPort:entry /tid == 1234 && arg4 != 0 && self->wake/", script)
        # Each non-observer callout claims a pending wake; observers never do.
        for function, kind in ib.RUN_LOOP_CALLOUTS.items():
            claims = [line for line in script.splitlines() if f"{function}:entry" in line and "@first[" in line]
            self.assertEqual(bool(claims), kind != "observer", function)
        # A timer by its CFRunLoopTimerRef, a source1 by its info, a block by its invoke pointer.
        self.assertIn("this->b = (uint64_t)(arg1) & 0x7fffffffffff; @calls[1, this->a, this->b]", script)
        self.assertIn("this->b = (uint64_t)(arg4) & 0x7fffffffffff; @calls[3, this->a, this->b]", script)
        self.assertIn("copyin(arg0 + 16, 8)", script)
        # Main-queue items: dispatch functions, blocks and Swift jobs (resume function 56 bytes in).
        self.assertIn("_dispatch_client_callout:entry", script)
        self.assertIn("_dispatch_call_block_and_release:entry", script)
        self.assertIn("swift_job_run:entry", script)
        self.assertIn("copyin(arg0 + 56, 8)", script)
        self.assertIn("profile-997 /pid == $target && tid == 1234 && self->ik/", script)

    def test_parse_reads_span_wakes_counts_and_stacks(self):
        parsed = ib.parse_wake_trace(TRACE_OUT + "garbage line\nCALL 9 1 1 5\n")
        self.assertEqual((parsed["span_ns"], parsed["wakes"]), (30_000_000_000, 3240))
        self.assertEqual(parsed["calls"][("timer", 0x18d0a1234, 0x6000a1)], 300)
        self.assertEqual(parsed["first"][("no-callout", 0, 0)], 930)
        self.assertEqual(sum(parsed["first"].values()), parsed["wakes"])
        frames, count = parsed["stacks"][("timer", 0x18d0a1234, 0x6000b2)][0]
        self.assertEqual((frames[0], count), ("cmux DEV`HeartbeatTimer.fire()+0x10", 500))
        self.assertEqual(len(parsed["calls"]), 7)  # kind 9 is not a kind

    def test_rates_come_from_the_trace_span_not_the_dtrace_run(self):
        app = types.SimpleNamespace(process=types.SimpleNamespace(pid=4242))
        reads = iter([{"main_wakes": 1000}, {"main_wakes": 4300}])
        app.rpc = lambda method, params=None, timeout=60: next(reads)
        clock = iter([100.0, 133.0])  # dtrace's start, attach and exit make the run 33 s
        output = TRACE_OUT.replace("SPAN 30000000000", "SPAN 25000000000")
        folder = tempfile.mkdtemp(prefix="idle-budget-trace-")
        self.addCleanup(shutil.rmtree, folder, True)
        with mock.patch.object(ib, "threads", lambda pid: {205: (0, ""), 101: (0, "")}), \
                mock.patch.object(ib.time, "monotonic", lambda: next(clock)), \
                mock.patch.object(ib.subprocess, "run", return_value=types.SimpleNamespace(
                    returncode=0, stdout=output, stderr="")) as run:
            result = ib.count_main_callouts(app, 30, folder)
        self.assertIn("-p", run.call_args.args[0])
        self.assertIn("tid == 101", Path(folder, "wake-trace.d").read_text())
        self.assertEqual((result["ok"], result["seconds"], result["main_wakes"]), (True, 25.0, 3240))
        self.assertEqual(result["main_wakes_per_s"], round(3240 / 25.0, 3))
        self.assertEqual((result["rpc_seconds"], result["rpc_main_wakes_per_s"]), (33.0, 100.0))
        named = trace(raw=result)
        self.assertNotIn("parsed", named)
        timer = next(r for r in named["callouts"] if r["item"] == "0x6000a1")
        self.assertEqual(timer["per_s"], 12.0)  # 300 over the 25 s traced, not over the 33 s run

    def test_a_trace_with_no_span_is_not_ok(self):
        app = types.SimpleNamespace(process=types.SimpleNamespace(pid=4242), rpc=lambda *a, **k: {})
        folder = tempfile.mkdtemp(prefix="idle-budget-trace-")
        self.addCleanup(shutil.rmtree, folder, True)
        with mock.patch.object(ib, "threads", lambda pid: {101: (0, "")}), \
                mock.patch.object(ib.subprocess, "run", return_value=types.SimpleNamespace(
                    returncode=0, stdout="CALL 1 1 1 3\n", stderr="")):
            result = ib.count_main_callouts(app, 30, folder)
        self.assertEqual((result["ok"], result["error"]), (False, "dtrace printed no SPAN line"))
        self.assertEqual(trace(raw=result)["callouts"], [])

    def test_each_wake_counts_once_and_items_are_their_own_rows(self):
        rows = trace()["callouts"]
        self.assertEqual(sum(r["wakes"] for r in rows), 3240)
        self.assertAlmostEqual(sum(r["per_s"] for r in rows), 108.0, places=2)
        source = next(r for r in rows if r["kind"] == "source0")
        # The source runs 50/s but claims only the 40/s wakes it ran first on.
        self.assertEqual((source["per_s"], source["calls_per_s"]), (40.0, 50.0))
        timers = {r["item"]: r for r in rows if r["kind"] == "timer"}
        self.assertEqual({item: r["per_s"] for item, r in timers.items()}, {"0x6000a1": 10.0, "0x6000b2": 1.0})
        queue = {r["callback"]: r["per_s"] for r in rows if r["kind"] == "main-queue"}
        self.assertEqual(queue, {WORKSPACE_SYNC: 20.0, PRESENCE_POLL: 5.0, None: 1.0})
        # Each item's stacks name only that item.
        self.assertEqual(timers["0x6000a1"]["stack_owners"],
                         [{"owner": "closure #1 in StatusPoller.start() (cmux DEV)", "share": 1.0}])
        self.assertEqual(timers["0x6000b2"]["stack_owners"], [{"owner": "HeartbeatTimer.fire() (cmux DEV)", "share": 1.0}])

    def test_the_image_range_decides_os_or_owner_when_atos_names_nothing(self):
        rows = {(r["kind"], r["item"], r["callback"]): r for r in trace(symbols={})["callouts"]}
        fire = rows[("timer", "0x6000a1", "0x18d0a1234 (in Foundation)")]
        self.assertEqual((fire["callback_named"], fire["callback_system"]), (False, True))
        flush = rows[("main-queue", None, "0x100a01000 (in cmux DEV)")]
        self.assertEqual((flush["callback_named"], flush["callback_system"]), (False, False))
        unknown = ib.trace_callouts(ib.parse_wake_trace(TRACE_OUT), 30.0, {})
        self.assertTrue(all(r["callback_system"] is None for r in unknown if r["callback"]))


class HiddenWakeSourceTests(unittest.TestCase):
    def result(self, **extra):
        return {"main_wakes_per_s": 107.0, "main_callouts": ib.main_callouts_from_samples([SAMPLE]),
                "wake_trace": trace(),
                "ledger": {"owners": [{"owner": "BusyWatchdog", "reason": "deadline", "per_s": 0.1},
                                      {"owner": "PresenceClient", "reason": "backoff", "per_s": 0.5}]},
                "main_run_loop_timer_fires": [{"timer": "0x6000a1", "owner": "unnamed NSTimer 0x6000a1 (context ?)",
                                               "named": False, "callout": FIRE, "context": "", "interval_s": 0.1,
                                               "per_s": 10.0}], **extra}

    def counted(self, report):
        return {(s["kind"], s["item"], s["callback"]): s for s in report["sources"] if s["basis"] == "callout-count"}

    def test_a_cheap_frequent_timer_and_a_costly_rare_one_keep_their_own_owner_and_rate(self):
        counted = self.counted(ib.hidden_wake_sources(self.result()))
        cheap = counted[("timer", "0x6000a1", "__NSFireTimer (Foundation)")]
        costly = counted[("timer", "0x6000b2", "__NSFireTimer (Foundation)")]
        self.assertEqual((cheap["owner"], cheap["owner_from"], cheap["per_s"]),
                         ("closure #1 in StatusPoller.start() (cmux DEV)", "item-stack", 10.0))
        self.assertEqual((costly["owner"], costly["owner_from"], costly["per_s"]),
                         ("HeartbeatTimer.fire() (cmux DEV)", "item-stack", 1.0))

    def test_two_main_queue_owners_are_two_rows_named_by_their_function(self):
        counted = self.counted(ib.hidden_wake_sources(self.result()))
        self.assertEqual((counted[("main-queue", None, WORKSPACE_SYNC)]["owner_from"],
                          counted[("main-queue", None, WORKSPACE_SYNC)]["per_s"]), ("callback", 20.0))
        self.assertEqual(counted[("main-queue", None, PRESENCE_POLL)]["per_s"], 5.0)
        drain = counted[("main-queue", None, None)]
        self.assertEqual((drain["owner"], drain["owner_from"]),
                         ("unnamed main-queue (main queue drain, no item ran)", "none"))

    def test_a_named_run_loop_timer_at_the_same_address_names_the_timer(self):
        named = {"timer": "0x6000b2", "owner": "cmuxHeartbeat (0x1 / 0x2) (cmux DEV)", "named": True,
                 "callout": "cmuxHeartbeat (0x1 / 0x2) (cmux DEV)", "context": "", "interval_s": 1.0, "per_s": 1.0}
        report = ib.hidden_wake_sources(self.result(main_run_loop_timer_fires=[named]))
        costly = self.counted(report)[("timer", "0x6000b2", "__NSFireTimer (Foundation)")]
        self.assertEqual((costly["owner"], costly["owner_from"]), ("cmuxHeartbeat (0x1 / 0x2) (cmux DEV)", "timer"))

    def test_each_basis_is_its_own_list_and_unattributed_is_the_unclaimed_wakes(self):
        report = ib.hidden_wake_sources(self.result())
        self.assertEqual(report["sources_by_basis"], {"callout-count": 6, "unattributed": 1, "run-loop-timer": 1, "ledger": 1})
        unattributed = next(s for s in report["sources"] if s["basis"] == "unattributed")
        self.assertEqual((unattributed["per_s"], unattributed["of"]), (31.0, "trace wakes no callout claimed"))
        self.assertEqual((report["trace_main_wakes_per_s"], report["trace"]["rpc_main_wakes_per_s"]), (108.0, 97.0))
        ledger = next(s for s in report["sources"] if s["basis"] == "ledger")
        self.assertEqual((ledger["owner"], ledger["thread"]), ("PresenceClient:backoff", "any"))
        self.assertEqual(len(report["observers"]), 2)  # one counted, one sampled
        self.assertEqual((report["naming_problems"], report["unnamed"]), ([], 1))

    def test_unnamed_callbacks_are_a_problem_and_never_an_owner(self):
        report = ib.hidden_wake_sources(self.result(wake_trace=trace(symbols={})))
        counted = self.counted(report)
        poll = counted[("main-queue", None, "0x100a02000 (in cmux DEV)")]
        self.assertEqual((poll["owner"], poll["owner_from"]), ("unnamed main-queue (0x100a02000 (in cmux DEV))", "none"))
        flush = counted[("main-queue", None, "0x100a01000 (in cmux DEV)")]
        self.assertEqual((flush["owner"], flush["owner_from"]), (WORKSPACE_SYNC, "item-stack"))
        cheap = counted[("timer", "0x6000a1", "0x18d0a1234 (in Foundation)")]
        self.assertEqual(cheap["owner_from"], "item-stack")
        self.assertEqual(report["naming_problems"], ["atos failed: 5 callbacks unnamed"])
        lines = ib.hidden_wake_lines("minimized", report, "a" * 40, "cmux20", report["naming_problems"])
        self.assertFalse(any(line.startswith("HIDDEN-WAKE ") for line in lines))

    def test_sample_time_frames_have_no_rate_and_no_floor(self):
        report = ib.hidden_wake_sources(self.result())
        self.assertEqual(len(report["frames"]), 5)
        self.assertTrue(all(f["per_s"] is None for f in report["frames"]))
        self.assertEqual(report["cause_samples"], 98)  # observers are not causes
        self.assertFalse(any(s.get("basis") == "sample-time" for s in report["sources"]))

    def test_without_a_trace_the_window_wakes_less_timer_fires_are_unattributed(self):
        report = ib.hidden_wake_sources(self.result(wake_trace={"ok": False, "error": "sudo: a password is required",
                                                                "callouts": []}))
        self.assertEqual(report["trace"]["ok"], False)
        unattributed = next(s for s in report["sources"] if s["basis"] == "unattributed")
        self.assertEqual((unattributed["per_s"], unattributed["of"]), (97.0, "window main wakes less run-loop timer fires"))
        self.assertNotIn("callout-count", report["sources_by_basis"])

    def test_lines_carry_sha_and_host_and_are_unconfirmed_on_a_problem(self):
        report = ib.hidden_wake_sources(self.result())
        report["samples_taken"] = 3
        lines = ib.hidden_wake_lines("minimized", report, "a" * 40, "cmux20")
        wakes = [json.loads(line.split(" ", 1)[1]) for line in lines if line.startswith("HIDDEN-WAKE ")]
        self.assertEqual(len(wakes), 9)
        self.assertTrue(all({"session", "owner", "per_s", "top", "kind", "basis"} <= set(w) for w in wakes))
        total = json.loads(lines[-1].split(" ", 1)[1])
        self.assertEqual((total["sha"], total["host"], total["samples_taken"], total["confirmed"]), ("a" * 40, "cmux20", 3, True))
        self.assertEqual(total["trace"]["seconds"], 30.0)
        self.assertEqual(sum(1 for line in lines if line.startswith("HIDDEN-WAKE-FRAME ")), 5)
        unconfirmed = ib.hidden_wake_lines("minimized", report, "a" * 40, "cmux20", ["Sentry did not start"])
        self.assertFalse(any(line.startswith("HIDDEN-WAKE ") for line in unconfirmed))
        self.assertEqual(sum(1 for line in unconfirmed if line.startswith("HIDDEN-WAKE-UNCONFIRMED ")), 9)
        self.assertEqual(json.loads(unconfirmed[-1].split(" ", 1)[1])["problems"], ["Sentry did not start"])


class SessionStateTests(unittest.TestCase):
    def test_hidden_and_minimized_states(self):
        hidden, minimized = ib.SESSIONS["light-hidden"], ib.SESSIONS["minimized"]
        shown = {"main": [{"visible": True, "miniaturized": False}]}
        self.assertIn("not hidden", ib.hidden_state_problem(hidden, shown))
        self.assertIsNone(ib.hidden_state_problem(hidden, {"main": [{"visible": False, "miniaturized": False}]}))
        self.assertIn("not miniaturized", ib.hidden_state_problem(minimized, shown))
        self.assertIsNone(ib.hidden_state_problem(minimized, {"main": [{"visible": False, "miniaturized": True}]}))
        self.assertIn("no main window", ib.hidden_state_problem(hidden, {"main": []}))
        self.assertIn("failed", ib.hidden_state_problem(hidden, {"error": "unreachable"}))

    def test_shipping_problems_read_the_applied_fields(self):
        good = {"activated": {"activated": True, "error": ""}, "sentry_started": True,
                "draws_when_occluded": {"windows": False, "pages": False, "predicted": False},
                "hang_reports": {"available": True, "setting": True, "decision": "on", "enabled": True, "on": True}}
        self.assertEqual(ib.shipping_problems(good), [])
        self.assertEqual(len(ib.shipping_problems({})), 4)
        self.assertEqual(ib.shipping_problems({**good, "draws_when_occluded": {"windows": True, "pages": True,
                                                                                "predicted": True}}),
                         ["draws when occluded (the automation draw, not the shipping one)"])
        self.assertEqual(len(ib.shipping_problems({**good, "draws_when_occluded": {"windows": None}})), 1)

    def test_an_action_error_raises(self):
        with self.assertRaises(ib.HiddenStateError):
            ib.check_action_reply("minimizeWindow", {"error": "no active window"})
        ib.check_action_reply("minimizeWindow", {})


class FakeApp:
    """BenchApp's surface main() uses, with a window that the session's action hides or minimizes (or not)."""
    instances = []

    def __init__(self, app, out=None, env=None, config=None, **_kw):
        self.app, self.out, self.env, self.config = app, out, env, config
        self.process = types.SimpleNamespace(pid=4242, poll=lambda: None)
        self.launched_env = None
        self.calls = []
        self.window = {"visible": True, "miniaturized": False}
        self.obey = True
        FakeApp.instances.append(self)

    def launch(self):
        self.launched_env = {k: v for k, v in (self.env or {}).items() if v is not None}

    def activate(self):
        return {"activated": True, "error": ""}

    def rpc(self, method, params=None, timeout=60):
        self.calls.append((method, params))
        if method == "action.run":
            if self.obey and params["action"] == "showHideAllWindows":
                self.window = {"visible": False, "miniaturized": False}
            if self.obey and params["action"] == "minimizeWindow":
                self.window = {"visible": False, "miniaturized": True}
            return {}
        if method == "debug.window_list":
            return {"windows": [{"kind": "main", "key": False, "occluded": True, **self.window}]}
        if method == "debug.hangs":
            return {"installed": True, "main_wakes": 0}
        if method == "debug.shipping_mode":  # a shipping app: hang reports send, no occluded draw
            return {"hang_reports": {"available": True, "setting": True, "decision": "on", "enabled": True},
                    "draws_when_occluded": False, "pages_render_when_covered": False}
        return {}

    def stop(self):
        pass


class MainHiddenWakeTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="idle-budget-hidden-")
        self.addCleanup(shutil.rmtree, self.folder, True)
        FakeApp.instances = []
        self.app = os.path.join(self.folder, "cmux DEV t.app")
        os.makedirs(os.path.join(self.app, "Contents", "MacOS"))
        open(os.path.join(self.app, "Contents", "MacOS", "cmux DEV"), "wb").close()

    def stamp(self, sha):
        with open(os.path.join(self.app, "Contents", "Info.plist"), "wb") as handle:
            plistlib.dump({"CMUXCommit": sha} if sha else {}, handle)

    def run_main(self, sessions, obey=True, shown_by_trace=False):
        import bench_launch
        order = self.order = []

        def counted(app, seconds, folder):
            order.append("trace")
            if shown_by_trace:
                FakeApp.instances[-1].window = {"visible": True, "miniaturized": False}
            return raw_trace()

        def sampled(pid, seconds, path):
            order.append("sample")
            return SAMPLE

        def fake(*args, **kwargs):
            app = FakeApp(*args, **kwargs)
            app.obey = obey
            return app

        measured = {"seconds": 60.0, "processes": [], "main_wakes_per_s": 107.0,
                    "ledger": {"owners": [{"owner": "PresenceClient", "reason": "backoff", "per_s": 0.5}]},
                    "main_run_loop_timer_fires": [], "windowserver": ib.windowserver_report(12.0, None, "rusage")}
        out = io.StringIO()
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(bench_launch, "BenchApp", fake))
            stack.enter_context(mock.patch.dict(os.environ, {"CMUX_CI_SHA": ""}))
            stack.enter_context(mock.patch.object(ib, "fresh_session", lambda app: {}))
            stack.enter_context(mock.patch.object(ib, "host_facts", lambda: {"host": "cmux20", "macos": "26.1"}))
            stack.enter_context(mock.patch.object(ib, "threads", lambda pid: {7: (0, "SentryCrash Exception Handler (Primary)")}))
            stack.enter_context(mock.patch.object(ib.procs, "Instance", lambda *a: None, create=True))
            self.measure = stack.enter_context(mock.patch.object(ib, "measure", return_value=measured))
            self.sample = stack.enter_context(mock.patch.object(ib, "run_sample", side_effect=sampled))
            self.count = stack.enter_context(mock.patch.object(ib, "count_main_callouts", side_effect=counted))
            stack.enter_context(mock.patch.object(ib, "symbolize", lambda _pid, _addresses: SYMBOLS))
            stack.enter_context(mock.patch.object(ib, "demangle_stacks", lambda stacks: stacks))
            clock = itertools.count(step=1.0)  # minimize()'s bounded wait ends without real time passing
            stack.enter_context(mock.patch.object(ib.time, "sleep", lambda _s: None))
            stack.enter_context(mock.patch.object(ib.time, "monotonic", lambda: next(clock)))
            stack.enter_context(contextlib.redirect_stdout(out))
            with self.assertRaises(SystemExit) as raised:
                ib.main(["--app", self.app, "--out", os.path.join(self.folder, "out"), "--sessions", sessions,
                         "--settle", "0", "--measure", "0"])
        self.assertEqual(raised.exception.code, 0)
        report = json.loads(Path(self.folder, "out", "idle-budget.json").read_text())
        return out.getvalue().splitlines(), report

    def test_minimized_launches_in_shipping_mode_minimizes_and_prints_the_report(self):
        self.stamp("b" * 40)
        lines, report = self.run_main("minimized")
        app = FakeApp.instances[0]
        for key in ("CMUX_NEXT_BENCH_SHIPPING_DRAW", "CMUX_NEXT_DEV_SENTRY", "CMUX_NEXT_DEV_HANG_REPORTS"):
            self.assertEqual(app.env[key], "1")
        self.assertIn(("action.run", {"action": "minimizeWindow", "args": {}, "focus": False, "origin": "script"}),
                      app.calls)
        self.assertIsNone(self.measure.call_args.kwargs["ledger_limit"])  # every ledger owner in a hidden session
        self.assertEqual(self.order, ["trace", "sample", "sample", "sample"])  # the trace before sample's suspensions
        wakes = [json.loads(line.split(" ", 1)[1]) for line in lines if line.startswith("HIDDEN-WAKE ")]
        self.assertTrue(any(w["owner"] == "closure #1 in StatusPoller.start() (cmux DEV)" for w in wakes))
        total = json.loads(next(line for line in lines if line.startswith("HIDDEN-WAKE-TOTAL ")).split(" ", 1)[1])
        self.assertEqual((total["sha"], total["host"], total["samples_taken"], total["confirmed"]),
                         ("b" * 40, "cmux20", 3, True))
        block = report["sessions"]["minimized"]["hidden_wake"]
        self.assertEqual((block["sha"], block["host"], block["problems"]), ("b" * 40, "cmux20", []))
        self.assertEqual(report["session_exits"], {"minimized": 0})

    def test_light_hidden_hides_the_app(self):
        self.stamp("c" * 40)
        lines, report = self.run_main("light-hidden")
        self.assertIn(("action.run", {"action": "showHideAllWindows", "args": {"hidden": True}, "focus": False,
                                      "origin": "script"}), FakeApp.instances[0].calls)
        self.assertEqual(report["session_exits"], {"light-hidden": 0})
        self.assertTrue(any(line.startswith("HIDDEN-WAKE-TOTAL ") for line in lines))

    def test_a_window_still_visible_fails_the_session_with_no_hidden_wake_line(self):
        self.stamp("c" * 40)
        lines, report = self.run_main("light-hidden,minimized", obey=False)
        self.assertEqual(report["session_exits"], {"light-hidden": 1, "minimized": 1})
        failed = [line for line in lines if line.startswith("IDLE-BUDGET-SESSION-FAILED")]
        self.assertIn("not hidden", failed[0])
        self.assertIn("not minimized", failed[1])
        self.assertFalse(any(line.startswith("HIDDEN-WAKE") for line in lines))
        self.measure.assert_not_called()

    def test_a_window_shown_during_the_trace_fails_the_session(self):
        self.stamp("c" * 40)
        lines, report = self.run_main("light-hidden", shown_by_trace=True)
        self.assertEqual(report["session_exits"], {"light-hidden": 1})
        failed = next(line for line in lines if line.startswith("IDLE-BUDGET-SESSION-FAILED"))
        self.assertIn("after the wake trace: a main window is visible", failed)
        self.assertFalse(any(line.startswith("HIDDEN-WAKE") for line in lines))
        self.assertEqual(self.order, ["trace"])

    def test_no_build_sha_fails_the_session_before_the_launch(self):
        self.stamp(None)
        lines, report = self.run_main("minimized")
        self.assertEqual(report["session_exits"], {"minimized": 1})
        self.assertIn("RecordError", report["sessions"]["minimized"]["error"])
        self.assertIsNone(FakeApp.instances[0].launched_env)
        self.assertFalse(any(line.startswith("HIDDEN-WAKE") for line in lines))


if __name__ == "__main__":
    unittest.main()
