#!/usr/bin/env python3
"""cmux-next-pr-pipeline-linux-batch.yml runs every step of pr-pipeline.yml's linux job, and a pull request leaves the
steps only a whole-directory input or the pipeline's own files reach to it (ci/run run --job linux --pr-scope)."""
from __future__ import annotations

import copy
import json
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import ci_steps  # noqa: E402

PIPELINE = ROOT / ".github/workflows/pr-pipeline.yml"
BATCH = ROOT / ".github/workflows/cmux-next-pr-pipeline-linux-batch.yml"
POST_MERGE = ROOT / ".github/workflows/cmux-next-post-merge.yml"
MANIFEST = ROOT / ".github/post-merge-batch.json"


def job_of(path: Path) -> dict:
    return yaml.safe_load(path.read_text())["jobs"]["linux"]


def table(steps: dict) -> ci_steps.Table:
    return ci_steps.parse({"jobs": {"linux": "l", "advisory": "a"},
                           "step": {name: {"job": "linux", "run": "true", **raw} for name, raw in steps.items()}})


class PrPipelineLinuxBatch(unittest.TestCase):
    def test_the_batch_job_has_the_pipeline_jobs_steps(self) -> None:
        want = copy.deepcopy(job_of(PIPELINE)["steps"])
        got = job_of(BATCH)["steps"]
        self.assertEqual(len(want), len(got))
        for w, g in zip(want, got):
            if w.get("uses", "").startswith("actions/checkout"):
                w["with"] = {"ref": "${{ inputs.sha || '' }}", **w["with"]}
            self.assertEqual(w, g, w.get("name"))

    def test_the_batch_runs_every_step_and_the_pull_request_its_scope(self) -> None:
        run = next(s for s in job_of(PIPELINE)["steps"] if s.get("id") == "run")
        self.assertIn("--pr-scope", run["run"])
        scope = run["env"]["CI_PR_PIPELINE_LINUX_PR_SCOPE"]
        # Only a pull request narrows; the batch's workflow_dispatch and workflow_call (from a dispatch) run all.
        self.assertIn("github.event_name == 'pull_request'", scope)
        self.assertIn("vars.CI_PR_PIPELINE_LINUX_PR_SCOPE", scope)
        self.assertTrue(scope.endswith("|| '0' }}"), scope)
        self.assertEqual(job_of(BATCH)["timeout-minutes"], job_of(PIPELINE)["timeout-minutes"])
        self.assertEqual(job_of(BATCH)["permissions"], job_of(PIPELINE)["permissions"])

    def test_the_post_merge_batch_calls_it(self) -> None:
        suite = json.loads(MANIFEST.read_text())["suites"]["pr-pipeline-linux"]
        self.assertEqual(suite["workflow"], BATCH.name)
        self.assertEqual(suite["paths"], [])
        jobs = yaml.safe_load(POST_MERGE.read_text())["jobs"]
        self.assertEqual(jobs["pr-pipeline-linux"]["uses"], f"./.github/workflows/{BATCH.name}")
        self.assertEqual(jobs["pr-pipeline-linux"]["permissions"], job_of(PIPELINE)["permissions"])
        self.assertIn("pr-pipeline-linux", jobs["judge"]["needs"])

    def test_pr_scope_routes_by_named_inputs_only(self) -> None:
        t = table({
            "named": {"inputs": ["scripts/x.py", "web/**"]},
            "dir": {"inputs": ["web/**"]},
            "one-dir": {"inputs": ["scripts/*remote*"]},
            "kept": {"inputs": ["**"], "pr_scope": False},
        })
        self.assertEqual(ci_steps.route(t, ["web/a.ts"], pr_scope=True), {"linux": ["kept"]})
        self.assertEqual(ci_steps.route(t, ["web/a.ts"]), {"linux": ["named", "dir", "kept"]})
        self.assertEqual(ci_steps.route(t, ["scripts/x.py"], pr_scope=True), {"linux": ["named", "kept"]})
        self.assertEqual(ci_steps.route(t, ["scripts/a_remote_b"], pr_scope=True), {"linux": ["one-dir", "kept"]})
        # A change to the pipeline routes every step on the base, only its own steps on a pull request.
        self.assertEqual(ci_steps.route(t, ["ci/steps.toml"], pr_scope=True), {"linux": ["kept"]})
        self.assertEqual(ci_steps.route(t, ["ci/steps.toml"]), {"linux": ["named", "dir", "one-dir", "kept"]})
        # An unknown diff still routes every step.
        self.assertEqual(ci_steps.route(t, None, pr_scope=True), {"linux": ["named", "dir", "one-dir", "kept"]})

    def test_pr_scope_does_not_change_a_steps_result_key(self) -> None:
        a = table({"s": {"inputs": ["web/**"]}})
        b = table({"s": {"inputs": ["web/**"], "pr_scope": False}})
        args = ([], "tree", ["web/a.ts"], {})
        self.assertEqual(ci_steps.step_key(a.steps["s"], a, *args), ci_steps.step_key(b.steps["s"], b, *args))

    def test_the_security_steps_keep_their_whole_route(self) -> None:
        steps = ci_steps.load().steps
        self.assertFalse(steps["security-holes"].pr_scope)
        self.assertFalse(steps["cache-receipts"].pr_scope)

    def test_a_gate_on_the_pull_requests_own_diff_keeps_its_whole_route(self) -> None:
        # package-conventions-gate fails only on what the pull request adds (--pr); the batch has no pull request.
        table = ci_steps.load()
        self.assertFalse(table.steps["package-conventions-gate"].pr_scope)
        routed = ci_steps.route(table, ["ios/Sources/App.swift"], pr_scope=True).get("linux", [])
        self.assertIn("package-conventions-gate", routed)


if __name__ == "__main__":
    unittest.main()
