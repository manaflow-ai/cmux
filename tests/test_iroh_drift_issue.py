#!/usr/bin/env python3
"""Exercise the drift workflow's issue writes with an offline GitHub stub."""

import json
from pathlib import Path
import subprocess
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/iroh-v2-production-drift.yml"


class DriftIssueTests(unittest.TestCase):
    def run_monitor(self, outcomes):
        workflow = WORKFLOW.read_text()
        script = textwrap.dedent(workflow.split("          script: |\n", 1)[1].split("      - name:", 1)[0])
        harness = """
const writes = [];
let issue = null;
const fs = {existsSync: () => true, readFileSync: () => 'different rules'};
const context = {repo: {owner: 'o', repo: 'r'}, serverUrl: 'https://github.com', runId: 1};
const github = {rest: {issues: {
  listForRepo: async () => ({data: issue && issue.state === 'open' ? [issue] : []}),
  getLabel: async () => ({}),
  create: async args => { writes.push(['create', args]); issue = {...args, number: 9, state: 'open'}; },
  createComment: async args => writes.push(['comment', args]),
  update: async args => { writes.push(['update', args]); Object.assign(issue, args); },
}}};
const run = async () => {
  for (const outcome of OUTCOMES) {
    process.env.DRIFT_OUTCOME = outcome;
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
""".replace("OUTCOMES", json.dumps(outcomes)).replace("SCRIPT", script)
        result = subprocess.run(["node", "-e", harness], capture_output=True, text=True, check=True)
        return json.loads(result.stdout)

    def test_repeated_drift_updates_the_issue_without_appending_comments(self):
        result = self.run_monitor(["failure", "failure", "failure"])
        self.assertEqual([kind for kind, _ in result["writes"]], ["create", "update", "update"])
        self.assertIn("actions/runs/3", result["issue"]["body"])

    def test_recovery_comments_once_and_closes_the_issue(self):
        result = self.run_monitor(["failure", "success", "success"])
        self.assertEqual([kind for kind, _ in result["writes"]], ["create", "comment", "update"])
        self.assertEqual(result["issue"]["state"], "closed")

    def test_success_with_no_open_issue_writes_nothing(self):
        self.assertEqual(self.run_monitor(["success"])["writes"], [])

    def test_new_drift_after_recovery_opens_a_new_issue(self):
        result = self.run_monitor(["failure", "success", "failure"])
        self.assertEqual([kind for kind, _ in result["writes"]], ["create", "comment", "update", "create"])
        self.assertEqual(result["issue"]["state"], "open")


if __name__ == "__main__":
    unittest.main()
