#!/usr/bin/env python3
"""chromium_host_restore.py, the restore row of chromium-host-bench.py --kill-host (p01-process-083), against a fake
app: 20 tabs in 3 windows that come back with their history on one new host pass; a tab that comes back without its
back list, shown windows slower than the 2 s budget, or no new host fail the row; a build without the host backend
does not run. Runs anywhere (no app).
Run: python3 -I scripts/cmux-next/tests/test_chromium_host_restore.py"""
import os, sys, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import chromium_host_restore as restore  # noqa: E402


class FakeApp:
    """Windows, tabs and one Chromium Host. After the kill a new host starts; each shown tab is back after
    `shown_after` seconds and each hidden tab once it is focused. `loses_history`: tabs come back with one entry;
    `no_restart`: no host starts after the kill."""

    def __init__(self, backend="host", shown_after=0.3, loses_history=False, no_restart=False):
        self.backend, self.shown_after = backend, shown_after
        self.loses_history, self.no_restart = loses_history, no_restart
        self.now, self.window, self.focused = 0.0, 0, None
        self.tabs, self.shown, self.hosts, self.killed_at = {}, {}, [7000], None

    def clock(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds

    def rpc(self, method, params=None, timeout=None):
        if method == "debug.cef":
            return {"backend": self.backend}
        if method == "debug.browser.page_status":
            return {"engine_state_saved": "1"}
        action = (params or {}).get("action")
        if action == "newWindow":
            self.window += 1
        elif action == "openBrowser.chromium":
            tab = f"t{len(self.tabs) + 1}"
            self.tabs[tab] = {"url": params["args"]["url"], "length": 1, "window": self.window, "back": True}
            self.shown[self.window], self.focused = tab, tab
        elif action == "tab.focus":
            tab = params["target"].split(":", 1)[1]
            self.shown[self.tabs[tab]["window"]], self.focused = tab, tab
            self.tabs[tab]["back"] = not self.no_restart
        return {}

    def kill(self, pid):
        self.hosts.remove(pid)
        self.killed_at = self.now
        for tab, state in self.tabs.items():
            state["back"] = False
            if self.loses_history:
                state["length"] = 1
        if not self.no_restart:
            self.hosts.append(pid + 1)

    def page_eval(self, script, tab):
        state = self.tabs[tab]
        if script.startswith("location.assign("):
            state["url"], state["length"] = script.split("(", 1)[1].split(")", 1)[0].strip("'"), 2
            return True
        if self.killed_at is not None and self.shown.get(state["window"]) == tab and not self.no_restart:
            state["back"] = state["back"] or self.now - self.killed_at >= self.shown_after
        self.now += 0.01
        wants_history = "history.length ===" in script
        return (state["back"] and f"location.href === {state['url']!r}" in script
                and (not wants_history or f"history.length === {state['length']}" in script))

    def focused_eval(self, script):
        return self.page_eval(script, self.focused) if "location.assign" not in script else None, self.focused


def wait(check, seconds, step=0.1):
    """Polls `check` on the fake clock (each eval moves it), at most `seconds`."""
    deadline = None
    while True:
        value = check()
        if value:
            return value
        app = wait.app
        deadline = app.now + seconds if deadline is None else deadline
        if app.now >= deadline:
            return None
        app.now += step


def run(app, **kwargs):
    wait.app = app
    return restore.run(app.rpc, wait, app.page_eval, app.focused_eval, "file:///probe.html", lambda: list(app.hosts),
                       app.kill, app.clock, app.sleep, **kwargs)


class RestoreRowTests(unittest.TestCase):
    def test_twenty_tabs_in_three_windows_back_with_their_history_pass(self):
        app = FakeApp()
        row, ran = run(app)
        self.assertTrue(ran)
        self.assertTrue(row["pass"], row)
        self.assertEqual(len(row["tabs"]), restore.TABS)
        self.assertEqual({entry["window"] for entry in row["tabs"]}, {0, 1, 2})
        self.assertEqual(sum(entry["shown"] for entry in row["tabs"]), restore.WINDOWS)
        self.assertLessEqual(row["shown_ms"], restore.SHOWN_BUDGET_MS)
        self.assertTrue(all(entry["hidden_ms"] is not None for entry in row["tabs"] if not entry["shown"]))
        self.assertTrue(row["one_host"])

    def test_a_tab_back_without_its_back_list_fails(self):
        row, ran = run(FakeApp(loses_history=True))
        self.assertTrue(ran)
        self.assertFalse(row["pass"])
        self.assertFalse(row["all_back"])

    def test_shown_windows_slower_than_the_budget_fail(self):
        row, ran = run(FakeApp(shown_after=3.0))
        self.assertTrue(ran)
        self.assertFalse(row["pass"])
        self.assertGreater(row["shown_ms"], restore.SHOWN_BUDGET_MS)

    def test_no_new_host_fails(self):
        row, ran = run(FakeApp(no_restart=True), tabs=4)
        self.assertTrue(ran)
        self.assertFalse(row["pass"])
        self.assertFalse(row["one_host"])
        self.assertIsNone(row["shown_ms"])

    def test_a_build_without_the_host_backend_does_not_run(self):
        row, ran = run(FakeApp(backend="inProcess"))
        self.assertFalse(ran)
        self.assertFalse(row["pass"])
        self.assertIn("not_run", row)


if __name__ == "__main__":
    unittest.main()
