#!/usr/bin/env python3
"""Exercise the review drift workflow's issue body construction offline."""

import json
from pathlib import Path
import subprocess
import textwrap
import unittest
import importlib.util
import contextlib
import io
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/feature-flag-review-drift.yml"


class FeatureFlagReviewDriftIssueTests(unittest.TestCase):
    def run_monitor(self, reports, fail_comments=0, initial_issue=None):
        workflow = WORKFLOW.read_text()
        script = textwrap.dedent(workflow.split("          script: |\n", 1)[1])
        harness = """
const writes = [];
let issue = INITIAL_ISSUE;
let labelExists = false;
let failComments = FAIL_COMMENTS;
const reportFiles = REPORTS;
let currentReport;
const fs = {readFileSync: () => {
  if (currentReport === null) throw new Error('report file missing');
  return currentReport;
}};
const getOctokit = () => null;
const core = {warning: message => writes.push(['warning', message])};
const context = {repo: {owner: 'o', repo: 'r'}, serverUrl: 'https://github.com', runId: 1};
const github = {rest: {issues: {
  listForRepo: async () => ({data: issue && issue.state === 'open' ? [issue] : []}),
  getLabel: async () => { if (labelExists) return {}; throw Object.assign(new Error('missing'), {status: 404}); },
  createLabel: async args => { labelExists = true; writes.push(['label', args]); },
  create: async args => { writes.push(['create', args]); issue = {...args, number: 9, state: 'open'}; },
  createComment: async args => {
    if (failComments > 0) { failComments--; writes.push(['failed-comment', args]); throw Object.assign(new Error('boom'), {status: 500}); }
    writes.push(['comment', args]);
  },
  update: async args => { writes.push(['update', args]); Object.assign(issue, args); },
}}};
const run = async () => {
  for (const report of reportFiles.slice()) {
    currentReport = report;
    process.env.HEAD_SHA = String(context.runId).repeat(40);
    await (async function(require) { SCRIPT })(name => {
      if (name === 'fs') return fs;
      // The workflow arms scripts/ci/incident_report.cjs (spare tokens); its own tests cover it.
      if (name.endsWith('/scripts/ci/incident_report.cjs')) return {arm: () => {}};
      throw new Error('unexpected dependency: ' + name);
    });
    context.runId++;
  }
  process.stdout.write(JSON.stringify({writes, issue}));
};
run().catch(error => {
  console.error(error);
  // Keep the writes and issue state a failed run left behind, for the retry check.
  process.stdout.write(JSON.stringify({writes, issue, failed: String(error.message)}));
  process.exitCode = 1;
});
""".replace("REPORTS", json.dumps(reports)).replace("SCRIPT", script) \
            .replace("INITIAL_ISSUE", json.dumps(initial_issue)).replace("FAIL_COMMENTS", str(fail_comments))
        # Only a run told to fail a comment may fail; any other error still fails the test.
        result = subprocess.run(["node", "-e", harness], capture_output=True, text=True, check=not fail_comments)
        return json.loads(result.stdout)

    def test_nonempty_report_creates_then_updates_one_issue(self):
        report = [{
            "key": "soon-release",
            "source": "Sources/FeatureFlags.swift",
            "reviewBy": "2026-10-05",
            "daysRemaining": 5,
        }]
        result = self.run_monitor([json.dumps(report), json.dumps(report)])
        self.assertEqual([kind for kind, _ in result["writes"]], ["label", "create", "update"])
        self.assertIn("soon-release", result["issue"]["body"])
        self.assertIn("Sources/FeatureFlags.swift", result["issue"]["body"])
        self.assertIn("Approaching", result["issue"]["body"])

    def test_empty_report_closes_existing_issue(self):
        report = [{
            "key": "soon-release",
            "source": "Sources/FeatureFlags.swift",
            "reviewBy": "2026-10-05",
            "daysRemaining": 5,
        }]
        result = self.run_monitor([json.dumps(report), "[]"])
        self.assertEqual([kind for kind, _ in result["writes"]], ["label", "create", "comment", "update"])
        self.assertEqual(result["issue"]["state"], "closed")
        comment = next(args["body"] for kind, args in result["writes"] if kind == "comment")
        self.assertIn("No valid feature flag review dates are approaching or already expired", comment)

    def test_expired_report_keeps_issue_open_and_identifies_expiration(self):
        report = [{"key": "expired-release", "source": "Example.swift",
                   "reviewBy": "2026-09-29", "daysRemaining": -1}]
        result = self.run_monitor([json.dumps(report)])
        self.assertEqual(result["issue"]["state"], "open")
        self.assertIn("Already expired", result["issue"]["body"])
        self.assertIn("-1", result["issue"]["body"])

    def test_owner_is_pinged_once_when_a_flag_expires(self):
        def day(days):
            return json.dumps([{"key": "lapsing-release", "source": "Example.swift",
                                "owner": "flag-owner", "reviewBy": "2026-10-18",
                                "daysRemaining": days}])
        result = self.run_monitor([day(1), day(-1), day(-2)])
        self.assertIn("@flag-owner", result["issue"]["body"])
        comments = [args["body"] for kind, args in result["writes"] if kind == "comment"]
        self.assertEqual(len(comments), 1, comments)
        self.assertIn("@flag-owner", comments[0])
        self.assertIn("lapsing-release", comments[0])

    def test_a_failed_owner_ping_is_retried_on_the_next_run(self):
        # #40423: the body must not record a flag as notified before its mention is delivered.
        def day(days):
            return json.dumps([{"key": "lapsing-release", "source": "Example.swift",
                                "owner": "flag-owner", "reviewBy": "2026-10-18",
                                "daysRemaining": days}])
        approaching = ("| Key | Source file | Owner | reviewBy | Days remaining | Status |\n"
                       "| --- | --- | --- | --- | ---: | --- |\n"
                       "| `lapsing-release` | `Example.swift` | @flag-owner | 2026-10-18 | 1 | Approaching |")
        open_issue = {"number": 9, "state": "open", "body": approaching}
        # The real client rejects on a 500: the run fails, leaving the issue body it wrote.
        failed = self.run_monitor([day(-1)], fail_comments=1, initial_issue=open_issue)
        self.assertEqual(failed.get("failed"), "boom")
        self.assertNotIn("Already expired", failed["issue"]["body"])
        result = self.run_monitor([day(-1)], initial_issue={**open_issue, "body": failed["issue"]["body"]})
        comments = [args["body"] for kind, args in result["writes"] if kind == "comment"]
        self.assertEqual(len(comments), 1, comments)
        self.assertIn("@flag-owner", comments[0])

    def test_failed_payloads_never_close_an_open_issue(self):
        report = [{"key": "soon-release", "source": "Example.swift",
                   "reviewBy": "2026-10-05", "daysRemaining": 5}]
        for failed in (None, "not JSON", '{"error": "collector failed"}'):
            with self.subTest(failed=failed):
                result = self.run_monitor([json.dumps(report), failed])
                self.assertEqual(result["issue"]["state"], "open")
                comments = [args["body"] for kind, args in result["writes"] if kind == "comment"]
                self.assertEqual(len(comments), 1)
                self.assertIn("report failed", comments[0])

    def test_failed_payload_opens_an_issue_when_none_exists(self):
        result = self.run_monitor(["{\"error\": \"collector failed\"}"])
        self.assertEqual(result["issue"]["state"], "open")
        self.assertIn("report failed", result["issue"]["body"])

    def test_report_main_error_payload_is_rejected_by_workflow(self):
        spec = importlib.util.spec_from_file_location(
            "report", ROOT / "scripts/report-feature-flag-review-lead-time.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        output = io.StringIO()
        with mock.patch.object(module, "_load_linter", return_value=object()), \
             contextlib.redirect_stdout(output):
            self.assertEqual(module.main(["--json"]), 0)
        report = [{"key": "soon-release", "source": "Example.swift",
                   "reviewBy": "2026-10-05", "daysRemaining": 5}]
        result = self.run_monitor([json.dumps(report), output.getvalue()])
        self.assertEqual(result["issue"]["state"], "open")


if __name__ == "__main__":
    unittest.main()
