"""The retired PR merge-tree publisher stays fail-closed.

The old pull_request_target workflow used a workflows-write App token to put
an untrusted pull-request merge commit on a real cmux-tui-pin-* branch. The
push then loaded the untrusted commit's workflows with OIDC and artifact
publication authority. Until a credential-free build plus trusted
default-branch publisher replaces it, both the workflow and helper refuse.
"""

import os
import pathlib
import subprocess
import sys
import unittest

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/publish_pr_merge_tree.py"
WORKFLOW = ROOT / ".github/workflows/cmux-next-pr-merge-tree.yml"
HEAD = "a" * 40


class PublisherTests(unittest.TestCase):
    def test_refuses_to_turn_a_pull_request_merge_commit_into_a_push_event(self):
        env = dict(
            os.environ,
            GH_TOKEN="actions-token",
            CMUX_PR_TREE_PIN_TOKEN="app-token",
            GITHUB_REPOSITORY="o/r",
            # Any network attempt would fail; the helper must refuse before it.
            GITHUB_API_URL="http://127.0.0.1:1",
        )
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "7", HEAD],
            env=env,
            text=True,
            capture_output=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("untrusted merge commit", result.stdout)

    def test_rejects_malformed_arguments(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "not-a-pr", "short"],
            text=True,
            capture_output=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("usage:", result.stderr)


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.text = WORKFLOW.read_text()
        self.workflow = yaml.safe_load(self.text)
        self.on = self.workflow.get("on", self.workflow.get(True))

    def test_has_no_automatic_untrusted_trigger_or_privilege(self):
        self.assertEqual(list(self.on), ["workflow_dispatch"])
        self.assertEqual(self.workflow.get("permissions"), {})
        (job,) = self.workflow["jobs"].values()
        self.assertEqual(job.get("permissions"), {})
        self.assertNotIn("environment", job)
        self.assertNotIn("create-github-app-token", self.text)
        self.assertNotIn("secrets.", self.text)
        self.assertNotIn("actions/checkout", self.text)


if __name__ == "__main__":
    unittest.main()
