#!/usr/bin/env python3
"""guard_attribution.py turns a red guard into a named culprit and a fix.

The cases pin the parts that must stay right without a GitHub run: reading
the failed steps and assertions out of a real fast guard log, reading the
repository variables out of the check's log and diffing them, finding the
first failing commit, the mechanical fixes, the comments (one per PR, log
text fenced so it cannot break out), the tracking issue lifecycle, and the
workflow's trust split (a PR's code never runs; only `report` can write).
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import guard_attribution as ga  # noqa: E402
import run_ci_guards  # noqa: E402

WORKFLOW = ROOT / ".github/workflows/ci-guard-attribution.yml"

# Trimmed from run 36199352592, a PR's "CI fast guards" job log.
CI_LOG = textwrap.dedent("""\
    2026-09-25T23:01:55.1Z ##[group]Run scripts/ci/guards-local.sh --no-stamp --jobs 8
    2026-09-25T23:01:55.1Z cmux guards: 1 groups, 57 steps, head cd0cdece70e0, base 028a1860776a, 8 workers
    2026-09-25T23:02:16.6Z   FAIL    0.4s  workflow-guard-tests / ci: Validate macOS jobs select a pinned Xcode
    2026-09-25T23:02:16.6Z ##[group]Validate macOS jobs select a pinned Xcode
    2026-09-25T23:02:16.6Z FAIL: cmux-terminal-client-xcframework.yml job build never runs scripts/select-ci-xcode.sh, so it builds with the image's default Xcode
    2026-09-25T23:02:16.6Z ##[endgroup]
    2026-09-25T23:02:37.3Z   FAIL    0.9s  workflow-guard-tests / ci: Validate fork runner routing
    2026-09-25T23:02:37.3Z ##[group]Validate fork runner routing
    2026-09-25T23:02:37.3Z FF....FF.......
    2026-09-25T23:02:37.3Z ======================================================================
    2026-09-25T23:02:37.3Z FAIL: test_every_fork_exercised_runner_has_a_hosted_path (__main__.ForkRunnerRoutingTests.test_every_fork_exercised_runner_has_a_hosted_path) (workflow='x.yml', line=41)
    2026-09-25T23:02:37.3Z No fork PR may queue forever on organization-only capacity.
    2026-09-25T23:02:37.3Z ----------------------------------------------------------------------
    2026-09-25T23:02:37.3Z Traceback (most recent call last):
    2026-09-25T23:02:37.3Z   File "/home/runner/work/cmux/cmux/tests/test_ci_fork_runner_routing.py", line 845, in test_every
    2026-09-25T23:02:37.3Z     self.assertTrue(
    2026-09-25T23:02:37.3Z AssertionError: False is not true : x.yml:41 has no GitHub-hosted macOS fork branch
    2026-09-25T23:02:37.3Z
    2026-09-25T23:02:37.3Z ======================================================================
    2026-09-25T23:02:37.3Z FAIL: test_no_workflow_falls_back_to_blacksmith_outside_manaflow_ai (__main__.ForkRunnerRoutingTests.test_no_workflow_falls_back_to_blacksmith_outside_manaflow_ai)
    2026-09-25T23:02:37.3Z Scheduled, dispatched and push-only workflows need a fork branch too.
    2026-09-25T23:02:37.3Z ----------------------------------------------------------------------
    2026-09-25T23:02:37.3Z Traceback (most recent call last):
    2026-09-25T23:02:37.3Z   File "/home/runner/work/cmux/cmux/tests/test_ci_fork_runner_routing.py", line 921, in test_no
    2026-09-25T23:02:37.3Z     self.assertEqual(errors, [], "\\n" + "\\n".join(errors))
    2026-09-25T23:02:37.3Z AssertionError: Lists differ: ["x.yml:41:[491 chars] }}"] != []
    2026-09-25T23:02:37.3Z
    2026-09-25T23:02:37.3Z First extra element 0:
    2026-09-25T23:02:37.3Z "x.yml:41: blacksmith-6vcpu-macos-15 is selectable outside manaflow-ai; start the expression with the owner fork branch"
    2026-09-25T23:02:37.3Z
    2026-09-25T23:02:37.3Z ----------------------------------------------------------------------
    2026-09-25T23:02:37.3Z Ran 14 tests in 0.703s
    2026-09-25T23:02:37.3Z
    2026-09-25T23:02:37.3Z FAILED (failures=2)
    2026-09-25T23:02:37.3Z ##[endgroup]
    2026-09-25T23:03:35.7Z failed: workflow-guard-tests / ci: Validate macOS jobs select a pinned Xcode; workflow-guard-tests / ci: Validate fork runner routing
    2026-09-25T23:03:35.7Z cmux guards: 55 steps passed, 2 failed, 0 skipped (Linux only) in 79.5s
    2026-09-25T23:03:35.7Z ##[error]Process completed with exit code 1.
    """)

# guards-local.sh output on a dev machine: ::group:: instead of ##[group].
LOCAL_LOG = textwrap.dedent("""\
    cmux guards: 1 groups, 57 steps, head 90e8953b0bb8, base 90e8953b0bb8, 8 workers
      FAIL    0.3s  workflow-guard-tests / ci: Validate runner label policy
    ::group::Validate runner label policy
    ...F.
    ======================================================================
    FAIL: test_every_runner_variable_a_workflow_reads_is_reported (__main__.TheReportSeesEveryRunnerVariable.test_every_runner_variable_a_workflow_reads_is_reported)
    ----------------------------------------------------------------------
    Traceback (most recent call last):
      File "tests/test_runner_label_policy.py", line 212, in test_every_runner_variable_a_workflow_reads_is_reported
        self.assertEqual(missing, set(), f"add to CMUX_CI_RUNNER_VARIABLES in {HEALTH_REPORT_WORKFLOW.name}")
    AssertionError: Items in the first set but not the second:
    'CI_SEED_KEEP_LOCAL_RUNNERS' : add to CMUX_CI_RUNNER_VARIABLES in ci-health-report.yml

    ----------------------------------------------------------------------
    Ran 5 tests in 0.1s

    FAILED (failures=1)
    ::endgroup::
    cmux guards: 56 steps passed, 1 failed, 0 skipped (Linux only) in 60.0s
    """)

# The variable check's step header as GitHub prints it: a multi-line value
# continues on lines without a timestamp.
VARS_LOG = textwrap.dedent("""\
    2026-09-25T23:06:57.9Z ##[group]Run python3 scripts/ci/check_repo_variables.py
    2026-09-25T23:06:57.9Z python3 scripts/ci/check_repo_variables.py
    2026-09-25T23:06:57.9Z shell: /usr/bin/bash -e {0}
    2026-09-25T23:06:57.9Z env:
    2026-09-25T23:06:57.9Z   GITHUB_REPO_NAME: manaflow-ai/cmux
    2026-09-25T23:06:57.9Z   CI_OWNED_POOL_SLOTS: {"glaeda-std-xcode-26.6": 42}
    2026-09-25T23:06:57.9Z   CMUX_CI_XCODE_APP_PR: /Applications/Xcode_26.6.app
    2026-09-25T23:06:57.9Z   CMUX_CI_RUNNER_VARIABLES: CI_PR_POOL_ORDER=
    LINUX_RUNNER=blacksmith-4vcpu-ubuntu-2404
    MACOS_RUNNER_PR={pr}

    2026-09-25T23:06:57.9Z ##[endgroup]
    2026-09-25T23:06:58.0Z {result}
    """)


def fake_tree(root: Path, *, with_exemptions: bool = True) -> ga.Tree:
    workflows = root / ".github/workflows"
    workflows.mkdir(parents=True)
    block = "          CMUX_CI_RUNNER_VARIABLES: |\n            LINUX_RUNNER=${{ vars.LINUX_RUNNER }}\n" \
            "            WINDOWS_RUNNER=${{ vars.WINDOWS_RUNNER }}\n        run: true\n"
    (workflows / "ci-health-report.yml").write_text("jobs:\n  r:\n    steps:\n      - env:\n" + block)
    (workflows / "ci-repo-variables.yml").write_text("jobs:\n  r:\n    steps:\n      - env:\n" + block)
    (workflows / "new.yml").write_text(
        "jobs:\n  a:\n    runs-on: ${{ vars.MACOS_RUNNER_NEW || 'macos-15' }}\n"
        "  b:\n    runs-on: ubuntu-24.04\n    env:\n      KEEP: ${{ vars.CI_FOO_RUNNERS }}\n")
    (root / "tests").mkdir()
    exemptions = 'NON_LABEL_RUNNER_VARIABLES = {"CI_SEED_KEEP_LOCAL_RUNNERS"}\n' if with_exemptions else ""
    (root / "tests/test_runner_label_policy.py").write_text("import re\n" + exemptions)
    return ga.Tree(root)


REPORT_FAILURE = ga.TestFailure(
    "TheReportSeesEveryRunnerVariable.test_every_runner_variable_a_workflow_reads_is_reported",
    "AssertionError: Items in the first set but not the second:\n'CI_FOO_RUNNERS'\n'MACOS_RUNNER_NEW' : "
    "add to CMUX_CI_RUNNER_VARIABLES in ci-health-report.yml",
)


class ReadingTheLog(unittest.TestCase):
    def test_ci_log_steps_tests_and_assertions(self) -> None:
        steps = ga.parse_guard_log(CI_LOG)
        self.assertEqual([s.step for s in steps],
                         ["Validate macOS jobs select a pinned Xcode", "Validate fork runner routing"])
        xcode, routing = steps
        self.assertEqual(xcode.tests[0].test, "")
        self.assertIn("never runs scripts/select-ci-xcode.sh", xcode.tests[0].message)
        self.assertEqual(len(routing.tests), 2)
        self.assertEqual(routing.tests[0].test,
                         "ForkRunnerRoutingTests.test_every_fork_exercised_runner_has_a_hosted_path "
                         "(workflow='x.yml', line=41)")
        self.assertTrue(routing.tests[0].message.startswith("AssertionError: False is not true"))
        self.assertNotIn("Traceback", routing.tests[0].message)
        self.assertIn("start the expression with the owner fork branch", routing.tests[1].message)

    def test_local_output_reads_the_same(self) -> None:
        (step,) = ga.parse_guard_log(LOCAL_LOG)
        self.assertEqual(step.step, "Validate runner label policy")
        self.assertIn("'CI_SEED_KEEP_LOCAL_RUNNERS' : add to CMUX_CI_RUNNER_VARIABLES", step.tests[0].message)

    def test_summary_line_names_failed_steps(self) -> None:
        self.assertEqual(ga.failed_steps_summary(CI_LOG),
                         {"Validate macOS jobs select a pinned Xcode", "Validate fork runner routing"})
        self.assertIsNone(ga.failed_steps_summary("nothing here\n"))


class RepositoryVariables(unittest.TestCase):
    def test_values_from_the_step_header_and_their_diff(self) -> None:
        green = ga.variable_values(ga.parse_step_env(VARS_LOG.replace("{pr}", "blacksmith-6vcpu-macos-26").replace("{result}", "repository variables: ok")))
        self.assertEqual(green["MACOS_RUNNER_PR"], "blacksmith-6vcpu-macos-26")
        self.assertEqual(green["CI_OWNED_POOL_SLOTS"], '{"glaeda-std-xcode-26.6": 42}')
        self.assertEqual(green["CI_PR_POOL_ORDER"], "")
        self.assertNotIn("GITHUB_REPO_NAME", green)
        red_log = VARS_LOG.replace("{pr}", "glaeda-std-xcode-26.6").replace(
            "{result}", "##[error]MACOS_RUNNER_PR is an owned label; use the picker")
        red = ga.variable_values(ga.parse_step_env(red_log))
        self.assertEqual(ga.variable_changes(red, green),
                         [{"name": "MACOS_RUNNER_PR", "old": "blacksmith-6vcpu-macos-26", "new": "glaeda-std-xcode-26.6"}])
        self.assertEqual(ga.error_annotations(red_log), ["MACOS_RUNNER_PR is an owned label; use the picker"])

    def test_the_issue_says_what_changed_and_how_to_restore_it(self) -> None:
        report = {"kind": "repo-variables", "run_url": "u", "errors": ["MACOS_RUNNER_PR is an owned label"],
                  "changes": [{"name": "MACOS_RUNNER_PR", "old": "blacksmith-6vcpu-macos-26", "new": "glaeda-std"}],
                  "green_run_url": "g", "state": "red", "branch": "main"}
        body = ga.render_issue(report, {}, {})
        self.assertIn("gh variable set MACOS_RUNNER_PR --repo manaflow-ai/cmux --body blacksmith-6vcpu-macos-26", body)
        self.assertEqual(ga.headline(report), "culprit: CI repository variables red, changed MACOS_RUNNER_PR")


class FirstFailingCommit(unittest.TestCase):
    def probe_for(self, broken_at: dict[str, int], commits: list[str], calls: list | None = None):
        def probe(sha: str, steps: set[str]) -> dict[str, bool]:
            if calls is not None:
                calls.append(sha)
            return {step: commits.index(sha) < broken_at[step] for step in steps}
        return probe

    def test_the_only_commit_needs_no_run(self) -> None:
        calls: list[str] = []
        verdict = ga.first_failing(["c1"], {"s"}, self.probe_for({"s": 0}, ["c1"], calls), True)
        self.assertEqual(verdict["s"]["sha"], "c1")
        self.assertEqual(calls, [])

    def test_each_commit_in_a_batch_is_run_until_each_step_fails(self) -> None:
        commits = ["c1", "c2", "c3", "c4"]
        calls: list[str] = []
        verdict = ga.first_failing(commits, {"a", "b"}, self.probe_for({"a": 1, "b": 2}, commits, calls), True)
        self.assertEqual((verdict["a"]["sha"], verdict["b"]["sha"]), ("c2", "c3"))
        self.assertEqual(calls, ["c1", "c2", "c3"])

    def test_no_baseline_and_red_from_the_start_names_nobody(self) -> None:
        commits = ["c1", "c2"]
        verdict = ga.first_failing(commits, {"a"}, self.probe_for({"a": 0}, commits), False)
        self.assertIsNone(verdict["a"]["sha"])

    def test_a_step_that_passes_alone_everywhere_is_left_unattributed(self) -> None:
        commits = ["c1", "c2"]
        verdict = ga.first_failing(commits, {"a"}, self.probe_for({"a": 9}, commits), True)
        self.assertIsNone(verdict["a"]["sha"])

    def test_an_unrunnable_probe_is_never_read_as_a_pass(self) -> None:
        commits = [f"c{i}" for i in range(ga.MAX_LINEAR_COMMITS * 4)]
        verdict = ga.first_failing(commits, {"a"}, lambda sha, steps: {s: None for s in steps}, True)
        self.assertIsNone(verdict["a"]["sha"])
        self.assertIn("could not be run", verdict["a"]["method"])

    def test_a_long_range_is_halved(self) -> None:
        commits = [f"c{i}" for i in range(ga.MAX_BISECT_COMMITS * 3)]
        calls: list[str] = []
        verdict = ga.first_failing(commits, {"a"}, self.probe_for({"a": 77}, commits, calls), True)
        self.assertEqual(verdict["a"]["sha"], "c77")
        self.assertLessEqual(len(calls), 8)


class MechanicalFixes(unittest.TestCase):
    def test_label_goes_in_both_lists_and_a_name_list_is_exempted(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            tree = fake_tree(Path(temp))
            fix = ga.fix_runner_variable_report(REPORT_FAILURE, tree)
            self.assertIn("`MACOS_RUNNER_NEW` picks a `runs-on:` label", fix.hint)
            self.assertIn("`CI_FOO_RUNNERS` is read by no `runs-on:`", fix.hint)
            self.assertIn("NON_LABEL_RUNNER_VARIABLES", fix.hint)
            changed = fix.edit(tree)
            self.assertEqual(sorted(changed), sorted([ga.HEALTH_REPORT, ga.REPO_VARIABLES, ga.LABEL_POLICY_TEST]))
            for path in (ga.HEALTH_REPORT, ga.REPO_VARIABLES):
                self.assertEqual(ga.runner_block(tree.read(path)), [
                    "LINUX_RUNNER=${{ vars.LINUX_RUNNER }}", "MACOS_RUNNER_NEW=${{ vars.MACOS_RUNNER_NEW }}",
                    "WINDOWS_RUNNER=${{ vars.WINDOWS_RUNNER }}"])
            self.assertIn('NON_LABEL_RUNNER_VARIABLES = {"CI_FOO_RUNNERS", "CI_SEED_KEEP_LOCAL_RUNNERS"}',
                          tree.read(ga.LABEL_POLICY_TEST))
            self.assertEqual(fix.edit(tree), [])  # idempotent

    def test_without_the_exemption_set_a_name_list_gets_a_hint_only(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            tree = fake_tree(Path(temp), with_exemptions=False)
            failure = ga.TestFailure("t", "'CI_FOO_RUNNERS' : add to CMUX_CI_RUNNER_VARIABLES in ci-health-report.yml")
            fix = ga.fix_runner_variable_report(failure, tree)
            self.assertIsNone(fix.edit)
            self.assertIn("exemptions in `tests/test_runner_label_policy.py`", fix.hint)

    def test_the_repository_variable_list_is_synced_to_the_report(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            tree = fake_tree(Path(temp))
            report = tree.read(ga.HEALTH_REPORT)
            tree.write(ga.HEALTH_REPORT, ga.add_block_line(report, "MACOS_RUNNER_26"))
            failure = ga.TestFailure("Wiring.test_same_runner_variables_as_the_health_report", "Lists differ")
            fix = ga.fix_runner_variable_lists_equal(failure, tree)
            self.assertEqual(fix.edit(tree), [ga.REPO_VARIABLES])
            self.assertEqual(ga.runner_block(tree.read(ga.REPO_VARIABLES)), ga.runner_block(tree.read(ga.HEALTH_REPORT)))

    def test_an_unregistered_test_gets_the_registry_writer(self) -> None:
        failure = ga.TestFailure("", "Run python3 scripts/ci/validate_test_execution_registry.py --write, or paste")
        fix = ga.fix_test_registry(failure, ga.Tree(ROOT))
        self.assertEqual(fix.command, "python3 scripts/ci/validate_test_execution_registry.py --write")

    def test_the_real_seed_variable_is_a_name_list(self) -> None:
        self.assertFalse(ga.runs_on_label(ga.Tree(ROOT), "CI_SEED_KEEP_LOCAL_RUNNERS"))
        self.assertTrue(ga.runs_on_label(ga.Tree(ROOT), "MACOS_RUNNER_PR"))

    def test_a_commit_tree_is_read_only(self) -> None:
        head = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
        tree = ga.Tree(ROOT, head)
        self.assertIn("ci-guards.yml", tree.workflows())
        with self.assertRaises(RuntimeError):
            tree.write("x", "y")


class Comments(unittest.TestCase):
    def step(self, **extra) -> dict:
        base = {"step": "Validate runner label policy", "label": "workflow-guard-tests / ci",
                "tests": [{"test": "T.test_x", "message": "AssertionError: ```\n@everyone"}], "excerpt": "",
                "command": "python3 tests/test_runner_label_policy.py",
                "reproduce": ga.reproduce("Validate runner label policy"),
                "fix": {"hints": ["add it to `NON_LABEL_RUNNER_VARIABLES`."]}}
        base.update(extra)
        return base

    def test_log_text_stays_inside_its_fence(self) -> None:
        text = "\n".join(ga.render_step(self.step()))
        self.assertIn("````\nAssertionError: ```\n@everyone\n````", text)
        self.assertEqual(ga.code("a`b\nc @x"), "`a'b c @x`")

    def test_culprit_comment_names_the_fix_and_pings_author_and_merger(self) -> None:
        culprit = {"pr": 14724, "sha": "90e8953b0bb8", "author": "alice", "merger": "bob", "method": "the only commit"}
        report = {"workflow": ga.FAST_WORKFLOW, "run_url": "https://run", "kind": "fast-guards", "branch": "main",
                  "state": "red", "steps": [self.step(culprit=culprit)]}
        body = ga.render_culprit_comment(report, 14724, report["steps"], 900, None)
        self.assertTrue(body.startswith("<!-- cmux-guard-culprit pr=14724 steps="))
        self.assertIn("**This PR broke `CI fast guards` on main.**", body)
        self.assertIn("add it to `NON_LABEL_RUNNER_VARIABLES`.", body)
        self.assertIn("scripts/ci/guards-local.sh --step 'Validate runner label policy'", body)
        self.assertTrue(body.rstrip().endswith("Tracking: #900. @alice @bob"))
        self.assertEqual(ga.headline(report), "culprit: CI fast guards red since #14724 by @alice, merged by @bob")

    def test_pr_comment_marks_a_step_that_is_red_on_main(self) -> None:
        report = {"state": "red", "sha": "abc", "run_url": "u", "steps": [
            self.step(red_on_main={"culprit": {"pr": 14724, "author": "alice"}, "issue": 900}),
            self.step(step="Validate fork runner routing")]}
        body = ga.render_pr_comment(report)
        self.assertTrue(body.startswith(ga.PR_MARKER))
        self.assertIn("red on main too, not this PR", body)
        self.assertIn("since #14724 by @alice (#900)", body)
        self.assertIn("### `Validate fork runner routing`", body)
        self.assertIn("passes on `abc`", ga.render_pr_comment({"state": "green", "sha": "abc", "run_url": "u"}))


class Robustness(unittest.TestCase):
    def test_an_older_checkout_the_runner_cannot_plan_counts_as_unknown(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            runner = Path(temp) / "runner"
            (runner / "scripts/ci").mkdir(parents=True)
            script = runner / "scripts/ci/guards-local.sh"
            script.write_text("#!/bin/sh\necho 'ci-guards.yml has no step named x' >&2\nexit 2\n")
            script.chmod(0o755)
            self.assertEqual(ga.run_steps(runner, ROOT, {"a", "b"}), {"a": None, "b": None})

    def test_only_this_repositorys_pull_request_counts(self) -> None:
        fork = {"number": 3, "base": {"repo": {"name": "cmux", "url": "https://api.github.com/repos/someone/cmux"}}}
        ours = {"number": 9, "base": {"repo": {"name": "cmux", "url": "https://api.github.com/repos/manaflow-ai/cmux"}}}
        gh = ga.GitHub("manaflow-ai/cmux", "t")
        self.assertEqual(ga.pr_number(gh, {"pull_requests": [fork, ours]}), 9)

    def test_a_green_run_between_resets_what_the_issue_knows(self) -> None:
        log = subprocess.run(["git", "-C", str(ROOT), "rev-list", "--first-parent", "--max-count=3", "HEAD"],
                             capture_output=True, text=True).stdout.split()
        red, middle, old = log
        runs = [{"conclusion": "success", "head_sha": middle}]
        self.assertTrue(ga.green_since(runs, ROOT, old, red))
        self.assertFalse(ga.green_since(runs, ROOT, middle, red))
        self.assertFalse(ga.green_since([{"conclusion": "failure", "head_sha": middle}], ROOT, old, red))

    def test_a_flood_of_fake_failures_stays_under_githubs_body_limit(self) -> None:
        steps = [{"step": f"s{i}", "tests": [{"test": "t", "message": "x" * 1400}] * 4, "excerpt": "",
                  "reproduce": "r", "fix": {}} for i in range(500)]
        body = ga.render_pr_comment({"state": "red", "sha": "a", "run_url": "u", "steps": steps})
        self.assertLess(len(body), 65536)
        self.assertIn("more failed steps in the run log", body)

    def test_only_a_verified_patch_becomes_a_fix_pr(self) -> None:
        report = {"branch": "main", "state": "red", "fix": {"patch": "diff\n", "verified": False, "steps": ["s"]}}
        self.assertEqual(ga.fix_patch(report), "")
        report["fix"]["verified"] = True
        self.assertEqual(ga.fix_patch(report), "diff\n")
        self.assertEqual(ga.fix_patch({**report, "branch": "pr"}), "")


class FakeGitHub:
    def __init__(self, issues=(), comments=None):
        self.issues, self.comment_map, self.calls = list(issues), comments or {}, 0

    def open_issues(self):
        return self.issues

    def comments(self, number):
        return self.comment_map.get(number, [])


class Reporting(unittest.TestCase):
    def red_report(self, known: bool = False) -> dict:
        culprit = {"pr": 14724, "sha": "90e8953b0bb8", "author": "alice", "merger": "alice", "method": "only"}
        return {"kind": "fast-guards", "workflow": ga.FAST_WORKFLOW, "branch": "main", "state": "red", "sha": "abc",
                "run_url": "u", "steps": [{"step": "S", "tests": [], "excerpt": "boom", "reproduce": "r",
                                           "culprit": culprit, "known": known, "fix": {"hints": ["h"]}}]}

    def writes(self, gh, report, fix_prs=None) -> list[str]:
        writer = ga.Writer(None, True)
        ga.report_main(writer, gh, "manaflow-ai/cmux", report, fix_prs or {})
        return [entry.splitlines()[0] for entry in writer.log]

    def test_first_red_opens_one_issue_and_comments_on_the_culprit(self) -> None:
        self.assertEqual(self.writes(FakeGitHub(), self.red_report()), [
            "--- would POST repos/manaflow-ai/cmux/issues",
            "--- would POST repos/manaflow-ai/cmux/issues/14724/comments"])

    def test_a_still_red_main_updates_the_issue_and_does_not_comment_again(self) -> None:
        issue = {"number": 900, "body": ga.ISSUE_MARKER.format(kind="fast-guards") + "\nold"}
        self.assertEqual(self.writes(FakeGitHub([issue]), self.red_report(known=True)),
                         ["--- would PATCH repos/manaflow-ai/cmux/issues/900"])

    def test_the_culprit_comment_is_edited_not_repeated(self) -> None:
        report = self.red_report()
        existing = ga.render_culprit_comment(report, 14724, report["steps"], 0, None)
        gh = FakeGitHub(comments={14724: [{"id": 5, "body": existing}]})
        self.assertEqual(self.writes(gh, report), ["--- would POST repos/manaflow-ai/cmux/issues"])

    def test_green_closes_the_issue(self) -> None:
        issue = {"number": 900, "body": ga.ISSUE_MARKER.format(kind="fast-guards")}
        green = {"kind": "fast-guards", "workflow": ga.FAST_WORKFLOW, "branch": "main", "state": "green", "sha": "d"}
        self.assertEqual(self.writes(FakeGitHub([issue]), green), [
            "--- would POST repos/manaflow-ai/cmux/issues/900/comments",
            "--- would PATCH repos/manaflow-ai/cmux/issues/900"])
        self.assertEqual(self.writes(FakeGitHub(), green), [])

    def test_the_issue_carries_its_state_for_the_next_run(self) -> None:
        body = ga.render_issue(self.red_report(), {"S": {"culprit": {"pr": 14724}}}, {})
        self.assertEqual(ga.issue_data({"body": body})["steps"]["S"]["culprit"]["pr"], 14724)

    def test_a_pr_comment_is_one_comment_updated_in_place(self) -> None:
        report = {"branch": "pr", "state": "red", "pr": 7, "sha": "abc", "run_url": "u", "steps": []}
        writer = ga.Writer(None, True)
        ga.report_pr(writer, FakeGitHub(), "manaflow-ai/cmux", report)
        self.assertEqual(writer.log[0].splitlines()[0], "--- would POST repos/manaflow-ai/cmux/issues/7/comments")
        writer = ga.Writer(None, True)
        gh = FakeGitHub(comments={7: [{"id": 3, "body": ga.PR_MARKER + "\nold"}]})
        ga.report_pr(writer, gh, "manaflow-ai/cmux", {**report, "state": "green"})
        self.assertEqual(writer.log[0].splitlines()[0], "--- would PATCH repos/manaflow-ai/cmux/issues/comments/3")
        writer = ga.Writer(None, True)
        ga.report_pr(writer, FakeGitHub(), "manaflow-ai/cmux", {**report, "state": "green"})
        self.assertEqual(writer.log, [])  # never red here: nothing to say


class StepSelection(unittest.TestCase):
    def test_a_stateful_group_keeps_the_steps_before_the_one_asked_for(self) -> None:
        steps = [run_ci_guards.Step(n, r, {}, None) for n, r in
                 (("a", "echo x >> $GITHUB_ENV"), ("b", "true"), ("c", "true"))]
        stateless = [run_ci_guards.Step(n, "true", {}, None) for n in ("a", "b", "c")]
        units = [run_ci_guards.Unit("j1", "g", steps), run_ci_guards.Unit("j2", "g", stateless)]
        selected = run_ci_guards.select_steps(units, {"b"})
        self.assertEqual([[s.name for s in u.steps] for u in selected], [["a", "b"], ["b"]])
        self.assertEqual(run_ci_guards.select_steps(units, {"zzz"}), [])


class WorkflowTrust(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.text = WORKFLOW.read_text(encoding="utf-8")
        cls.workflow = run_ci_guards.load_yaml(WORKFLOW)

    def test_follows_both_guard_workflows(self) -> None:
        on = self.workflow.get("on", self.workflow.get(True))
        self.assertEqual(sorted(on["workflow_run"]["workflows"]), sorted([ga.FAST_WORKFLOW, ga.VARS_WORKFLOW]))
        self.assertEqual(on["workflow_run"]["types"], ["completed"])

    def test_only_report_writes_and_nothing_checks_out_the_pr(self) -> None:
        analyze, report = self.workflow["jobs"]["analyze"], self.workflow["jobs"]["report"]
        self.assertNotIn("write", analyze["permissions"].values())
        self.assertEqual(report["permissions"]["issues"], "write")
        for step in analyze["steps"] + report["steps"]:
            if "actions/checkout" in str(step.get("uses")):
                self.assertNotIn("head_sha", json.dumps(step.get("with")))
        self.assertNotIn("pull_request_target", self.text)

    def test_the_report_job_is_named_by_the_headline(self) -> None:
        self.assertIn("needs.analyze.outputs.headline", self.workflow["jobs"]["report"]["name"])


if __name__ == "__main__":
    unittest.main()
