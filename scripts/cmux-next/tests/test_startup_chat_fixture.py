"""The startup comparator must reject a missing, changed or duplicated chat."""
import copy
import importlib.util
import json
import stat
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from startup_chat_fixture import ChatFixture

spec = importlib.util.spec_from_file_location("bench_startup", Path(__file__).resolve().parents[1] / "bench-startup.py")
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)
from test_bench_startup_agent_mark import FakeDaemon


class Client:
    def __init__(self, state):
        self.state = state

    def call(self, method, params):
        return {"ok": True, "result": self.state}


class SeedClient:
    """A create can take effect even when its acknowledgement times out."""
    def __init__(self, error=None, state=None, create_applies=True):
        self.sock = mock.Mock()
        self.error = error
        self.state = state or {}
        self.create_applies = create_applies
        self.creates = self.sends = self.clicks = 0
        self.calls = []

    def call(self, method, params):
        self.calls.append((method, params))
        action = params.get("action")
        if action == "new_chat":
            self.creates += 1
            if self.error:
                return {"ok": True, "result": {"pane": "chat-pane", "error": self.error}}
        elif action == "click" and params.get("selector") == ".acpmux-trust-ask-action":
            self.clicks += 1
            if self.create_applies:
                self.state["sessionId"] = "new-session"
        elif action == "send_prompt":
            self.sends += 1
            text = params["text"]
            self.state.update(transcript=[{"kind": "user", "text": text},
                                          {"kind": "assistant", "text": "echo: " + text}],
                              lastAssistant={"text": "echo: " + text}, isWorking=False)
        return {"ok": True, "result": self.state}


