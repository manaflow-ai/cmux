#!/usr/bin/env python3
"""Exercise the review drift workflow's issue body construction offline."""

import json
from pathlib import Path
import subprocess
import textwrap
import unittest


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
const fs = {readFileSync: () => JSON.stringify(reportFiles.shift())};
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
        result = self.run_monitor([report, report])
        self.assertEqual([kind for kind, _ in result["writes"]], ["label", "create", "update"])
        self.assertIn("soon-release", result["issue"]["body"])
        self.assertIn("Sources/FeatureFlags.swift", result["issue"]["body"])

    def test_empty_report_closes_existing_issue(self):
        report = [{
            "key": "soon-release",
            "source": "Sources/FeatureFlags.swift",
            "reviewBy": "2026-10-05",
            "daysRemaining": 5,
        }]
        result = self.run_monitor([report, []])
        self.assertEqual([kind for kind, _ in result["writes"]], ["label", "create", "comment", "update"])
        self.assertEqual(result["issue"]["state"], "closed")


if __name__ == "__main__":
    unittest.main()
