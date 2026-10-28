#!/usr/bin/env python3
"""chromium_host_hang.py, the --hang row of chromium-host-bench.py (p01-process-084), against a fake app on a fake
clock: a banner at 2000 to 2050 ms that goes once the host runs passes; a late banner, a deadline armed with no
input waiting, a banner that stays after the host resumes, and no banner at all fail; an in-process backend, the
feature off and a host that does not ack its dispatch are not run; the host is always resumed. Runs anywhere.
Run: python3 -I scripts/cmux-next/tests/test_chromium_host_hang.py"""
import os, sys, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import chromium_host_hang as hang  # noqa: E402


class FakeApp:
    """cmux and its host on a fake clock. `late_ms`: the deadline's lateness past 2 s; `idle_armed`: a deadline
    armed with no input waiting; `stays`: the banner stays after the resume; `route`: keys reach the host's ring."""

    def __init__(self, backend="host", feature=True, watching=True, late_ms=20, idle_armed=False, stays=False, route=True):
        self.backend, self.feature, self.watching = backend, feature, watching
        self.late_ms, self.idle_armed, self.stays, self.route = late_ms, idle_armed, stays, route
        self.now = 0.0
        self.stopped = False
        self.key_at = None
        self.busy_count = 0
        self.last_busy_after = -1
        self.signals = []

    def clock(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds

    def wait(self, check, seconds, step=0.1):
        deadline = self.now + seconds
        while self.now < deadline:
            value = check()
            if value:
                return value
            self.sleep(step)
        return None

    def state(self):
        busy = False
        if self.key_at is not None:
            due = self.key_at + (hang.BUSY_AFTER_MS + self.late_ms) / 1000
            if self.stopped and self.now >= due:
                if self.busy_count == 0:
                    self.busy_count, self.last_busy_after = 1, hang.BUSY_AFTER_MS + self.late_ms
                busy = True
            elif not self.stopped:
                busy = self.stays and self.busy_count > 0
        armed = (self.key_at is not None and self.stopped and not busy) or (self.idle_armed and self.key_at is None)
        return {"watching": 1 if self.watching else 0, "busy": 1 if busy else 0, "armed": 1 if armed else 0,
                "busy_count": self.busy_count, "last_busy_after_ms": self.last_busy_after, "host_hangs": 0}

    def rpc(self, method, params=None, timeout=None):
        if method == "debug.cef":
            report = {"backend": self.backend}
            if self.backend == "host" and self.feature:
                report["host_hang"] = self.state()
            return report
        if method == "action.run":
            return {"ok": True}
        if method == "debug.key":
            if self.route:
                self.key_at = self.now
            return {"ok": True}
        raise AssertionError(method)

    def run(self, hold_ms=5000):
        return hang.run(self.rpc, self.wait, lambda script: True, "file:///hang.html", lambda: 4242,
                        lambda pid: self.signal("STOP", pid), lambda pid: self.signal("CONT", pid), hold_ms,
                        sleep=self.sleep, clock=self.clock)

    def signal(self, name, pid):
        assert pid == 4242
        self.signals.append(name)
        self.stopped = name == "STOP"
        if not self.stopped:
            self.key_at = None if not self.stays else self.key_at


class HangRowTests(unittest.TestCase):
    def test_a_banner_at_two_seconds_that_goes_passes(self):
        app = FakeApp()
        row, ok = app.run()
        self.assertTrue(ok, row)
        self.assertEqual(row["busy_after_ms"], 2020)
        self.assertEqual(row["idle_armed"], 0)
        self.assertTrue(row["gone"])
        self.assertEqual(app.signals, ["STOP", "CONT"])
        self.assertGreaterEqual(app.now, 5.0, "the host stays stopped for the whole hold")

    def test_a_late_banner_fails(self):
        row, ok = FakeApp(late_ms=150).run()
        self.assertFalse(ok)
        self.assertEqual(row["busy_after_ms"], 2150)

    def test_a_deadline_with_no_input_waiting_fails(self):
        row, ok = FakeApp(idle_armed=True).run()
        self.assertFalse(ok)
        self.assertEqual(row["idle_armed"], 1)

    def test_a_banner_that_stays_after_the_host_runs_fails(self):
        row, ok = FakeApp(stays=True).run()
        self.assertFalse(ok)
        self.assertFalse(row["gone"])

    def test_no_banner_fails_and_the_host_is_resumed(self):
        app = FakeApp(route=False)
        row, ok = app.run()
        self.assertFalse(ok)
        self.assertIn("error", row)
        self.assertEqual(app.signals, ["STOP", "CONT"])

    def test_not_run_without_the_host_the_feature_or_its_acks(self):
        for app, reason in ((FakeApp(backend="inProcess"), "not the Chromium Host"),
                            (FakeApp(feature=False), hang.FEATURES), (FakeApp(watching=False), "cmux_host_hang_watch")):
            row, ok = app.run()
            self.assertFalse(ok)
            self.assertIn(reason, row["not_run"])
            self.assertEqual(app.signals, [], "the host is never stopped")

    def test_the_verdict_takes_the_tolerance_both_ways(self):
        base = {"idle_armed": 0, "gone": True}
        self.assertTrue(hang.verdict({**base, "busy_after_ms": 1900}))
        self.assertTrue(hang.verdict({**base, "busy_after_ms": 2100}))
        self.assertFalse(hang.verdict({**base, "busy_after_ms": 2101}))
        self.assertFalse(hang.verdict({**base, "busy_after_ms": -1}))


if __name__ == "__main__":
    unittest.main()
