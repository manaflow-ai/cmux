"""The retired PR merge-tree publisher stays fail-closed.

The old pull_request_target workflow used a workflows-write App token to put
an untrusted pull-request merge commit on a real cmux-tui-pin-* branch. The
push then loaded the untrusted commit's workflows with OIDC and artifact
publication authority. Until a credential-free build plus trusted
<<<<<<< HEAD
default-branch publisher replaces it, the helper refuses. The disabled
dispatch-only workflow stub (cmux-next-pr-merge-tree.yml) that only failed is
gone (ci-v2 step 11): with no workflow, nothing can grant it a trigger.
"""

=======
default-branch publisher replaces it, both the workflow and helper refuse.
"""

import http.server
>>>>>>> origin/main
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
<<<<<<< HEAD
=======
        calls = []

        class GitHub(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_GET(self):
                calls.append((self.command, self.path))
                self.send_response(503)
                self.end_headers()

            do_POST = do_GET

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), GitHub)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        threading.Thread(target=server.serve_forever, daemon=True).start()
>>>>>>> origin/main
        env = dict(
            os.environ,
            GH_TOKEN="actions-token",
            CMUX_PR_TREE_PIN_TOKEN="app-token",
            GITHUB_REPOSITORY="o/r",
<<<<<<< HEAD
            # Any network attempt would fail; the helper must refuse before it.
            GITHUB_API_URL="http://127.0.0.1:1",
=======
            # Even valid credentials must not let a stale caller reach GitHub.
            GITHUB_API_URL=f"http://127.0.0.1:{server.server_address[1]}",
>>>>>>> origin/main
        )
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "7", HEAD],
            env=env,
            text=True,
            capture_output=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
<<<<<<< HEAD
=======
        self.assertEqual(calls, [], "retired publisher must refuse before any API request")
>>>>>>> origin/main
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
<<<<<<< HEAD
=======


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
>>>>>>> origin/main


if __name__ == "__main__":
    unittest.main()
