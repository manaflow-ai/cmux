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


class SessionCommands(unittest.TestCase):
    NEW_HELP = "Usage: acpmux [OPTIONS] [COMMAND]\n\nCommands:\n  new     Create a session\n  send    Send a prompt\n  race    x\n"
    OLD_HELP = "Usage: acpmux [OPTIONS] [COMMAND]\n\nCommands:\n  acp     ACP verbs\n  send    Send a prompt\n"

    def test_a_build_without_acp_creates_with_new(self):
        self.assertEqual(tsf.new_session_argvs(self.NEW_HELP), [["--json", "new"]])

    def test_an_older_build_creates_with_acp_new(self):
        self.assertEqual(tsf.new_session_argvs(self.OLD_HELP), [["--json", "acp", "new"]])

    def test_no_help_tries_both(self):
        self.assertEqual(tsf.new_session_argvs(""), [["--json", "new"], ["--json", "acp", "new"]])

    def test_session_id_from_any_shape(self):
        sid = "01a1e1cc-16d3-71d1-9d19-cd23eb5fa32d"
        self.assertEqual(tsf.session_id(json.dumps({"sessionId": sid})), sid)
        self.assertEqual(tsf.session_id(json.dumps({"session": {"id": sid}})), sid)
        self.assertEqual(tsf.session_id(f"created {sid}\n"), sid)
        self.assertIsNone(tsf.session_id('{"error": {"code": "usage"}}'))


class MarkerSync(unittest.TestCase):
    def test_transitions_are_the_flips_in_order(self):
        import tab_switch_capture as cap
        series = [[0.0, 10], [0.5, 12], [1.0, 240], [1.2, 241], [2.0, 9], [3.0, 250]]
        self.assertEqual(cap.transitions(series), [1.0, 2.0, 3.0])
        self.assertEqual(cap.transitions([]), [])


class SettleBlock(unittest.TestCase):
    """A block's pending switches judged on its frames: the leave flip's frame is the reference, the mark flip is t0."""

    def test_a_return_with_a_blank_frame_and_a_clean_return(self):
        import random
        import tab_switch_judge as judge
        w, h = 20, 10

        def tex(seed):
            rng = random.Random(seed)
            return bytes(rng.randrange(256) for _ in range(w * h))
        chat, term, blank = tex(1), tex(2), bytes([128]) * (w * h)
        frames = [(0.0, chat), (1.1, term), (2.004, blank), (2.012, chat),  # round 1: one blank frame, then the chat
                  (4.1, term), (5.003, chat)]                                # round 2: the chat on the first frame
        flips = {"a:leave": 1.0, "a:mark": 2.0, "a:end": 3.0, "b:leave": 4.0, "b:mark": 5.0, "b:end": 6.0}
        h_ = self.harness(w, h)
        judged = h_.settle_block([{"label": "a", "kind": "return", "shown": "chat"},
                                  {"label": "b", "kind": "return", "shown": "chat"}], frames, flips)
        (a, sa), (b, sb) = judged
        self.assertEqual(sa["blank_frames"], 1)
        self.assertEqual(sa["to_content_ms"], 12.0)
        self.assertIn("sheet", sa)
        self.assertEqual((sb["blank_frames"], sb["wrong_frames"], sb["to_content_ms"]), (0, 0, 3.0))
        self.assertEqual(judge.budget_fails(sb, "b"), [])

    def harness(self, w, h):
        rec = types.SimpleNamespace(w=w, h=h, frame_ms=1000 / 120, scale=1.0)
        args = types.SimpleNamespace(out=tempfile.mkdtemp(prefix="tsw-out-"), tolerance=0.002)
        hh = tsf.Harness(args, types.SimpleNamespace(control=None), rec, tempfile.mkdtemp(prefix="tsw-root-"))
        hh.content, hh.strip = (0, 0, w, h), None
        return hh


