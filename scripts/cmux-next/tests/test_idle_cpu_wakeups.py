#!/usr/bin/env python3
"""idle_cpu.py's wakeup sources of the app at idle (--wake-trace): the app's own ledger (debug.wakeups) per owner
and reason over the measured windows, the main run loop's repeating timers, and each thread's wakeups from a
short capped System Trace (thread_wakes.record).
Run: python3 -I scripts/cmux-next/tests/test_idle_cpu_wakeups.py (not a CI job)."""
import ctypes, os, sys, unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
if sys.platform == "darwin":
    import idle_cpu  # noqa: E402
else:
    with mock.patch.object(ctypes, "CDLL", mock.MagicMock()):
        import idle_cpu  # noqa: E402

RUN_LOOP = ("<CFRunLoopTimer 0x1>{valid = Yes, firing = No, interval = 1, tolerance = 0, next fire date = 5.0, "
            "callout = PresenceTick (0x2)}\n"
            "<CFRunLoopTimer 0x3>{valid = Yes, firing = No, interval = 0, tolerance = 0, next fire date = 9.0, "
            "callout = OneShot (0x4)}\n"
            "<CFRunLoopTimer 0x5>{valid = No, firing = No, interval = 0.5, tolerance = 0, next fire date = 1.0, "
            "callout = Dead (0x6)}\n")


class WakeupKinds(unittest.TestCase):
    def test_a_window_splits_package_idle_and_interrupt_wakeups(self):
        # host_load=8 runs read about half the idle runs' wakeups/s (0.85 against 1.5 per acpmux daemon) with the same
        # context switches/s (0.9): the wakeups counter is package-idle plus interrupt wakeups, and a busy Mac's
        # package is never idle. Each window keeps both, so a busy run is judged by a counter the load does not hide.
        usage = lambda cpu, pkg, intr: (0, 0, 0, cpu, pkg + intr, pkg)
        spans = [((0.0, {7: (usage(0, 10, 5), 100)}), (10.0, {7: (usage(10**7, 13, 15), 109)}))]
        row = idle_cpu.rows_of({7: ("acpmux-daemon", "acpmux")}, spans)[0]
        self.assertEqual(row["windows"][0]["wakeups_per_s"], 1.3)
        self.assertEqual(row["windows"][0]["idle_wakeups_per_s"], 0.3)
        self.assertEqual(row["windows"][0]["interrupt_wakeups_per_s"], 1.0)
        self.assertEqual((row["idle_wakeups_per_s"], row["interrupt_wakeups_per_s"], row["switches_per_s"]),
                         (0.3, 1.0, 0.9))


class WakeReport(unittest.TestCase):
    def test_ledger_rates_over_the_windows_busiest_first(self):
        before = {"uptime_s": 100.0, "ledger": [{"owner": "dock", "reason": "badge", "count": 10},
                                                {"owner": "sidebar", "reason": "clock", "count": 5}]}
        after = {"uptime_s": 160.0, "ledger": [{"owner": "dock", "reason": "badge", "count": 13},
                                               {"owner": "sidebar", "reason": "clock", "count": 125},
                                               {"owner": "new", "reason": "x", "count": 6}],
                 "main_run_loop": RUN_LOOP}
        got = idle_cpu.wake_report(before, after)
        self.assertEqual([(e["owner"], e["reason"]) for e in got["ledger"]],
                         [("sidebar", "clock"), ("new", "x"), ("dock", "badge")])
        self.assertEqual(got["ledger"][0]["per_s"], 2.0)
        self.assertEqual(got["ledger"][1]["per_s"], 0.1)   # born in the window: counts from 0
        self.assertEqual(got["ledger_per_s"], 2.15)
        # Only valid repeating timers: a one-shot or a dead timer wakes nothing again.
        self.assertEqual(got["timers"], [{"callout": "PresenceTick (0x2)", "interval_s": 1.0, "per_s": 1.0}])

    def test_an_error_answer_is_kept_not_raised(self):
        got = idle_cpu.wake_report({"error": "no debug.wakeups"}, {"error": "no debug.wakeups"})
        self.assertEqual(got["error"], "no debug.wakeups")

    def test_threads_by_wakeups_with_their_names(self):
        traced = {"seconds": 10, "threads": {7: {"name": "CrBrowserMain", "wakes": 30, "running_ns": 5_000_000},
                                             8: {"name": "", "wakes": 2, "running_ns": 1000}}}
        rows = idle_cpu.thread_wake_rows(traced)
        self.assertEqual(rows[0], {"tid": 7, "name": "CrBrowserMain", "wakes_per_s": 3.0, "cpu_ms_per_s": 0.5})
        self.assertEqual(rows[1]["name"], "?")

    def test_an_unnamed_thread_is_named_by_its_sampled_stack(self):
        # "cmux DEV" threads with no pthread name woke 4.5 times/s in all (ca941dd8): the sample says what they wait on.
        traced = {"seconds": 10, "threads": {8: {"name": "", "wakes": 12, "running_ns": 1000},
                                             9: {"name": "cmux DEV", "wakes": 3, "running_ns": 1000}}}
        sampled = {8: {"header": "", "frames": ["kevent_id (libsystem_kernel.dylib)", "DaemonConnection.read() (cmux DEV)"]},
                   9: {"header": "DispatchQueue_42: com.cmux.health  (serial)", "frames": ["x (y)"]}}
        rows = idle_cpu.thread_wake_rows(traced, sampled, process_name="cmux DEV")
        self.assertEqual(rows[0]["name"], "~kevent_id > DaemonConnection.read()")
        self.assertEqual(rows[0]["frames"], sampled[8]["frames"])
        self.assertEqual(rows[1]["name"], "DispatchQueue_42: com.cmux.health  (serial)")

    def test_the_option_is_bounded(self):
        args = idle_cpu.parse_args(["--app", "/x.app", "--wake-trace", "10"])
        self.assertEqual(args.wake_trace, 10)
        for bad in ("-1", "16"):
            with self.assertRaises(SystemExit), mock.patch("sys.stderr"):
                idle_cpu.check_args(idle_cpu.parse_args(["--app", "/x.app", "--wake-trace", bad]))


if __name__ == "__main__":
    unittest.main()
