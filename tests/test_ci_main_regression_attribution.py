"""New failures on main's full suite, their suspect pull requests, and the report text."""

import importlib.util
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/main_regression_attribution.py"
WORKFLOW = ROOT / ".github/workflows/ci-main-full-suite.yml"
sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("main_regression_attribution", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE  # dataclasses resolve annotations through it
SPEC.loader.exec_module(MODULE)

REPO = "manaflow-ai/cmux"
PREV = "p" * 40
HEAD = "h" * 40
LOG = """\
2026-09-25T07:44:10.4990000Z Test Case '-[cmuxTests.FooTests testBar]' failed (0.1 seconds).
2026-09-25T07:44:10.4990110Z RATCHET_NEW_FAILURE AgentSessionAutoResumeSwiftTests/splitAfterRestore()
2026-09-25T07:44:10.4990120Z \x1b[31mRATCHET_NEW_FAILURE FooTests/testBar\x1b[0m
2026-09-25T07:44:10.4990130Z RATCHET_KNOWN_FAILURE SidebarHiddenPresentationTests/visibility()
2026-09-25T07:44:10.4990140Z   echo "RATCHET_NEW_FAILURE $identifier"
"""


def run(**overrides):
    base = {
        "id": 2, "event": "workflow_dispatch", "head_branch": "main", "path": ".github/workflows/ci.yml",
        "head_sha": HEAD, "status": "completed", "conclusion": "failure",
        "created_at": "2026-09-25T07:00:00Z", "html_url": "https://github.com/x/runs/2",
    }
    base.update(overrides)
    return base


def pr_node(number, merge_sha, state="MERGED", base="main"):
    return {
        "number": number, "title": f"PR {number}", "url": f"https://github.com/{REPO}/pull/{number}",
        "state": state, "baseRefName": base, "author": {"login": "someone"},
        "mergeCommit": {"oid": merge_sha} if merge_sha else None,
    }


def pr(number, edited=(), reached=()):
    return MODULE.PullRequest(
        number=number, title=f"PR {number}", url=f"u/{number}", merge_sha=f"m{number}",
        edited_suites=set(edited), reached_suites=set(reached),
    )


class ExtractionTests(unittest.TestCase):
    def test_reads_only_ratchet_new_failure_verdict_lines(self):
        self.assertEqual(
            MODULE.ratchet_failures(LOG),
            {"AgentSessionAutoResumeSwiftTests/splitAfterRestore()", "FooTests/testBar"},
        )

    def test_a_failed_shard_is_complete_only_when_every_batch_was_graded(self):
        self.assertTrue(MODULE.shard_log_complete(LOG))
        self.assertTrue(MODULE.shard_log_complete("typed app-host run passed: 796 test cases\n"))
        # Failed before any batch was graded: no verdict at all.
        self.assertFalse(MODULE.shard_log_complete("##[error]Process completed with exit code 1.\n"))
        for stop in (
            "incomplete app-host run: app host restarted after test execution",
            "typed xcresult is incomplete: 3 selected Test Case(s) have no terminal result",
            "No typed xcresult test JSON found for unit-physical-3",
            "xcodebuild status 70 is not ratchetable",
        ):
            with self.subTest(stop=stop):
                self.assertFalse(MODULE.shard_log_complete(LOG + stop + "\n"))

    def test_app_host_ran_needs_every_shard_finished(self):
        shards = [{"name": f"macos / app-host unit tests ({n}/7)", "conclusion": "failure"} for n in range(1, 8)]
        rollup = {"name": "ci-status", "conclusion": "failure"}
        self.assertTrue(MODULE.app_host_ran(shards + [rollup]))
        self.assertFalse(MODULE.app_host_ran(shards[:-1] + [{**shards[-1], "conclusion": "cancelled"}]))
        # A compile break skips every shard, which says nothing about tests.
        self.assertFalse(MODULE.app_host_ran([{"name": "macos / macOS compile admission", "conclusion": "failure"}]))


class BaselineTests(unittest.TestCase):
    def test_previous_run_is_an_earlier_tested_full_suite_run(self):
        current = run()
        runs = [
            current,
            run(id=5, created_at="2026-09-25T08:00:00Z"),  # later
            run(id=3, created_at="2026-09-25T06:00:00Z", conclusion="cancelled"),
            run(id=4, created_at="2026-09-25T05:00:00Z", event="pull_request"),
            run(id=1, created_at="2026-09-25T04:00:00Z", conclusion="success"),
            run(id=0, created_at="2026-09-25T03:00:00Z"),
        ]
        self.assertEqual([r["id"] for r in MODULE.earlier_tested_runs(runs, current)], [1, 0])

    def test_new_failures_drop_what_failed_before(self):
        current = {"A/a()": ["j1"], "B/b()": ["j2"]}
        self.assertEqual(MODULE.new_failures(current, {"A/a()"}), {"B/b()": ["j2"]})
        self.assertEqual(MODULE.new_failures(current, set()), current)


class MergedPullRequestTests(unittest.TestCase):
    def test_only_pull_requests_merged_by_a_commit_in_the_range_count(self):
        # rev-list order: newest first.
        shas = ["m2", "branchcommit", "m1", "direct"]
        associated = {
            "m2": [pr_node(2, "m2")],
            "branchcommit": [pr_node(2, "m2"), pr_node(9, None, state="OPEN")],
            "m1": [pr_node(1, "m1"), pr_node(7, "elsewhere")],
            "direct": [pr_node(8, "m8", base="release")],
        }
        prs, direct = MODULE.merged_prs(shas, associated)
        self.assertEqual([p.number for p in prs], [1, 2])  # oldest merge first
        self.assertEqual(direct, ["direct"])


class RankingTests(unittest.TestCase):
    def test_one_pull_request_is_the_suspect(self):
        only = pr(1)
        self.assertEqual(MODULE.suspects_for("Suite/test()", [only]), ([only], "only pull request in the range"))

    def test_a_direct_push_in_the_range_needs_the_pull_request_to_reach_the_suite(self):
        self.assertEqual(MODULE.suspects_for("Suite/test()", [pr(1)], ["abc"])[0], [])
        reaches = pr(1, reached={"Suite"})
        self.assertEqual(MODULE.suspects_for("Suite/test()", [reaches], ["abc"])[0], [reaches])

    def test_overlay_reads_changed_files_at_the_merge(self):
        files = {"Sources/A.swift": "old", "Sources/B.swift": "b", "cmuxTests/T.swift": "t"}
        self.assertEqual(
            MODULE.overlay(files, {"Sources/A.swift": "new", "cmuxTests/T.swift": None, "Sources/C.swift": "c"}),
            {"Sources/A.swift": "new", "Sources/B.swift": "b", "Sources/C.swift": "c"},
        )
        self.assertEqual(files["Sources/A.swift"], "old")

    def test_editing_the_suite_beats_reaching_it(self):
        edits, reaches, neither = pr(1, edited={"Suite"}), pr(2, reached={"Suite"}), pr(3)
        suspects, how = MODULE.suspects_for("Suite/test()", [neither, reaches, edits])
        self.assertEqual([p.number for p in suspects], [1])
        self.assertEqual(how, "edits the suite")
        suspects, how = MODULE.suspects_for("Suite/test()", [neither, reaches])
        self.assertEqual([p.number for p in suspects], [2])

    def test_ties_name_every_top_pull_request(self):
        a, b = pr(1, reached={"Suite"}), pr(2, reached={"Suite"})
        self.assertEqual([p.number for p in MODULE.suspects_for("Suite/t()", [a, b, pr(3)])[0]], [1, 2])

    def test_no_signal_blames_nobody(self):
        self.assertEqual(MODULE.suspects_for("Suite/t()", [pr(1), pr(2)])[0], [])
        self.assertEqual(MODULE.suspects_for("Suite/t()", [])[0], [])


class ReportTests(unittest.TestCase):
    def setUp(self):
        self.a, self.b = pr(1, reached={"S"}), pr(2, reached={"S", "T"})
        self.failures = {"S/x()": ["https://job/1"], "T/y()": ["https://job/2"], "U/z()": ["https://job/3"]}
        self.attributions = {test: MODULE.suspects_for(test, [self.a, self.b]) for test in self.failures}
        self.previous = run(id=1, head_sha=PREV, conclusion="success", html_url="https://github.com/x/runs/1")

    def test_issue_section_lists_each_new_failure_with_suspects_and_jobs(self):
        text = MODULE.issue_section(
            repo=REPO, run=run(), previous=self.previous, failures=self.failures,
            attributions=self.attributions, prs=[self.a, self.b], direct=[],
        )
        self.assertIn(f"### New since `{PREV[:10]}`", text)
        self.assertIn(f"https://github.com/{REPO}/compare/{PREV}...{HEAD}", text)
        self.assertIn("`S/x()` | #1, #2 (changes code the suite names) | [job](https://job/1)", text)
        self.assertIn("`T/y()` | #2 (changes code the suite names)", text)
        self.assertIn("`U/z()` | unattributed", text)

    def test_issue_section_without_new_failures_or_baseline(self):
        text = MODULE.issue_section(
            repo=REPO, run=run(), previous=self.previous, failures={}, attributions={}, prs=[], direct=[],
        )
        self.assertIn("No app-host test fails here", text)
        text = MODULE.issue_section(
            repo=REPO, run=run(), previous=None, failures={}, attributions={}, prs=[], direct=[],
        )
        self.assertIn("No earlier full-suite run", text)

    def test_one_comment_per_suspect_with_its_own_tests(self):
        plan = MODULE.comment_plan(self.failures, self.attributions)
        self.assertEqual([(p.number, tests) for p, tests, _, _ in plan], [(1, ["S/x()"]), (2, ["S/x()", "T/y()"])])
        pr2, tests, how, others = plan[1]
        body = MODULE.pr_comment(
            repo=REPO, pr=pr2, tests=tests, how=how, run=run(), previous=self.previous,
            failures=self.failures, others=others,
        )
        self.assertTrue(body.startswith(MODULE.marker(2, ["S/x()", "T/y()"], f"{PREV[:10]}..{HEAD[:10]}")))
        self.assertTrue(MODULE.already_told([body], 2, ["T/y()", "S/x()"], "other..range"))
        self.assertIn("- `S/x()` (changes code the suite names; also suspected: #1) [job](https://job/1)", body)
        self.assertIn("- `T/y()` (changes code the suite names) [job](https://job/2)", body)
        self.assertNotIn("U/z()", body)
        self.assertNotIn("—", body)

    def test_a_wide_tie_pings_nobody(self):
        tied = [pr(n, reached={"S"}) for n in range(1, MODULE.MAX_PINGED_SUSPECTS + 2)]
        failures = {"S/x()": ["https://job/1"]}
        attributions = {"S/x()": MODULE.suspects_for("S/x()", tied)}
        self.assertEqual(len(attributions["S/x()"][0]), len(tied))
        self.assertEqual(MODULE.comment_plan(failures, attributions), [])

    def test_a_pull_request_hears_once_per_test_set_and_once_per_range(self):
        told = ["intro", MODULE.marker(2, ["a", "b"], "p..h")]
        self.assertEqual(MODULE.marker(2, ["b", "a"], "p..h"), MODULE.marker(2, ["a", "b"], "p..h"))
        self.assertTrue(MODULE.already_told(told, 2, ["b", "a"], "p2..h2"))  # same tests, later range
        self.assertTrue(MODULE.already_told(told, 2, ["a"], "p..h"))  # re-run of the same range
        self.assertFalse(MODULE.already_told(told, 2, ["a"], "p2..h2"))
        self.assertFalse(MODULE.already_told(told, 3, ["a", "b"], "p..h"))
        self.assertFalse(MODULE.already_told([], 2, ["a"], "p..h"))


class WorkflowTests(unittest.TestCase):
    text = WORKFLOW.read_text(encoding="utf-8")
    report = text.split("\n  report:\n", 1)[1]

    def test_report_job_can_comment_on_pull_requests(self):
        self.assertIn("pull-requests: write", self.report)
        self.assertIn("issues: write", self.report)

    def test_attribution_feeds_the_issue_section_and_cannot_block_it(self):
        self.assertIn("scripts/ci/main_regression_attribution.py", self.report)
        step = self.report.split("main_regression_attribution.py", 1)[0].rsplit("- name:", 1)[1]
        self.assertIn("continue-on-error: true", step)
        self.assertIn("--extra-section", self.report)

    def test_the_issue_sync_checkout_stays_shallow_and_attribution_deepens_it(self):
        checkout = self.report.split("      - name: Checkout\n", 1)[1].split("\n      - name:", 1)[0]
        self.assertIn("fetch-depth: 1", checkout)
        for tree in ("scripts/ci", "cmuxTests", "Sources", "Packages/macOS", "Packages/Shared", "CLI"):
            self.assertIn(f"            {tree}\n", checkout)
        step = self.report.split("main_regression_attribution.py", 1)[0].rsplit("- name:", 1)[1]
        self.assertIn("git fetch --no-tags --filter=blob:none --depth=", step)


if __name__ == "__main__":
    unittest.main()
