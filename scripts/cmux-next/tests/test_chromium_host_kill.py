#!/usr/bin/env python3
"""chromium_host_kill.py, the --kill-host rows of chromium-host-bench.py (p01-process-082), against a fake app: the
signal each row sends to the host, the crash page it reads (`debug.browser.page_status`), the Reload it presses and
the page it waits for under a new host. A correct app passes every row; an app that shows no crash page, a crash
page without Reload, a Reload that brings nothing back, an app that died with its host, and a build without the host
backend each fail the row they break. Runs anywhere (no app, no process is signalled).
Run: python3 -I scripts/cmux-next/tests/test_chromium_host_kill.py"""
import os, signal, sys, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import chromium_host_kill as kill  # noqa: E402

GONE_TEXT = "Aw, Snap!\nChromium stopped while it showed this page. Reload starts Chromium again.\nReload"


class FakeApp:
    """The app as the rows see it: a host pid that a signal ends and a Reload replaces. `no_crash_page` keeps the
    page as it was after the host's end; `no_reload` shows the crash page with no button; `stuck` leaves the crash
    page after Reload; `dies` ends cmux with its host."""

    def __init__(self, backend="host", no_crash_page=False, no_reload=False, stuck=False, dies=False):
        self.backend, self.no_crash_page, self.no_reload, self.stuck, self.dies = backend, no_crash_page, no_reload, stuck, dies
        self.host, self.gone, self.app_alive = 100, False, True
        self.sent = []

    def rpc(self, method, params=None, timeout=60):
        params = params or {}
        if method == "debug.cef":
            return {"backend": self.backend}
        if method == "action.run":
            return {"ok": True}
        if method == "browser.page.eval":
            return {"tab": "t1", "value": None if self.gone or self.host is None else True}
        if method == "debug.browser.page_status":
            assert params["tab"] == "t1", params
            if params.get("press") == "reload":
                if not self.gone or self.no_reload:
                    return {"pressed": "0"}
                if not self.stuck:
                    self.gone, self.host = False, self.next_host
                return {"pressed": "1"}
            text = GONE_TEXT if not self.no_reload else GONE_TEXT.rsplit("\n", 1)[0] + "\n"
            return {"gone": "1" if self.gone else "0", "gone_text": text if self.gone else ""}
        raise AssertionError(f"unexpected method {method}")

    def send(self, pid, number):
        assert pid == self.host, (pid, self.host)
        self.sent.append(number)
        self.next_host = self.host + 1
        self.host = None
        self.gone = not self.no_crash_page
        self.app_alive = not self.dies


def instant(check, seconds, step=0.1):
    """The bench's wait() for a fake app that changes only on the rows' calls: one read."""
    return check() or None


def run(app, signals="KILL"):
    return kill.run(app.rpc, instant, "file:///kill-host.html", kill.signal_numbers(signals), lambda: app.host, 7,
                    lambda pid: pid == 7 and app.app_alive, send=app.send)


class KillHostRowsTest(unittest.TestCase):
    def test_signals_parse_to_numbers(self):
        self.assertEqual(kill.signal_numbers("TRAP,sigsegv,ABRT,KILL"),
                         [("TRAP", signal.SIGTRAP), ("SEGV", signal.SIGSEGV), ("ABRT", signal.SIGABRT), ("KILL", signal.SIGKILL)])
        with self.assertRaises(ValueError):
            kill.signal_numbers("HUP")

    def test_a_correct_app_passes_every_row(self):
        app = FakeApp()
        rows, ok = run(app, "TRAP,SEGV,ABRT,KILL")
        self.assertTrue(ok, rows)
        self.assertEqual(list(rows), list(kill.SIGNALS))
        self.assertEqual(app.sent, [signal.SIGTRAP, signal.SIGSEGV, signal.SIGABRT, signal.SIGKILL])
        row = rows["KILL"]
        self.assertTrue(row["crash_page"] and row["back"] and row["new_host"] and row["cmux_alive"])
        self.assertIsNotNone(row["crash_page_ms"])
        self.assertEqual(row["host_pid"], 103)
        self.assertEqual(row["new_host_pid"], 104)

    def test_no_crash_page_fails_the_row(self):
        rows, ok = run(FakeApp(no_crash_page=True))
        self.assertFalse(ok)
        self.assertFalse(rows["KILL"]["crash_page"])
        self.assertIsNone(rows["KILL"]["crash_page_ms"])

    def test_a_crash_page_without_reload_fails_the_row(self):
        rows, ok = run(FakeApp(no_reload=True))
        self.assertFalse(ok)
        self.assertFalse(rows["KILL"]["crash_page"])

    def test_a_reload_that_brings_nothing_back_fails_the_row(self):
        rows, ok = run(FakeApp(stuck=True))
        self.assertFalse(ok)
        self.assertTrue(rows["KILL"]["crash_page"])
        self.assertFalse(rows["KILL"]["back"])

    def test_cmux_ending_with_its_host_fails_the_row(self):
        rows, ok = run(FakeApp(dies=True))
        self.assertFalse(ok)
        self.assertFalse(rows["KILL"]["cmux_alive"])

    def test_without_the_host_backend_no_row_runs(self):
        app = FakeApp(backend="inProcess")
        rows, ok = run(app)
        self.assertFalse(ok)
        self.assertTrue(all("not_run" in row for row in rows.values()))
        self.assertEqual(app.sent, [])


if __name__ == "__main__":
    unittest.main()
