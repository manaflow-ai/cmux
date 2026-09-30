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
    def run_monitor(self, reports):
        workflow = WORKFLOW.read_text()
        script = textwrap.dedent(workflow.split("          script: |\n", 1)[1])
        harness = """
const writes = [];
let issue = null;
let labelExists = false;
const reportFiles = REPORTS;
let currentReport;
const fs = {readFileSync: () => {
  if (currentReport === null) throw new Error('report file missing');
  return currentReport;
}};
const core = {warning: message => writes.push(['warning', message])};
const context = {repo: {owner: 'o', repo: 'r'}, serverUrl: 'https://github.com', runId: 1};
const github = {rest: {issues: {
  listForRepo: async () => ({data: issue && issue.state === 'open' ? [issue] : []}),
  getLabel: async () => { if (labelExists) return {}; throw Object.assign(new Error('missing'), {status: 404}); },
  createLabel: async args => { labelExists = true; writes.push(['label', args]); },
  create: async args => { writes.push(['create', args]); issue = {...args, number: 9, state: 'open'}; },
  createComment: async args => writes.push(['comment', args]),
  update: async args => { writes.push(['update', args]); Object.assign(issue, args); },
}}};
const run = async () => {
  for (const report of reportFiles.slice()) {
    currentReport = report;
    process.env.HEAD_SHA = String(context.runId).repeat(40);
    await (async function(require) { SCRIPT })(name => {
      if (name === 'fs') return fs;
      throw new Error('unexpected dependency: ' + name);
    });
    context.runId++;
  }
  process.stdout.write(JSON.stringify({writes, issue}));
};
run().catch(error => { console.error(error); process.exitCode = 1; });
""".replace("REPORTS", json.dumps(reports)).replace("SCRIPT", script)
        result = subprocess.run(["node", "-e", harness], capture_output=True, text=True, check=True)
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
