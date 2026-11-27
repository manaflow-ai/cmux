#!/usr/bin/env python3
"""debug-labs-keys-dispatch.yml starts feat-cmux-next's report only when that branch has the file.

cmux#54280 moved debug-labs-keys-report.yml off feat-cmux-next to a private repo (2026-11-24); every daily
dispatch since failed "Workflow does not have 'workflow_dispatch' trigger" (runs 45626408061, 45831824446).
The step's script runs here under node with a fake `github`: a 404 skips green, any other error fails,
and a present file is dispatched.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/debug-labs-keys-dispatch.yml"

HARNESS = r"""
const [status] = process.argv.slice(2);
const calls = [];
const github = { rest: {
  repos: { getContent: async () => { calls.push('getContent'); if (status !== '200') { const e = new Error('x'); e.status = Number(status); throw e; } return {}; } },
  actions: {
    listWorkflowRuns: async () => { calls.push('list'); return { data: { total_count: 0, workflow_runs: [] } }; },
    createWorkflowDispatch: async () => { calls.push('dispatch'); },
  },
} };
const summary = { addRaw() { return summary; }, async write() {} };
const core = { notice: () => {}, summary };
const context = { repo: { owner: 'o', repo: 'r' } };
const script = require('fs').readFileSync(process.env.SCRIPT, 'utf8');
const run = new Function('github', 'core', 'context', 'process', 'getOctokit', 'require', `return (async () => {${script}})();`);
run(github, core, context, { env: {} }, () => ({}), require)
  .then(() => console.log(JSON.stringify({ ok: true, calls })))
  .catch((e) => console.log(JSON.stringify({ ok: false, calls, status: e.status })));
"""


def step_script() -> str:
    jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
    for job in jobs.values():
        for step in job.get("steps", []):
            if "createWorkflowDispatch" in str(step.get("with", {}).get("script", "")):
                return step["with"]["script"]
    raise AssertionError("no dispatch step")


@unittest.skipUnless(shutil.which("node"), "node is not installed")
class DispatchTests(unittest.TestCase):
    def run_with(self, status: str) -> dict:
        with tempfile.TemporaryDirectory() as tmp:
            script = Path(tmp, "script.js")
            script.write_text(step_script())
            harness = Path(tmp, "harness.js")
            harness.write_text(HARNESS)
            out = subprocess.run(["node", str(harness), status], check=True, text=True, capture_output=True,
                                 env={"SCRIPT": str(script), "PATH": "/usr/bin:/bin:/usr/local/bin"})
            return json.loads(out.stdout)

    def test_a_missing_report_file_skips_green(self):
        self.assertEqual(self.run_with("404"), {"ok": True, "calls": ["getContent"]})

    def test_any_other_error_fails(self):
        result = self.run_with("500")
        self.assertFalse(result["ok"])
        self.assertNotIn("dispatch", result["calls"])

    def test_a_present_report_file_is_dispatched(self):
        result = self.run_with("200")
        self.assertTrue(result["ok"])
        self.assertEqual(result["calls"][-1], "dispatch")


if __name__ == "__main__":
    unittest.main()
