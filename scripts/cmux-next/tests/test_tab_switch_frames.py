"""tab_switch_frames.py's control calls and setup-fault rows, without an app: the NIGHTLY run of 2026-11-15 died on
`Control.action() got multiple values for argument 'name'` (agent.harness.add's own `name` argument)."""
import json
import os
import socket
import sys
import tempfile
import threading
import types
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import tab_switch_frames as tsf  # noqa: E402


class FakeApp:
    """A control socket that answers every request with {"result": {}} and keeps what it was sent."""

    def __init__(self):
        self.folder = tempfile.mkdtemp(prefix="tsw-")
        self.path = os.path.join(self.folder, "c.sock")
        self.requests = []
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(self.path)
        self.server.listen(4)
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            with conn:
                buf = b""
                while not buf.endswith(b"\n"):
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    buf += chunk
                self.requests.append(json.loads(buf))
                conn.sendall(b'{"id": 1, "result": {}}\n')

    def close(self):
        self.server.close()


class ControlCalls(unittest.TestCase):
    def setUp(self):
        self.app = FakeApp()
        self.control = tsf.Control(self.app.path)

    def tearDown(self):
        self.app.close()

    def test_an_action_argument_named_name_reaches_the_action(self):
        reply = self.control.action("agent.harness.add", focus=False, id="tab-switch-turns", name="tab-switch-turns",
                                    command="/usr/bin/python3", args="'agent.py'", protocol="acp", replace="true")
        self.assertEqual(reply, {})
        sent = self.app.requests[-1]
        self.assertEqual(sent["method"], "action.run")
        self.assertEqual(sent["params"]["action"], "agent.harness.add")
        self.assertEqual(sent["params"]["args"]["name"], "tab-switch-turns")
        self.assertNotIn("focus", sent["params"])

    def test_an_action_argument_named_action_reaches_the_action(self):
        self.control.action("x.y", action="inner")
        sent = self.app.requests[-1]["params"]
        self.assertEqual((sent["action"], sent["args"], sent["focus"]), ("x.y", {"action": "inner"}, True))


class AgentsSetup(unittest.TestCase):
    """Agents.__init__ as the NIGHTLY runs it: the real Control over a fake socket, only the Mac helpers (the bundle's
    acpmux and its socket lookup) stubbed. A keyword that clashes with Control.action's own parameters fails here."""

    def test_registers_both_test_agents_by_name(self):
        app = FakeApp()
        self.addCleanup(app.close)
        bm = types.SimpleNamespace(FakeChats=types.SimpleNamespace(acpmux_socket=lambda bundle: "/tmp/acpmux.sock"))
        icl = types.SimpleNamespace(bundled_acpmux=lambda bundle: "/bundle/acpmux")
        real = tsf.mac_helpers
        tsf.mac_helpers = lambda: (bm, icl)
        self.addCleanup(setattr, tsf, "mac_helpers", real)
        agents = tsf.Agents(types.SimpleNamespace(control=tsf.Control(app.path)), "/bundle")
        added = [r["params"] for r in app.requests if r["params"].get("action") == "agent.harness.add"]
        self.assertEqual([a["args"]["id"] for a in added], [tsf.TURNS_AGENT[0], tsf.STREAM_AGENT[0]])
        self.assertEqual([a["args"]["name"] for a in added], [tsf.TURNS_AGENT[0], tsf.STREAM_AGENT[0]])
        self.assertEqual(agents.env["ACPMUX_SOCKET"], "/tmp/acpmux.sock")
        self.assertEqual(agents.cli, "/bundle/acpmux")


class SetupFaultRows(unittest.TestCase):
    def harness(self):
        args = types.SimpleNamespace(out=tempfile.mkdtemp(prefix="tsw-out-"))
        app = types.SimpleNamespace(control=None)
        h = tsf.Harness(args, app, None, tempfile.mkdtemp(prefix="tsw-root-"))
        h.chat_note = "chat setup: TypeError: boom"
        return h

    def test_a_failed_load_and_a_missing_chat_are_rows_with_their_reason(self):
        rows = self.harness().run(["agents"], 2, ["chat-long-return", "terminal-return"], None, [],
                                  {"agents": "agents setup: TypeError: boom"})
        by = {(r["name"], r["load"]): r for r in rows}
        self.assertEqual(set(by), {("chat-long-return", "agents"), ("terminal-return", "agents")})
        self.assertEqual(by[("chat-long-return", "agents")]["switches"], [])
        self.assertIn("chat setup", by[("chat-long-return", "agents")]["budget_fail"][0])
        self.assertIn("agents setup", by[("terminal-return", "agents")]["budget_fail"][0])


if __name__ == "__main__":
    unittest.main()
