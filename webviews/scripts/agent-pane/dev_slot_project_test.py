#!/usr/bin/env python3
"""dev_slot_project.py copies only chats with no work left for a daemon.

    python3 -I webviews/scripts/agent-pane/dev_slot_project_test.py
"""

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dev_slot_project as projection  # noqa: E402


def chat(root: Path, name: str, records: list[tuple[str, str, dict]]) -> Path:
    session = root / "sessions" / name
    (session / "events").mkdir(parents=True)
    (session / "session.json").write_text(json.dumps({"id": name}))
    lines = [
        json.dumps({"seq": i, "at": i, "dir": d, "kind": k, "msg": m}, separators=(",", ":"))
        for i, (d, k, m) in enumerate(records)
    ]
    (session / "events" / "000001.ndjson").write_text("\n".join(lines) + "\n")
    return session


DONE = [("mux", "turn_started", {"turnId": "t1"}), ("mux", "turn_result", {"turnId": "t1", "status": "end_turn"})]


class ProjectionTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.source = Path(self.tmp.name, "source")
        self.slot = Path(self.tmp.name, "slot")
        self.slot.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def project(self, limit=30):
        taken, skipped = projection.project(self.source, self.slot, limit)
        return sorted(taken), dict(skipped)

    def test_copies_a_finished_chat_and_leaves_the_source_alone(self):
        source = chat(self.source, "done", DONE)
        before = (source / "events" / "000001.ndjson").read_bytes()
        self.assertEqual(self.project(), (["done"], {}))
        self.assertEqual((self.slot / "sessions" / "done" / "events" / "000001.ndjson").read_bytes(), before)
        self.assertEqual((source / "events" / "000001.ndjson").read_bytes(), before)

    def test_skips_every_kind_of_pending_work(self):
        chat(self.source, "running", [("mux", "turn_started", {"turnId": "t1"})])
        chat(self.source, "queued", [*DONE, ("mux", "queued", {"turnId": "t2", "promptId": "p2"})])
        chat(self.source, "moving", [*DONE, ("mux", "transfer_out", {"transferId": "x"})])
        chat(self.source, "paired", [*DONE, ("mux", "agent_pair_held", {})])
        chat(self.source, "failed", [("mux", "turn_started", {"turnId": "t1"}),
                                     ("mux", "turn_result", {"turnId": "t1", "status": "failed"})])
        taken, skipped = self.project()
        self.assertEqual(taken, [])
        self.assertEqual(sorted(skipped), ["failed", "moving", "paired", "queued", "running"])
        self.assertEqual(list((self.slot / "sessions").iterdir()), [])

    def test_closed_work_counts_as_quiet(self):
        chat(self.source, "joined", [*DONE, ("mux", "queued", {"turnId": "t2"}),
                                     ("mux", "dequeued", {"turnId": "t2", "joinedTurnId": "t1"})])
        chat(self.source, "removed", [("mux", "queued", {"turnId": "t2"}), ("mux", "queue_removed", {"turnId": "t2"})])
        chat(self.source, "moved-back", [*DONE, ("mux", "transfer_out", {}), ("mux", "transfer_aborted", {})])
        chat(self.source, "pair-done", [*DONE, ("mux", "agent_pair_held", {}), ("mux", "agent_pair_released", {})])
        self.assertEqual(self.project(), (["joined", "moved-back", "pair-done", "removed"], {}))

    def test_an_unnoticed_inbox_message_wakes_the_chat(self):
        chat(self.source, "unread", [*DONE, ("mux", "inbox", {"promptId": "m1"})])
        chat(self.source, "noticed", [*DONE, ("mux", "inbox", {"promptId": "m1"}),
                                      ("mux", "inbox_noticed", {"promptIds": ["m1"], "noticePromptId": "n1"})])
        chat(self.source, "removed", [*DONE, ("mux", "inbox", {"promptId": "m1"}),
                                      ("mux", "inbox_removed", {"promptId": "m1"})])
        chat(self.source, "delivered", [*DONE, ("mux", "inbox", {"promptId": "m1", "deliveredRead": True})])
        taken, skipped = self.project()
        self.assertEqual(taken, ["delivered", "noticed", "removed"])
        self.assertEqual(list(skipped), ["unread"])

    def test_a_queued_prompt_waits_until_its_turn_starts(self):
        # The daemon restores a queued prompt whose turn never started, whatever else was logged.
        chat(self.source, "queued", [("mux", "queued", {"turnId": "t2"}), ("mux", "turn_result", {"turnId": "t2"})])
        self.assertEqual(self.project()[0], [])

    def test_a_plain_dequeue_waits_for_its_turn(self):
        chat(self.source, "dequeued", [("mux", "queued", {"turnId": "t2"}), ("mux", "dequeued", {"turnId": "t2"})])
        self.assertEqual(self.project()[0], [])

    def test_an_agents_update_never_counts(self):
        # An agent's record may carry any kind; only the daemon's own (`mux`) open work.
        chat(self.source, "agent", [*DONE, ("in", "turn_started", {"turnId": "t9"})])
        self.assertEqual(self.project()[0], ["agent"])

    def test_takes_the_newest_up_to_the_limit_and_replaces_the_last_projection(self):
        for name in ("a", "b", "c"):
            chat(self.source, name, DONE)
        (self.slot / "sessions" / "stale").mkdir(parents=True)
        taken, _ = self.project(limit=2)
        self.assertEqual(len(taken), 2)
        self.assertEqual(sorted(p.name for p in (self.slot / "sessions").iterdir()), taken)


if __name__ == "__main__":
    unittest.main()
