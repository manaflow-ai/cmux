#!/usr/bin/env python3
"""chromium_host_kill_app.py, the --kill-app rows of chromium-host-bench.py (p01-process-150), against a fake app: a
host that outlives cmux, refuses the bench's unsigned offer, is adopted by the relaunch with the page's timeOrigin
kept, ends when a relaunch of another version offers (a new host starts and the tab reloads at its URL) and ends 30 s
after a last kill passes; a host that dies with cmux, a relaunch that starts a new host, a page that reloads, a host
that accepts an unsigned peer, a mismatched host that keeps running or a tab not back at its URL, or one that never
ends fails its row; a build without the host backend does not run. The bench's offer frame is the golden offer of host_adoption_test.cpp. Runs anywhere (no app).
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

    HREF = "file:///probe.html?probe=kill-app"

    def __init__(self, backend="host", survives=True, adopts=True, reloads=False, answers_unsigned=False, grace=30.0,
                 mismatch_ends=True, mismatch_reloads=True, mismatch_href=HREF):
        self.backend, self.survives, self.adopts, self.reloads = backend, survives, adopts, reloads
        self.answers_unsigned, self.grace = answers_unsigned, grace
        self.mismatch_ends, self.mismatch_reloads, self.mismatch_href = mismatch_ends, mismatch_reloads, mismatch_href
        self.now, self.app_running, self.host, self.orphaned_at = 0.0, True, 500, None
        self.adopted, self.started, self.origin, self.href = 0, 1, 1000.5, self.HREF
        self.adoption, self.lingering = None, None
        self.events = []

    def rpc(self, method, params=None):
        if method != "debug.cef" or not self.app_running:
            return None
        supervisor = {"pid": self.host, "hosts_adopted": self.adopted,
                      "hosts_started": self.started - 1 if self.adopted else self.started, "adoption": self.adoption}
        return {"backend": self.backend, "host_supervisor": supervisor}

    def open_page(self, url):
        return "tab-1"

    def find_tab(self, url):
        return "tab-2"

    def page_eval(self, script, tab):
        return {kill_app.TIME_ORIGIN: self.origin, kill_app.HREF: self.href}.get(script)

    def kill_app(self):
        self.events.append("kill")
        self.app_running = False
        if self.survives and self.host:
            self.orphaned_at = self.now
        else:
            self.host = None

    def relaunch(self, env=None):
        self.app_running = True
        if (env or {}).get(kill_app.ADOPTION_WIRE_ENV) == kill_app.MISMATCHED_WIRE:
            self.events.append("relaunch as another version")
            self.lingering = None if self.mismatch_ends else self.host
            self.host, self.started, self.adopted, self.orphaned_at = 700, 1, 0, None
            self.adoption = "host 600 speaks another version: it closed its pages, and a new host starts"
            self.origin += 7 if self.mismatch_reloads else 0
            self.href = self.mismatch_href
            return
        self.events.append("relaunch")
        if self.adopts and self.pid_alive(self.host or 0):
            self.adopted, self.orphaned_at = 1, None
            if self.reloads:
                self.origin += 1
        else:
            self.host, self.started, self.adopted, self.origin = 600, 1, 0, self.origin + 5

    def pid_alive(self, pid):
        if pid and pid == self.lingering:
            return True
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
        self.assertTrue(row["mismatch"]["pass"], row["mismatch"])
        self.assertEqual(row["expires"]["host"], 700, "the expiring orphan is the host the mismatched relaunch started")
        self.assertEqual(bench.events, ["kill", "relaunch", "kill", "relaunch as another version", "kill"])

    def test_a_mismatched_host_that_keeps_running_fails(self):
        row, _ = kill_app.run(FakeBench(mismatch_ends=False), "file:///probe.html")
        self.assertFalse(row["mismatch"]["old_host_ended"])
        self.assertFalse(row["pass"])

    def test_a_tab_that_keeps_the_mismatched_hosts_page_fails(self):
        row, _ = kill_app.run(FakeBench(mismatch_reloads=False), "file:///probe.html")
        self.assertFalse(row["mismatch"]["pass"], "the tab was not restored from its history record")

    def test_a_tab_not_back_at_its_url_fails(self):
        row, _ = kill_app.run(FakeBench(mismatch_href="about:blank"), "file:///probe.html")
        self.assertFalse(row["mismatch"]["pass"])
        self.assertFalse(row["pass"])

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
