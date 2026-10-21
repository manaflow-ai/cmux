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

Once the new pin is up it cancels the artifacts runs still queued or running
for the same pull request's older merge commits (21 of 29 pin runs on
2026-10-20/21 were cancelled by hand), and only those: never the current pin's
run, another pull request's pin, a non-pin run, a pin it cannot attribute to
this pull request, or one whose cmux-tui tree may be the new merge's own.
"""

import base64
import http.server
import json
import os
import pathlib
import subprocess
import sys
import threading
import unittest
import urllib.parse

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/publish_pr_merge_tree.py"
WORKFLOW = ROOT / ".github/workflows/cmux-next-pr-merge-tree.yml"
HEAD = "a" * 40
MERGE = "b" * 40
PIN = f"cmux-tui-pin-{MERGE[:12]}"
BASE = "e" * 40
OLD_HEAD = "1" * 40
OLD_MERGE = "2" * 40
OTHER_HEAD = "3" * 40
OTHER_MERGE = "4" * 40
NEW_TREE = "5" * 40
OLD_TREE = "6" * 40
SAME_KEY_TREE = "7" * 40
INPUTS = """# Files whose contents determine the cmux-next cmux-tui tree key.
tree cmux-tui
gitlink ghostty
gitlink ghostty-next
blob scripts/ci/macos-cross.sh
tree first-party-apps/cloud/server
"""
TREES = {
    NEW_TREE: {"cmux-tui": "c" * 40, "ghostty": "8" * 40, "ghostty-next": "9" * 40, "scripts": "a1" * 20},
    # The older merge built another cmux-tui tree: another key.
    OLD_TREE: {"cmux-tui": "d" * 40, "ghostty": "8" * 40, "ghostty-next": "9" * 40, "scripts": "a1" * 20},
    # Only non-whole inputs differ: the key may be the new merge's own.
    SAME_KEY_TREE: {"cmux-tui": "c" * 40, "ghostty": "8" * 40, "ghostty-next": "9" * 40, "scripts": "a2" * 20},
}


def merge_message(head, base=BASE):
    return f"Merge {head} into {base}\n"


def pin_run(run_id, sha, status="queued", head=OLD_HEAD, branch=None, tree=OLD_TREE):
    return {"id": run_id, "status": status, "event": "push", "head_sha": sha,
            "head_branch": branch or f"cmux-tui-pin-{sha[:12]}",
            "head_commit": {"id": sha, "tree_id": tree, "message": merge_message(head)}}


def job(name, status, conclusion=None):
    return {"name": name, "status": status, "conclusion": conclusion}


def merge_commit(head, tree, base=BASE):
    return {"parents": [base, head], "message": merge_message(head, base), "tree": tree}


COMMITS = {
    MERGE: merge_commit(HEAD, NEW_TREE),
    OLD_MERGE: merge_commit(OLD_HEAD, OLD_TREE),
    OTHER_MERGE: merge_commit(OTHER_HEAD, OLD_TREE),
}


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
        elif self.path.startswith("/repos/o/r/actions/workflows/cmux-tui-artifacts.yml/runs?"):
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            if query.get("event") != ["push"] or "status" not in query:
                self.reply(400, {"message": "unexpected runs query"})
            elif state.get("list_status"):
                self.reply(state["list_status"], {"message": "Server Error"})
            else:
                runs = [run for run in state.get("active_runs", []) if run["status"] == query["status"][0]]
                self.reply(200, {"total_count": len(runs), "workflow_runs": runs})
        elif self.path.startswith("/repos/o/r/contents/scripts/cmux-next/cmux-tui-tree-inputs.txt?ref="):
            self.reply(200, {"encoding": "base64", "content": base64.b64encode(INPUTS.encode()).decode()})
        elif self.path.startswith("/repos/o/r/commits/") and self.path.endswith("/pulls?per_page=100"):
            sha = self.path.split("/")[5]
            if state.get("pulls_status"):
                self.reply(state["pulls_status"], {"message": "Server Error"})
            else:
                self.reply(200, [{"number": number, "state": "open", "head": {"sha": "f" * 40}}
                                 for number in state.get("pulls_of", {OLD_HEAD: [7], HEAD: [7]}).get(sha, [])])
        elif self.path.startswith("/repos/o/r/commits/") and self.path.split("/")[5] in COMMITS:
            commit = COMMITS[self.path.split("/")[5]]
            self.reply(200, {"sha": self.path.split("/")[5], "parents": [{"sha": sha} for sha in commit["parents"]],
                             "commit": {"message": commit["message"], "tree": {"sha": commit["tree"]}}})
        elif self.path.startswith("/repos/o/r/git/trees/") and self.path.split("/")[6] in TREES:
            entries = TREES[self.path.split("/")[6]]
            self.reply(200, {"truncated": False, "tree": [
                {"path": name, "type": "commit" if name.startswith("ghostty") else "tree", "sha": sha}
                for name, sha in entries.items()]})
        elif self.path.startswith("/repos/o/r/actions/runs/") and "/jobs?" in self.path:
            run_id = int(self.path.split("/")[6])
            if state.get("jobs_status"):
                self.reply(state["jobs_status"], {"message": "Server Error"})
            else:
                jobs = state.get("jobs_of", {}).get(run_id, [job("cmux-tui tree preflight", "completed", "success")])
                self.reply(200, {"total_count": len(jobs), "jobs": jobs})
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
        elif self.path.startswith("/repos/o/r/actions/runs/") and self.path.endswith("/cancel"):
            self.reply(202, {})
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


def cancelled(posts):
    return [post[1].split("/")[6] for post in posts if post[1].endswith("/cancel")]


class SupersededPinTests(unittest.TestCase):
    """After the new pin, the older pins of the same pull request stop."""

    publish = PublisherTests.publish

    def test_the_previous_pin_queued_is_cancelled_after_the_new_pin(self):
        result, posts = self.publish(active_runs=[pin_run(101, OLD_MERGE, "queued")])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(cancelled(posts), ["101"], result.stdout)
        # The new pin is published first, and the cancel uses GITHUB_TOKEN.
        self.assertEqual(posts[0][1], "/repos/o/r/git/refs")
        self.assertEqual(FakeGitHub.tokens[-1], ("/repos/o/r/actions/runs/101/cancel", "Bearer actions-token"))
        self.assertIn("cancelled", result.stdout)
        self.assertIn("101", result.stdout)

    def test_the_previous_pin_in_progress_is_cancelled(self):
        for status in ("in_progress", "waiting", "pending"):
            result, posts = self.publish(active_runs=[pin_run(102, OLD_MERGE, status)])
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(cancelled(posts), ["102"], status)

    def test_older_pins_are_cancelled_when_the_current_merge_already_has_a_run(self):
        result, posts = self.publish(runs=[{"status": "in_progress", "conclusion": None}],
                                     active_runs=[pin_run(103, OLD_MERGE, "queued")])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(cancelled(posts), ["103"], result.stdout)

    def test_the_current_pins_runs_are_never_cancelled(self):
        # The new merge commit's own run, and a pin of another merge of the
        # current head (an older base), are both kept.
        current_head_other_base = "0" * 40
        COMMITS[current_head_other_base] = merge_commit(HEAD, OLD_TREE, base="9" * 40)
        self.addCleanup(COMMITS.pop, current_head_other_base)
        result, posts = self.publish(active_runs=[
            pin_run(104, MERGE, "queued", head=HEAD, tree=NEW_TREE),
            pin_run(105, MERGE, "in_progress", head=HEAD, tree=NEW_TREE),
            pin_run(106, current_head_other_base, "queued", head=HEAD),
        ])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(cancelled(posts), [], result.stdout)

    def test_a_pin_of_another_pull_request_is_untouched(self):
        result, posts = self.publish(active_runs=[pin_run(107, OTHER_MERGE, "queued", head=OTHER_HEAD)],
                                     pulls_of={OTHER_HEAD: [8], HEAD: [7]})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(cancelled(posts), [], result.stdout)

    def test_a_pin_whose_head_a_stacked_pull_request_shares_is_untouched(self):
        # #8 is stacked under #7: its head is in both, so the pin may be #8's own.
        result, posts = self.publish(active_runs=[pin_run(115, OLD_MERGE, "queued")],
                                     pulls_of={OLD_HEAD: [8, 7], HEAD: [7]})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(cancelled(posts), [], result.stdout)

    def test_a_pin_run_that_started_publishing_is_kept(self):
        # cmux-tui-artifacts.yml never cancels a started run so no write-once upload stops halfway: a
        # cancel mid-publish leaves a prefix without its manifest or completion, and the next run of
        # that key or commit fails on it. Nor one whose preflight runs (it may hold the tree claim
        # a deferred run waits on).
        preflight_done = job("cmux-tui tree preflight", "completed", "success")
        for jobs in (
            [preflight_done, job("publish to R2", "in_progress")],
            [preflight_done, job("publish to R2", "completed", "success"), job("publish tree-addressed cmux-tui", "queued")],
            [preflight_done, job("publish tree-addressed cmux-tui", "in_progress")],
            [preflight_done, job("mark the published tree as daemon-tested", "in_progress")],
            [job("cmux-tui tree preflight", "in_progress")],
        ):
            result, posts = self.publish(active_runs=[pin_run(116, OLD_MERGE, "in_progress")], jobs_of={116: jobs})
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(cancelled(posts), [], jobs)

    def test_a_pin_run_before_its_publish_is_cancelled(self):
        preflight_done = job("cmux-tui tree preflight", "completed", "success")
        for jobs in (
            [],  # queued: no job has started
            [job("cmux-tui tree preflight", "queued")],
            [preflight_done, job("build / build aarch64-apple-darwin", "in_progress"),
             job("cmux_next_ daemon tests (macOS)", "queued"), job("publish to R2", "queued")],
            [preflight_done, job("publish skipped (branch not allowed)", "completed", "skipped")],
        ):
            result, posts = self.publish(active_runs=[pin_run(117, OLD_MERGE, "in_progress")], jobs_of={117: jobs})
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(cancelled(posts), ["117"], jobs)

    def test_a_failed_jobs_lookup_keeps_the_run(self):
        result, posts = self.publish(active_runs=[pin_run(118, OLD_MERGE, "in_progress")], jobs_status=500)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(cancelled(posts), [], result.stdout)

    def test_non_pin_runs_are_untouched(self):
        runs = [pin_run(108, OLD_MERGE, "queued", branch=branch)
                for branch in ("feat-cmux-next", "main", "nightly", "lane/x", "next-batch/1")]
        result, posts = self.publish(active_runs=runs)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(cancelled(posts), [], result.stdout)

    def test_a_failed_run_listing_cancels_nothing_and_the_publish_still_succeeds(self):
        result, posts = self.publish(list_status=500, active_runs=[pin_run(109, OLD_MERGE, "queued")])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(posts, [("POST", "/repos/o/r/git/refs", {"ref": f"refs/heads/{PIN}", "sha": MERGE})])
        self.assertIn("cancel", result.stdout.lower())

    def test_an_unattributable_pin_is_untouched(self):
        not_a_merge = "0" * 40
        COMMITS[not_a_merge] = {"parents": [BASE], "message": merge_message(OLD_HEAD), "tree": OLD_TREE}
        self.addCleanup(COMMITS.pop, not_a_merge)
        for state in (
            # A pin of a commit that is not GitHub's merge commit (pin-cmux-tui.sh, next_batch.py).
            {"active_runs": [pin_run(110, not_a_merge, "queued")]},
            # The pull request lookup fails.
            {"active_runs": [pin_run(111, OLD_MERGE, "queued")], "pulls_status": 500},
            # No pull request has the older head (a force push dropped it).
            {"active_runs": [pin_run(112, OLD_MERGE, "queued")], "pulls_of": {HEAD: [7]}},
            # The commit cannot be read.
            {"active_runs": [pin_run(113, "f" * 40, "queued")]},
        ):
            result, posts = self.publish(**state)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(cancelled(posts), [], state)

    def test_an_older_pin_that_may_share_the_new_tree_key_is_kept(self):
        same_key = "0" * 40
        COMMITS[same_key] = merge_commit(OLD_HEAD, SAME_KEY_TREE)
        self.addCleanup(COMMITS.pop, same_key)
        result, posts = self.publish(active_runs=[pin_run(114, same_key, "queued", tree=SAME_KEY_TREE)])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(cancelled(posts), [], result.stdout)


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
