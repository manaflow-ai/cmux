#!/usr/bin/env python3
"""Tests of chief-home-migrate.py on fake tag homes shaped like Lawrence's
2026-10-05 data: hmchief (a compactor notice only), hmchief3 (11 messages and a
34-entry memory) and hmchief4 (one message no host ever logged).

Run: python3 scripts/cmux-next/tests/test_chief_home_migrate.py
"""
import importlib.util
import io
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from contextlib import redirect_stdout, redirect_stderr

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("migrate", os.path.join(HERE, "..", "chief-home-migrate.py"))
migrate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migrate)

# conversation_store.rs schema version 2, as the daemon writes it.
SCHEMA = [
    "CREATE TABLE meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)",
    "CREATE TABLE conversation (id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, participants_json TEXT NOT NULL, "
    "last_seq INTEGER NOT NULL CHECK(last_seq >= 0), rev INTEGER NOT NULL CHECK(rev >= 1), created_at TEXT NOT NULL, updated_at TEXT NOT NULL)",
    "CREATE INDEX conversation_by_updated ON conversation(updated_at DESC, id DESC)",
    "CREATE TABLE message (conversation TEXT NOT NULL, seq INTEGER NOT NULL CHECK(seq >= 1), id TEXT NOT NULL, "
    "message_json TEXT NOT NULL, PRIMARY KEY(conversation, seq)) WITHOUT ROWID",
    "CREATE UNIQUE INDEX message_by_id ON message(id)",
    "CREATE TABLE op_ledger (conversation TEXT NOT NULL, idempotency_key TEXT NOT NULL, fingerprint TEXT NOT NULL, "
    "result_json TEXT NOT NULL, PRIMARY KEY(conversation, idempotency_key)) WITHOUT ROWID",
    "CREATE TABLE create_ledger (idempotency_key TEXT PRIMARY KEY NOT NULL, fingerprint TEXT NOT NULL, conversation TEXT NOT NULL) WITHOUT ROWID",
    "CREATE TABLE read_cursor (conversation TEXT NOT NULL, participant TEXT NOT NULL, seq INTEGER NOT NULL CHECK(seq >= 0), "
    "PRIMARY KEY(conversation, participant)) WITHOUT ROWID",
    "CREATE TABLE op_ledger_v2 (conversation TEXT NOT NULL, actor TEXT NOT NULL, idempotency_key TEXT NOT NULL, "
    "fingerprint TEXT NOT NULL, result_json TEXT NOT NULL, PRIMARY KEY(conversation, actor, idempotency_key)) WITHOUT ROWID",
    "CREATE TABLE agent_guard (conversation TEXT PRIMARY KEY NOT NULL, agent_text_streak INTEGER NOT NULL CHECK(agent_text_streak >= 0), "
    "last_agent_text_at TEXT) WITHOUT ROWID",
    "CREATE TABLE agent_token (participant TEXT PRIMARY KEY NOT NULL, token_hash TEXT NOT NULL) WITHOUT ROWID",
]
PARTICIPANTS = json.dumps([{"id": "user_local", "kind": "human", "display_name": "lawrence"},
                           {"id": "agent_mux", "kind": "agent", "display_name": "Chief", "agent_class": "mux", "acp_session": "mux"}])


def make_tag(root, name, conv, created, messages, log=(), logged_seq=None, cursor=None):
    """One tag: its mux home (memory + host.json) and its daemon store."""
    mux = os.path.join(root, "mux", name)
    chat = os.path.join(mux, "optchat", "chat")
    os.makedirs(os.path.join(chat, "main"))
    os.makedirs(os.path.join(chat, "tree"))
    for i, (kind, text, date) in enumerate(log):
        with open(os.path.join(chat, "main", date[:10] + ".jsonl"), "a") as f:
            f.write(migrate.main_line(i, kind, text, date))
    if log:
        with open(os.path.join(chat, "tree", log[0][2][:10] + ".jsonl"), "w") as f:
            f.write(json.dumps({"l": 1, "i": 0, "text": "summary", "size": 7}) + "\n")
    if logged_seq is not None:
        json.dump({"conversation": conv, "logged_seq": logged_seq, "outbox": [], "turn": None, "children": {}},
                  open(os.path.join(mux, "optchat", "host.json"), "w"))
    db_path = os.path.join(root, "tui", name, "conversations.sqlite3")
    os.makedirs(os.path.dirname(db_path))
    db = sqlite3.connect(db_path)
    for sql in SCHEMA:
        db.execute(sql)
    db.execute("insert into meta values ('schema_version', '2')")
    for seq, (mid, author, key, text, at) in enumerate(messages, 1):
        body = {"id": mid, "conversation": conv, "seq": seq, "client_msg_id": key, "author": author,
                "parts": [{"type": "text", "text": text}], "created_at": at, "reactions": []}
        db.execute("insert into message values (?, ?, ?, ?)", (conv, seq, mid, json.dumps(body)))
    last = messages[-1][4] if messages else created
    db.execute("insert into conversation values (?, 'Chief', ?, ?, ?, ?, ?)", (conv, PARTICIPANTS, len(messages), len(messages) + 2, created, last))
    db.execute("insert into create_ledger values ('home-chief', 'fp', ?)", (conv,))
    if cursor is not None:
        db.execute("insert into read_cursor values (?, 'user_local', ?)", (conv, cursor))
    db.commit()
    db.close()
    return "%s=%s:%s" % (name, mux, db_path)