class Restoration(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.fixture = ChatFixture(Path(self.temp.name) / "receipts")
        self.addCleanup(self.fixture.close)
        self.fixture.environment("test")
        self.exchange = [{"kind": "user", "text": "marker"}, {"kind": "assistant", "text": "echo: marker"}]
        self.fixture.expected["test"] = {"sessionId": "session-1", "transcript": self.exchange}
        self.state = {"sessionId": "session-1", "transcript": copy.deepcopy(self.exchange), "isWorking": False,
                      "queued": []}
        self.marks = {"first_terminal_frame": 1200, "agent_pane.painted": 1500,
                      "agent_pane.settled_painted": 1800}

    def test_same_session_and_complete_exchange_produce_receipt(self):
        receipt = self.fixture.verify("test", Client(self.state), self.marks)
        self.assertEqual(json.loads(Path(receipt["receipt"]).read_text()), self.state)

    def test_terminal_only_sample_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "paint marks"):
            self.fixture.verify("test", Client(self.state), {"first_terminal_frame": 1200})

    def test_saved_chat_paint_without_settled_live_chat_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "paint marks"):
            self.fixture.verify("test", Client(self.state),
                                {"first_terminal_frame": 1200, "agent_pane.painted": 1500})

    def test_lost_replaced_duplicate_and_still_running_work_are_rejected(self):
        cases = [dict(sessionId="other"), dict(transcript=[]),
                 dict(transcript=self.exchange + self.exchange), dict(isWorking=True), dict(queued=["marker"])]
        for change in cases:
            with self.subTest(change=change), self.assertRaisesRegex(RuntimeError, "conversation"):
                self.fixture.verify("test", Client({**self.state, **change}), self.marks)

    def test_old_receipt_directory_cannot_supply_a_new_run(self):
        with self.assertRaises(FileExistsError):
            ChatFixture(self.fixture.output)

    def test_artifacts_on_a_shared_volume_do_not_place_daemon_state_there(self):
        shared = Path(self.temp.name) / "shared-volume"
        shared.mkdir(mode=0o777)
        shared.chmod(0o777)
        fixture = ChatFixture(shared / "receipts")
        self.addCleanup(fixture.close)
        environment = fixture.environment("shared")
        home = Path(environment["ACPMUX_HOME"]).resolve()
        for ancestor in (home, *home.parents):
            mode = ancestor.stat().st_mode
            self.assertFalse(mode & 0o022 and not mode & stat.S_ISVTX,
                             f"unsafe daemon state ancestor: {ancestor}")

    def test_creation_timeout_is_reconciled_without_creating_twice(self):
        client = SeedClient('timedOut("DevTools Runtime.evaluate (5.0 seconds)")')
        self.fixture.seed("test", client, 1)
        self.assertEqual(client.creates, 1)
        self.assertEqual(client.sends, 1)
        self.assertEqual(self.fixture.expected["test"]["sessionId"], "new-session")
        self.assertEqual(len(self.fixture.expected["test"]["transcript"]), 2)

    def test_seed_answers_folder_trust_prompt_before_waiting_for_session(self):
        client = SeedClient()
        self.fixture.seed("test", client, 1)
        click = next(index for index, (_, params) in enumerate(client.calls)
                     if params.get("action") == "click" and
                     params.get("selector") == ".acpmux-trust-ask-action")
        create = next(index for index, (_, params) in enumerate(client.calls)
                      if params.get("action") == "new_chat")
        self.assertEqual(client.clicks, 1)
        self.assertLess(create, click)
        self.assertFalse(any(method == "acp.trust.set" for method, _ in client.calls))

    def test_existing_session_is_rejected_before_creating_another(self):
        client = SeedClient(state={"sessionId": "existing-session"})
        with self.assertRaisesRegex(RuntimeError, "existing"):
            self.fixture.seed("test", client, 1)
        self.assertEqual(client.creates, 0)
        self.assertEqual(client.sends, 0)

    def test_creation_timeout_without_a_session_fails_without_replay(self):
        client = SeedClient('timedOut("DevTools Runtime.evaluate (5.0 seconds)")', create_applies=False)
        with self.assertRaisesRegex(RuntimeError, "did not become ready"):
            self.fixture.seed("test", client, 0.01)
        self.assertEqual(client.creates, 1)
        self.assertEqual(client.sends, 0)

    def test_explicit_creation_error_is_not_treated_as_a_timeout(self):
        client = SeedClient("The app refused this request.")
        with self.assertRaisesRegex(RuntimeError, "refused"):
            self.fixture.seed("test", client, 1)
        self.assertEqual(client.creates, 1)
        self.assertEqual(client.sends, 0)

    def test_seed_waits_for_the_selected_agent_page_before_creating_a_session(self):
        """A new-chat page paints before a conversation exists to emit chat paint."""
        page = {"opened": False, "selected": False, "painted": False}
        state = {}

        class App:
            sock = mock.Mock()

            def call(self, method, params):
                if method == "action.run":
                    if params["action"] == "palette.newAgentChat":
                        page["opened"] = True
                    elif params["action"] == "palette.goToTab" and params.get("target", {}).get("id") == "chat":
                        page["selected"] = page["opened"]
                    return {"ok": True}
                if not page["painted"]:
                    return {"error": "no pane shows an agent tab", "agent_panes": []}
                if params["action"] == "new_chat":
                    pass
                elif params["action"] == "click" and params.get("selector") == ".acpmux-trust-ask-action":
                    state["sessionId"] = "session-1"
                elif params["action"] == "send_prompt":
                    text = params["text"]
                    state.update(transcript=[{"kind": "user", "text": text},
                                             {"kind": "assistant", "text": "echo: " + text}],
                                 lastAssistant={"text": "echo: " + text}, isWorking=False)
                return {"ok": True, "result": state}

            def close(self):
                pass

        class Launch:
            def __init__(self, *args):
                self.marks = {}

            def wait_for(self, mark, *args, **kwargs):
                wanted = [mark] if isinstance(mark, str) else mark
                self.marks["daemon.first_tree_applied"] = 50
                page["painted"] = page["selected"]
                if page["painted"]:
                    self.marks["agent_pane.newtab_painted"] = 100
                landed = any if kwargs.get("any_of") else all
                return landed(name in self.marks for name in wanted)

            def quit(self):
                pass

        app = App()
        marker = Path(self.temp.name) / "seeded"
        with mock.patch("bench_cli_storm.Client", FakeDaemon), \
                mock.patch.multiple(bench, Launch=Launch, CHAT_FIXTURE=self.fixture, REALISTIC_WORKSPACES=1,
                                    HIDDEN_SCREENS=0, SEED_FOCUS="agent"), \
                mock.patch.object(bench, "reset_state"), \
                mock.patch.object(bench, "daemon_socket", return_value="unused"), \
                mock.patch.object(bench, "app_client", return_value=app), \
                mock.patch.object(bench, "app_tab_id", side_effect=lambda *args: "chat" if len(args) > 3 else "terminal"), \
                mock.patch.object(bench, "seeded_marker", return_value=marker):
            bench.seed_realistic("test", self.temp.name, 1)
        self.assertTrue(page["painted"])
        self.assertEqual(self.fixture.expected["test"]["transcript"], state["transcript"])
        self.assertEqual(len(state["transcript"]), 2)


if __name__ == "__main__":
    unittest.main()
