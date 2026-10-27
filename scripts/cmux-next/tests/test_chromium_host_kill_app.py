#!/usr/bin/env python3
"""chromium_host_kill_app.py, the --kill-app rows of chromium-host-bench.py (p01-process-150), against a fake app: a
host that outlives cmux, refuses the bench's unsigned offer, is adopted by the relaunch with the page's timeOrigin
kept and ends 30 s after a second kill passes; a host that dies with cmux, a relaunch that starts a new host, a page
that reloads, a host that accepts an unsigned peer or one that never ends fails its row; a build without the host
backend does not run. The bench's offer frame is the golden offer of host_adoption_test.cpp. Runs anywhere (no app).
Run: python3 -I scripts/cmux-next/tests/test_chromium_host_kill_app.py"""
import os, sys, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import chromium_host_kill_app as kill_app  # noqa: E402

# host_adoption_test.cpp's kGoldenOffer (ChromiumHostAdoptionTests.goldenOffer).
GOLDEN_OFFER = ("4c0000002080000000000000050002007731050002006131010004001e0000000200080001000000000000000200080002000000"
                "000000000200080003000000000000000200080004000000000000000100040092100000")


class FakeBench:
    """One app and its host on a fake clock. `survives`: the host outlives a kill of cmux; `adopts`: the relaunch
    adopts it (else it starts a new host); `reloads`: the page after the relaunch has a new timeOrigin; `answers_unsigned`:
    the host replies to the bench's offer; `grace`: seconds an orphan lives (None: forever)."""

    def __init__(self, backend="host", survives=True, adopts=True, reloads=False, answers_unsigned=False, grace=30.0):
        self.backend, self.survives, self.adopts, self.reloads = backend, survives, adopts, reloads
        self.answers_unsigned, self.grace = answers_unsigned, grace
        self.now, self.app_running, self.host, self.orphaned_at = 0.0, True, 500, None
        self.adopted, self.started, self.origin = 0, 1, 1000.5
        self.events = []

    def rpc(self, method, params=None):
        if method != "debug.cef" or not self.app_running:
            return None
        supervisor = {"pid": self.host, "hosts_adopted": self.adopted, "hosts_started": self.started - 1 if self.adopted else self.started}
        return {"backend": self.backend, "host_supervisor": supervisor}

    def open_page(self, url):
        return "tab-1"

    def find_tab(self, url):
        return "tab-2"

    def page_eval(self, script, tab):
        return self.origin if script == kill_app.TIME_ORIGIN else None

    def kill_app(self):
        self.events.append("kill")
        self.app_running = False
        if self.survives and self.host:
            self.orphaned_at = self.now
        else:
            self.host = None

    def relaunch(self):
        self.events.append("relaunch")
        self.app_running = True
        if self.adopts and self.pid_alive(self.host or 0):
            self.adopted, self.orphaned_at = 1, None
            if self.reloads:
                self.origin += 1
        else:
            self.host, self.started, self.adopted, self.origin = 600, 1, 0, self.origin + 5

    def pid_alive(self, pid):
        if pid != self.host or not pid:
            return False
        if self.orphaned_at is not None and self.grace is not None and self.now - self.orphaned_at >= self.grace + 0.5:
            self.host = None
            return False
        return True

    def socket_exists(self):
        return self.orphaned_at is not None

    def offer_refused(self):
        return not self.answers_unsigned

    def sleep(self, seconds):
        self.now += seconds

    def monotonic(self):
        return self.now


class KillAppRowsTests(unittest.TestCase):
    def test_a_host_that_survives_and_is_adopted_passes(self):
        bench = FakeBench()
        row, ran = kill_app.run(bench, "file:///probe.html")
        self.assertTrue(ran)
        self.assertTrue(row["pass"], row)
        self.assertEqual(row["time_origin"]["before"], row["time_origin"]["after"])
        self.assertTrue(29 <= row["expires"]["seconds"] <= 47, row["expires"])
        self.assertEqual(bench.events, ["kill", "relaunch", "kill"])

    def test_a_host_that_dies_with_cmux_fails(self):
        row, _ = kill_app.run(FakeBench(survives=False), "file:///probe.html")
        self.assertFalse(row["survives"]["pass"])
        self.assertIn("not_run", row["refused"])
        self.assertFalse(row["pass"])

    def test_a_relaunch_that_starts_a_new_host_fails(self):
        row, _ = kill_app.run(FakeBench(adopts=False), "file:///probe.html")
        self.assertFalse(row["adopted"]["pass"])
        self.assertFalse(row["time_origin"]["pass"])
        self.assertFalse(row["pass"])

    def test_a_reloaded_page_fails_the_time_origin_row(self):
        row, _ = kill_app.run(FakeBench(reloads=True), "file:///probe.html")
        self.assertTrue(row["adopted"]["pass"])
        self.assertFalse(row["time_origin"]["pass"])
        self.assertFalse(row["pass"])

    def test_a_host_that_answers_an_unsigned_peer_fails(self):
        row, _ = kill_app.run(FakeBench(answers_unsigned=True), "file:///probe.html")
        self.assertFalse(row["refused"]["pass"])
        self.assertFalse(row["pass"])

    def test_an_orphan_that_never_ends_fails(self):
        row, _ = kill_app.run(FakeBench(grace=None), "file:///probe.html")
        self.assertFalse(row["expires"]["ended"])
        self.assertFalse(row["pass"])

    def test_no_host_backend_does_not_run(self):
        row, ran = kill_app.run(FakeBench(backend="inProcess"), "file:///probe.html")
        self.assertFalse(ran)
        self.assertIn("not_run", row)

    def test_the_offer_frame_is_the_golden_offer(self):
        frame = kill_app.offer_frame(4242, wire=b"w1", abi=b"a1", min_fork_api=30, framework=(1, 2, 3, 4))
        self.assertEqual(frame.hex(), GOLDEN_OFFER)


if __name__ == "__main__":
    unittest.main()
