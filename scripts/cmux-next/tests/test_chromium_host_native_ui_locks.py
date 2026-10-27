#!/usr/bin/env python3
"""chromium_host_native_ui_locks.py, the fullscreen and lock rows of chromium-host-bench.py --native-ui
(p01-process-229), against a fake app: a correct app passes each row; an app without cmux's locks, one whose Escape
leaves a lock held, one that still opens a tab for Cmd-T under a keyboard lock, one whose locked moves never reach
the page and a host that shows a window each fail the row they break. Runs anywhere (no app).
Run: python3 -I scripts/cmux-next/tests/test_chromium_host_native_ui_locks.py"""
import os, sys, tempfile, unittest
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import chromium_host_native_ui_dialogs as dialogs  # noqa: E402
import chromium_host_native_ui_locks as locks  # noqa: E402

APP_PID, HOST_PID = 100, 200
BROWSER = 7


class FakeApp:
    """The app as the rows see it. `locks` False: no cmux locks (host_locks null); `sticky_escape`: Escape ends
    nothing; `cmd_t_opens_tab`: cmux runs New Tab under a keyboard lock; `moves_lost`: locked moves never reach the
    page; `host_window`: the host shows a window."""

    def __init__(self, locks=True, sticky_escape=False, cmd_t_opens_tab=False, moves_lost=False, host_window=False):
        self.locks, self.sticky_escape, self.cmd_t_opens_tab = locks, sticky_escape, cmd_t_opens_tab
        self.moves_lost, self.host_window = moves_lost, host_window
        self.ask, self.title = None, ""
        self.fullscreen = self.pointer = self.keyboard = None
        self.asked = self.granted = 0
        self.moves, self.keys, self.tabs = 0, [], 1

    def windows(self, pid):
        return [{"alpha": 1.0}] if pid == HOST_PID and self.host_window else []

    def page_eval(self, script):
        return {"document.title": self.title,
                "document.fullscreenElement !== null": self.fullscreen is not None,
                "document.fullscreenElement === null": self.fullscreen is None,
                "document.pointerLockElement !== null": self.pointer is not None,
                "document.pointerLockElement === null": self.pointer is None,
                "window.moves": self.moves, "window.keys": list(self.keys)}.get(script)

    def report(self):
        if not self.locks:
            return None
        return {"installed": True, "asked": self.asked, "granted": self.granted, "pointer": self.pointer,
                "keyboard": self.keyboard, "fullscreen": self.fullscreen,
                "holds_keys": self.keyboard is not None and self.fullscreen == self.keyboard}

    def rpc(self, method, params=None, timeout=30):
        params = params or {}
        if method == "action.run" and params.get("action") == "openBrowser.chromium":
            self.ask = parse_qs(urlparse(params["args"]["url"]).query).get("ask", [None])[0]
            self.title, self.tabs = "lock probe", self.tabs + 1
            return {}
        if method == "debug.cef":
            return {"host_locks": self.report()}
        if method == "debug.mouse" and params.get("action") == "move":
            if self.pointer is not None and not self.moves_lost:
                self.moves += 1
            return {"delivered": 1}
        if method == "debug.mouse":
            if self.ask in ("fullscreen", "keyboard"):
                self.fullscreen = BROWSER
            if self.ask in ("pointer", "keyboard") and self.locks:
                self.asked, self.granted = self.asked + 1, self.granted + 1
                if self.ask == "pointer":
                    self.pointer = BROWSER
                else:
                    self.keyboard = BROWSER
            return {"delivered": 2}
        if method == "debug.key" and params.get("key") == "t":
            if self.keyboard is not None and self.fullscreen == self.keyboard and not self.cmd_t_opens_tab:
                self.keys.append("Meta+t")
            else:
                self.tabs += 1
            return {}
        if method == "debug.key" and params.get("key") == "escape":
            if not self.sticky_escape:
                self.fullscreen = self.pointer = self.keyboard = None
            return {}
        if method == "debug.focus":
            return {"windows": [{"topology": [{"tabs": [f"tab{i}:browser" for i in range(self.tabs)]}]}]}
        return {}


def instant_wait(check, seconds, step=0.1):
    for _ in range(3):
        value = check()
        if value:
            return value
    return None


def run(app, rows=locks.ROWS):
    clear = lambda: dialogs.host_ui_clear(lambda: HOST_PID, lambda: APP_PID, app.windows)  # noqa: E731
    with tempfile.TemporaryDirectory() as out:
        return locks.run(app.rpc, instant_wait, app.page_eval, out, clear, rows_to_run=rows)


class LockRowsTests(unittest.TestCase):
    def setUp(self):
        self.sleep = locks.time.sleep
        locks.time.sleep = lambda seconds: None

    def tearDown(self):
        locks.time.sleep = self.sleep

    def test_a_correct_app_passes_each_row(self):
        rows, ok = run(FakeApp())
        self.assertTrue(ok, rows)
        self.assertEqual(set(rows), set(locks.ROWS))
        self.assertTrue(rows["pointer_lock"]["granted"] and rows["pointer_lock"]["moves"] > 0)
        self.assertTrue(rows["keyboard_lock"]["page_got_cmd_t"] and rows["keyboard_lock"]["no_new_tab"])

    def test_no_cmux_locks_fails_every_row_as_not_run(self):
        rows, ok = run(FakeApp(locks=False))
        self.assertFalse(ok)
        for name in locks.ROWS:
            self.assertIn("not_run", rows[name], name)

    def test_an_escape_that_ends_nothing_fails_every_row(self):
        rows, ok = run(FakeApp(sticky_escape=True))
        self.assertFalse(ok)
        for name in locks.ROWS:
            self.assertFalse(rows[name]["escaped"], name)

    def test_cmux_taking_cmd_t_fails_the_keyboard_row(self):
        rows, ok = run(FakeApp(cmd_t_opens_tab=True), rows=("keyboard_lock",))
        self.assertFalse(ok)
        self.assertFalse(rows["keyboard_lock"]["no_new_tab"])

    def test_lost_moves_fail_the_pointer_row(self):
        rows, ok = run(FakeApp(moves_lost=True), rows=("pointer_lock",))
        self.assertFalse(ok)
        self.assertEqual(rows["pointer_lock"]["moves"], 0)

    def test_a_host_window_fails_every_row(self):
        rows, ok = run(FakeApp(host_window=True))
        self.assertFalse(ok)
        for name in locks.ROWS:
            self.assertFalse(rows[name]["host"]["clear"], name)


if __name__ == "__main__":
    unittest.main()
