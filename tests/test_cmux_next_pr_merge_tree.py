"""The feat-cmux-next pull request merge-tree publisher (cmux-next-pr-merge-tree.yml).

A pull request that changes a cmux-tui tree input needs its merge tree
published before cmux-next's same-tree checks can run; its own pull_request
token cannot start that (HTTP 403), so the same-tree check went red on 33 pull
requests in a day. The publisher runs from main as pull_request_target,
executes none of the pull request's code, and against a fake GitHub API:
points cmux-tui-pin-<sha12> at the merge commit with the release App's token
(GITHUB_TOKEN gets 403 on a ref at a feat-cmux-next commit), whose push starts
the artifacts run; dispatches that run with GITHUB_TOKEN only for a pin that
already existed; and publishes nothing when a run already publishes the tree,
for a conflict or for a newer head.
"""

import http.server
import json
import os
import pathlib
import subprocess
import sys
import threading
import unittest

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/publish_pr_merge_tree.py"
WORKFLOW = ROOT / ".github/workflows/cmux-next-pr-merge-tree.yml"
HEAD = "a" * 40
MERGE = "b" * 40
PIN = f"cmux-tui-pin-{MERGE[:12]}"


class FakeGitHub(http.server.BaseHTTPRequestHandler):
    """Answers the calls the publisher makes from `state`, and records them."""

    state: dict = {}
    calls: list = []
    tokens: list = []

    def log_message(self, *_args):
        pass

    def reply(self, status, body=None):
        data = b"" if body is None else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.calls.append(("GET", self.path))
        state = self.state
        if self.path == "/repos/o/r/pulls/7":
            mergeable = state["mergeable"].pop(0) if len(state["mergeable"]) > 1 else state["mergeable"][0]
            self.reply(200, {"head": {"sha": state.get("head", HEAD)}, "mergeable": mergeable,
                             "merge_commit_sha": MERGE if mergeable else None})
        elif self.path.startswith("/repos/o/r/actions/workflows/cmux-tui-artifacts.yml/runs?head_sha="):
            self.reply(200, {"workflow_runs": state.get("runs", [])})
        elif self.path == f"/repos/o/r/git/ref/heads/{PIN}":
            existing = state.get("existing_pin")
            self.reply(200, {"object": {"sha": existing}}) if existing else self.reply(404, {"message": "Not Found"})
        else:
            self.reply(404, {"message": "Not Found"})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])) or b"null")
        self.calls.append(("POST", self.path, body))
        self.tokens.append((self.path, self.headers["Authorization"]))
        if self.path == "/repos/o/r/git/refs":
            self.reply(422, {"message": "Reference already exists"}) if self.state.get("existing_pin") else self.reply(201, {})
        elif self.path == "/repos/o/r/actions/workflows/cmux-tui-artifacts.yml/dispatches":
            self.reply(self.state.get("dispatch_status", 204))
        else:
            self.reply(404, {"message": "Not Found"})


