"""The merge receipt: which checks a pull request's head had passed when it merged."""

import argparse
import contextlib
import http.server
import importlib.util
import io
import json
import os
import pathlib
import sys
import threading
import time
import unittest
from unittest import mock

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/merge_receipt.py"
WORKFLOW = ROOT / ".github/workflows/merge-receipt.yml"
FIXTURES = ROOT / "tests/fixtures/merge_receipt"
SPEC = importlib.util.spec_from_file_location("merge_receipt", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE  # dataclasses resolve annotations through it
SPEC.loader.exec_module(MODULE)

MERGED = "2026-09-25T10:00:00Z"


def run(name, conclusion="SUCCESS", started="2026-09-25T09:00:00Z", completed="2026-09-25T09:30:00Z",
        required=False, app="github-actions"):
    return {
        "__typename": "CheckRun", "name": name, "status": "COMPLETED" if completed else "IN_PROGRESS",
        "conclusion": conclusion if completed else None, "startedAt": started, "completedAt": completed,
        "isRequired": required, "checkSuite": {"app": {"slug": app}},
    }


def snapshot(*contexts):
    return {"mergedAt": MERGED, "headRefOid": "a" * 40, "contexts": list(contexts)}


def load(name):
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


class StateAtMergeTests(unittest.TestCase):
    def test_each_check_is_read_as_of_the_merge(self):
        self.assertEqual(MODULE.state_at(run("a"), MERGED)[0], "success")
        self.assertEqual(MODULE.state_at(run("a", "FAILURE"), MERGED)[0], "failure")
        self.assertEqual(MODULE.state_at(run("a", "SKIPPED"), MERGED)[0], "skipped")
        self.assertEqual(MODULE.state_at(run("a", "NEUTRAL"), MERGED)[0], "success")
        # Finished after the merge: it was still running when the merge happened.
        self.assertEqual(MODULE.state_at(run("a", completed="2026-09-25T10:05:00Z"), MERGED)[0], "in progress")
        self.assertEqual(MODULE.state_at(run("a", completed=None), MERGED)[0], "in progress")
        self.assertEqual(MODULE.state_at(run("a", started="2026-09-25T10:01:00Z"), MERGED)[0], "not reported")
        self.assertEqual(MODULE.state_at(run("a", started=None, completed=None), MERGED)[0], "pending")

    def test_status_contexts_count_only_when_posted_before_the_merge(self):
        status = {"__typename": "StatusContext", "context": "x", "state": "SUCCESS", "createdAt": "2026-09-25T09:00:00Z"}
        self.assertEqual(MODULE.state_at(status, MERGED)[0], "success")
        self.assertEqual(MODULE.state_at(dict(status, createdAt="2026-09-25T11:00:00Z"), MERGED)[0], "not reported")

    def test_the_latest_run_started_before_the_merge_wins(self):
        checks = MODULE.checks_at_merge([
            run("Web complexity", "CANCELLED", started="2026-09-25T09:00:00Z"),
            run("Web complexity", "SUCCESS", started="2026-09-25T09:10:00Z"),
            run("Web complexity", "FAILURE", started="2026-09-25T10:10:00Z", completed="2026-09-25T10:20:00Z"),
        ], MERGED)
        self.assertEqual([(c.name, c.state) for c in checks if c.name == "Web complexity"], [("Web complexity", "success")])

    def test_jobs_that_had_not_started_are_left_out_but_ci_status_is_expected(self):
        checks = MODULE.checks_at_merge([run("macos / CLI product tests", started="2026-09-25T10:30:00Z")], MERGED)
        self.assertEqual([(c.name, c.state) for c in checks], [("ci-status", "not reported")])


class GroupingTests(unittest.TestCase):
    def test_reusable_jobs_lose_their_prefix_and_guards_and_shards_fold(self):
        self.assertEqual(MODULE.group_name("macos / macOS compile admission"), "macOS compile admission")
        self.assertEqual(MODULE.group_name("guards / workflow-guard-tests / ci"), "guards")
        self.assertEqual(MODULE.group_name("macos / app-host unit tests (3/7)"), "app-host unit tests")
        self.assertEqual(
            MODULE.group_name("macos / inputs.unit_selectors != '' && 'app-host unit tests (changed suites)' || x"),
            "app-host unit tests",
        )
        self.assertEqual(MODULE.group_name("ci-status"), "ci-status")

    def test_a_group_reports_its_worst_member(self):
        group = MODULE.Group("guards", [MODULE.Check("a", "success"), MODULE.Check("b", "in progress"),
                                        MODULE.Check("c", "skipped")])
        self.assertEqual(group.state, "in progress")
        self.assertEqual(MODULE.Group("x", [MODULE.Check("a", "skipped")]).state, "skipped")
        self.assertEqual(MODULE.Group("x", [MODULE.Check("a", "skipped"), MODULE.Check("b", "success")]).state, "success")


class ReceiptTests(unittest.TestCase):
    def test_a_merge_before_compile_admission_finished_is_unverified(self):
        # #14461 merged while macOS compile admission was still running.
        result = MODULE.receipt(load("pr14461.json"))
        self.assertTrue(result.unverified)
        lines = result.body.splitlines()
        self.assertEqual(lines[0], "**Merge receipt** for `e9426f528e`, merged 2026-09-25 10:23:09 UTC")
        self.assertEqual(
            lines[1], "- Not verified at merge: ci-status (not reported), macOS compile admission (in progress)",
        )
        self.assertIn("guards (17)", lines[2])
        self.assertNotIn("CLA", result.body)
        self.assertNotIn("Socket", result.body)
        self.assertIn("swift-package-tests", next(line for line in lines if line.startswith("- Skipped by policy")))
        self.assertIn("`merged-unverified`", result.body)
        self.assertTrue(result.body.endswith(MODULE.MARKER))
        self.assertLessEqual(len(lines), 8)

    def test_an_all_green_merge_is_one_line(self):
        result = MODULE.receipt(load("pr14433.json"))
        self.assertFalse(result.unverified)
        self.assertEqual(result.body.splitlines(), [
            "**Merge receipt** for `bef1de725c`: every check was green at merge "
            "(14 verified; 15 skipped by policy). Full suite runs on main after merge.",
            MODULE.MARKER,
        ])

    def test_app_host_skipped_by_policy_is_not_unverified(self):
        result = MODULE.receipt(snapshot(
            run("ci-status", required=True), run("macos / macOS compile admission"),
            run("macos / app-host unit tests (1/7)", "SKIPPED"),
        ))
        self.assertFalse(result.unverified)

    def test_a_failed_non_judging_job_is_listed_without_the_label(self):
        result = MODULE.receipt(snapshot(run("ci-status", required=True), run("linux-preflight", "FAILURE")))
        self.assertFalse(result.unverified)
        self.assertIn("- Not verified at merge: linux-preflight (failure)", result.body)
        self.assertNotIn("merged-unverified", result.body)

    def test_any_required_check_not_green_is_unverified(self):
        result = MODULE.receipt(snapshot(run("ci-status", required=True), run("Web complexity", "FAILURE", required=True)))
        self.assertTrue(result.unverified)

    def test_bots_and_cla_show_only_when_they_failed(self):
        quiet = MODULE.receipt(snapshot(
            run("ci-status", required=True), run("Socket Security: Project Report", app="socket-security"),
            run("CLA Assistant", required=True),
        ))
        self.assertNotIn("Socket", quiet.body)
        self.assertNotIn("CLA", quiet.body)
        loud = MODULE.receipt(snapshot(run("ci-status", required=True), run("CLA Assistant", "FAILURE", required=True)))
        self.assertIn("CLA Assistant (failure)", loud.body)
        self.assertFalse(loud.unverified)

    def test_the_receipt_is_the_receipt_line_of_the_status_comment(self):
        # An old receipt (its marker last) is edited into the status comment; other lines stay.
        calls, comments = [], [
            {"id": 3, "body": f"old\n{MODULE.MARKER}", "user": {"login": "github-actions[bot]"}},
            {"id": 5, "body": f"quoting\n{MODULE.MARKER}", "user": {"login": "someone"}},
        ]

        def api(method, path, payload):
            if method == "GET":
                return comments
            calls.append((method, path))
            comments[0]["body"] = payload["body"]
            return None
        body = MODULE.receipt(snapshot(run("ci-status", required=True))).body
        MODULE.pr_status.upsert("o/r", 7, "receipt", body, legacy=MODULE.MARKER, api=api, sleep=lambda _: None)
        self.assertEqual(calls, [("PATCH", "/repos/o/r/issues/comments/3")])
        self.assertEqual(MODULE.pr_status.parse(comments[0]["body"]), {"receipt": body})

    def test_check_names_are_inert_markdown(self):
        result = MODULE.receipt(snapshot(
            run("ci-status", required=True), run("@team #12 <!-- hide `x`", "FAILURE"),
        ))
        self.assertIn("@\u200bteam #\u200b12 &lt;\\!-- hide \\`x\\` (failure)", result.body)
        self.assertEqual(result.body.count("<!--"), 1)  # only the marker


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        self.job = self.workflow["jobs"]["receipt"]

    def test_runs_after_a_merge_into_main_from_any_fork(self):
        trigger = self.workflow[True]["pull_request_target"]  # YAML reads `on` as True
        self.assertEqual(trigger, {"types": ["closed"], "branches": ["main"]})
        self.assertEqual(self.job["if"], "github.event.pull_request.merged == true")

    def test_never_checks_out_pull_request_code(self):
        self.assertEqual(self.workflow["permissions"], {})
        self.assertEqual(self.job["permissions"], {
            "contents": "read", "pull-requests": "write", "checks": "read", "statuses": "read",
        })
        checkout = next(step for step in self.job["steps"] if step.get("uses", "").startswith("actions/checkout@"))["with"]
        self.assertEqual(checkout["ref"], "${{ github.workflow_sha }}")
        self.assertFalse(checkout["persist-credentials"])
        self.assertEqual(checkout["sparse-checkout"].split(), ["scripts/ci/merge_receipt.py", "scripts/ci/pr_status.py"])
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertNotIn("pull_request.head", text)

    def test_writes_spend_the_cmux_bot_pool_and_fall_back_to_the_job_token(self):
        mint = self.job["steps"][0]
        self.assertEqual(mint["id"], "cmux-bot-token")
        self.assertTrue(mint["uses"].startswith("actions/create-github-app-token@"))
        self.assertIs(mint["continue-on-error"], True)
        self.assertEqual(mint["if"], "vars.CMUX_BOT_APP_ID != ''")
        self.assertEqual({k: v for k, v in mint["with"].items() if k.startswith("permission-")},
                         {"permission-issues": "write", "permission-pull-requests": "write"})
        post = next(step for step in self.job["steps"] if step.get("name") == "Post merge receipt")
        self.assertEqual(post["env"]["GH_TOKEN"], "${{ steps.cmux-bot-token.outputs.token || github.token }}")
        self.assertEqual(post["env"]["CHECKS_TOKEN"], "${{ github.token }}")


SPENT = b'{"message":"API rate limit exceeded for installation ID 1234567.","documentation_url":"https://docs.github.com/rest/overview/resources-in-the-rest-api#rate-limiting"}'


class FakeGitHub(http.server.BaseHTTPRequestHandler):
    """GitHub with the repository's REST pool spent, as at 09:33Z on 2026-11-16 (run 43840796214): every REST call
    answers 403 with X-RateLimit-Remaining 0 and a reset an hour out; GraphQL, a separate pool, still answers."""

    seen: list = []
    posted: list = []
    rest_spent = True

    def log_message(self, *args):
        pass

    def answer(self, code, body, headers=()):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        for key, value in headers:
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def handle_any(self):
        length = int(self.headers.get("Content-Length") or 0)
        payload = json.loads(self.rfile.read(length) or b"null") if length else None
        self.seen.append((self.command, self.path))
        if self.path == "/graphql":
            self.answer(200, json.dumps({"data": {
                "repository": {"issueOrPullRequest": {"comments": {
                    "pageInfo": {"hasNextPage": False, "endCursor": None},
                    "nodes": [{"fullDatabaseId": str(i + 1), "body": body,
                               "author": {"__typename": "Bot", "login": "github-actions"}}
                              for i, body in enumerate(self.posted)]}}},
                "rateLimit": {"limit": 5000, "cost": 1, "remaining": 4000, "used": 1000,
                              "resetAt": "2026-11-16T10:00:00Z"}}}).encode())
        elif self.rest_spent:
            self.answer(403, SPENT, [("X-RateLimit-Limit", "1000"), ("X-RateLimit-Remaining", "0"),
                                     ("X-RateLimit-Used", "1000"), ("X-RateLimit-Resource", "core"),
                                     ("X-RateLimit-Reset", str(int(time.time()) + 3600))])
        elif self.command == "POST":
            self.posted.append((payload or {}).get("body"))
            self.answer(201, json.dumps({"id": 1, "body": (payload or {}).get("body")}).encode())
        else:
            self.answer(200, b"[]")

    do_GET = do_POST = do_PATCH = do_DELETE = handle_any


class SpentQuotaTests(unittest.TestCase):
    """Replays run 43840796214 (#40579): `merge_receipt.py post` failed on GET /repos/.../issues/40579/comments,
    HTTP 403 Forbidden, both attempts, after its GraphQL reads had passed."""

    def setUp(self):
        FakeGitHub.seen = []
        FakeGitHub.posted = []
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeGitHub)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        env = {"GITHUB_API_URL": f"http://127.0.0.1:{self.server.server_address[1]}", "GH_TOKEN": "t",
               "PR_STATUS_SETTLE_SECONDS": "0"}
        self.env = mock.patch.dict(os.environ, env)
        self.env.start()
        os.environ.pop("GITHUB_GRAPHQL_URL", None)
        self.labels = []
        self.patches = [
            mock.patch.object(MODULE, "fetch", lambda repo, number: {
                "number": number, "merged": True, "mergedAt": MERGED, "headRefOid": "b82e0c4cfc" + "0" * 30,
                "labels": [], "contexts": [run("ci-status", required=True)]}),
            mock.patch.object(MODULE, "gh", lambda args, token=None: self.labels.append(args) or ""),
        ]
        for patch in self.patches:
            patch.start()

    def tearDown(self):
        for patch in self.patches:
            patch.stop()
        self.env.stop()
        self.server.shutdown()
        self.server.server_close()

    def post(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = MODULE.command_post(argparse.Namespace(repo="o/r", pr=40579, dry_run=False, snapshot_output=None))
        return code, out.getvalue()

    def test_a_spent_rest_pool_reads_comments_over_graphql_and_warns_instead_of_failing(self):
        code, out = self.post()
        self.assertEqual(code, 0)
        self.assertNotIn(("GET", "/repos/o/r/issues/40579/comments?per_page=100&page=1"), FakeGitHub.seen)
        self.assertEqual(FakeGitHub.seen[0], ("POST", "/graphql"))
        # the one REST write is refused once, not retried into the empty pool
        self.assertEqual(FakeGitHub.seen[1:], [("POST", "/repos/o/r/issues/40579/comments")])
        self.assertIn("::warning title=merge-receipt::#40579 receipt not written", out)
        self.assertIn("API rate limit exceeded for installation", out)

    def test_with_rest_answering_the_receipt_is_posted_with_no_rest_read(self):
        FakeGitHub.rest_spent = False
        try:
            code, out = self.post()
        finally:
            FakeGitHub.rest_spent = True
        self.assertEqual(code, 0)
        self.assertNotIn("::warning", out)
        # read, write, read back after the settle wait: only the write is REST
        self.assertEqual(FakeGitHub.seen, [("POST", "/graphql"), ("POST", "/repos/o/r/issues/40579/comments"),
                                           ("POST", "/graphql")])
        self.assertIn("**Merge receipt** for `b82e0c4cfc`", FakeGitHub.posted[0])


if __name__ == "__main__":
    unittest.main()
