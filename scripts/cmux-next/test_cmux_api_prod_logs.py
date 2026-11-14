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

TEAM = "team_0000aaaa1111bbbb2222"


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
        for leak in (TEAM, "0000aaaa1111bbbb2222", "user_8f2a91c0d7e6", "hunter2", "s3cret", "token"):
            self.assertNotIn(leak, text)
        self.assertEqual(counts, {})

    def test_a_token_field_holding_an_id_is_hashed(self):
        row, _, text = published(event({"msg": "team selection unreachable", "op": TEAM}))
        self.assertEqual(row["log"]["op"], logs.tag(TEAM))
        self.assertNotIn(TEAM, text)

    def test_the_path_hashes_id_segments_and_drops_the_query(self):
        row, _, text = published(event({"msg": "x"}, url="https://api.cmux.dev/v1/invites/card/AbC123secret?x=1"))
        self.assertEqual(row["path"], "/v1/invites/card/" + logs.tag("AbC123secret"))
        row, _, text = published(event({"msg": "x"}, url="https://api.cmux.dev/v1/hands/" + TEAM + "/pair?invite=abc"))
        self.assertEqual(row["path"], "/v1/hands/" + logs.tag(TEAM) + "/pair")
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

    def test_a_404_path_made_of_words_prints_hashed(self):
        row, _, text = published(event({"msg": "x"}, url="https://api.cmux.dev/v1/do-not-share-this/merger-plan", status=404))
        self.assertEqual(row["path"], "/v1/" + logs.tag("do-not-share-this") + "/" + logs.tag("merger-plan"))
        self.assertNotIn("share", text)
        self.assertNotIn("merger", text)
        self.assertEqual(row["status"], 404)

    def test_the_kept_count_is_boolean_and_needles_never_read_raw_event_text(self):
        secret = event({"msg": "the merger closes friday", "team": TEAM}, url="https://api.cmux.dev/v1/home/url")
        listed = event({"msg": "team selection unreachable", "team": TEAM}, url="https://api.cmux.dev/v1/auth/token")
        head, rows = logs.publish([secret, secret, listed], ["merger closes"], account=TEAM)
        self.assertIs(head["kept_any"], False)
        self.assertNotIn("kept", head)
        self.assertNotIn("printed", head)
        self.assertEqual(rows, [])
        head, rows = logs.publish([secret, secret, listed], [TEAM], account=TEAM)
        self.assertIs(head["kept_any"], True)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["log"]["team"], logs.tag(TEAM))
        head, rows = logs.publish([secret, listed], ["/auth/"], account=TEAM)
        self.assertIs(head["kept_any"], True)
        self.assertEqual([r["path"] for r in rows], ["/v1/auth/token"])
        self.assertNotIn(TEAM, json.dumps([head, rows]))
        self.assertEqual(head["logs_dropped_unlisted"], 1)

    def test_the_stack_team_diagnostics_print(self):
        for msg in ("stack teams unreadable", "stack team sync failed", "team list membership unreachable"):
            row, counts, text = published(event({"msg": msg, "error": "Error: upstream said hunter2"}))
            self.assertEqual(row["log"], {"msg": msg, "error": True})
            self.assertNotIn("hunter2", text)
        row, _, text = published(event({"msg": "stack team sync rejected; ended", "team": TEAM, "code": "validation.invalid"}))
        self.assertEqual(row["log"], {"msg": "stack team sync rejected; ended", "team": logs.tag(TEAM), "code": "validation.invalid"})
        row, _, _ = published(event({"msg": "stack team sync rejected; ended", "code": "not a token; hunter2"}))
        self.assertNotIn("code", row["log"])
        row, _, _ = published(event({"msg": "stack team still missing after re-checks; dropped", "type": "team.updated"}))
        self.assertEqual(row["log"], {"msg": "stack team still missing after re-checks; dropped", "type": "team.updated"})

    def test_a_stack_sync_outcome_prints_only_from_its_fixed_enum(self):
        def outcome(v):
            row, _, text = published(event({"msg": "synced a stack team", "team": TEAM, "outcome": v}))
            return row["log"]["outcome"], text
        self.assertEqual(outcome("member_present")[0], "member_present")
        self.assertEqual(outcome("stack_server_not_configured")[0], "stack_server_not_configured")
        self.assertEqual(outcome("reject:validation.invalid")[0], "reject")
        got, text = outcome("the team was not found because hunter2")
        self.assertEqual(got, "other")
        self.assertNotIn("hunter2", text)
        self.assertEqual(outcome("lowercase_token_not_in_enum")[0], "other")
        self.assertEqual(outcome({"password": "hunter2"})[0], "other")


class AccountIsolationTests(unittest.TestCase):
    def test_a_foreign_team_with_the_target_in_its_url_is_not_published(self):
        foreign = event({"msg": "team selection unreachable", "team": "team_foreign"},
                        url="https://api.cmux.dev/v1/auth/" + TEAM)
        # The original public API accepts no identity scope and leaks this row via its URL hash.
        head, rows = logs.publish([foreign], [TEAM])
        self.assertEqual(rows, [])
        self.assertEqual(head["events_in_window"], 0)

    def test_scope_is_checked_before_counts_and_projection(self):
        good = event({"msg": "team selection unreachable", "team": TEAM})
        bad = event({"msg": "private text", "team": "team_foreign"})
        conflict = event({"msg": "team selection unreachable", "team": TEAM, "account": "team_foreign"})
        missing = event({"msg": "team selection unreachable"})
        head, rows = logs.publish([good, bad, conflict, missing], [], account=TEAM)
        self.assertEqual(len(rows), 1)
        self.assertEqual(head["events_in_window"], 1)
        self.assertNotIn("logs_dropped_unlisted", head)
        self.assertEqual(rows[0]["log"]["team"], logs.tag(TEAM))

    def test_foreign_url_match_is_rejected_with_an_explicit_account(self):
        foreign = event({"msg": "team selection unreachable", "team": "team_foreign"},
                        url="https://api.cmux.dev/v1/auth/" + TEAM)
        head, rows = logs.publish([foreign], [TEAM], account=TEAM)
        self.assertEqual(rows, [])
        self.assertEqual(head["events_in_window"], 0)

    def test_conflicting_parsed_sources_and_invalid_identities_fail_closed(self):
        for value in (None, [], 42, TEAM + "-suffix"):
            with self.subTest(value=value):
                candidate = event({"msg": "team selection unreachable", "team": value})
                self.assertEqual(logs.publish([candidate], [], account=TEAM)[1], [])
        candidate = event({"msg": "team selection unreachable", "team": TEAM})
        candidate["source"] = {"msg": "team selection unreachable", "team": "team_foreign"}
        self.assertEqual(logs.publish([candidate], [], account=TEAM)[1], [])

    def test_account_field_and_refining_needles_keep_only_the_scoped_row(self):
        own = event({"msg": "team selection unreachable", "account": TEAM},
                    url="https://api.cmux.dev/v1/auth/token")
        other = event({"msg": "team selection unreachable", "account": "team_other"},
                      url="https://api.cmux.dev/v1/auth/token")
        head, rows = logs.publish([own, other], ["/auth/"], account=TEAM)
        self.assertEqual(len(rows), 1)
        self.assertEqual(head["events_in_window"], 1)


if __name__ == "__main__":
    unittest.main()