class PublisherTests(unittest.TestCase):
    def publish(self, **state):
        FakeGitHub.state = {"mergeable": [True], **state}
        FakeGitHub.calls = []
        FakeGitHub.tokens = []
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeGitHub)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.shutdown)
        env = dict(os.environ, GH_TOKEN="actions-token", CMUX_PR_TREE_PIN_TOKEN="app-token", GITHUB_REPOSITORY="o/r",
                   GITHUB_API_URL=f"http://127.0.0.1:{server.server_address[1]}",
                   CMUX_PR_TREE_POLL_SECONDS="0", CMUX_PR_TREE_MERGE_WAIT_SECONDS="5")
        result = subprocess.run([sys.executable, str(SCRIPT), "7", HEAD], env=env, text=True,
                                capture_output=True, timeout=30)
        return result, [call for call in FakeGitHub.calls if call[0] == "POST"]

    def test_pins_the_merge_commit_with_the_app_token_and_its_push_publishes(self):
        result, posts = self.publish(mergeable=[None, None, True])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        # The App's ref is a real push, which starts the artifacts run itself.
        self.assertEqual(posts, [("POST", "/repos/o/r/git/refs", {"ref": f"refs/heads/{PIN}", "sha": MERGE})])
        self.assertEqual(FakeGitHub.tokens, [("/repos/o/r/git/refs", "Bearer app-token")])

    def test_an_active_or_published_run_is_not_dispatched_again(self):
        for run in ({"status": "in_progress", "conclusion": None}, {"status": "completed", "conclusion": "success"}):
            result, posts = self.publish(runs=[run])
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(posts, [], run)

    def test_a_failed_run_is_dispatched_again(self):
        # Its pin exists from the first attempt, so only a dispatch restarts it.
        result, posts = self.publish(existing_pin=MERGE, runs=[{"status": "completed", "conclusion": "failure"}])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual([post[1] for post in posts][-1], "/repos/o/r/actions/workflows/cmux-tui-artifacts.yml/dispatches")

    def test_an_existing_pin_at_the_merge_commit_is_dispatched_with_the_actions_token(self):
        result, posts = self.publish(existing_pin=MERGE)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(posts[-1], ("POST", "/repos/o/r/actions/workflows/cmux-tui-artifacts.yml/dispatches", {"ref": PIN}))
        self.assertEqual(FakeGitHub.tokens[-1], ("/repos/o/r/actions/workflows/cmux-tui-artifacts.yml/dispatches", "Bearer actions-token"))

    def test_a_pin_at_another_commit_fails(self):
        result, posts = self.publish(existing_pin="c" * 40)
        self.assertEqual(result.returncode, 1)
        self.assertIn("::error", result.stdout)
        self.assertNotIn("dispatches", json.dumps(posts))

    def test_a_conflict_or_a_newer_head_publishes_nothing(self):
        for state in ({"mergeable": [False]}, {"head": "d" * 40}):
            result, posts = self.publish(**state)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(posts, [], state)

    def test_a_refused_dispatch_fails_loudly(self):
        result, _ = self.publish(existing_pin=MERGE, dispatch_status=403)
        self.assertEqual(result.returncode, 1)
        self.assertIn("::error title=cmux-tui merge tree not published", result.stdout)


class WorkflowTests(unittest.TestCase):
    """The workflow holds the write token without running the pull request's code."""

    def setUp(self):
        self.text = WORKFLOW.read_text()
        self.workflow = yaml.safe_load(self.text)
        self.on = self.workflow.get("on", self.workflow.get(True))

    def test_runs_from_main_for_feat_cmux_next_pull_requests(self):
        self.assertEqual(list(self.on), ["pull_request_target"])
        self.assertEqual(self.on["pull_request_target"]["branches"], ["feat-cmux-next"])
        self.assertIn("cmux-tui/**", self.on["pull_request_target"]["paths"])

    def test_same_repository_only_and_no_pull_request_code(self):
        (job,) = self.workflow["jobs"].values()
        self.assertIn("github.event.pull_request.head.repo.full_name == github.repository", job["if"])
        self.assertEqual(self.workflow.get("permissions"), {})
        self.assertEqual(job["permissions"], {"actions": "write", "contents": "read", "pull-requests": "read"})
        # The App key lives only in this job's protected environment.
        self.assertEqual(job["environment"], "cmux-tui-merge-tree")
        (mint,) = [step for step in job["steps"] if "create-github-app-token" in step.get("uses", "")]
        self.assertEqual(mint["with"]["permission-contents"], "write")
        self.assertEqual(mint["with"]["permission-workflows"], "write")
        self.assertEqual(mint["with"]["repositories"], "${{ github.event.repository.name }}")
        checkouts = [step for step in job["steps"] if "actions/checkout" in step.get("uses", "")]
        self.assertEqual(len(checkouts), 1)
        # The trusted default branch, where the publisher script lives (a plain
        # pull_request_target checkout is the pull request's base, feat-cmux-next).
        self.assertEqual(checkouts[0]["with"]["ref"], "${{ github.event.repository.default_branch }}")
        self.assertFalse(checkouts[0]["with"]["persist-credentials"])
        self.assertNotIn("pull_request.head.ref", self.text)
        self.assertNotIn("refs/pull/", self.text)


if __name__ == "__main__":
    unittest.main()
