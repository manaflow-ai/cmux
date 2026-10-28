#!/usr/bin/env python3
"""chromium_host_agent_cdp.py, the --modes agentcdp row of chromium-host-bench.py (p01-process-233), against a fake app:
a burst whose CDP never reaches the app's main thread and whose keys stay in one frame passes; one the app relays
itself (one `browser-host.cdp` task per message), one that misses the rate or errs, and one whose key p99 is over a
frame fail; a build without the host backend does not run. The --kill-app row: a host that ends with cmux is not
measurable, a surviving host whose page keeps its timeOrigin passes, and one whose page reloaded fails. Runs anywhere
(no app).
Run: python3 -I scripts/cmux-next/tests/test_chromium_host_agent_cdp.py"""
import json, os, sys, unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import chromium_host_agent_cdp as agentcdp  # noqa: E402


class Done:
    """An agent eval that already ended."""

    def __init__(self, code, out, err=""):
        self.value = (code, out, err)

    def result(self):
        return self.value


class FakeApp:
    """`debug.cef`, `action.run`, `debug.main_budget` (its owners), the probe's eval, the agent session and the typing
    probe. `cdp_tasks`: the app's `browser-host.cdp` tasks during the burst; `messages`/`errors`: what the session got
    through; `keys`: the probe's key-to-frame values for the burst."""

    def __init__(self, backend="host", cdp_tasks=0, messages=None, errors=0, keys=(4.0, 6.0, 8.0), origin=1000.5):
        self.backend, self.cdp_tasks, self.errors, self.keys, self.origin = backend, cdp_tasks, errors, keys, origin
        self.messages = agentcdp.RATE * agentcdp.SECONDS if messages is None else messages
        self.calls, self.scripts, self.typed = [], [], []

    def rpc(self, method, params=None, timeout=None):
        self.calls.append((method, params))
        if method == "debug.cef":
            return {"backend": self.backend}
        if method == "debug.main_budget" and not (params or {}).get("reset"):
            return {"owners": [{"owner": "browser-host.cdp.prepare", "tasks": 1},
                               {"owner": "browser-host.cdp", "tasks": self.cdp_tasks},
                               {"owner": "terminal.render", "tasks": 900}]}
        return {}

    def agent(self, script, timeout):
        self.scripts.append(script)
        burst = "slice < 0;" not in script
        report = {"id": "tab_1", "origin": self.origin, "messages": self.messages if burst else 0,
                  "errors": self.errors if burst else 0, "seconds": agentcdp.SECONDS if burst else 0}
        return Done(0, "console noise\n" + json.dumps(report) + "\n")

    def type_keys(self, seconds):
        self.typed = list(self.keys)

    def typed_ms(self):
        return list(self.typed)


def run(app):
    return agentcdp.run(app.rpc, lambda check, *_: check(), lambda _script: True, "file:///probe.html", app.agent,
                        app.type_keys, app.typed_ms)


class AgentCdpRow(unittest.TestCase):
    def test_a_burst_that_never_reaches_the_main_thread_passes(self):
        app = FakeApp()
        row, ran = run(app)
        self.assertTrue(ran)
        self.assertTrue(row["pass"], row)
        self.assertEqual(row["main_turns"], {"browser-host.cdp.prepare": 1, "browser-host.cdp": 0})
        self.assertEqual(row["key_to_frame_ms"]["n"], 3)
        # The tab is hidden behind a terminal before the session claims it; the budget resets before the burst.
        actions = [p["action"] for m, p in app.calls if m == "action.run"]
        self.assertEqual(actions, ["openBrowser.chromium", "newTab"])
        self.assertIn(("debug.main_budget", {"reset": True}), app.calls)
        self.assertEqual(len(app.scripts), 2, "a warm-up claim, then the burst")

    def test_a_burst_the_app_relays_itself_fails(self):
        row, _ = run(FakeApp(cdp_tasks=agentcdp.RATE * 10))
        self.assertFalse(row["pass"])
        self.assertFalse(row["checks"]["main_turns"])

    def test_a_short_or_failing_burst_fails(self):
        self.assertFalse(run(FakeApp(messages=agentcdp.RATE))[0]["checks"]["rate"])
        self.assertFalse(run(FakeApp(errors=3))[0]["checks"]["rate"])

    def test_a_key_over_one_frame_at_p99_fails(self):
        row, _ = run(FakeApp(keys=[5.0] * 95 + [40.0] * 5))
        self.assertFalse(row["checks"]["key"], row["key_to_frame_ms"])
        self.assertFalse(run(FakeApp(keys=()))[0]["checks"]["key"], "no key measured is no pass")

    def test_without_the_host_backend_the_row_does_not_run(self):
        row, ran = run(FakeApp(backend="inproc"))
        self.assertFalse(ran)
        self.assertIn("not_run", row)

    def test_the_script_paces_the_rate_in_slices(self):
        script = agentcdp.agent_script("file:///p.html", rate=1000, seconds=2)
        self.assertIn("slice < 20;", script)
        self.assertIn("i < 50;", script, "50 evaluates (100 messages) per 100 ms slice is 1,000 messages a second")
        self.assertIn("slice < 0;", agentcdp.agent_script("file:///p.html", rate=0))


class KillAppRow(unittest.TestCase):
    def kill(self, survived, origin_after):
        app = FakeApp()
        origins = iter([app.origin, origin_after])

        def agent(script, timeout):
            return Done(0, json.dumps({"id": "tab_1", "origin": next(origins)}))

        relaunched = []
        with mock.patch.object(agentcdp.os, "kill") as kill:
            row, ran = agentcdp.kill_app(4242, 4343, lambda: relaunched.append(True), agent, "file:///p.html",
                                         lambda pid: survived, lambda _s: None)
        kill.assert_called_once_with(4242, agentcdp.signal.SIGKILL)
        return row, ran, relaunched

    def test_a_host_that_ends_with_cmux_is_not_measurable(self):
        row, ran, relaunched = self.kill(False, None)
        self.assertTrue(ran)
        self.assertFalse(row["pass"])
        self.assertIn("p01-process-150", row["not_measurable"])
        self.assertEqual(relaunched, [], "cmux was relaunched for a host that is gone")

    def test_the_same_page_driven_again_passes(self):
        row, _, relaunched = self.kill(True, 1000.5)
        self.assertTrue(row["pass"], row)
        self.assertEqual(relaunched, [True])

    def test_a_reloaded_page_fails(self):
        row, _, _ = self.kill(True, 2000.0)
        self.assertFalse(row["pass"])


if __name__ == "__main__":
    unittest.main()
