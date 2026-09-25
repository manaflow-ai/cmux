"""The merge receipt: which checks a pull request's head had passed when it merged."""

import importlib.util
import json
import pathlib
import sys
import unittest

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

    def test_the_existing_receipt_comment_is_found_by_its_marker(self):
        comments = [{"databaseId": 1, "body": "hi"}, {"databaseId": 7, "body": f"old\n{MODULE.MARKER}"}]
        self.assertEqual(MODULE.existing_comment(comments), 7)
        self.assertIsNone(MODULE.existing_comment(comments[:1]))


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
        checkout = self.job["steps"][0]["with"]
        self.assertEqual(checkout["ref"], "${{ github.workflow_sha }}")
        self.assertFalse(checkout["persist-credentials"])
        self.assertEqual(checkout["sparse-checkout"], "scripts/ci/merge_receipt.py")
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertNotIn("pull_request.head", text)


if __name__ == "__main__":
    unittest.main()