class LoadNames(unittest.TestCase):
    """The load modes fable-instant-at-any-load set (L0..L5), the older names, and combinations."""

    def test_modes(self):
        self.assertEqual(tsf.parse_load("L0"), {})
        self.assertEqual(tsf.parse_load("L1"), {"live": (60, 2000)})
        self.assertEqual(tsf.parse_load("L2")["bg_chats"], 10)
        self.assertTrue(tsf.parse_load("L3")["chat100k"])
        self.assertEqual(tsf.parse_load("L4"), tsf.parse_load("cpu-max"))
        l5 = tsf.parse_load("L5")
        for key in ("live", "bg_chats", "chat100k", "cpu", "stress"):
            self.assertIn(key, l5)

    def test_numbered_and_combined(self):
        self.assertEqual(tsf.parse_load("agents-12"), {"bg_chats": 12})
        self.assertEqual(tsf.parse_load("cpu-max+tabs-40+chat-100k"), {"cpu": True, "tabs": 40, "chat100k": True})
        self.assertEqual(tsf.parse_load("L1+L3")["live"], (60, 2000))
        for bad in ("L6", "agents-0", "tabs-", "gpu"):
            with self.assertRaises(ValueError):
                tsf.parse_load(bad)

    def test_stress_loads_run_last(self):
        self.assertEqual(tsf.order_loads(["L5", "L0", "L4+tabs-40", "L1"]), ["L0", "L4+tabs-40", "L1", "L5"])


class TargetedActions(unittest.TestCase):
    def test_target_rides_beside_the_args(self):
        app = FakeApp()
        self.addCleanup(app.close)
        tsf.Control(app.path).action("closeTab", focus=False, target="tab:t1")
        sent = app.requests[-1]["params"]
        self.assertEqual((sent["target"], sent["args"]), ("tab:t1", {}))

    def test_confirmation_required_runs_once_more_with_confirm(self):
        control = tsf.Control("/nonexistent")
        calls = []

        def call(method, params=None, timeout=30):
            calls.append(params)
            return {"error": {"code": "confirmation_required"}} if len(calls) == 1 else {}
        control.call = call
        self.assertEqual(control.action("closeWorkspace", target="workspace:w1"), {})
        self.assertEqual([c["args"] for c in calls], [{}, {"confirm": True}])
        self.assertEqual(calls[1]["target"], "workspace:w1")


class SettledAndOddities(unittest.TestCase):
    """settle_block adds settled_ms and the oddity log (each with its sheet) to every judged action."""

    def test_a_new_workspace_that_keeps_moving_after_its_content(self):
        import random
        w, h = 32, 32

        def tex(seed):
            rng = random.Random(seed)
            return bytes(rng.randrange(256) for _ in range(w * h))
        old, new = tex(1), tex(2)

        def sidebar(frame, value):
            out = bytearray(frame)
            for y in range(16):
                out[y * w:y * w + 16] = bytes([value]) * 16
            return bytes(out)
        frames = [(0.0, old), (1.010, sidebar(new, 10)), (1.050, sidebar(new, 90)), (1.120, sidebar(new, 200))]
        flips = {"n:leave": 0.999, "n:mark": 1.0, "n:end": 2.0}
        hh = SettleBlock().harness(w, h)
        hh.content = (16, 0, w, h)
        judged = hh.settle_block([{"label": "n", "kind": "settled", "strip": "sidebar"}], frames, flips)
        (_item, s), = judged
        self.assertEqual(s["to_content_ms"], 10.0)
        self.assertEqual(s["settled_ms"], 120.0)
        self.assertEqual(s["changed_after_first"], 2)
        kinds = {o["kind"]: o for o in s["oddities"]}
        self.assertIn("layout-after-content", kinds)
        self.assertTrue(os.path.exists(os.path.join(hh.args.out, kinds["layout-after-content"]["sheet"])))
        self.assertEqual(kinds["layout-after-content"]["ms"], 120.0)

    def test_an_at_item_is_judged_against_its_ref_flip_frame(self):
        import random
        w, h = 20, 10

        def tex(seed):
            rng = random.Random(seed)
            return bytes(rng.randrange(256) for _ in range(w * h))
        a, b = tex(1), tex(2)
        frames = [(0.0, a), (1.5, b), (2.008, a)]
        flips = {"n:leave": 0.9, "n:mark": 1.0, "n:end": 1.8, "s:leave": 1.9, "s:mark": 2.0, "s:end": 3.0}
        hh = SettleBlock().harness(w, h)
        judged = hh.settle_block([{"label": "s", "kind": "at", "ref_flip": "n:leave"}], frames, flips)
        (_item, s), = judged
        self.assertEqual(s["to_content_ms"], 8.0)
        self.assertTrue(s["end_matches_reference"])
        self.assertEqual(s["settled_ms"], 8.0)
        self.assertEqual(s["oddities"], [])


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
