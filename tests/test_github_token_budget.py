#!/usr/bin/env python3
"""scripts/ci/github_token_budget.py warns only when the GITHUB_TOKEN budget is low."""
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import github_token_budget as budget  # noqa: E402


def rate(remaining, limit=1000):
    return json.dumps({"resources": {"core": {"limit": limit, "remaining": remaining, "used": limit - remaining,
                                              "reset": 1_800_000_000}}})


class BudgetTests(unittest.TestCase):
    def run_main(self, answers, env=None):
        calls = []

        def fake(args, token):
            calls.append((args[:2], token))
            answer = answers.pop(0)
            if isinstance(answer, Exception):
                raise answer
            return answer
        with tempfile.NamedTemporaryFile("r+") as summary, mock.patch.object(budget, "gh", fake), \
                mock.patch.dict(os.environ, {"GH_TOKEN": "own", "GITHUB_REPOSITORY": "o/r",
                                             "GITHUB_STEP_SUMMARY": summary.name, **(env or {})}, clear=False):
            self.assertEqual(budget.main([]), 0)
            return calls, Path(summary.name).read_text()

    def test_a_healthy_budget_makes_one_call_and_writes_nothing(self):
        calls, summary = self.run_main([rate(500)], {"ISSUE_TOKEN": "bot"})
        self.assertEqual(calls, [(["api", "rate_limit"], "own")])
        self.assertEqual(summary, "")

    def test_a_low_budget_warns_and_files_one_issue(self):
        calls, summary = self.run_main([rate(150), "[]", "[]", "https://github.com/o/r/issues/9\n"], {"ISSUE_TOKEN": "bot"})
        self.assertIn("150 of 1000 left", summary)
        self.assertEqual([c[0] for c in calls], [["api", "rate_limit"], ["issue", "list"], ["issue", "list"], ["issue", "create"]])
        self.assertEqual({c[1] for c in calls[1:]}, {"bot"})

    def test_an_open_issue_gets_a_comment_at_most_hourly(self):
        listed = json.dumps([{"number": 9, "title": budget.TITLE, "state": "OPEN", "updatedAt": "2020-01-01T00:00:00Z"}])
        calls, _ = self.run_main([rate(10), "[]", listed, ""], {"ISSUE_TOKEN": "bot"})
        self.assertEqual(calls[-1][0], ["issue", "comment"])
        fresh = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        listed = json.dumps([{"number": 9, "title": budget.TITLE, "state": "OPEN", "updatedAt": fresh}])
        calls, _ = self.run_main([rate(10), listed, listed], {"ISSUE_TOKEN": "bot"})
        self.assertEqual(calls[-1][0], ["issue", "list"])

    def test_a_recently_closed_alert_is_not_opened_again_within_the_hour(self):
        fresh = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        listed = json.dumps([{"number": 9, "title": budget.TITLE, "state": "CLOSED", "updatedAt": fresh}])
        calls, _ = self.run_main([rate(10), listed, "[]"], {"ISSUE_TOKEN": "bot"})
        self.assertEqual([c[0] for c in calls], [["api", "rate_limit"], ["issue", "list"], ["issue", "list"]])
        old = json.dumps([{"number": 9, "title": budget.TITLE, "state": "CLOSED", "updatedAt": "2020-01-01T00:00:00Z"}])
        calls, _ = self.run_main([rate(10), old, "[]", "https://github.com/o/r/issues/10\n"], {"ISSUE_TOKEN": "bot"})
        self.assertEqual(calls[-1][0], ["issue", "create"])

    def test_the_lookup_includes_closed_alerts(self):
        calls = []

        def fake(args, token):
            calls.append(args)
            return "[]" if args[:2] == ["issue", "list"] else "x"
        with mock.patch.object(budget, "gh", fake):
            budget.file_issue("o/r", "bot", "t", "u")
        self.assertEqual([c[c.index("--state") + 1] for c in calls[:2]], ["all", "open"])

    def test_an_old_open_alert_hidden_behind_closed_ones_gets_the_comment(self):
        closed = json.dumps([{"number": n, "title": budget.TITLE, "state": "CLOSED",
                              "updatedAt": "2020-01-01T00:00:00Z"} for n in range(20, 40)])
        still_open = json.dumps([{"number": 5, "title": budget.TITLE, "state": "OPEN", "updatedAt": "2019-01-01T00:00:00Z"}])
        calls, _ = self.run_main([rate(10), closed, still_open, ""], {"ISSUE_TOKEN": "bot"})
        self.assertEqual(calls[-1][0], ["issue", "comment"])

    def test_without_an_issue_token_it_only_warns(self):
        os.environ.pop("ISSUE_TOKEN", None)
        calls, summary = self.run_main([rate(10)], {"ISSUE_TOKEN": ""})
        self.assertEqual(len(calls), 1)
        self.assertIn("budget low", summary)

    def test_an_unreadable_budget_never_fails(self):
        calls, summary = self.run_main([OSError("boom")])
        self.assertEqual(summary, "")


if __name__ == "__main__":
    unittest.main()
