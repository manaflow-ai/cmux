#!/usr/bin/env python3
"""chromium_host_lifecycle.py, the quit and runtime-update rows of chromium-host-bench.py (p01-process-087), against a
fake app. Quit: a page with typed input asks, Stay keeps cmux, its host and the page, and Leave ends cmux with no host
left pass; a page that never asks, a Stay that still quits, or a host that outlives quit's deadline fail. Runtime
update: the host kept while the page shows, restarted on the newer runtime once hidden, and the tab back with its
history pass; no restart, a restart on the old runtime or a lost history fail. A build without the host backend does
not run. Runs anywhere (no app).
Run: python3 -I scripts/cmux-next/tests/test_chromium_host_lifecycle.py"""
import os, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import chromium_host_lifecycle as lifecycle  # noqa: E402

URL = "file:///quit.html"


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def clock(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds

    def wait(self, check, seconds, step=0.1):
        """Polls `check` on the fake clock, at most `seconds`."""
        deadline = self.now + seconds
        while True:
            value = check()
            if value:
                return value
            if self.now >= deadline:
                return None
            self.now += step


class FakeQuitApp(FakeClock):
    """One Chromium tab with the quit probe and one Chromium Host. `asks`: the page's beforeunload asks once typed;
    `stay_quits`: Stay ends cmux anyway; `host_lingers`: the host outlives cmux."""

    def __init__(self, backend="host", asks=True, stay_quits=False, host_lingers=False):
        super().__init__()
        self.backend, self.asks, self.stay_quits, self.host_lingers = backend, asks, stay_quits, host_lingers
        self.url, self.value, self.used = None, "", False
        self.quitting, self.prompts, self.running, self.hosts = False, [], True, [7000]

    def end(self):
        self.running, self.quitting = False, False
        if not self.host_lingers:
            self.hosts = []

    def rpc(self, method, params=None, timeout=None):
        params = params or {}
        if method == "debug.cef":
            return {"backend": self.backend}
        if method == "action.run" and params.get("action") == "openBrowser.chromium":
            self.url = params["args"]["url"]
            return {}
        if method == "debug.cef.devtools":
            if params["method"] == "Input.dispatchMouseEvent":
                self.used = True
            elif params["method"] == "Input.insertText" and self.used:
                self.value += params["params"]["text"]
            return {"result": "{}"}
        if method == "debug.quit":
            if params.get("open"):
                self.quitting = True
                if self.asks and self.value:
                    self.prompts = [{"kind": "beforeUnload(isReload: false)"}]
                else:
                    self.end()
            return {"quitting": self.quitting}
        if method == "debug.browser.prompts":
            answer = params.get("respond")
            if answer and self.prompts:
                self.prompts = []
                if answer == "accept" or self.stay_quits:
                    self.end()
                else:
                    self.quitting = False
            return {"prompts": list(self.prompts)}
        return {}

    def page_eval(self, script, tab):
        self.now += 0.01
        if "getBoundingClientRect" in script:
            return [190, 60]
        if "document.getElementById('field').value" in script:
            return self.value == lifecycle.TYPED and f"location.href === {self.url!r}" in script or (
                self.value == lifecycle.TYPED and "window.changed" in script)
        return None

    def focused_eval(self, script):
        return (self.url is not None and f"location.href === {self.url!r}" in script), "t1"


class FakeUpdateApp(FakeClock):
    """One Chromium tab and one Chromium Host. Once the page is hidden after a newer runtime, a new host starts on it
    after `restart_after` s. `no_restart`: none starts; `old_runtime`: it starts on the old runtime; `loses_history`:
    the tab comes back with one entry."""

    def __init__(self, backend="host", restart_after=1.0, no_restart=False, old_runtime=False, loses_history=False):
        super().__init__()
        self.backend, self.restart_after = backend, restart_after
        self.no_restart, self.old_runtime, self.loses_history = no_restart, old_runtime, loses_history
        self.url, self.length, self.shown, self.hidden_at = None, 1, True, None
        self.hosts, self.runtimes, self.pending = [7000], ["bundled"], None

    def host_pids(self):
        if self.pending and self.hidden_at is not None and not self.no_restart and self.now - self.hidden_at >= self.restart_after:
            self.hosts, self.pending = [self.hosts[0] + 1], None
            self.runtimes.append("bundled" if self.old_runtime else self.pending_path)
            if self.loses_history:
                self.length = 1
        return list(self.hosts)

    def rpc(self, method, params=None, timeout=None):
        params = params or {}
        if method == "debug.cef":
            return {"backend": self.backend}
        if method == "debug.browser.page_status":
            return {"engine_state_saved": "1"}
        if method == "debug.updater":
            if "path" in params:
                self.pending = self.pending_path = params["path"]
                return {"updated": True, "state": "waiting: not checked"}
            self.host_pids()
            state = "none" if not self.pending else ("waiting: a page is on screen" if self.shown else "waiting: not checked")
            return {"state": state, "host_runtimes": list(self.runtimes)}
        action = params.get("action")
        if action == "openBrowser.chromium":
            self.url = params["args"]["url"]
        elif action == "newTab":
            self.shown, self.hidden_at = False, self.now
        elif action == "tab.focus":
            self.shown = True
        return {}

    def page_eval(self, script, tab):
        self.now += 0.01
        if script.startswith("location.assign("):
            self.url, self.length = script.split("(", 1)[1].split(")", 1)[0].strip("'"), 2
            return True
        if self.pending and not self.shown:
            return None  # its host is restarting
        return f"location.href === {self.url!r}" in script and f"history.length === {self.length}" in script

    def focused_eval(self, script):
        return (self.url is not None and f"location.href === {self.url!r}" in script), "t1"


def run_quit(app):
    return lifecycle.run_quit(app.rpc, app.wait, app.page_eval, app.focused_eval, URL, lambda: list(app.hosts),
                              lambda: app.running, app.clock)


def run_update(app):
    return lifecycle.run_runtime_update(app.rpc, app.wait, app.page_eval, app.focused_eval, "file:///page.html",
                                        app.host_pids, "/out/runtime-update/Frameworks", app.clock, app.sleep)


class QuitRowTests(unittest.TestCase):
    def test_asks_stays_then_leaves_with_no_host_left(self):
        row, ran = run_quit(FakeQuitApp())
        self.assertTrue(ran)
        self.assertTrue(row["pass"], row)
        self.assertTrue(row["typed"] and row["stayed"] and row["same_host"] and row["page_kept"] and row["left"])
        self.assertLessEqual(row["asked_ms"], lifecycle.ASK_BUDGET_MS)

    def test_a_page_that_never_asks_fails(self):
        row, ran = run_quit(FakeQuitApp(asks=False))
        self.assertTrue(ran)
        self.assertFalse(row["pass"])
        self.assertIsNone(row["asked_ms"])

    def test_a_stay_that_still_quits_fails(self):
        row, ran = run_quit(FakeQuitApp(stay_quits=True))
        self.assertTrue(ran)
        self.assertFalse(row["pass"])
        self.assertNotIn("left", row)

    def test_a_host_that_outlives_cmux_fails(self):
        row, ran = run_quit(FakeQuitApp(host_lingers=True))
        self.assertTrue(ran)
        self.assertFalse(row["pass"])
        self.assertFalse(row["left"])

    def test_a_build_without_the_host_backend_does_not_run(self):
        row, ran = run_quit(FakeQuitApp(backend="inProcess"))
        self.assertFalse(ran)
        self.assertIn("not_run", row)


class RuntimeUpdateRowTests(unittest.TestCase):
    def test_kept_while_shown_restarted_on_the_newer_runtime_and_back_pass(self):
        row, ran = run_update(FakeUpdateApp())
        self.assertTrue(ran)
        self.assertTrue(row["pass"], row)
        self.assertTrue(row["kept_while_shown"] and row["runtime_used"] and row["back"])
        self.assertLessEqual(row["restart_s"], lifecycle.RESTART_BUDGET_S)

    def test_no_restart_fails(self):
        row, ran = run_update(FakeUpdateApp(no_restart=True))
        self.assertTrue(ran)
        self.assertFalse(row["pass"])
        self.assertIsNone(row["restart_s"])

    def test_a_restart_on_the_old_runtime_fails(self):
        row, ran = run_update(FakeUpdateApp(old_runtime=True))
        self.assertTrue(ran)
        self.assertFalse(row["pass"])
        self.assertFalse(row["runtime_used"])

    def test_a_lost_history_fails(self):
        row, ran = run_update(FakeUpdateApp(loses_history=True))
        self.assertTrue(ran)
        self.assertFalse(row["pass"])
        self.assertFalse(row["back"])

    def test_a_build_without_the_host_backend_does_not_run(self):
        row, ran = run_update(FakeUpdateApp(backend="inProcess"))
        self.assertFalse(ran)
        self.assertIn("not_run", row)


class RuntimeCopyTests(unittest.TestCase):
    def test_links_each_framework_entry_at_another_path(self):
        with tempfile.TemporaryDirectory() as root:
            frameworks = os.path.join(root, "cmux DEV.app", "Contents", "Frameworks")
            os.makedirs(os.path.join(frameworks, "Chromium Embedded Framework.framework"))
            open(os.path.join(frameworks, "libcmux_cef_shim.dylib"), "w").close()
            copy = lifecycle.runtime_copy(os.path.join(root, "cmux DEV.app"), os.path.join(root, "out"))
            self.assertNotEqual(copy, frameworks)
            self.assertEqual(sorted(os.listdir(copy)), ["Chromium Embedded Framework.framework", "libcmux_cef_shim.dylib"])
            self.assertEqual(os.readlink(os.path.join(copy, "libcmux_cef_shim.dylib")),
                             os.path.join(frameworks, "libcmux_cef_shim.dylib"))
            self.assertEqual(lifecycle.runtime_copy(os.path.join(root, "cmux DEV.app"), os.path.join(root, "out")), copy)


if __name__ == "__main__":
    unittest.main()