def lawrence_like(root):
    hmchief = make_tag(root, "hmchief", "conv_A", "2026-10-06T00:29:27.642Z",
                       [("msg_a1", "agent_mux", "notice:optchat:compactor:1", "The memory compactor cannot build summaries", "2026-10-06T00:29:27.800Z")],
                       logged_seq=1)
    hmchief3 = make_tag(root, "hmchief3", "conv_B", "2026-10-06T03:05:53.696Z", [
        ("msg_b1", "user_local", "cmk_1", "hi", "2026-10-06T03:06:01.998Z"),
        ("msg_b2", "agent_mux", "turn:optchat:0:x", "Hello.", "2026-10-06T03:06:04.622Z"),
        ("msg_b3", "user_local", "cmk_2", "do it", "2026-10-06T04:37:53.998Z"),
        ("msg_b4", "agent_mux", "turn:optchat:3:y", "I did not do anything yet.", "2026-10-06T04:38:04.517Z"),
    ], log=[("user", "hi", "2026-10-05T20:06:02.025-07:00"), ("talk", "Hello.", "2026-10-05T20:06:04.279-07:00"),
            ("user", "do it", "2026-10-05T21:37:54.000-07:00"), ("talk", "I did not do anything yet.", "2026-10-05T21:38:04.000-07:00")],
        logged_seq=4, cursor=3)
    hmchief4 = make_tag(root, "hmchief4", "conv_C", "2026-10-06T04:49:46.626Z",
                        [("msg_c1", "user_local", "cmk_3", "What are my agents doing right now?", "2026-10-06T04:55:30.495Z")], cursor=1)
    return [hmchief, hmchief3, hmchief4]


def run(args):
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        code = migrate.main(args)
    return code, out.getvalue() + err.getvalue()


def store(into):
    path = os.path.join(into, "tui", migrate.session_component(migrate.chief_session(into)), "conversations.sqlite3")
    db = sqlite3.connect(path)
    return db, path


class ChiefHomeMigrateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        self.into = os.path.join(self.root, "chief", "default")
        self.sources = lawrence_like(self.root)
        self.args = sum((["--source", s] for s in self.sources), []) + ["--into", self.into, "--user-home", self.root]

    def tearDown(self):
        self.tmp.cleanup()

    def test_the_session_name_matches_the_app(self):
        # ChiefHomeTests pins the same value for the same path.
        self.assertEqual(migrate.chief_session("/Users/someone/.cmux/chief/default"), "cmux-chief-1dff6c69")
        self.assertEqual(migrate.session_component("cmux-app-hmchief"), "cmux-app-hmchief-de68d63ca74ae6ff")

    def test_a_dry_run_reports_and_writes_nothing(self):
        code, text = run(self.args)
        self.assertEqual(code, 0)
        self.assertIn("6 messages, 0 duplicates dropped", text)
        self.assertIn("copy of hmchief3; 1 human messages no memory held are appended (hmchief4 seq 1)", text)
        self.assertFalse(os.path.exists(self.into))

    def test_apply_builds_one_history_in_time_order_with_the_memory_agreeing(self):
        code, text = run(self.args + ["--apply"])
        self.assertEqual(code, 0, text)
        db, path = store(self.into)
        rows = [json.loads(r[0]) for r in db.execute("select message_json from message order by seq")]
        self.assertEqual([m["id"] for m in rows], ["msg_a1", "msg_b1", "msg_b2", "msg_b3", "msg_b4", "msg_c1"])
        self.assertEqual({m["conversation"] for m in rows}, {"conv_B"})
        self.assertEqual([m["seq"] for m in rows], list(range(1, 7)))
        conv = db.execute("select id, last_seq, created_at from conversation").fetchall()
        self.assertEqual(conv, [("conv_B", 6, "2026-10-06T00:29:27.642Z")])
        cursors = dict(db.execute("select participant, seq from read_cursor").fetchall())
        # hmchief3's user read up to its seq 3 (now seq 4); hmchief4's up to its seq 1 (now 6).
        self.assertEqual(cursors, {"agent_mux": 6, "user_local": 6})
        self.assertEqual(db.execute("select conversation from create_ledger where idempotency_key = 'home-chief'").fetchone(), ("conv_B",))
        self.assertEqual(oct(os.stat(path).st_mode & 0o777), "0o600")
        log, tree = migrate.read_log(os.path.join(self.into, "optchat", "chat"))
        self.assertEqual([(e["i"], e["kind"], e["text"]) for e in log][-2:],
                         [(3, "talk", "I did not do anything yet."), (4, "user", "What are my agents doing right now?")])
        self.assertEqual(tree, 1, "the copied memory keeps its summaries")
        # The chat's human messages and the memory's user entries are the same, in the same order.
        self.assertEqual([m["parts"][0]["text"] for m in rows if m["author"] == "user_local"],
                         [e["text"] for e in log if e["kind"] == "user"])
        host = json.load(open(os.path.join(self.into, "optchat", "host.json")))
        self.assertEqual((host["conversation"], host["logged_seq"], host["outbox"], host["turn"]), ("conv_B", 6, [], None))
        backup = os.listdir(os.path.join(self.into, "migration-backup"))
        self.assertEqual(len(backup), 1)
        self.assertEqual(sorted(os.listdir(os.path.join(self.into, "migration-backup", backup[0]))), ["hmchief", "hmchief3", "hmchief4"])

    def test_running_it_again_does_nothing(self):
        self.assertEqual(run(self.args + ["--apply"])[0], 0)
        before = open(store(self.into)[1], "rb").read()
        code, text = run(self.args + ["--apply"])
        self.assertEqual(code, 0)
        self.assertIn("Already migrated", text)
        self.assertEqual(open(store(self.into)[1], "rb").read(), before)

    def test_a_chief_home_with_its_own_history_is_refused(self):
        os.makedirs(os.path.join(self.into, "optchat", "chat", "main"))
        with open(os.path.join(self.into, "optchat", "chat", "main", "2026-10-06.jsonl"), "w") as f:
            f.write(migrate.main_line(0, "user", "already here", "2026-10-06T08:00:00.000-07:00"))
        code, text = run(self.args + ["--apply"])
        self.assertEqual(code, 4, text)

    def test_an_unlogged_message_older_than_the_memory_moves_after_it(self):
        late = make_tag(self.root, "early", "conv_D", "2026-10-06T03:00:00.000Z",
                        [("msg_d1", "user_local", "cmk_9", "typed while no host ran", "2026-10-06T03:10:00.000Z")])
        code, text = run(self.args + ["--source", late, "--apply"])
        self.assertEqual(code, 0, text)
        rows = [json.loads(r[0]) for r in store(self.into)[0].execute("select message_json from message order by seq")]
        log, _ = migrate.read_log(os.path.join(self.into, "optchat", "chat"))
        self.assertEqual([m["parts"][0]["text"] for m in rows if m["author"] == "user_local"],
                         [e["text"] for e in log if e["kind"] == "user"])
        self.assertEqual(rows[-2]["id"], "msg_d1")

    def test_two_memories_interleave_by_time_and_drop_their_summaries(self):
        other = make_tag(self.root, "other", "conv_E", "2026-10-06T03:00:00.000Z",
                         [("msg_e1", "user_local", "cmk_e", "from another Chief", "2026-10-06T03:20:00.000Z")],
                         log=[("user", "from another Chief", "2026-10-05T20:20:00.500-07:00")], logged_seq=1)
        code, text = run(self.args + ["--source", other, "--apply"])
        self.assertEqual(code, 0, text)
        log, tree = migrate.read_log(os.path.join(self.into, "optchat", "chat"))
        self.assertEqual([e["i"] for e in log], list(range(len(log))))
        self.assertEqual([e["text"] for e in log][:3], ["hi", "Hello.", "from another Chief"])
        self.assertEqual(tree, 0)

    def test_the_same_message_in_two_sources_is_kept_once(self):
        dup = make_tag(self.root, "dup", "conv_F", "2026-10-06T05:00:00.000Z",
                       [("msg_b1", "user_local", "cmk_1", "hi", "2026-10-06T03:06:01.998Z")])
        code, text = run(self.args + ["--source", dup])
        self.assertIn("1 duplicates dropped", text)


if __name__ == "__main__":
    unittest.main()
