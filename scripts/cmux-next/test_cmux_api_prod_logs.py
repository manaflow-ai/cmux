#!/usr/bin/env python3
"""cmux-api-prod-logs publishes default-deny: tenant text, serialized objects and unlisted msgs never reach the
public row; ids print only hashed (python3 scripts/cmux-next/test_cmux_api_prod_logs.py)."""
import importlib.util
import json
import os
import tempfile
import unittest

_spec = importlib.util.spec_from_file_location(
    "cmux_api_prod_logs", os.path.join(os.path.dirname(os.path.abspath(__file__)), "cmux-api-prod-logs.py"))
logs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(logs)

TEAM = "team_d4390fb0a0f47a8e135a"


def event(message, url="https://api.cmux.dev/v1/teams/" + TEAM + "/members?invite=abc", status=403):
    return {"timestamp": 1794400000000,
            "$metadata": {"type": "cf-worker", "message": message if isinstance(message, str) else json.dumps(message)},
            "$workers": {"outcome": "ok", "event": {"request": {"method": "POST", "url": url}, "response": {"status": status}}}}


def published(e):
    counts = {}
    row = logs.line(e, counts)
    row.pop("_ts", None)
    return row, counts, json.dumps(row)


class DefaultDenyTests(unittest.TestCase):
    def test_a_serialized_secret_in_msg_is_dropped(self):
        row, counts, text = published(event({"msg": json.dumps({"password": "hunter2"}), "team": TEAM}))
        self.assertNotIn("log", row)
        self.assertNotIn("hunter2", text)
        self.assertNotIn("password", text)
        self.assertEqual(counts, {"logs_dropped_unlisted": 1})

    def test_a_tenant_automation_line_is_dropped_even_with_an_allowlisted_msg(self):
        for line in ({"source": "automation", "team": TEAM, "run": "r1", "automation": "a1", "level": "info",
                      "msg": "Q3 plan: acquire the competitor quietly before the board meeting", "attrs": "{}"},
                     {"source": "automation", "team": TEAM, "msg": "sso gate unreachable"},
                     {"team": TEAM, "run": "r1", "automation": "a1", "level": "error",
                      "msg": "Error: confidential customer list attached"}):
            row, counts, text = published(event(line))
            self.assertNotIn("log", row)
            self.assertNotIn("confidential", text)
            self.assertNotIn("competitor", text)
            self.assertEqual(counts, {"logs_dropped_tenant": 1})

    def test_confidential_prose_is_dropped(self):
        prose = "the merger with the other company closes friday; do not tell the team"
        row, counts, text = published(event({"msg": prose}))
        self.assertNotIn("log", row)
        self.assertNotIn("merger", text)
        self.assertEqual(counts, {"logs_dropped_unlisted": 1})

    def test_plain_text_console_lines_never_print(self):
        row, counts, text = published(event("password=hunter2 for the admin"))
        self.assertNotIn("log", row)
        self.assertNotIn("hunter2", text)

    def test_an_allowlisted_msg_prints_typed_fields_with_the_team_redacted(self):
        row, counts, text = published(event({"msg": "team selection unreachable", "team": TEAM, "code": "not_a_member",
                                             "attempts": 2, "error": "upstream https://x/?token=s3cret",
                                             "detail": {"password": "hunter2"}, "user": "user_8f2a91c0d7e6",
                                             "step": "free text with spaces", "fails": "3"}))
        log = row["log"]
        self.assertEqual(log["msg"], "team selection unreachable")
        self.assertEqual(log["team"], logs.tag(TEAM))
        self.assertTrue(log["team"].startswith("h:"))
        self.assertEqual(log["user"], logs.tag("user_8f2a91c0d7e6"))
        self.assertEqual(log["code"], "not_a_member")
        self.assertEqual(log["attempts"], 2)
        self.assertIs(log["error"], True)
        self.assertNotIn("step", log)
        self.assertNotIn("fails", log)
        self.assertNotIn("detail", log)
        for leak in (TEAM, "d4390fb0a0f47a8e135a", "user_8f2a91c0d7e6", "hunter2", "s3cret", "token"):
            self.assertNotIn(leak, text)
        self.assertEqual(counts, {})

    def test_a_token_field_holding_an_id_is_hashed(self):
        row, _, text = published(event({"msg": "team selection unreachable", "op": TEAM}))
        self.assertEqual(row["log"]["op"], logs.tag(TEAM))
        self.assertNotIn(TEAM, text)

    def test_the_path_hashes_id_segments_and_drops_the_query(self):
        row, _, text = published(event({"msg": "x"}, url="https://api.cmux.dev/v1/invites/card/AbC123secret?x=1"))
        self.assertEqual(row["path"], "/v1/invites/card/" + logs.tag("AbC123secret"))
        row, _, text = published(event({"msg": "x"}))
        self.assertEqual(row["path"], "/v1/teams/" + logs.tag(TEAM) + "/members")
        self.assertNotIn(TEAM, text)
        self.assertNotIn("invite=abc", text)
        self.assertEqual(row["method"], "POST")
        self.assertEqual(row["status"], 403)

    def test_an_email_never_prints(self):
        row, _, text = published(event({"msg": "team selection unreachable", "team": "leo@example.com", "code": "a@b.co"},
                                       url="https://api.cmux.dev/v1/users/leo@example.com"))
        self.assertNotIn("example.com", text)
        self.assertNotIn("a@b.co", text)

    def test_needles_come_from_the_event_file(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump({"inputs": {"needles": TEAM + ",/auth/"}}, f)
        try:
            self.assertEqual(logs.event_needles(f.name), TEAM + ",/auth/")
        finally:
            os.unlink(f.name)
        self.assertEqual(logs.event_needles("/nonexistent/event.json"), "")

    def test_the_allowlist_is_exact_ids_not_substrings(self):
        self.assertIn("team selection unreachable", logs.PUBLIC_MSGS)
        row, counts, _ = published(event({"msg": "team selection unreachable: hunter2"}))
        self.assertNotIn("log", row)
        self.assertEqual(counts, {"logs_dropped_unlisted": 1})
        self.assertNotIn("invocation without a harness marker: not metered", logs.PUBLIC_MSGS)


if __name__ == "__main__":
    unittest.main()
