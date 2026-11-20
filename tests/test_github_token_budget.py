#!/usr/bin/env python3
"""scripts/ci/github_token_budget.py warns only when the GITHUB_TOKEN budget is low."""
from contextlib import redirect_stdout
from datetime import datetime, timezone
import io
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
    def run_main(self, answers, env=None, argv=()):
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
            self.assertEqual(budget.main(list(argv)), 0)
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

    def test_notice_prints_one_parseable_annotation(self):
        out = io.StringIO()
        with redirect_stdout(out):
            calls, summary = self.run_main([rate(640)], {"ISSUE_TOKEN": ""}, ["--notice"])
        self.assertEqual(calls, [(["api", "rate_limit"], "own")])
        lines = [l for l in out.getvalue().splitlines() if l.startswith("::notice")]
        self.assertEqual(len(lines), 1)
        prefix = "::notice title=github-token-budget::"
        self.assertTrue(lines[0].startswith(prefix))
        body = json.loads(lines[0][len(prefix):])
        self.assertEqual({k: body[k] for k in ("remaining", "limit", "used", "reset")},
                         {"remaining": 640, "limit": 1000, "used": 360, "reset": 1_800_000_000})
        read_at = datetime.fromisoformat(body["read_at"].replace("Z", "+00:00"))
        self.assertLess(abs((datetime.now(timezone.utc) - read_at).total_seconds()), 60)
        # A message with a newline, % or "::" would break the workflow command.
        self.assertFalse(any(c in lines[0][len(prefix):] for c in "%\r\n") or "::" in lines[0][len(prefix):])
        self.assertEqual(summary, "")

    def test_notice_with_a_low_budget_also_warns(self):
        out = io.StringIO()
        with redirect_stdout(out):
            self.run_main([rate(150)], {"ISSUE_TOKEN": ""}, ["--notice"])
        text = out.getvalue()
        self.assertIn('::notice title=github-token-budget::{"remaining":150,', text)
        self.assertIn("::warning title=GITHUB_TOKEN budget low::", text)

    def test_without_notice_no_notice_is_printed(self):
        out = io.StringIO()
        with redirect_stdout(out):
            self.run_main([rate(640)])
        self.assertNotIn("::notice", out.getvalue())

    def test_the_hosted_light_rescue_prints_the_notice_first_and_never_fails_on_it(self):
        workflow = (ROOT / ".github/workflows/ci-hosted-light-rescue.yml").read_text()
        steps = workflow.split("    steps:\n", 1)[1]
        budget_at = steps.index("scripts/ci/github_token_budget.py --notice")
        self.assertLess(budget_at, steps.index("hosted_light_rescue.py"))
        step = steps[steps.rindex("      - name:", 0, budget_at):budget_at]
        self.assertIn("continue-on-error: true", step)
        self.assertIn("BUDGET_TOKEN: ${{ github.token }}", step)
        self.assertNotIn("ISSUE_TOKEN", step)

    def test_an_unreadable_budget_never_fails(self):
        calls, summary = self.run_main([OSError("boom")])
        self.assertEqual(summary, "")


if __name__ == "__main__":
    unittest.main()
