#!/usr/bin/env python3
"""chromium_host_helper_kill.py, the --helper-kill rows of chromium-host-bench.py (p01-process-225), against a fake app
and process table: the rows pick the host's own children (never another process), SIGKILL each, and pass on one
`debug.crashes` record per kill with its pid, type and signal. An app that records no host helper (in-process
monitoring only, the gap the task closes), one that records an end twice, a tab whose renderers are not the host's
children and a build without the host backend each fail the row they break. Runs anywhere (no app).
Run: python3 -I scripts/cmux-next/tests/test_chromium_host_helper_kill.py"""
import os, signal, sys, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import chromium_host_helper_kill as kill_rows  # noqa: E402

APP, HOST = 100, 200
HELPER = "/Applications/cmux.app/Contents/Frameworks/cmux Helper.app/Contents/MacOS/cmux Helper"


class FakeApp:
    """The app, its Chromium Host and the host's helpers. `records_host_helpers` False: the app hears no HELPER_EXIT
    (helpers watched in process only); `twice` records each end twice; `app_renderers` puts the tab's renderer under
    the app instead of the host."""

    def __init__(self, backend="host", records_host_helpers=True, twice=False, app_renderers=False):
        self.backend, self.records, self.twice = backend, records_host_helpers, twice
        renderer_parent = APP if app_renderers else HOST
        self.processes = {
            APP: (1, "/Applications/cmux.app/Contents/MacOS/cmux"),
            HOST: (APP, "/Applications/cmux.app/Contents/MacOS/cmux Chromium Host --framework=/x"),
            301: (HOST, f"{HELPER} --type=gpu-process --gpu-preferences=x"),
            302: (HOST, f"{HELPER} --type=utility --utility-sub-type=storage.mojom.StorageService"),
            303: (HOST, f"{HELPER} --type=utility --utility-sub-type={kill_rows.NETWORK_SERVICE}"),
            304: (renderer_parent, f"{HELPER} --type=renderer --renderer-client-id=7"),
            305: (HOST, f"{HELPER} --type=renderer --extension-process --renderer-client-id=8"),
            900: (1, "/usr/bin/some-other-process --type=renderer"),  # not the host's: never signalled
        }
        self.crashes, self.signalled = [], []

    def rpc(self, method, params=None, timeout=60):
        if method == "debug.cef":
            return {"backend": self.backend}
        if method == "action.run":
            return {"ok": True}
        if method == "debug.webui":
            helpers = [pid for pid, (ppid, _) in self.processes.items() if ppid == HOST]
            return {"browser_tabs": [{"tab": "t", "renderer_clients": [7], "renderer_pids": [304]}],
                    "processes": [{"pid": pid} for pid in helpers]}
        if method == "debug.crashes":
            return {"chromium": list(self.crashes), "chromium_total": len(self.crashes)}
        raise AssertionError(method)

    def ps_rows(self):
        return [(pid, ppid, command) for pid, (ppid, command) in self.processes.items()]

    def host_pid(self):
        return HOST if self.backend == "host" else None

    def kill(self, pid, sig):
        self.signalled.append((pid, sig))
        ppid, command = self.processes.pop(pid)
        if not self.records or ppid != HOST:
            return
        identity = kill_rows.helper_identity(command)
        record = {"process_type": "extension" if identity[2] else identity[0], "pid": pid, "reason": "killed",
                  "code": int(sig), "source": "process"}
        self.crashes += [record] * (2 if self.twice else 1)


def run(app):
    return kill_rows.run(app.rpc, lambda check, *_: check(), app.ps_rows, app.host_pid, app.kill, "file:///probe.html",
                         sleep=lambda _: None)


class HelperKillRows(unittest.TestCase):
    def test_every_row_passes_when_each_host_helper_is_recorded_once(self):
        app = FakeApp()
        rows, ok = run(app)
        self.assertTrue(ok, rows)
        self.assertEqual(rows["tab_processes"]["renderer_pids"], [304])
        self.assertEqual([pid for pid, _ in app.signalled], [303, 301, 304], "network service, GPU, the tab's renderer")
        self.assertTrue(all(sig == signal.SIGKILL for _, sig in app.signalled))
        for row, kind in (("utility", "utility"), ("gpu", "gpu-process"), ("renderer", "renderer")):
            self.assertEqual(rows[row]["process_type"], kind)
            self.assertEqual(len(rows[row]["records"]), 1)

    def test_no_record_of_a_host_helper_fails_every_kill_row(self):
        rows, ok = run(FakeApp(records_host_helpers=False))
        self.assertFalse(ok)
        self.assertTrue(rows["tab_processes"]["ok"])
        for row in kill_rows.KILL_ROWS:
            self.assertFalse(rows[row]["ok"], row)
            self.assertEqual(rows[row]["records"], [])

    def test_a_second_record_of_one_end_fails_the_row(self):
        rows, ok = run(FakeApp(twice=True))
        self.assertFalse(ok)
        self.assertFalse(any(rows[row]["ok"] for row in kill_rows.KILL_ROWS))

    def test_renderers_outside_the_host_fail_the_tab_row_and_are_never_signalled(self):
        app = FakeApp(app_renderers=True)
        rows, ok = run(app)
        self.assertFalse(ok)
        self.assertFalse(rows["tab_processes"]["ok"])
        self.assertNotIn(304, [pid for pid, _ in app.signalled], "a renderer of the app is not the host's to kill")
        self.assertNotIn(900, [pid for pid, _ in app.signalled])
        self.assertNotIn(305, [pid for pid, _ in app.signalled], "an extension renderer is not a page renderer")
        self.assertFalse(rows["renderer"]["ok"])

    def test_without_the_host_backend_nothing_runs(self):
        app = FakeApp(backend="inProcess")
        rows, ok = run(app)
        self.assertFalse(ok)
        self.assertEqual(set(rows), set(kill_rows.ROWS))
        self.assertTrue(all("not_run" in row for row in rows.values()))
        self.assertEqual(app.signalled, [])

    def test_a_utility_stands_in_when_no_network_service_runs(self):
        children = {302: ("utility", "storage.mojom.StorageService", False), 301: ("gpu-process", "", False)}
        self.assertEqual(kill_rows.pick(children, "utility", []), 302)
        self.assertIsNone(kill_rows.pick(children, "renderer", []))
        self.assertEqual(kill_rows.helper_identity("x --type=renderer --extension-process"), ("renderer", "", True))
        self.assertIsNone(kill_rows.helper_identity("/Applications/cmux.app/Contents/MacOS/cmux"))


if __name__ == "__main__":
    unittest.main()
