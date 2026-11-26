"""The retired PR merge-tree publisher stays fail-closed.

The old pull_request_target workflow used a workflows-write App token to put
an untrusted pull-request merge commit on a real cmux-tui-pin-* branch. The
push then loaded the untrusted commit's workflows with OIDC and artifact
publication authority. Until a credential-free build plus trusted
default-branch publisher replaces it, the helper refuses. The disabled
dispatch-only workflow stub (cmux-next-pr-merge-tree.yml) that only failed is
gone (ci-v2 step 11): with no workflow, nothing can grant it a trigger.
"""

import os
import pathlib
import subprocess
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/publish_pr_merge_tree.py"
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


if __name__ == "__main__":
    unittest.main()
