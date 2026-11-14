"""The startup comparator must reject a missing, changed or duplicated chat."""
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from startup_chat_fixture import ChatFixture


class Client:
    def __init__(self, state):
        self.state = state

    def call(self, method, params):
        return {"ok": True, "result": self.state}


class Restoration(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.fixture = ChatFixture(Path(self.temp.name) / "receipts")
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


if __name__ == "__main__":
    unittest.main()
