"""Fix-forward merging requires actual builds and same-base test evidence."""
import contextlib
import copy
import io
from datetime import datetime, timedelta, timezone
import json
import importlib.util
from pathlib import Path
import unittest
from unittest import mock
import signal
import subprocess
import tempfile
import time
import os
import shlex
import sys
import textwrap

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("merge_green", ROOT / "scripts/ci/main_fix_evidence.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
# No helper run reaches the real repository: merged-head checks use a fixture clone.
os.environ["GH_MERGE_GREEN_REPO_DIR"] = os.path.join(tempfile.gettempdir(), "gh-merge-green-no-repo")
# Under GH_MERGE_GREEN_TEST the freeze check reads GH_MERGE_GREEN_FREEZE_ISSUES and
# GH_MERGE_GREEN_FREEZE_EVENTS, never the repository's issues. Every run gets empty
# fixtures (no freezes); a test run without them refuses.
_NO_FREEZES = tempfile.NamedTemporaryFile("w", suffix="-freezes.json", delete=False)
_NO_FREEZES.write("[]")
_NO_FREEZES.close()
os.environ["GH_MERGE_GREEN_FREEZE_ISSUES"] = _NO_FREEZES.name
os.environ["GH_MERGE_GREEN_FREEZE_EVENTS"] = _NO_FREEZES.name
os.environ["GH_MERGE_GREEN_TEST"] = "1"
HEAD = "a" * 40
# Under GH_MERGE_GREEN_TEST the review receipt check reads GH_MERGE_GREEN_REVIEWS, never the
# pull request. Every run gets an independent review's SHIP receipt on HEAD unless a test
# passes its own; a test run without the fixture refuses.


def reviews_fixture(*comments, head=HEAD):
    """A pull request read for scripts/ci/review_receipt.py: comments are (body, createdAt)."""
    handle = tempfile.NamedTemporaryFile("w", suffix="-reviews.json", delete=False)
    json.dump({"headRefOid": head, "reviews": {"nodes": []}, "comments": {"nodes": [
        {"createdAt": at, "body": body, "authorAssociation": "MEMBER", "author": {"__typename": "User", "login": "teamleaderleo"}}
        for body, at in comments]}}, handle)
    handle.close()
    return handle.name


SHIP_RECEIPT = f"Review (subagent, correctness first): SHIP at {HEAD}"
os.environ["GH_MERGE_GREEN_REVIEWS"] = reviews_fixture((SHIP_RECEIPT, "2026-10-21T05:00:00Z"))
MERGED_SHA = "d" * 40
BASE = "b" * 40
ANCESTOR = "c" * 40
NAMES = ("cmux-next Release compile (Xcode 26)", "cmux app scheme compile (Debug)", "cmux-next swift test")
BUILD_STEPS = ("Release compile", "Compile the cmux scheme", "Build package and tests")
TEST_STEP = "Run WebKit driver package tests"
ISSUE = "✘ Test fragmentNavigation() recorded an issue at NavigationEdgeTests.swift:18:6: Caught error: Timeout waiting for load"
SUMMARY = "✘ Test run with 15 tests in 2 suites failed after 5.731 seconds with 1 issue."


# scripts/ci/merge-fast-gate-protected-paths.txt as the base carries it.
PROTECTED_PATHS = "# comment\n.github/workflows/\nscripts/ci/\nscripts/gh-merge-green\n"


CMUX_NEXT_WORKFLOW = """name: cmux-next
on:
  pull_request:
    branches: [feat-cmux-next]
    paths:
      - Packages/macOS/CmuxNext/**
      - 'scripts/cmux-next/bundle-*.sh'
      - docs/mdm/**
      - "!docs/mdm/*.md"
  push:
    branches: [feat-cmux-next]
    paths:
      - docs/**
jobs:
  path_route:
    name: cmux-next path routing
  checks:
    name: cmux-next checks (god files, concurrency, crash safety, l10n)
  swift-canary:
    name: cmux-next Swift canary
  fast-tier:
    name: cmux-next fast tier
  swift-test:
    name: cmux-next swift test
  release-compile:
    name: cmux-next Release compile (Xcode 26)
  cmux-scheme-compile:
    name: ${{ inputs.dev_daily == true && 'cmux NEXT DEV Release compile' || 'cmux app scheme compile (Debug)' }}
"""
RATE_LIMITED = "<rate limited>"
CI_WORKFLOW = """name: CI
jobs:
  changes:
    runs-on: ubuntu-latest
  web:
    uses: ./.github/workflows/ci-web.yml
"""
CI_WEB_WORKFLOW = """name: Web
jobs:
  react-apps-check:
    runs-on: ubuntu-latest
"""


def test_log(issue=ISSUE):
    return "\n".join(f"cmux-next swift test\t{TEST_STEP}\t2026-10-02T19:10:10Z {line}" for line in (issue, SUMMARY))


class FakeGitHub:
    def __init__(self):
        self.pr = {"state": "open", "head": {"sha": HEAD}, "base": {"sha": BASE, "ref": "feat-cmux-next"}, "mergeable": True}
        self.head_checks = []
        self.base_checks = []
        self.ancestor_checks = []
        self.parents = {BASE: []}
        self.compare_files = []
        self.compare_entries = None
        self.jobs = {}
        self.logs = {}
        for i, (name, step) in enumerate(zip(NAMES, BUILD_STEPS), 1):
            check = {"id": i, "name": name, "status": "completed", "conclusion": "success", "app": {"slug": "github-actions"}, "details_url": f"https://github.com/manaflow-ai/cmux/actions/runs/10/job/{i}"}
            self.head_checks.append(check)
            self.jobs[i] = {"id": i, "head_sha": HEAD, "run_id": 10, "status": "completed", "conclusion": "success", "name": name, "steps": [{"name": step, "status": "completed", "conclusion": "success"}]}
        self.head_checks.append({"id": 4, "name": "ci-status", "status": "completed", "conclusion": "success", "app": {"slug": "github-actions"}})
        self.head_checks.append({"id": 5, "name": "web-validation", "status": "completed", "conclusion": "success", "app": {"slug": "github-actions"}})
        self.files = []

    def json(self, route, *, paginate=False):
        if route.endswith("pulls/42"):
            return copy.deepcopy(self.pr)
        if "/compare/" in route:
            return {"files": self.compare_entries if self.compare_entries is not None else [{"filename": path} for path in self.compare_files]}
        if "/commits/" in route:
            sha = route.split("/commits/", 1)[1].split("/", 1)[0]
            if "/check-runs" not in route:
                return {"sha": sha, "parents": [{"sha": parent} for parent in self.parents.get(sha, [])]}
            if sha == ANCESTOR:
                checks = self.ancestor_checks
            else:
                checks = self.head_checks if HEAD in route else self.base_checks
            return [{"check_runs": copy.deepcopy(checks)}]
        if "/actions/jobs/" in route:
            return copy.deepcopy(self.jobs[int(route.rsplit("/", 1)[1])])
        if "/files" in route:
            return [copy.deepcopy(self.files)]
        raise AssertionError(route)

    def log(self, repo, job):
        return self.logs[job["id"]]

    def fail_test(self, *, same_base=True):
        self.head_checks[2]["conclusion"] = "failure"
        job = self.jobs[3]
        job["conclusion"] = "failure"
        job["steps"].append({"name": TEST_STEP, "status": "completed", "conclusion": "failure"})
        self.logs[3] = test_log()
        base = copy.deepcopy(job)
        base.update(id=30, head_sha=BASE, run_id=20)
        self.jobs[30] = base
        check = copy.deepcopy(self.head_checks[2])
        check.update(id=30, details_url="https://github.com/manaflow-ai/cmux/actions/runs/20/job/30")
        self.base_checks = [check]
        self.logs[30] = test_log() if same_base else test_log(ISSUE.replace("Timeout waiting for load", "Unexpected result"))


class MainFixEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.gh = FakeGitHub()

    def validate(self):
        return module.validate("manaflow-ai/cmux", 42, self.gh)

    def test_a_rate_limited_main_fix_exits_3(self):
        class Limited:
            def json(self, route, *, paginate=False):
                raise module.RateLimited("GitHub rate-limited `gh api`; core 0 of 5000 left")
        original = module.GitHub
        module.GitHub = Limited
        try:
            with contextlib.redirect_stderr(io.StringIO()) as err:
                status = module.main(["manaflow-ai/cmux#42", "--check-only"])
        finally:
            module.GitHub = original
        self.assertEqual(status, 3)
        self.assertIn("rate-limited:", err.getvalue())

    def test_green_requires_three_actual_builds(self):
        evidence = self.validate()
        self.assertIn(HEAD, evidence)
        self.assertIn("Release compile", evidence)
        self.assertIn("Build package and tests", evidence)

    def test_missing_debug_compile_is_not_green(self):
        self.gh.head_checks.pop(1)
        with self.assertRaisesRegex(module.Refused, "Debug"):
            self.validate()

    def test_missing_or_pending_web_validation_is_not_green(self):
        self.gh.head_checks.pop()
        with self.assertRaisesRegex(module.Refused, "web-validation"):
            self.validate()
        self.gh = FakeGitHub()
        self.gh.head_checks[-1]["status"] = "in_progress"
        self.gh.head_checks[-1]["conclusion"] = None
        with self.assertRaisesRegex(module.Refused, "web-validation"):
            self.validate()

    def test_skipped_or_queued_compile_cannot_be_waived(self):
        for state in ("skipped", "failure", "cancelled", None):
            with self.subTest(state=state):
                self.gh = FakeGitHub()
                self.gh.jobs[1]["steps"][0]["conclusion"] = state
                with self.assertRaisesRegex(module.Refused, "Release compile"):
                    self.validate()

    def test_swift_build_failure_cannot_be_waived_by_base(self):
        self.gh.fail_test()
        self.gh.jobs[3]["steps"][0]["conclusion"] = "failure"
        with self.assertRaisesRegex(module.Refused, "Build package and tests"):
            self.validate()

    def test_same_base_failure_is_named_in_audit(self):
        self.gh.fail_test()
        evidence = self.validate()
        self.assertIn(BASE, evidence)
        self.assertIn("fragmentNavigation()", evidence)
        self.assertIn("Timeout waiting for load", evidence)
        self.assertIn("/job/30", evidence)

    def test_same_test_with_a_different_error_is_not_a_match(self):
        self.gh.fail_test(same_base=False)
        with self.assertRaisesRegex(module.Refused, "not reproduced"):
            self.validate()

    def test_other_base_sha_is_rejected(self):
        self.gh.fail_test()
        self.gh.jobs[30]["head_sha"] = "c" * 40
        with self.assertRaisesRegex(module.Refused, "exact"):
            self.validate()

    def test_missing_base_run_is_rejected(self):
        self.gh.fail_test()
        self.gh.base_checks = []
        with self.assertRaisesRegex(module.Refused, "base"):
            self.validate()

    def test_missing_base_run_uses_nearest_ancestor_and_audits_why(self):
        """Path-filtered base changes use and audit the nearest ancestor run."""
        self.gh.fail_test()
        self.gh.base_checks = []
        self.gh.parents[BASE] = [ANCESTOR]
        ancestor = copy.deepcopy(self.gh.head_checks[2])
        ancestor.update(id=31, head_sha=ANCESTOR, details_url="https://github.com/manaflow-ai/cmux/actions/runs/21/job/31")
        self.gh.ancestor_checks = [ancestor]
        self.gh.compare_files = ["plans/cmux-next/path-filtered.md"]
        ancestor_job = copy.deepcopy(self.gh.jobs[3])
        ancestor_job.update(id=31, head_sha=ANCESTOR, run_id=21)
        self.gh.jobs[31] = ancestor_job
        self.gh.logs[31] = test_log()
        evidence = self.validate()
        self.assertIn(f"nearest ancestor `{ANCESTOR}`", evidence)
        self.assertIn("intervening changes are path-filtered", evidence)
        self.assertIn("/job/31", evidence)

    def test_ancestor_fallback_rejects_intervening_source_changes(self):
        """Source changes between the ancestor and base refuse the fallback."""
        self.gh.fail_test()
        self.gh.base_checks = []
        self.gh.parents[BASE] = [ANCESTOR]
        ancestor = copy.deepcopy(self.gh.head_checks[2])
        ancestor.update(id=31, head_sha=ANCESTOR, details_url="https://github.com/manaflow-ai/cmux/actions/runs/21/job/31")
        self.gh.ancestor_checks = [ancestor]
        self.gh.compare_files = ["Packages/macOS/CmuxNext/Sources/Changed.swift"]
        with self.assertRaisesRegex(module.Refused, "intervening changes may affect the test"):
            self.validate()

    def test_ancestor_fallback_rejects_renamed_source_file(self):
        """Renames out of source paths cannot masquerade as docs-only changes."""
        self.gh.fail_test()
        self.gh.base_checks = []
        self.gh.parents[BASE] = [ANCESTOR]
        ancestor = copy.deepcopy(self.gh.head_checks[2])
        ancestor.update(id=31, head_sha=ANCESTOR, details_url="https://github.com/manaflow-ai/cmux/actions/runs/21/job/31")
        self.gh.ancestor_checks = [ancestor]
        self.gh.compare_entries = [{"filename": "docs/cmux-next/renamed.md", "previous_filename": "Packages/macOS/CmuxNext/Sources/Changed.swift"}]
        with self.assertRaisesRegex(module.Refused, "intervening changes may affect the test"):
            self.validate()

    def test_ancestor_fallback_rejects_compare_file_cap(self):
        """A capped compare response cannot prove all intervening paths are safe."""
        self.gh.fail_test()
        self.gh.base_checks = []
        self.gh.parents[BASE] = [ANCESTOR]
        ancestor = copy.deepcopy(self.gh.head_checks[2])
        ancestor.update(id=31, head_sha=ANCESTOR, details_url="https://github.com/manaflow-ai/cmux/actions/runs/21/job/31")
        self.gh.ancestor_checks = [ancestor]
        self.gh.compare_entries = [{"filename": "plans/path-filtered.md"}] * 300
        with self.assertRaisesRegex(module.Refused, "300-file limit"):
            self.validate()

    def test_timeout_or_setup_failure_is_not_a_test_failure(self):
        self.gh.fail_test()
        self.gh.jobs[3]["steps"][-1]["name"] = "Fetch dependencies"
        with self.assertRaisesRegex(module.Refused, "non-test"):
            self.validate()

    def test_fatal_crash_without_assertions_cannot_match(self):
        self.gh.fail_test()
        self.gh.logs[3] = test_log("Fatal error: unused runner")
        with self.assertRaisesRegex(module.Refused, "parse"):
            self.validate()

    def test_unparsed_issue_cannot_be_hidden_beside_a_known_failure(self):
        self.gh.fail_test()
        self.gh.logs[3] += "\ncmux-next swift test\t" + TEST_STEP + "\t✘ Test another() recorded an issue: unknown format"
        with self.assertRaisesRegex(module.Refused, "parse"):
            self.validate()

    def test_newest_attempt_wins_over_old_green(self):
        old = copy.deepcopy(self.gh.head_checks[0])
        self.gh.head_checks[0].update(id=10, status="in_progress", conclusion=None)
        self.gh.head_checks.append(old)
        with self.assertRaises(module.Refused):
            self.validate()

    def test_other_failing_checks_are_not_bypassed(self):
        self.gh.head_checks.append({"id": 8, "name": "workflow-guard-tests", "status": "completed", "conclusion": "failure", "app": {"slug": "github-actions"}})
        with self.assertRaisesRegex(module.Refused, "workflow-guard-tests"):
            self.validate()

    def test_conflict_markers_are_rejected(self):
        self.gh.files = [{"filename": "test.swift", "patch": "@@ -1 +1 @@\n+<<<<<<< HEAD"}]
        with self.assertRaisesRegex(module.Refused, "conflict"):
            self.validate()

    def test_closed_pr_is_rejected(self):
        self.gh.pr["state"] = "closed"
        with self.assertRaisesRegex(module.Refused, "open"):
            self.validate()

class InstalledHelperRegression(unittest.TestCase):
    def test_help_prints_usage_without_querying_github(self):
        with tempfile.TemporaryDirectory() as directory:
            gh = Path(directory) / "gh"
            gh.write_text("#!/bin/sh\necho gh-called >&2\nexit 2\n")
            gh.chmod(0o755)
            for flag in ("--help", "-h"):
                result = subprocess.run(
                    [str(ROOT / "scripts/gh-merge-green"), flag],
                    env={**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"], "GH_MERGE_GREEN_NO_AUTO_UPDATE": "1"},
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("gh-merge-green OWNER/REPO#PR", result.stdout)
                self.assertNotIn("gh-called", result.stderr)

    def test_main_fix_from_symlink_resolves_checked_in_validator(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            symlink = directory / "gh-merge-green"
            symlink.symlink_to(ROOT / "scripts/gh-merge-green")
            python = directory / "python3"
            marker = directory / "validator-called"
            python.write_text(
                "#!/bin/sh\n"
                "printf '%s\\n' \"$@\" > \"$VALIDATOR_MARKER\"\n"
            )
            python.chmod(0o755)
            gh = directory / "gh"
            gh.write_text(
                "#!/bin/sh\n"
                "if [ \"$1 $2\" = 'pr view' ]; then printf '%s\\n' '{\"headRefOid\":\""
                + HEAD
                + "\",\"baseRefName\":\"main\",\"labels\":[]}'; exit 0; fi\n"
                "exit 2\n"
            )
            gh.chmod(0o755)
            result = subprocess.run(
                [str(symlink), "manaflow-ai/cmux#42", "--main-fix", "--squash"],
                cwd=directory,
                env={
                    **os.environ,
                    "PATH": str(directory) + os.pathsep + os.environ["PATH"],
                    "VALIDATOR_MARKER": str(marker),
                    "GH_MERGE_GREEN_NO_AUTO_UPDATE": "1",
                },
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists(), result.stderr)

    def run_helper(self, directory, marker, *, check_name="ci-status", check_conclusion="success", extra_checks=(), extra_args=(), event_log=None, labels=(), cmux_next_runs=(("completed", "success", 1),), changed_files=("docs/README.md",), cmux_next_workflow=None, is_cross_repository=False, pr_fields=None, base="feat-cmux-next", full=True, rollup=(), rollup_head=HEAD, excuse=None, files_rest_fails=False, rollup_base=None, base_after=None, base_workflow=None, protected_paths=PROTECTED_PATHS, rollup_files_limit=None, terminate_after=None, rate_limit=None, check_paths=None, fast_gates_base=None, fast_gates_after=None, tip_sha=None, compare=None, reviews=None, reviews_final=None):
        """full=True keeps a feat-cmux-next merge on the full gate (--full) these
        tests were written for; full=False runs the default fast gate, whose
        `gh pr view --json statusCheckRollup` read returns rollup. excuse=(status, output)
        stands in for scripts/ci/base_red_excuse.py through a python3 on PATH."""
        gh = Path(directory) / "gh"
        if excuse is not None:
            python = Path(directory) / "python3"
            python.write_text(
                "#!/bin/sh\n"
                "case \"$1\" in */base_red_excuse.py) printf '%s\\n' " + shlex.quote(excuse[1]) + "; exit " + str(int(excuse[0])) + ";; esac\n"
                "exec " + shlex.quote(sys.executable) + " \"$@\"\n")
            python.chmod(0o755)
        if full:
            extra_args = ("--full", *extra_args)
        rollup_payload = shlex.quote(json.dumps({"headRefOid": rollup_head, "baseRefName": rollup_base or base, "files": [{"path": f} for f in changed_files[:rollup_files_limit]], "statusCheckRollup": [
            {"__typename": "CheckRun", "name": name, "status": status.upper(), "conclusion": conclusion.upper()} for name, status, conclusion in rollup]}))
        checks = [{"id": 1, "name": check_name, "status": "completed", "conclusion": check_conclusion}]
        checks.extend(
            {"id": index + 2, "name": name, "status": status, "conclusion": conclusion}
            for index, (name, status, conclusion) in enumerate(extra_checks)
        )
        check_payload = shlex.quote(json.dumps([{"check_runs": checks}]))
        runs_payload = shlex.quote(json.dumps({"total_count": len(cmux_next_runs), "workflow_runs": [
            {"id": 900 + index, "status": status, "conclusion": conclusion, "run_attempt": attempt, "head_sha": HEAD, "event": "pull_request"}
            for index, (status, conclusion, attempt) in enumerate(cmux_next_runs)]}))
        if cmux_next_workflow is None:
            cmux_next_workflow = CMUX_NEXT_WORKFLOW
        workflow_route = (
            "printf '%s' " + shlex.quote(cmux_next_workflow) + "; exit 0"
            if cmux_next_workflow else "exit 1"
        )
        # The fast gate reads the paths filter and the protected paths from the base.
        if base_workflow is None:
            base_workflow = cmux_next_workflow
        base_workflow_route = "printf '%s' " + shlex.quote(base_workflow) + "; exit 0" if base_workflow else "exit 1"
        if base_workflow == RATE_LIMITED:
            base_workflow_route = "echo 'gh: API rate limit exceeded for user ID 1. (HTTP 403)' >&2; exit 1"
        protected_route = "printf '%s' " + shlex.quote(protected_paths) + "; exit 0" if protected_paths is not None else "exit 1"
        check_paths_route = ("printf '%s' " + shlex.quote(check_paths) + "; exit 0" if check_paths is not None
                             else "echo 'gh: Not Found (HTTP 404)' >&2; exit 1")

        def fast_status(base_sha, state="success", at="2026-10-21T13:00:00Z"):
            return json.dumps({"statuses": [{"context": "cmux-next/fast-gates", "state": state, "updated_at": at,
                                             "description": f"base {base_sha}",
                                             "target_url": "https://example.test/runs/7"}] if base_sha else []})
        # The head's cmux-next/fast-gates status: fast_gates_base before a dispatch, then fast_gates_after
        # (base, state) once the check-path gate dispatched the workflow.
        after = fast_status(*fast_gates_after, at="2026-10-21T14:12:00Z") if fast_gates_after else fast_status(fast_gates_base)
        check_paths_reads = (
            "if [ \"$1\" = api ] && printf '%s' \"$*\" | grep -q 'commits/" + HEAD + "/status'; then "
            "if [ -e \"$MERGE_MARKER.dispatched\" ]; then printf '%s\\n' " + shlex.quote(after) + "; "
            "else printf '%s\\n' " + shlex.quote(fast_status(fast_gates_base)) + "; fi; exit 0; fi\n"
            "if [ \"$1\" = api ] && printf '%s' \"$*\" | grep -q 'branches/feat-cmux-next'; then "
            "printf '%s\\n' " + shlex.quote(tip_sha or BASE) + "; exit 0; fi\n"
            "if [ \"$1\" = api ] && printf '%s' \"$*\" | grep -q '/compare/'; then printf '%s\\n' "
            + shlex.quote(json.dumps(compare or {"status": "diverged", "ahead_by": 0, "files": []})) + "; exit 0; fi\n"
            "if [ \"$1\" = api ] && printf '%s' \"$*\" | grep -q 'cmux-next-fast-gates.yml/dispatches'; then "
            "printf '%s\\n' dispatch >> \"$EVENT_LOG\"; touch \"$MERGE_MARKER.dispatched\"; exit 0; fi\n"
        ) if check_paths is not None else ""
        rate_limit_route = ("if [ \"$1 $2\" = 'api rate_limit' ]; then printf '%s\\n' "
                            + shlex.quote(json.dumps({"resources": rate_limit})) + "; exit 0; fi\n") if rate_limit else ""
        gh.write_text(
            "#!/bin/sh\n"
            + rate_limit_route +
            "if [ \"$1 $2\" = 'pr view' ] && printf '%s' \"$*\" | grep -q statusCheckRollup; then "
            "printf '%s\\n' " + rollup_payload + "; exit 0; fi\n"
            "if [ \"$1 $2\" = 'pr view' ] && [ -e \"$MERGE_MARKER\" ]; then "
            "printf '%s\\n' '{\"headRefOid\":\"" + HEAD + "\",\"baseRefName\":\"" + base + "\",\"state\":\"MERGED\",\"mergeCommit\":{\"oid\":\"" + MERGED_SHA + "\"},\"labels\":[]}'; exit 0; fi\n"
            + ("if [ \"$1 $2\" = 'pr view' ] && [ -e \"$MERGE_MARKER.viewed\" ]; then "
               "printf '%s\\n' '{\"headRefOid\":\"" + HEAD + "\",\"baseRefName\":\"" + base_after + "\",\"state\":\"OPEN\",\"labels\":[]}'; exit 0; fi\n"
               if base_after else "") +
            "if [ \"$1 $2\" = 'pr view' ]; then touch \"$MERGE_MARKER.viewed\"; "
            "printf '%s\\n' '{\"headRefOid\":\"" + HEAD + "\",\"baseRefName\":\"" + base + "\",\"state\":\"OPEN\",\"isCrossRepository\":" + json.dumps(is_cross_repository) + ",\"labels\":" + json.dumps([{"name": label} for label in labels]) + "".join("," + json.dumps(k) + ":" + json.dumps(v) for k, v in (pr_fields or {}).items()).replace("'", "'\\''") + "}'; exit 0; fi\n"
            "if [ \"$1 $2\" = 'pr comment' ]; then printf '%s\\n' comment >> \"$EVENT_LOG\"; exit 0; fi\n"
            "if [ \"$1 $2\" = 'pr merge' ]; then printf '%s\\n' \"$*\" >> \"$MERGE_ARGS_LOG\"; printf '%s\\n' merge >> \"$EVENT_LOG\"; touch \"$MERGE_MARKER\"; exit 0; fi\n"
            "if [ \"$1\" = api ] && printf '%s' \"$*\" | grep -q '/check-runs'; then "
            "printf '%s\\n' " + check_payload + "; exit 0; fi\n"
            "if [ \"$1\" = api ] && printf '%s' \"$*\" | grep -q 'workflows/cmux-next.yml/runs'; then "
            "printf '%s\\n' " + runs_payload + "; exit 0; fi\n"
            "if [ \"$1\" = api ] && printf '%s' \"$*\" | grep -q 'contents/.github/workflows/cmux-next.yml?ref=" + HEAD + "'; then "
            + workflow_route + "; fi\n"
            "if [ \"$1\" = api ] && printf '%s' \"$*\" | grep -q 'contents/.github/workflows/cmux-next.yml?ref=" + base + "'; then "
            + base_workflow_route + "; fi\n"
            "if [ \"$1\" = api ] && printf '%s' \"$*\" | grep -q 'contents/scripts/ci/merge-fast-gate-protected-paths.txt?ref=" + base + "'; then "
            + protected_route + "; fi\n"
            # The check-path gate's list: not on the base (a 404) unless a test gives one.
            "if [ \"$1\" = api ] && printf '%s' \"$*\" | grep -q 'contents/scripts/ci/check-paths.txt'; then "
            + check_paths_route + "; fi\n"
            + check_paths_reads +
            "if [ \"$1\" = api ] && printf '%s' \"$*\" | grep -q 'contents/.github/workflows/ci.yml?ref=" + HEAD + "'; then "
            "printf '%s' " + shlex.quote(CI_WORKFLOW) + "; exit 0; fi\n"
            "if [ \"$1\" = api ] && printf '%s' \"$*\" | grep -q 'contents/.github/workflows/ci-web.yml?ref=" + HEAD + "'; then "
            "printf '%s' " + shlex.quote(CI_WEB_WORKFLOW) + "; exit 0; fi\n"
            + ("if [ \"$1\" = api ] && printf '%s' \"$*\" | grep -q 'pulls/42/files.*filename'; then "
               + ("echo 'gh: API rate limit exceeded for user ID 1. (HTTP 403)' >&2; " if files_rest_fails == "quota" else "")
               + "exit 1; fi\n"
               "if [ \"$1 $2\" = 'api graphql' ] && printf '%s' \"$*\" | grep -q 'files(first'; then printf '%s\\n' "
               + shlex.quote(json.dumps({"data": {"repository": {"pullRequest": {"files": {"nodes": [{"path": f} for f in changed_files], "pageInfo": {"hasNextPage": False}}}}}}))
               + "; exit 0; fi\n" if files_rest_fails else "") +
            "if [ \"$1\" = api ] && printf '%s' \"$*\" | grep -q 'pulls/42/files'; then "
            "printf '%s\\n' " + " ".join(shlex.quote(f) for f in changed_files) + "; exit 0; fi\n"
            "if [ \"$1\" = api ] && printf '%s' \"$*\" | grep -q '/contents/'; then printf '%s\\n' 'HTTP/2.0 200'; exit 0; fi\n"
            "if [ \"$1\" = api ]; then printf '%s\\n' '[]'; exit 0; fi\n"
            "exit 2\n"
        )
        gh.chmod(0o755)
        argv = [str(ROOT / "scripts/gh-merge-green"), "manaflow-ai/cmux#42", *extra_args, "--squash"]
        env = {**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"], "MERGE_MARKER": str(marker), "EVENT_LOG": str(event_log or Path(directory) / "events"), "MERGE_ARGS_LOG": str(Path(directory) / "merge-args"), "GH_MERGE_GREEN_NO_AUTO_UPDATE": "1", "GH_MERGE_GREEN_CHECK_PATHS_INTERVAL": "0"}
        if reviews is not None:
            env["GH_MERGE_GREEN_REVIEWS"] = reviews
        if reviews_final is not None:
            env["GH_MERGE_GREEN_REVIEWS_FINAL"] = reviews_final
        if terminate_after is None:
            return subprocess.run(argv, env=env, capture_output=True, text=True)
        # A caller's timeout: SIGTERM to the whole group while the gate still waits.
        process = subprocess.Popen(argv, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                   start_new_session=True)
        time.sleep(terminate_after)
        os.killpg(process.pid, signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=60)
        return subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)

    def test_fork_trust_rejects_non_full_sha_values(self):
        for value in ("main", "a" * 39, "A" * 40):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as directory:
                marker = Path(directory) / "merged"
                result = self.run_helper(directory, marker, extra_args=("--trust-fork-head", value))
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(marker.exists())
                self.assertIn("full lowercase 40-character SHA", result.stderr)

    def test_bug_fix_without_observed_section_warns_and_still_merges(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, pr_fields={"title": "fix(sidebar): keep the group open", "body": "## Summary\nIt's fixed.\n<!-- Observed -->"})
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())
            self.assertIn('no "Observed / Not run" section', result.stderr)

    def test_bug_fix_with_observed_section_does_not_warn(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, pr_fields={"title": "Fix the sidebar group", "body": "## Observed / Not run\n- base red, head green"})
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())
            self.assertNotIn("Observed / Not run", result.stderr)

    def test_exploration_label_refuses_before_merging(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, labels=("exploration",))
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("exploration PR, needs a decision from Leo or the team before merging.", result.stderr)

    def test_an_early_refusal_prints_exactly_one_summary_line(self):
        """The exploration label refuses before the base decides the gate; the run still says so once."""
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, full=False, labels=("exploration",))
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            summary = [line for line in result.stderr.splitlines() if line.startswith("gh-merge-green:")]
            self.assertEqual(len(summary), 1, result.stderr)
            self.assertIn("refused", summary[0])
            self.assertNotIn("merged", summary[0])

    def test_exploration_label_refuses_main_fix_before_validator(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            symlink = directory / "gh-merge-green"
            symlink.symlink_to(ROOT / "scripts/gh-merge-green")
            validator_marker = directory / "validator-called"
            python = directory / "python3"
            python.write_text("#!/bin/sh\ntouch \"$VALIDATOR_MARKER\"\n")
            python.chmod(0o755)
            gh = directory / "gh"
            gh.write_text(
                "#!/bin/sh\n"
                "if [ \"$1 $2\" = 'pr view' ]; then printf '%s\\n' '{\"headRefOid\":\""
                + HEAD
                + "\",\"baseRefName\":\"main\",\"labels\":[{\"name\":\"exploration\"}]}'; exit 0; fi\n"
                "exit 2\n"
            )
            gh.chmod(0o755)
            result = subprocess.run(
                [str(symlink), "manaflow-ai/cmux#42", "--main-fix", "--squash"],
                cwd=directory,
                env={
                    **os.environ,
                    "PATH": str(directory) + os.pathsep + os.environ["PATH"],
                    "VALIDATOR_MARKER": str(validator_marker),
                    "GH_MERGE_GREEN_NO_AUTO_UPDATE": "1",
                },
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(validator_marker.exists())
            self.assertIn("exploration PR, needs a decision from Leo or the team before merging.", result.stderr)

    def test_a_cmux_next_run_still_running_refuses_even_with_override(self):
        """ci-status and the reported checks were green while the cmux-next run's
        native jobs were still queued (#17602) or rerunning after a runner loss
        (#17625): those heads merged with Mac tests that never ran."""
        cases = {
            "native jobs not created yet": [("in_progress", None, 1)],
            "rerun queued after a runner loss": [("completed", "cancelled", 1), ("queued", None, 2)],
            "rerun waiting": [("waiting", None, 2)],
        }
        for label, runs in cases.items():
            for extra_args in ((), ("--override", "the cmux-next swift test is red on the feat-cmux-next base for the same test")):
                with self.subTest(label=label, override=bool(extra_args)), tempfile.TemporaryDirectory() as directory:
                    marker = Path(directory) / "merged"
                    result = self.run_helper(directory, marker, cmux_next_runs=runs, extra_args=extra_args)
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertFalse(marker.exists())
                    self.assertIn("cmux-next run", result.stderr)
                    self.assertIn("still", result.stderr)

    def test_a_cmux_next_run_that_did_not_succeed_refuses_even_with_override(self):
        """A cancelled cmux-next run is completed, so the pending-run guard let
        #17653, #18079, #18080 and #18083 merge in the seconds between cancelling
        stale queued runs and rerunning them: swift test, generated files and
        Release compile never ran. Routing skips happen inside a successful run,
        so only a run that concluded success shows the native lanes ran or were
        not needed."""
        cases = {
            "cancelled before the rerun started": [("completed", "cancelled", 1)],
            "skipped run": [("completed", "skipped", 1)],
            "timed out": [("completed", "timed_out", 1)],
            "startup failure": [("completed", "startup_failure", 1)],
            "newest run cancelled after an older success": [("completed", "success", 1), ("completed", "cancelled", 1)],
        }
        for label, runs in cases.items():
            for extra_args in ((), ("--override", "the cmux-next swift test is red on the feat-cmux-next base for the same test")):
                with self.subTest(label=label, override=bool(extra_args)), tempfile.TemporaryDirectory() as directory:
                    marker = Path(directory) / "merged"
                    result = self.run_helper(directory, marker, cmux_next_runs=runs, extra_args=extra_args)
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertFalse(marker.exists())
                    self.assertIn("cmux-next run", result.stderr)

    def test_a_pull_request_outside_the_cmux_next_paths_filter_merges(self):
        """cmux-next.yml filters pull_request by paths, so a docs or CI change has
        no cmux-next run; ci-status on the exact head still gates it."""
        for files in (["docs/README.md"], ["scripts/cmux-next/sub/bundle-x.sh", "README.md"], ["docs/mdm/README.md", "docs/mdm/keep.md"]):
            with self.subTest(files=files), tempfile.TemporaryDirectory() as directory:
                marker = Path(directory) / "merged"
                result = self.run_helper(directory, marker, cmux_next_runs=[], changed_files=files)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue(marker.exists())

    def test_no_cmux_next_run_for_a_covered_change_refuses_even_with_override(self):
        """#18100 merged seconds after a push, before GitHub had created the
        cmux-next run for its head: no run and a green ci-status passed. A change
        the workflow's paths filter covers gets a run, so its absence means the
        run does not exist yet."""
        for files in (["Packages/macOS/CmuxNext/Sources/CmuxNextApp/A.swift"], ["docs/README.md", "scripts/cmux-next/bundle-acpmux.sh"]):
            for extra_args in ((), ("--override", "the cmux-next swift test is red on the feat-cmux-next base for the same test")):
                with self.subTest(files=files, override=bool(extra_args)), tempfile.TemporaryDirectory() as directory:
                    marker = Path(directory) / "merged"
                    result = self.run_helper(directory, marker, cmux_next_runs=[], changed_files=files, extra_args=extra_args)
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertFalse(marker.exists())
                    self.assertIn("cmux-next run", result.stderr)

    def test_no_cmux_next_run_with_an_unreadable_workflow_refuses(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, cmux_next_runs=[], cmux_next_workflow="")
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())

    def test_an_older_cancelled_cmux_next_run_behind_a_success_merges(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, cmux_next_runs=[("completed", "cancelled", 1), ("completed", "success", 1)])
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())

    def test_a_failed_cmux_next_run_needs_an_override(self):
        """A red native lane on the base stays waivable, as its check run is."""
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, cmux_next_runs=[("completed", "failure", 1)])
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("cmux-next run", result.stderr)
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, cmux_next_runs=[("completed", "failure", 1)],
                                     extra_args=("--override", "the cmux-next swift test is red on the feat-cmux-next base for the same test"))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())

    def test_a_finished_cmux_next_run_merges(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, cmux_next_runs=[("completed", "success", 1)])
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())

    FAST_GREEN = (
        ("cmux-next path routing", "completed", "success"),
        ("cmux-next fast tier", "completed", "success"),
        ("cmux-next Swift canary", "completed", "success"),
        ("cmux-next swift test", "in_progress", ""),
        ("cmux-next daemon tests", "queued", ""),
    )
    SWIFT = ("Packages/macOS/CmuxNext/Sources/CmuxNextApp/A.swift",)

    def test_feat_next_merges_on_the_fast_gate_without_waiting_for_the_full_suites(self):
        """Lawrence 2026-10-14: waiting for every check slowed iteration. A feat-cmux-next
        merge needs only the fast tier and the touched compiles on the exact head; the
        swift test, daemon tests and the rest of the cmux-next run land after it."""
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, full=False, changed_files=self.SWIFT, rollup=self.FAST_GREEN,
                                     cmux_next_runs=[("in_progress", None, 1)],
                                     extra_checks=[("cmux-next swift test", "in_progress", "")])
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())
            summary = [line for line in result.stderr.splitlines() if line.startswith("gh-merge-green:")]
            self.assertEqual(len(summary), 1, result.stderr)
            self.assertIn("fast gate", summary[0])
            self.assertIn("cmux-next fast tier", summary[0])
            self.assertIn("waited", summary[0])

    def test_a_merge_stopped_while_the_gate_waits_says_so(self):
        """2026-10-20: a caller's timeout stopped gh-merge-green while the fast tier was still
        queued, and its summary read "refused ... (fast gate: nothing reported; waited 0m00s)"."""
        queued = tuple(("cmux-next fast tier", "queued", "") if name == "cmux-next fast tier" else (name, status, c)
                       for name, status, c in self.FAST_GREEN)
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, full=False, changed_files=self.SWIFT, rollup=queued,
                                     cmux_next_runs=[("in_progress", None, 1)], extra_args=("--wait", "600"),
                                     terminate_after=2)
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertFalse(marker.exists())
            summary = [line for line in result.stderr.splitlines() if line.startswith("gh-merge-green:")]
            self.assertEqual(len(summary), 1, result.stderr)
            self.assertIn("stopped by SIGTERM (check the PR)", summary[0])
            self.assertIn("still waiting for the gate's lanes when stopped", summary[0])
            self.assertNotIn("nothing reported", summary[0])

    def test_a_wait_that_runs_out_names_the_queued_lane_in_the_summary(self):
        """2026-10-20: #22200's --wait ran out with the fast tier still QUEUED, and the summary
        read `fast gate: nothing reported; waited 0m00s, 898s in all`."""
        queued = tuple(("cmux-next fast tier", "queued", "") if name == "cmux-next fast tier" else (name, status, c)
                       for name, status, c in self.FAST_GREEN)
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, full=False, changed_files=self.SWIFT, rollup=queued,
                                     extra_args=("--wait", "0"))
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertFalse(marker.exists())
            summary = [line for line in result.stderr.splitlines() if line.startswith("gh-merge-green:")]
            self.assertEqual(len(summary), 1, result.stderr)
            self.assertIn("--wait ran out with cmux-next fast tier (queued) not done", summary[0])
            self.assertNotIn("nothing reported", summary[0])

    RATE_SPENT = {"core": {"limit": 5000, "remaining": 0, "reset": 4102444800},
                  "graphql": {"limit": 5000, "remaining": 4800, "reset": 4102444800}}

    def test_a_spent_rest_quota_refuses_at_once_with_the_reset_time(self):
        """2026-10-20: GraphQL was rate-limited, the REST fallback was too, and gh-merge-green
        refused only about 30 minutes later, with no reset time."""
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, full=False, changed_files=self.SWIFT, rollup=self.FAST_GREEN,
                                     rate_limit=self.RATE_SPENT)
            self.assertEqual(result.returncode, 75, result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("rate-limited:", result.stderr)
            self.assertIn("core 0 of 5000 left, resets 00:00:00Z", result.stderr)
            summary = [line for line in result.stderr.splitlines() if line.startswith("gh-merge-green:")]
            self.assertEqual(len(summary), 1, result.stderr)
            self.assertIn("refused (GitHub rate limit)", summary[0])

    def test_a_rate_limited_paths_filter_read_refuses_before_the_wait(self):
        """Review on #22443: a rate-limited read of the base's paths filter counted as covered,
        and the fast gate then waited out --wait for routing that never came."""
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, full=False, changed_files=("docs/README.md",), rollup=(),
                                     base_workflow=RATE_LIMITED, extra_args=("--wait", "600"))
            self.assertEqual(result.returncode, 75, result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("rate-limited: GitHub rate-limited gh api", result.stderr)

    def test_a_red_after_a_recovered_rate_limited_read_is_still_a_red(self):
        """Review on #22443: the REST file list was rate-limited and its GraphQL fallback answered;
        a genuine red after it is an ordinary refusal (exit 1), not a rate limit."""
        rollup = [c for c in self.FAST_GREEN if c[0] != "cmux-next fast tier"] + [("cmux-next fast tier", "completed", "failure")]
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, full=False, changed_files=self.SWIFT, rollup=rollup,
                                     files_rest_fails="quota", excuse=(1, "not excused: the head's own red"))
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("used GraphQL fallback", result.stderr)
            self.assertNotIn("rate-limited:", result.stderr)

    def test_a_rate_limited_base_comparison_refuses_as_rate_limited(self):
        rollup = [c for c in self.FAST_GREEN if c[0] != "cmux-next fast tier"] + [("cmux-next fast tier", "completed", "failure")]
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, full=False, changed_files=self.SWIFT, rollup=rollup,
                                     excuse=(3, "rate-limited: core 0 of 5000 left"))
            self.assertEqual(result.returncode, 75, result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("rate-limited:", result.stderr)

    def test_the_fast_gate_refuses_a_red_fast_lane_or_a_red_gating_check(self):
        for red in (("cmux-next fast tier", "completed", "failure"),
                    ("cmux-next Swift canary", "completed", "failure"),
                    ("web / react-apps-check", "completed", "failure"),
                    ("app-size", "completed", "failure")):
            rollup = [c for c in self.FAST_GREEN if c[0] != red[0]] + [red]
            with self.subTest(red=red[0]), tempfile.TemporaryDirectory() as directory:
                marker = Path(directory) / "merged"
                result = self.run_helper(directory, marker, full=False, changed_files=self.SWIFT, rollup=rollup)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(marker.exists())
                self.assertIn(red[0], result.stderr)

    def test_the_fast_gate_waits_for_a_fast_lane_and_gives_up_at_its_timeout(self):
        rollup = [c for c in self.FAST_GREEN if c[0] != "cmux-next fast tier"] + [("cmux-next fast tier", "in_progress", "")]
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, full=False, changed_files=self.SWIFT, rollup=rollup,
                                     extra_args=("--wait", "0"))
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("still waiting on cmux-next fast tier", result.stderr)

    def test_the_fast_gate_waits_for_routing_before_the_run_exists(self):
        """Right after a push nothing has reported; a covered change waits for routing."""
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, full=False, changed_files=self.SWIFT, rollup=(),
                                     cmux_next_runs=[], extra_args=("--wait", "0"))
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("cmux-next path routing", result.stderr)

    OVERRIDE = "the fast tier is red on the feat-cmux-next base for the same test"
    LINT = "cmux-next checks (god files, concurrency, crash safety, l10n)"

    def test_override_waives_a_red_fast_lane_on_the_fast_gate(self):
        rollup = [c for c in self.FAST_GREEN if c[0] != "cmux-next fast tier"] + [("cmux-next fast tier", "completed", "failure")]
        with tempfile.TemporaryDirectory() as directory:
            marker, events = Path(directory) / "merged", Path(directory) / "events"
            result = self.run_helper(directory, marker, full=False, changed_files=self.SWIFT, rollup=rollup,
                                     extra_args=("--override", self.OVERRIDE), event_log=events,
                                     excuse=(1, "the base is green"))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())
            self.assertEqual(events.read_text().splitlines(), ["comment", "merge"])
            self.assertIn("--override waives cmux-next fast tier", result.stderr)

    def test_override_waives_a_red_lint_check_on_the_fast_gate(self):
        """--override is the human escape hatch for a red lint check too: its reason is
        posted on the PR before the merge, so every waiver is on the record."""
        rollup = list(self.FAST_GREEN) + [(self.LINT, "completed", "failure")]
        with tempfile.TemporaryDirectory() as directory:
            marker, events = Path(directory) / "merged", Path(directory) / "events"
            result = self.run_helper(directory, marker, full=False, changed_files=self.SWIFT, rollup=rollup,
                                     extra_args=("--override", self.OVERRIDE), event_log=events,
                                     excuse=(1, "the base is green"))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())
            self.assertEqual(events.read_text().splitlines(), ["comment", "merge"])
            self.assertIn(f"--override waives {self.LINT}", result.stderr)

    # The check-path gate (scripts/ci/merge_check_paths.py, tests/test_merge_check_paths.py): 2026-10-21, #22975
    # merged after #23365 landed check:fixed-waits on the base and never ran it.
    CHECK_PATHS = "webviews/scripts/check-*\n.github/workflows/ci-web.yml\n"
    LANDED = {"status": "ahead", "ahead_by": 1, "files": [".github/workflows/ci-web.yml", "webviews/scripts/check-fixed-waits.ts"]}

    def test_the_check_path_gate_passes_a_fresh_fast_gates_result(self):
        with tempfile.TemporaryDirectory() as directory:
            marker, events = Path(directory) / "merged", Path(directory) / "events"
            result = self.run_helper(directory, marker, full=False, changed_files=self.SWIFT, rollup=self.FAST_GREEN,
                                     event_log=events, check_paths=self.CHECK_PATHS, fast_gates_base=ANCESTOR,
                                     tip_sha=ANCESTOR)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())
            self.assertEqual(events.read_text().splitlines(), ["merge"])
            self.assertIn("check paths fresh", result.stdout + result.stderr)

    def test_replay_of_22975_the_check_path_gate_reruns_the_fast_gates_and_refuses_their_red(self):
        with tempfile.TemporaryDirectory() as directory:
            marker, events = Path(directory) / "merged", Path(directory) / "events"
            result = self.run_helper(directory, marker, full=False, changed_files=self.SWIFT, rollup=self.FAST_GREEN,
                                     event_log=events, check_paths=self.CHECK_PATHS, fast_gates_base=ANCESTOR,
                                     fast_gates_after=(MERGED_SHA, "failure"), tip_sha=MERGED_SHA,
                                     compare=self.LANDED)
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertEqual(events.read_text().splitlines(), ["dispatch"])
            self.assertIn("has changed the check path .github/workflows/ci-web.yml since", result.stderr)
            self.assertIn("check-path gate", result.stderr)

    def test_the_check_path_gate_merges_on_the_reruns_fresh_success(self):
        with tempfile.TemporaryDirectory() as directory:
            marker, events = Path(directory) / "merged", Path(directory) / "events"
            result = self.run_helper(directory, marker, full=False, changed_files=self.SWIFT, rollup=self.FAST_GREEN,
                                     event_log=events, check_paths=self.CHECK_PATHS, fast_gates_base=ANCESTOR,
                                     fast_gates_after=(MERGED_SHA, "success"), tip_sha=MERGED_SHA,
                                     compare=self.LANDED)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())
            self.assertEqual(events.read_text().splitlines(), ["dispatch", "merge"])

    def test_override_waives_the_check_path_gates_red(self):
        with tempfile.TemporaryDirectory() as directory:
            marker, events = Path(directory) / "merged", Path(directory) / "events"
            result = self.run_helper(directory, marker, full=False, changed_files=self.SWIFT, rollup=self.FAST_GREEN,
                                     event_log=events, check_paths=self.CHECK_PATHS, fast_gates_base=ANCESTOR,
                                     fast_gates_after=(MERGED_SHA, "failure"), tip_sha=MERGED_SHA,
                                     compare=self.LANDED, extra_args=("--override", self.OVERRIDE))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())
            self.assertIn("merge", events.read_text().splitlines())
            self.assertIn("--override waives the check-path gate", result.stderr)

    def test_a_dry_run_dispatches_nothing_for_a_stale_check_path(self):
        with tempfile.TemporaryDirectory() as directory:
            marker, events = Path(directory) / "merged", Path(directory) / "events"
            result = self.run_helper(directory, marker, full=False, changed_files=self.SWIFT, rollup=self.FAST_GREEN,
                                     event_log=events, check_paths=self.CHECK_PATHS, fast_gates_base=ANCESTOR,
                                     tip_sha=MERGED_SHA, compare=self.LANDED, extra_args=("--dry-run",))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertFalse(events.exists() and "dispatch" in events.read_text())
            self.assertIn("a merge would dispatch", result.stderr)

    def test_a_red_fast_lane_the_base_shares_merges_on_the_fast_gate(self):
        rollup = [c for c in self.FAST_GREEN if c[0] != "cmux-next fast tier"] + [("cmux-next fast tier", "completed", "failure")]
        with tempfile.TemporaryDirectory() as directory:
            marker, events = Path(directory) / "merged", Path(directory) / "events"
            result = self.run_helper(directory, marker, full=False, changed_files=self.SWIFT, rollup=rollup,
                                     event_log=events, excuse=(0, "cmux-next fast tier: red on the base too"))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())
            self.assertEqual(events.read_text().splitlines(), ["merge"])
            self.assertIn("note: cmux-next fast tier: red on the base too", result.stderr)

    def test_a_red_lint_check_the_base_prints_too_merges_on_the_fast_gate(self):
        """Like the full gate (#22128): the base comparison excuses a lint red only when the
        base prints every finding."""
        rollup = list(self.FAST_GREEN) + [(self.LINT, "completed", "failure")]
        with tempfile.TemporaryDirectory() as directory:
            marker, events = Path(directory) / "merged", Path(directory) / "events"
            result = self.run_helper(directory, marker, full=False, changed_files=self.SWIFT, rollup=rollup,
                                     event_log=events, excuse=(0, f"{self.LINT}: red on the base too"))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())
            self.assertIn("red on the base too", result.stderr)

    def test_the_fast_gate_waits_for_a_pending_lint_check(self):
        """main's full gate never lets a pending god-file, l10n or concurrency check
        through (#21692); the fast gate waits for it instead of merging past it."""
        rollup = list(self.FAST_GREEN) + [(self.LINT, "in_progress", "")]
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, full=False, changed_files=self.SWIFT, rollup=rollup,
                                     extra_args=("--wait", "0"))
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn(f"still waiting on {self.LINT}", result.stderr)

    def test_the_fast_gate_refuses_a_completed_red_in_a_full_gate_lane(self):
        """It does not wait for ci-status, the swift test or the Release compile, but one that
        already finished red is judged as the full gate judges it: refused unless the base has it."""
        for red in ("ci-status", "cmux-next swift test", "cmux-next Release compile (Xcode 26)"):
            rollup = [c for c in self.FAST_GREEN if c[0] != red] + [(red, "completed", "failure")]
            with self.subTest(red=red), tempfile.TemporaryDirectory() as directory:
                marker = Path(directory) / "merged"
                result = self.run_helper(directory, marker, full=False, changed_files=self.SWIFT, rollup=rollup,
                                         excuse=(1, "the base is green"))
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(marker.exists())
                self.assertIn(f"{red} red on {HEAD}, not excused", result.stderr)

    def test_the_fast_gate_keeps_the_graphql_fallback_for_changed_files(self):
        """#21529: a REST file listing that fails falls back to GraphQL on the fast gate too
        (its own routing read and the freeze check), rather than refusing."""
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, full=False, changed_files=self.SWIFT, rollup=self.FAST_GREEN,
                                     files_rest_fails=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())
            self.assertIn("used GraphQL fallback to inspect changed files", result.stderr)

    def test_a_base_retargeted_during_the_fast_wait_refuses(self):
        """--match-head-commit pins the head, not the base: a PR moved from feat-cmux-next
        to main while the fast gate waits must not merge into main on it."""
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, full=False, changed_files=self.SWIFT, rollup=self.FAST_GREEN,
                                     rollup_base="main")
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("base changed to main", result.stderr)

    def test_a_base_retargeted_before_the_merge_refuses_on_both_gates(self):
        for full in (False, True):
            with self.subTest(full=full), tempfile.TemporaryDirectory() as directory:
                marker = Path(directory) / "merged"
                result = self.run_helper(directory, marker, full=full, changed_files=self.SWIFT if not full else ("docs/README.md",),
                                         rollup=self.FAST_GREEN, base_after="main")
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(marker.exists())
                self.assertIn("base moved from feat-cmux-next to main", result.stderr)

    def test_override_does_not_waive_a_cancelled_fast_lane(self):
        """Like the full gate's cmux-next run: a cancelled or timed-out lane has no verdict to waive."""
        for conclusion in ("cancelled", "timed_out"):
            rollup = [c for c in self.FAST_GREEN if c[0] != "cmux-next fast tier"] + [("cmux-next fast tier", "completed", conclusion)]
            with self.subTest(conclusion=conclusion), tempfile.TemporaryDirectory() as directory:
                marker, events = Path(directory) / "merged", Path(directory) / "events"
                result = self.run_helper(directory, marker, full=False, changed_files=self.SWIFT, rollup=rollup,
                                         extra_args=("--override", self.OVERRIDE), event_log=events)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(marker.exists())
                self.assertFalse(events.exists())
                self.assertIn("no verdict", result.stderr)

    def test_the_fast_gate_refuses_when_a_lane_it_keys_on_is_renamed(self):
        """A renamed job would otherwise drop out of the gate silently."""
        renamed = CMUX_NEXT_WORKFLOW.replace("cmux-next checks (god files, concurrency, crash safety, l10n)", "cmux-next checks")
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, full=False, changed_files=self.SWIFT, rollup=self.FAST_GREEN,
                                     cmux_next_workflow=renamed)
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("god-file, l10n or concurrency lint job", result.stderr)

    def test_the_fast_gate_refuses_an_untrusted_fork(self):
        """The full gate refuses an untrusted fork in merged_head_checks (#21587); the fast
        gate skips those checks, so it must refuse the fork itself, before the wait."""
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, full=False, changed_files=self.SWIFT, rollup=self.FAST_GREEN,
                                     is_cross_repository=True)
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("untrusted fork", result.stderr)
            self.assertIn("--trust-fork-head", result.stderr)

    def test_the_fast_gate_merges_a_fork_head_trusted_by_sha(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, full=False, changed_files=self.SWIFT, rollup=self.FAST_GREEN,
                                     is_cross_repository=True, extra_args=("--trust-fork-head", HEAD))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())

    def test_the_fast_gate_reads_the_paths_filter_from_the_base(self):
        """A PR that drops its own files from cmux-next.yml's paths filter must not skip
        the routing wait: the filter that decides is the base's."""
        head_workflow = CMUX_NEXT_WORKFLOW.replace("      - Packages/macOS/CmuxNext/**\n", "")
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, full=False, changed_files=self.SWIFT, rollup=(),
                                     cmux_next_workflow=head_workflow, base_workflow=CMUX_NEXT_WORKFLOW,
                                     extra_args=("--wait", "0"))
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("cmux-next path routing", result.stderr)

    def test_an_untrusted_fork_refuses_before_the_fast_wait(self):
        """The fork refusal comes before the fast gate decides anything: with fast lanes
        still pending and --override, the refusal names the fork, not the wait."""
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, full=False, changed_files=self.SWIFT, rollup=(),
                                     is_cross_repository=True,
                                     extra_args=("--wait", "0", "--override", "the red check is a known base failure on this exact head"))
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("untrusted fork", result.stderr)
            self.assertNotIn("still waiting", result.stderr)

    def test_a_web_file_past_the_first_100_still_waits_for_react_apps_check(self):
        """gh pr view --json files stops at 100 files; the helper's paginated REST list
        decides web routing, so a webviews file at position 101 still waits."""
        files = tuple(f"docs/{i}.md" for i in range(100)) + ("webviews/src/a.ts",)
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, full=False, changed_files=files, rollup=(),
                                     rollup_files_limit=100, extra_args=("--wait", "0"))
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("react-apps-check", result.stderr)

    def test_feat_next_refuses_a_head_with_no_review_receipt(self):
        """2026-10-21: cmux#22899 merged before its re-review, which then found cmux#22988, and
        #22911 merged before its green run. Into feat-cmux-next a head merges only with an
        independent review's SHIP receipt for that exact head, as next-autoland requires."""
        old = reviews_fixture((f"Review (subagent, correctness first): SHIP at {'b' * 40}", "2026-10-21T05:00:00Z"))
        for name, reviews in (("none", reviews_fixture()), ("an older head", old)):
            for full in (False, True):
                with self.subTest(receipt=name, full=full), tempfile.TemporaryDirectory() as directory:
                    marker = Path(directory) / "merged"
                    result = self.run_helper(directory, marker, full=full, changed_files=self.SWIFT, rollup=self.FAST_GREEN,
                                             reviews=reviews)
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertFalse(marker.exists())
                    self.assertIn("no SHIP review receipt", result.stderr)
                    self.assertIn(f"Review (subagent, correctness first): SHIP at {HEAD}", result.stderr)

    def test_override_cannot_waive_the_review_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            marker, events = Path(directory) / "merged", Path(directory) / "events"
            result = self.run_helper(directory, marker, full=False, changed_files=self.SWIFT, rollup=self.FAST_GREEN,
                                     extra_args=("--override", self.OVERRIDE), event_log=events, reviews=reviews_fixture())
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("no SHIP review receipt", result.stderr)
            self.assertIn("--override cannot waive", result.stderr)
            self.assertFalse(events.exists() and "comment" in events.read_text(), "posted an override for a refused merge")

    def test_a_newer_block_on_the_head_beats_its_ship(self):
        reviews = reviews_fixture((SHIP_RECEIPT, "2026-10-21T05:00:00Z"),
                                  (f"Independent review (codex): BLOCK at {HEAD[:12]}: drops a lock", "2026-10-21T06:00:00Z"))
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, full=False, changed_files=self.SWIFT, rollup=self.FAST_GREEN,
                                     reviews=reviews)
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("no SHIP review receipt", result.stderr)

    def test_a_block_posted_during_the_wait_refuses_before_the_override_comment(self):
        """The receipt is read again right before the merge, ahead of the merge-override and
        merge-source-trust comments: a BLOCK posted while the gate waited stops the merge and
        leaves no override on the record for a merge that never happened."""
        during = reviews_fixture((SHIP_RECEIPT, "2026-10-21T05:00:00Z"),
                                 (f"Independent review (codex): BLOCK at {HEAD[:12]}: drops a lock", "2026-10-21T06:00:00Z"))
        with tempfile.TemporaryDirectory() as directory:
            marker, events = Path(directory) / "merged", Path(directory) / "events"
            result = self.run_helper(directory, marker, full=False, changed_files=self.SWIFT, rollup=self.FAST_GREEN,
                                     extra_args=("--override", self.OVERRIDE), event_log=events, reviews_final=during)
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("no SHIP review receipt", result.stderr)
            self.assertFalse(events.exists() and "comment" in events.read_text(), "posted an override for a refused merge")

    def test_the_receipt_is_named_when_the_head_merges(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, full=False, changed_files=self.SWIFT, rollup=self.FAST_GREEN)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())
            self.assertIn("review receipt", result.stderr)

    def test_main_does_not_need_a_review_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, full=False, base="main", reviews=reviews_fixture())
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())

    def test_a_test_run_without_the_reviews_fixture_refuses(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, full=False, changed_files=self.SWIFT, rollup=self.FAST_GREEN,
                                     reviews="")
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("GH_MERGE_GREEN_REVIEWS", result.stderr)

    def test_main_keeps_the_full_wait_without_full(self):
        """Only feat-cmux-next gets the fast gate: a main PR with green fast lanes and a
        pending ci-status still waits on everything, without --full."""
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, full=False, base="main", rollup=self.FAST_GREEN,
                                     check_name="ci-status", extra_checks=[], check_conclusion="")
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            summary = [line for line in result.stderr.splitlines() if line.startswith("gh-merge-green:")]
            self.assertEqual(len(summary), 1, result.stderr)
            self.assertIn("full gate", summary[0])

    def test_full_keeps_the_wait_for_every_check(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, full=True, changed_files=self.SWIFT, rollup=self.FAST_GREEN,
                                     cmux_next_runs=[("in_progress", None, 1)])
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("cmux-next run", result.stderr)

    def test_the_full_gate_also_prints_one_summary_line(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, full=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            summary = [line for line in result.stderr.splitlines() if line.startswith("gh-merge-green:")]
            self.assertEqual(len(summary), 1, result.stderr)
            self.assertIn("full gate", summary[0])

    def test_ci_status_is_required_on_the_exact_head(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())

    def test_ci_status_remains_required_after_gate_removal(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())

    def test_feat_next_native_and_release_checks_are_required_when_reported(self):
        names = (
            "cmux-next Release compile (Xcode 26)",
            "cmux app scheme compile (Debug)",
            "cmux-next swift test",
        )
        for name, status, conclusion in (
            (names[0], "in_progress", ""),
            (names[1], "completed", "failure"),
        ):
            with self.subTest(name=name, status=status, conclusion=conclusion), tempfile.TemporaryDirectory() as directory:
                marker = Path(directory) / "merged"
                result = self.run_helper(directory, marker, extra_checks=[(name, status, conclusion)])
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(marker.exists())
                self.assertIn(name, result.stderr)
                self.assertIn("REPAIR.md#merging", result.stderr)

        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(
                directory,
                marker,
                extra_checks=[(name, "completed", "success") for name in names],
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())

    def test_override_posts_reason_before_merging_a_completed_red_check(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            events = Path(directory) / "events"
            reason = "ci-status is a known main failure and this exact fix repairs the failing path"
            result = self.run_helper(
                directory,
                marker,
                check_conclusion="failure",
                extra_args=("--override", reason),
                event_log=events,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())
            self.assertEqual(events.read_text().splitlines(), ["comment", "merge"])

    def test_override_waives_a_red_god_file_l10n_or_concurrency_lint(self):
        reason = "the lint red is a known base failure unrelated to this change"
        for name in (
            "cmux-next checks (god files, concurrency, crash safety, l10n)",
            "cmux-next god files",
            "cmux-next l10n",
            "concurrency lint",
        ):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                marker = Path(directory) / "merged"
                events = Path(directory) / "events"
                result = self.run_helper(
                    directory,
                    marker,
                    extra_checks=[(name, "completed", "failure")],
                    extra_args=("--override", reason),
                    event_log=events,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue(marker.exists())
                self.assertEqual(events.read_text().splitlines(), ["comment", "merge"])

    def test_override_cannot_bypass_risk_evidence_or_a_pending_lint_check(self):
        reason = "the swift test lane is a known base failure unrelated to this change"
        cases = [("risk evidence", "completed", "failure"), ("risk evidence", "in_progress", "")]
        cases += [(name, "in_progress", "") for name in (
            "cmux-next checks (god files, concurrency, crash safety, l10n)",
            "cmux-next god files",
            "cmux-next l10n",
            "concurrency lint",
        )]
        for name, status, conclusion in cases:
            with self.subTest(name=name, status=status), tempfile.TemporaryDirectory() as directory:
                marker = Path(directory) / "merged"
                events = Path(directory) / "events"
                result = self.run_helper(
                    directory,
                    marker,
                    check_conclusion="failure",
                    extra_checks=[(name, status, conclusion)],
                    extra_args=("--override", reason),
                    event_log=events,
                )
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(marker.exists())
                self.assertFalse(events.exists(), "the override reason was posted before refusing")
                self.assertIn(name, result.stderr)
                self.assertIn("--override cannot bypass", result.stderr)

    def test_red_lint_check_refuses_without_override(self):
        name = "cmux-next checks (god files, concurrency, crash safety, l10n)"
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, extra_checks=[(name, "completed", "failure")])
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn(name, result.stderr)
            # The base is asked whether it fails the same way before refusing.
            self.assertIn(f"'{name}' on {HEAD}, not excused by feat-cmux-next", result.stderr)

    def test_override_still_merges_when_lint_checks_are_green(self):
        name = "cmux-next checks (god files, concurrency, crash safety, l10n)"
        reason = "the swift test lane is a known base failure unrelated to this change"
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(
                directory,
                marker,
                check_conclusion="failure",
                extra_checks=[(name, "completed", "success")],
                extra_args=("--override", reason),
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())

    def test_override_requires_eight_words(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(
                directory,
                marker,
                check_conclusion="failure",
                extra_args=("--override", "too short"),
            )
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("8 words", result.stderr)

    def test_refusal_prints_repair_guidance(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, check_name="other-check")
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("fix:", result.stderr)
            self.assertIn("see cmuxterm-hq REPAIR.md#merging", result.stderr)

    def test_main_fix_without_any_compile_evidence_refuses_to_merge(self):
        with tempfile.TemporaryDirectory() as directory:
            gh = Path(directory) / "gh"
            marker = Path(directory) / "merged"
            gh.write_text("#!/bin/sh\ncase \"$*\" in\n*'pr view'*) echo '{\"headRefOid\":\"" + HEAD + "\",\"baseRefName\":\"feat-cmux-next\",\"labels\":[]}';;\n*'pulls/42') echo '{\"state\":\"open\",\"head\":{\"sha\":\"" + HEAD + "\"},\"base\":{\"sha\":\"" + BASE + "\",\"ref\":\"feat-cmux-next\"}}';;\n*'pr merge'*) touch \"$MERGE_MARKER\";;\n*) echo '[]';;\nesac\n")
            gh.chmod(0o755)
            result = subprocess.run([str(ROOT / "scripts/gh-merge-green"), "manaflow-ai/cmux#42", "--main-fix", "--squash"], env={**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"], "MERGE_MARKER": str(marker), "GH_MERGE_GREEN_NO_AUTO_UPDATE": "1"}, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists(), "the helper merged without any compile evidence")

    def test_large_file_and_patch_lists_do_not_trip_pipefail(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            marker = directory / "merged"
            gh = directory / "gh"
            gh.write_text(textwrap.dedent(f"""\
                #!/bin/sh
                if [ "$1 $2" = 'pr view' ]; then
                  printf '%s\\n' '{{"headRefOid":"{HEAD}","baseRefName":"main"}}'
                  exit 0
                fi
                if [ "$1 $2" = 'pr merge' ]; then
                  touch "$MERGE_MARKER"
                  exit 0
                fi
                if [ "$1" = api ] && printf '%s' "$*" | grep -q 'contents/scripts/ci/check-paths.txt'; then
                  echo 'gh: Not Found (HTTP 404)' >&2; exit 1
                fi
                if [ "$1" = api ] && printf '%s' "$*" | grep -q '/contents/'; then
                  printf '%s\\n' 'HTTP/2.0 200'; exit 0
                fi
                if [ "$1" = api ] && printf '%s' "$*" | grep -q '/pulls/42/files'; then
                  case "$*" in
                    *'.[].filename'*) i=0; while [ "$i" -lt 100000 ]; do printf '%s\\n' 'Sources/Large.swift'; i=$((i + 1)); done ;;
                    *'.[].patch'*)
                      if [ "$INCLUDE_CONFLICT" = 1 ]; then printf '%s\\n' '+<<<<<<< HEAD'; fi
                      i=0; while [ "$i" -lt 100000 ]; do printf '%s\\n' '+ordinary line'; i=$((i + 1)); done ;;
                  esac
                  exit 0
                fi
                if [ "$1" = api ] && printf '%s' "$*" | grep -q '/check-runs'; then
                  printf '%s\\n' '[{{"check_runs":[{{"id":1,"name":"ci-status","status":"completed","conclusion":"success"}},{{"id":2,"name":"macos / macOS compile admission","status":"completed","conclusion":"success"}}]}}]'
                  exit 0
                fi
                exit 2
            """))
            gh.chmod(0o755)
            result = subprocess.run(
                [str(ROOT / "scripts/gh-merge-green"), "manaflow-ai/cmux#42", "--squash"],
                env={**os.environ, "PATH": str(directory) + os.pathsep + os.environ["PATH"], "MERGE_MARKER": str(marker), "INCLUDE_CONFLICT": "0", "GH_MERGE_GREEN_NO_AUTO_UPDATE": "1"},
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())

            marker.unlink()
            result = subprocess.run(
                [str(ROOT / "scripts/gh-merge-green"), "manaflow-ai/cmux#42", "--squash"],
                env={**os.environ, "PATH": str(directory) + os.pathsep + os.environ["PATH"], "MERGE_MARKER": str(marker), "INCLUDE_CONFLICT": "1", "GH_MERGE_GREEN_NO_AUTO_UPDATE": "1"},
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("conflict", result.stderr)


class WorkflowPresenceRegression(unittest.TestCase):
    """Repositories without the aggregate workflow use all exact-head verdicts."""

    def run_case(self, *, workflow=False, probe_status=404, checks=None, statuses=None, app_workflow=False, files=None, workflow_body=None,
                 raw_content=None, app_workflow_body=None, graphql_workflows=None, extra_args=()):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            marker = directory / "merged"
            queries = directory / "queries"
            payload = {"head": HEAD, "workflow": workflow, "probe_status": probe_status,
                       "checks": checks if checks is not None else [{"id": 1, "name": "tests", "status": "completed", "conclusion": "success"}],
                       "statuses": statuses or [], "app_workflow": app_workflow, "files": files or [],
                       "workflow_body": workflow_body, "raw_content": raw_content, "app_workflow_body": app_workflow_body,
                       "graphql_workflows": graphql_workflows or {}}
            fixture = directory / "fixture.json"
            fixture.write_text(__import__("json").dumps(payload))
            gh = directory / "gh"
            gh.write_text("#!/usr/bin/env python3\n" + textwrap.dedent(r"""
                import json, os, sys
                from pathlib import Path
                x = json.loads(Path(os.environ['FIXTURE']).read_text())
                a = sys.argv[1:]
                with open(os.environ['QUERIES'], 'a') as f: f.write(' '.join(a) + '\n')
                if a[:2] == ['pr', 'view']:
                    print(json.dumps({'headRefOid': x['head'], 'baseRefName': 'main', 'state': 'OPEN'}))
                elif a[:2] == ['pr', 'comment']:
                    pass
                elif a[:2] == ['pr', 'merge']:
                    Path(os.environ['MERGE_MARKER']).touch()
                elif a[:2] == ['api', 'graphql']:
                    expr = next((arg.removeprefix('expr=') for arg in a if arg.startswith('expr=')), '')
                    if expr not in x['graphql_workflows']: sys.exit(2)
                    body = x['graphql_workflows'][expr]
                    print(json.dumps({'data': {'repository': {'object': {'text': body} if body is not None else None}}}))
                elif a[0] == 'api' and any('contents/scripts/ci/check-paths.txt' in arg for arg in a):
                    print('gh: Not Found (HTTP 404)', file=sys.stderr)
                    sys.exit(1)
                elif a[0] == 'api' and any('/contents/' in arg for arg in a):
                    present = x['app_workflow'] if any('ci-macos.yml' in arg for arg in a) else x['workflow']
                    code = 200 if present else x['probe_status']
                    print('HTTP/2.0 ' + str(code))
                    print()
                    body = x['app_workflow_body'] if any('ci-macos.yml' in arg for arg in a) else x['workflow_body']
                    if x['raw_content'] is not None and not any('ci-macos.yml' in arg for arg in a):
                        print(json.dumps(x['raw_content']))
                    elif body is not None:
                        print(json.dumps({'encoding': 'base64', 'content': __import__('base64').b64encode(body.encode()).decode()}))
                    else:
                        print('{}')
                    sys.exit(0 if code == 200 else 1)
                elif a[0] == 'api' and any('/check-runs' in arg for arg in a):
                    print(json.dumps([{'check_runs': x['checks']}]))
                elif a[0] == 'api' and any('/statuses' in arg for arg in a):
                    print(json.dumps([x['statuses']]))
                elif a[0] == 'api' and any('/files' in arg for arg in a):
                    if '.[].filename' in a: print('\n'.join(x['files']))
                else:
                    sys.exit(2)
                """))
            gh.chmod(0o755)
            result = subprocess.run([str(ROOT / 'scripts/gh-merge-green'), 'manaflow-ai/cmuxterm-hq#1254', *extra_args, '--squash'],
                env={**os.environ, 'PATH': str(directory) + os.pathsep + os.environ['PATH'], 'FIXTURE': str(fixture), 'MERGE_MARKER': str(marker), 'QUERIES': str(queries), 'GH_MERGE_GREEN_NO_AUTO_UPDATE': '1'}, capture_output=True, text=True)
            return result, marker.exists(), queries.read_text()

    def test_no_ci_workflow_merges_all_green_checks(self):
        result, merged, queries = self.run_case()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(merged)
        self.assertIn('ref=main', queries)
        self.assertIn('/commits/' + HEAD + '/check-runs', queries)

    def test_no_ci_workflow_accepts_neutral_and_skipped_checks(self):
        for conclusion in ("neutral", "skipped"):
            with self.subTest(conclusion=conclusion):
                result, merged, _ = self.run_case(checks=[{"id": 1, "name": "Vercel Agent Review", "status": "completed", "conclusion": conclusion}])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(merged)

    def test_no_ci_workflow_refuses_pending_failed_and_empty_checks(self):
        for checks in ([], [{'id': 1, 'name': 'tests', 'status': 'in_progress'}],
                       [{'id': 1, 'name': 'tests', 'status': 'completed', 'conclusion': 'failure'}]):
            with self.subTest(checks=checks):
                result, merged, _ = self.run_case(checks=checks)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(merged)
                self.assertIn('REPAIR.md#merging', result.stderr)

    def test_no_ci_workflow_with_an_advisory_red_vercel_check_merges(self):
        # bash 3.2 (macOS /bin/bash) treats an empty array as unset under set -u: the
        # "other failing checks" note died on ${must[*]} with no refusal reason.
        result, merged, _ = self.run_case(checks=[
            {"id": 1, "name": "tests", "status": "completed", "conclusion": "success"},
            {"id": 2, "name": "Vercel", "status": "completed", "conclusion": "failure"}],
            files=["docs/README.md"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(merged)
        self.assertNotIn("unbound variable", result.stderr)

    def test_no_ci_workflow_override_waives_only_a_red_lint_check(self):
        """--full --override waives a red lint check without the aggregate workflow too;
        risk evidence and any other red still refuse."""
        reason = "the lint red is a known base failure unrelated to this change"
        lint = {'id': 2, 'name': 'cmux-next checks (god files, concurrency, crash safety, l10n)', 'status': 'completed', 'conclusion': 'failure'}
        green = {'id': 1, 'name': 'tests', 'status': 'completed', 'conclusion': 'success'}
        result, merged, _ = self.run_case(checks=[green, lint], extra_args=("--override", reason))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(merged)
        self.assertIn("--override waives " + lint['name'], result.stderr)
        result, merged, _ = self.run_case(checks=[green, lint])
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertFalse(merged)
        for other in ({'id': 3, 'name': 'tests', 'status': 'completed', 'conclusion': 'failure'},
                      {'id': 3, 'name': 'risk evidence', 'status': 'completed', 'conclusion': 'failure'}):
            with self.subTest(other=other['name']):
                result, merged, _ = self.run_case(checks=[lint, other], extra_args=("--override", reason))
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertFalse(merged)

    def test_no_ci_workflow_refuses_pending_status_context(self):
        result, merged, _ = self.run_case(statuses=[{'id': 2, 'context': 'review', 'state': 'pending'}])
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(merged)

    def test_vercel_override_waives_only_the_named_external_status(self):
        result, merged, _ = self.run_case(
            statuses=[{'id': 2, 'context': 'Vercel', 'state': 'pending'}],
            extra_args=("--override", "Vercel preview is unrelated to this CLI change"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(merged)
        result, merged, _ = self.run_case(
            statuses=[{'id': 2, 'context': 'review', 'state': 'pending'}],
            extra_args=("--override", "Vercel preview is unrelated to this CLI change"))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(merged)

    def test_large_graphql_workflow_preserves_aggregate_gate(self):
        # Linux limits each argv element to 128 KiB, even when ARG_MAX is larger.
        # Keep the aggregate at the end so truncated content cannot silently merge.
        large_workflow = "name: app\n" + ("# " + "x" * 126 + "\n") * 2048 + "jobs:\n  ci-status:\n    needs: [tests]\n"
        for name, conclusion, should_merge in (("ci-status", "success", True),
                                                ("tests", "success", False),
                                                ("ci-status", "failure", False)):
            with self.subTest(name=name, conclusion=conclusion):
                result, merged, queries = self.run_case(
                    probe_status=500,
                    graphql_workflows={
                        "main:.github/workflows/ci.yml": None,
                        "main:.github/workflows/ci-macos.yml": large_workflow,
                    },
                    checks=[{'id': 1, 'name': name, 'status': 'completed', 'conclusion': conclusion}],
                )
                self.assertEqual(merged, should_merge, result.stdout + result.stderr)
                self.assertEqual(result.returncode == 0, should_merge, result.stderr)
                self.assertIn('expr=main:.github/workflows/ci-macos.yml', queries)
                self.assertIn('used GraphQL fallback to inspect main:.github/workflows/ci-macos.yml', result.stderr)
                self.assertNotIn('Argument list too long', result.stderr)
                if not should_merge:
                    self.assertIn('ci-status', result.stderr)

    def test_workflow_probe_failure_is_not_absence(self):
        for code in (403, 500):
            result, merged, _ = self.run_case(probe_status=code)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(merged)

    def test_present_ci_workflow_still_requires_ci_status(self):
        result, merged, _ = self.run_case(workflow=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(merged)
        self.assertIn('ci-status', result.stderr)

    def test_ci_workflow_without_a_ci_status_job_merges_all_green_checks(self):
        tests_only = "name: CI\non: pull_request\njobs:\n  tests:\n    runs-on: macos-15\n    steps:\n      - run: swift test\n"
        result, merged, _ = self.run_case(workflow=True, workflow_body=tests_only)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(merged)
        result, merged, _ = self.run_case(workflow=True, workflow_body=tests_only,
                                          checks=[{'id': 1, 'name': 'tests', 'status': 'completed', 'conclusion': 'failure'}])
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(merged)

    def test_ci_workflow_with_a_ci_status_job_requires_it(self):
        aggregate = "jobs:\n  tests:\n    runs-on: x\n  # ci-status: in a comment does not count\n  ci-status:\n    needs: [tests]\n"
        result, merged, _ = self.run_case(workflow=True, workflow_body=aggregate)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(merged)
        self.assertIn('ci-status', result.stderr)

    def test_unreadable_workflow_body_still_requires_ci_status(self):
        # The contents API returns empty content with encoding "none" for files over 1 MB.
        for raw in ({'encoding': 'none', 'content': ''}, {'content': None}, {'encoding': 'base64', 'content': ''}):
            with self.subTest(raw=raw):
                result, merged, _ = self.run_case(workflow=True, raw_content=raw)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(merged)
                self.assertIn('ci-status', result.stderr)

    def test_ci_status_job_in_the_app_workflow_requires_it(self):
        tests_only = "jobs:\n  tests:\n    runs-on: x\n"
        result, merged, _ = self.run_case(workflow=True, workflow_body=tests_only, app_workflow=True,
                                          app_workflow_body="jobs:\n    'ci-status': # aggregate\n      needs: [tests]\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(merged)
        self.assertIn('ci-status', result.stderr)

    def test_absent_app_workflow_does_not_require_compile(self):
        result, merged, _ = self.run_case(workflow=True, files=['Sources/App.swift'], checks=[{'id': 1, 'name': 'ci-status', 'status': 'completed', 'conclusion': 'success'}])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(merged)

    def macos_routing_checks(self):
        return [
            {'id': 1, 'name': 'ci-status', 'status': 'completed', 'conclusion': 'success',
             'app': {'slug': 'github-actions'}, 'check_suite': {'id': 100}},
            {'id': 2, 'name': 'macos', 'status': 'completed', 'conclusion': 'skipped',
             'app': {'slug': 'github-actions'}, 'check_suite': {'id': 100}},
        ]

    def run_ios_routing_case(self, checks):
        return self.run_case(workflow=True, app_workflow=True,
                             files=['Packages/iOS/CmuxMobileShellUI/Sources/MobileDisplaySettings.swift'],
                             checks=checks)

    def test_ios_only_diff_accepts_explicit_macos_skip_from_successful_ci_suite(self):
        result, merged, _ = self.run_ios_routing_case(self.macos_routing_checks())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(merged)

    def test_macos_skip_requires_current_successful_github_actions_suite(self):
        invalid_skips = [
            {'status': 'in_progress', 'conclusion': None},
            {'conclusion': 'failure'},
            {'conclusion': 'success'},
            {'conclusion': 'neutral'},
            {'check_suite': {'id': 99}},
            {'check_suite': {}},
            {'app': {'slug': 'other-app'}},
        ]
        for invalid_skip in invalid_skips:
            with self.subTest(invalid_skip=invalid_skip):
                checks = self.macos_routing_checks()
                checks[-1].update(invalid_skip)
                result, merged, _ = self.run_ios_routing_case(checks)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(merged)
                self.assertIn('macOS compile admission', result.stderr)
        for replacement in ({'name': 'unrelated'}, {'conclusion': 'skipped'},
                            {'app': {'slug': 'other-app'}}, {'check_suite': {}}):
            with self.subTest(ci_status=replacement):
                checks = self.macos_routing_checks()
                checks[0].update(replacement)
                result, merged, _ = self.run_ios_routing_case(checks)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(merged)

    def test_macos_skip_does_not_hide_newer_route_or_scheduled_compile(self):
        for conclusion in ('failure', 'success'):
            with self.subTest(newer_route=conclusion):
                checks = self.macos_routing_checks()
                checks.append({**checks[-1], 'id': 3, 'conclusion': conclusion})
                result, merged, _ = self.run_ios_routing_case(checks)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(merged)
        for status, conclusion in (('in_progress', None), ('completed', 'failure')):
            with self.subTest(compile=(status, conclusion)):
                checks = self.macos_routing_checks()
                checks.append({'id': 3, 'name': 'macos / macOS compile admission',
                               'status': status, 'conclusion': conclusion})
                result, merged, _ = self.run_ios_routing_case(checks)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(merged)
                self.assertIn('macOS compile admission', result.stderr)


class HelperCheckoutUpdateRegression(unittest.TestCase):
    """The symlinked helper refreshes only a clean main checkout."""

    # The caller's settings that change what the helper does before it reads a PR: the installer's
    # GH_MERGE_GREEN_NO_AUTO_UPDATE=1 skips this very update, and GH_REPO/GH_HOST point gh elsewhere.
    CALLER = ("GH_MERGE_GREEN_NO_AUTO_UPDATE", "GH_MERGE_GREEN_HOME", "GH_REPO", "GH_HOST")

    def invoke(self, mode):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            checkout = directory / "checkout"
            updated = checkout / "scripts" / "gh-merge-green"
            updated.parent.mkdir(parents=True)
            updated.write_text(f"#!/bin/sh\nprintf updated > {directory / 'updated'}\n")
            updated.chmod(0o755)
            log = directory / "git.log"
            fake_git = directory / "git"
            fake_git.write_text(textwrap.dedent(f"""\
                #!/usr/bin/env python3
                import os, sys
                from pathlib import Path
                a = sys.argv[1:]
                log = Path(os.environ['GIT_LOG'])
                with log.open('a') as stream:
                    stream.write(' '.join(a) + '\\n')
                if a[-2:] == ['rev-parse', '--show-toplevel']:
                    print(os.environ['CHECKOUT'])
                elif 'status' in a and '--porcelain' in a:
                    if os.environ['MODE'] == 'dirty':
                        print(' M scripts/gh-merge-green')
                    elif os.environ['MODE'] == 'untracked' and '--untracked-files=no' not in a:
                        print('?? .metadata_never_index')
                elif a[-2:] == ['branch', '--show-current']:
                    print('main')
                elif a[-2:] == ['rev-parse', 'refs/remotes/origin/main']:
                    print('b' * 40)
                elif a[-2:] == ['rev-parse', 'HEAD']:
                    print('a' * 40)
                elif 'merge-base' in a and '--is-ancestor' in a:
                    if os.environ['MODE'] in ('behind', 'untracked') and a[-2:] == ['a' * 40, 'b' * 40]:
                        sys.exit(0)
                    sys.exit(1)
                elif 'merge' in a and '--ff-only' in a:
                    print('fast-forward')
                elif 'fetch' in a:
                    pass
                else:
                    sys.exit(2)
            """))
            fake_git.chmod(0o755)
            fake_gh = directory / "gh"
            fake_gh.write_text("#!/bin/sh\nexit 2\n")
            fake_gh.chmod(0o755)
            result = subprocess.run(
                [str(ROOT / "scripts/gh-merge-green"), "manaflow-ai/cmux#42"],
                env={**{k: v for k, v in os.environ.items() if k not in self.CALLER},
                     "PATH": str(directory) + os.pathsep + os.environ["PATH"],
                     "CHECKOUT": str(checkout), "GIT_LOG": str(log), "MODE": mode,
                     "UPDATE_MARKER": str(directory / "updated")},
                capture_output=True, text=True,
            )
            marker = directory / "updated"
            diagnostics = (result, marker.exists(), marker.read_text() if marker.exists() else "", log.read_text() if log.exists() else "", result.stderr)
            return diagnostics

    def test_the_installers_environment_does_not_skip_the_update(self):
        """install-gh-merge-green.sh runs these tests with GH_MERGE_GREEN_NO_AUTO_UPDATE=1 (its pinned snapshot must
        not move), and a session may export GH_REPO or GH_HOST. Inheriting them skipped the update under test, so
        the helper went on to read the PR: cosmic-gray's installer refused every main from 538ade5724 (2026-10-21)
        with "not green: cannot read manaflow-ai/cmux#42" while a bare run passed."""
        caller = {"GH_MERGE_GREEN_NO_AUTO_UPDATE": "1", "GH_MERGE_GREEN_HOME": "/nonexistent",
                  "GH_REPO": "someone/else", "GH_HOST": "github.example.com"}
        with mock.patch.dict(os.environ, caller):
            result, marker_exists, marker_content, log, stderr = self.invoke("behind")
            self.assertEqual(result.returncode, 0, stderr + "\n" + log)
            self.assertTrue(marker_exists, stderr + "\n" + log)
            result, marker_exists, marker_content, log, stderr = self.invoke("dirty")
            self.assertIn("dirty", stderr)  # the update ran and refused; the PR read after it is the fake gh's

    def test_clean_main_checkout_fast_forwards_and_reexecutes(self):
        result, marker_exists, marker_content, log, stderr = self.invoke("behind")
        self.assertEqual(result.returncode, 0, stderr + "\n" + log)
        self.assertTrue(marker_exists, stderr + "\n" + log)
        self.assertEqual(marker_content, "updated")
        self.assertIn("fetch --quiet origin main", log)
        self.assertIn("merge --ff-only", log)

    def test_dirty_checkout_warns_and_does_not_update(self):
        result, marker_exists, marker_content, log, stderr = self.invoke("dirty")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(marker_exists)
        self.assertIn("checkout", stderr)
        self.assertIn("dirty", stderr)
        self.assertIn("REPAIR.md#merging", stderr)

    def test_an_untracked_file_alone_does_not_stop_the_update(self):
        """cosmic-gray's helper checkout sat 14 h behind main (2026-10-21): its only change was
        Spotlight's untracked .metadata_never_index. An untracked file can't be lost by a
        fast-forward (git refuses one that would overwrite it), so only tracked edits block."""
        result, marker_exists, marker_content, log, stderr = self.invoke("untracked")
        self.assertEqual(result.returncode, 0, stderr + "\n" + log)
        self.assertTrue(marker_exists, stderr + "\n" + log)
        self.assertEqual(marker_content, "updated")
        self.assertNotIn("dirty", stderr)
        self.assertIn("merge --ff-only", log)

    def test_diverged_checkout_warns_and_does_not_update(self):
        result, marker_exists, marker_content, log, stderr = self.invoke("diverged")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(marker_exists)
        self.assertIn("diverged", stderr)
        self.assertIn("REPAIR.md#merging", stderr)


class FreezeRegression(unittest.TestCase):
    """A merge refuses a PR touching a path an open merge-freeze issue freezes
    (scripts/ci/merge_freeze.py), on every base, from any host."""

    def freeze(self, number, paths, *, owner="freezer", branch=None, created_hours_ago=1, expires_in_hours=2):
        now = datetime.now(timezone.utc)
        stamp = lambda t: t.strftime("%Y-%m-%dT%H:%M:%SZ")
        created = now - timedelta(hours=created_hours_ago)
        body = f"paths: {paths}\nexpires: {stamp(now + timedelta(hours=expires_in_hours))}\n"
        if branch:
            body += f"branch: {branch}\n"
        return {
            "number": number, "title": f"freeze {number}", "state": "open", "body": body,
            "user": {"login": owner}, "created_at": stamp(created), "labels": [{"name": "merge-freeze"}],
            "labeled_by": "maintainer", "labeler_role": "maintain", "labeled_at": stamp(created),
            "last_edited_at": None,
        }

    def ok_by(self, login):
        return [{"event": "labeled", "label": {"name": "freeze-ok"}, "actor": {"login": login}}]

    def run_with(self, directory, issues, changed_files, *, events=(), extra_args=(), issues_text=None, base="feat-cmux-next", full=True, rollup=(), fork=False):
        directory = Path(directory)
        issues_path = directory / "freeze-issues.json"
        issues_path.write_text(issues_text if issues_text is not None else json.dumps(issues))
        events_path = directory / "freeze-events.json"
        events_path.write_text(json.dumps(list(events)))
        ssh_log = directory / "ssh-calls"
        (directory / "ssh").write_text(f"#!/bin/sh\necho \"$*\" >> {ssh_log}\nexit 1\n")
        (directory / "ssh").chmod(0o755)
        saved = {name: os.environ.get(name) for name in ("GH_MERGE_GREEN_FREEZE_ISSUES", "GH_MERGE_GREEN_FREEZE_EVENTS")}
        os.environ.update(GH_MERGE_GREEN_FREEZE_ISSUES=str(issues_path), GH_MERGE_GREEN_FREEZE_EVENTS=str(events_path))
        try:
            marker = directory / "merged"
            result = InstalledHelperRegression.run_helper(
                self, str(directory), marker, changed_files=changed_files, extra_args=extra_args, base=base,
                full=full, rollup=rollup, is_cross_repository=fork)
        finally:
            for name, value in saved.items():
                if value is None:
                    os.environ.pop(name, None)
                else:
                    os.environ[name] = value
        self.assertFalse(ssh_log.exists(), ssh_log.read_text() if ssh_log.exists() else "")
        return result, marker

    def test_a_frozen_file_refuses_the_merge(self):
        with tempfile.TemporaryDirectory() as directory:
            result, marker = self.run_with(
                directory, [self.freeze(7, "Packages/macOS/CmuxNext/Package.swift")],
                ("docs/README.md", "Packages/macOS/CmuxNext/Package.swift"))
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("frozen", result.stderr)
            self.assertIn("#7", result.stderr)
            self.assertIn("Packages/macOS/CmuxNext/Package.swift", result.stderr)

    def test_a_file_under_a_frozen_directory_refuses_the_merge(self):
        with tempfile.TemporaryDirectory() as directory:
            result, marker = self.run_with(
                directory, [self.freeze(8, "webviews/src/agent-session/")],
                ("webviews/src/agent-session/acpmux/ModelPicker.tsx",))
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("webviews/src/agent-session/", result.stderr)

    def test_a_sibling_of_a_frozen_prefix_still_merges(self):
        with tempfile.TemporaryDirectory() as directory:
            result, marker = self.run_with(
                directory, [self.freeze(9, "docs/frozen/ docs/app.md")],
                ("docs/frozen-notes/a.md", "docs/app.md.orig"))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())

    def test_the_owners_freeze_ok_label_lets_the_merge_through(self):
        with tempfile.TemporaryDirectory() as directory:
            result, marker = self.run_with(
                directory, [self.freeze(10, "docs/frozen/", owner="freezer")],
                ("docs/frozen/a.md",), events=self.ok_by("freezer"))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())

    def test_freeze_ok_from_someone_else_still_refuses(self):
        with tempfile.TemporaryDirectory() as directory:
            result, marker = self.run_with(
                directory, [self.freeze(11, "docs/frozen/", owner="freezer")],
                ("docs/frozen/a.md",), events=self.ok_by("someone-else"))
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("#11", result.stderr)

    def test_a_lapsed_freeze_blocks_nothing(self):
        with tempfile.TemporaryDirectory() as directory:
            result, marker = self.run_with(
                directory, [self.freeze(12, "docs/frozen/", created_hours_ago=80, expires_in_hours=-1)],
                ("docs/frozen/a.md",))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())

    def test_a_freeze_on_another_branch_does_not_block(self):
        with tempfile.TemporaryDirectory() as directory:
            result, marker = self.run_with(
                directory, [self.freeze(13, "docs/frozen/", branch="main")], ("docs/frozen/a.md",))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())

    def test_a_main_merge_checks_freezes_too(self):
        # The WINDOW check ran only for feat-cmux-next; a freeze issue covers every base.
        with tempfile.TemporaryDirectory() as directory:
            result, marker = self.run_with(
                directory, [self.freeze(16, "docs/frozen/", branch="main")], ("docs/frozen/a.md",), base="main")
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("#16", result.stderr)

    def test_the_fast_gate_still_refuses_a_frozen_path(self):
        """The fast gate shortens the wait for checks, never the freeze check (#21957):
        a feat-cmux-next PR with green fast lanes touching a frozen path refuses,
        with or without --override."""
        fast_green = InstalledHelperRegression.FAST_GREEN
        for extra_args in ((), ("--override", "the red check is a known base failure on this exact head")):
            with self.subTest(override=bool(extra_args)), tempfile.TemporaryDirectory() as directory:
                result, marker = self.run_with(
                    directory, [self.freeze(17, "docs/frozen/")], ("docs/frozen/a.md",),
                    full=False, rollup=fast_green, extra_args=extra_args)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(marker.exists())
                self.assertIn("#17", result.stderr)
                self.assertIn("fast gate", result.stderr)

    def test_the_fast_gate_merges_an_unfrozen_path_and_the_owners_freeze_ok(self):
        fast_green = InstalledHelperRegression.FAST_GREEN
        cases = (([self.freeze(18, "docs/frozen/")], ("docs/README.md",), ()),
                 ([self.freeze(19, "docs/frozen/", owner="freezer")], ("docs/frozen/a.md",), self.ok_by("freezer")))
        for issues, files, events in cases:
            with self.subTest(files=files), tempfile.TemporaryDirectory() as directory:
                result, marker = self.run_with(directory, issues, files, events=events, full=False, rollup=fast_green)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue(marker.exists())

    def test_a_reviewed_fork_on_the_fast_gate_still_stops_at_a_freeze(self):
        with tempfile.TemporaryDirectory() as directory:
            result, marker = self.run_with(
                directory, [self.freeze(21, "docs/frozen/")], ("docs/frozen/a.md",),
                full=False, rollup=InstalledHelperRegression.FAST_GREEN, fork=True,
                extra_args=("--trust-fork-head", HEAD))
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("#21", result.stderr)

    def test_a_main_merge_without_full_checks_freezes_on_the_full_gate(self):
        with tempfile.TemporaryDirectory() as directory:
            result, marker = self.run_with(
                directory, [self.freeze(20, "docs/frozen/", branch="main")], ("docs/frozen/a.md",),
                base="main", full=False, rollup=InstalledHelperRegression.FAST_GREEN)
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("#20", result.stderr)
            self.assertIn("full gate", result.stderr)

    def test_test_mode_without_freeze_fixtures_refuses(self):
        # GH_MERGE_GREEN_TEST left set in a real shell must not read as "no freezes".
        for name in ("GH_MERGE_GREEN_FREEZE_ISSUES", "GH_MERGE_GREEN_FREEZE_EVENTS"):
            with self.subTest(unset=name), tempfile.TemporaryDirectory() as directory:
                saved = os.environ.pop(name)
                try:
                    marker = Path(directory) / "merged"
                    result = InstalledHelperRegression.run_helper(self, directory, marker)
                finally:
                    os.environ[name] = saved
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(marker.exists())
                self.assertIn("freeze state unknown", result.stderr)

    def test_override_does_not_lift_a_freeze(self):
        with tempfile.TemporaryDirectory() as directory:
            result, marker = self.run_with(
                directory, [self.freeze(14, "Packages/macOS/CmuxNext/Package.swift")],
                ("Packages/macOS/CmuxNext/Package.swift",),
                extra_args=("--override", "the red check is a known base failure on this exact head"))
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())

    def test_an_unreadable_freeze_state_refuses(self):
        with tempfile.TemporaryDirectory() as directory:
            result, marker = self.run_with(directory, None, ("docs/README.md",), issues_text="{not json")
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("freeze state unknown", result.stderr)


class RetiredTokenRegression(unittest.TestCase):
    """--freeze-token and --window-token belonged to the WINDOW file on
    cmux-lawrence. They warn and are ignored, so old callers keep working, and
    no merge reaches cmux-lawrence over ssh or mails a RELEASE."""

    def test_retired_tokens_warn_and_merge_without_ssh(self):
        for flag in ("--freeze-token", "--window-token"):
            with self.subTest(flag=flag), tempfile.TemporaryDirectory() as directory:
                result, marker = FreezeRegression.run_with(
                    self, directory, [], ("docs/README.md",), extra_args=(flag, "c0dec0de1234"))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue(marker.exists())
                self.assertIn(f"{flag} is retired", result.stderr)
                self.assertNotIn("RELEASE", result.stderr)

    def test_a_retired_token_does_not_lift_a_freeze(self):
        with tempfile.TemporaryDirectory() as directory:
            result, marker = FreezeRegression.run_with(
                self, directory, [FreezeRegression.freeze(self, 15, "docs/frozen/")], ("docs/frozen/a.md",),
                extra_args=("--freeze-token", "d0c5d0c5"))
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("#15", result.stderr)

    def test_a_token_flag_without_a_value_still_refuses(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            gh = Path(directory) / "gh"
            gh.write_text("#!/bin/sh\nexit 2\n")
            gh.chmod(0o755)
            result = subprocess.run(
                [str(ROOT / "scripts/gh-merge-green"), "manaflow-ai/cmux#42", "--window-token"],
                env={**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"], "GH_MERGE_GREEN_NO_AUTO_UPDATE": "1"},
                capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())


class MergedHeadChecksRegression(unittest.TestCase):
    """Before a feat-cmux-next merge, the merged head passes the Swift god-file
    check (CmuxNext changes) and vp check (webviews changes), run with the base
    branch's copy of the god-file script and baseline."""

    GODFILES = (
        "#!/usr/bin/env bash\n"
        "# fixture: fails on a GOD marker in the merged package; logs its arguments\n"
        "printf '%s\\n' \"$*\" >> \"$CHECK_LOG\"\n"
        "dir=\"$(cd \"$(dirname \"${BASH_SOURCE[0]}\")\" && pwd)\"\n"
        "grep -q base-baseline \"$dir/godfile-baseline.tsv\" || { echo 'not the base baseline'; exit 3; }\n"
        "pkg=\"${@: -1}\"\n"
        "if [ -e \"$pkg/Sources/GOD.swift\" ]; then echo 'god type: Example spans 1013 lines'; exit 1; fi\n"
    )
    SCOPED_GODFILES = (
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "printf '%s\\n' \"$*\" >> \"$CHECK_LOG\"\n"
        "dir=\"$(cd \"$(dirname \"${BASH_SOURCE[0]}\")\" && pwd)\"\n"
        "grep -q base-baseline \"$dir/godfile-baseline.tsv\"\n"
        "pkg=\"${@: -1}\"\n"
        "files=()\n"
        "while (($#)); do\n"
        "  if [[ $1 == --file ]]; then files+=(\"$2\"); shift 2; else shift; fi\n"
        "done\n"
        "[[ ${#files[@]} -gt 0 ]] || { echo 'unscoped scan'; exit 1; }\n"
        "for file in \"${files[@]}\"; do\n"
        "  [[ -f \"$pkg/${file#Packages/macOS/CmuxNext/}\" ]] || { echo \"missing $file\"; exit 1; }\n"
        "done\n"
        "module=\"${files[0]#Packages/macOS/CmuxNext/Sources/}\"\n"
        "module=\"${module%%/*}\"\n"
        "if [[ -e \"$pkg/Sources/$module/Feature.swift\" && -e \"$pkg/Sources/$module/Feature+Extra.swift\" ]]; then\n"
        "  echo 'god type: Feature spans 1013 lines'; exit 1\n"
        "fi\n"
    )

    def git(self, *args, cwd):
        return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()

    def fixture(self, directory, pr_files, *, pr_script=None, base_files=None, base_script=None):
        directory = Path(directory)
        origin = directory / "origin.git"
        work = directory / "work"
        self.git("init", "-q", "--bare", str(origin), cwd=directory)
        self.git("init", "-q", "-b", "feat-cmux-next", str(work), cwd=directory)
        for args in (("config", "user.email", "t@example.invalid"), ("config", "user.name", "t")):
            self.git(*args, cwd=work)
        scripts = work / "scripts/cmux-next"
        scripts.mkdir(parents=True)
        (scripts / "check-no-godfiles.sh").write_text(base_script or self.GODFILES)
        (scripts / "check-no-godfiles.sh").chmod(0o755)
        (scripts / "godfile-baseline.tsv").write_text("base-baseline\n")
        (work / "Packages/macOS/CmuxNext").mkdir(parents=True)
        (work / "Packages/macOS/CmuxNext/Package.swift").write_text("// package\n")
        (work / "webviews").mkdir()
        (work / "webviews/package.json").write_text("{}\n")
        for path, text in (base_files or {}).items():
            (work / path).parent.mkdir(parents=True, exist_ok=True)
            (work / path).write_text(text)
        self.git("add", "-A", cwd=work)
        self.git("commit", "-qm", "base", cwd=work)
        self.git("remote", "add", "origin", str(origin), cwd=work)
        self.git("push", "-q", "origin", "feat-cmux-next", cwd=work)
        self.git("checkout", "-qb", "pr", cwd=work)
        for path, text in pr_files.items():
            (work / path).parent.mkdir(parents=True, exist_ok=True)
            (work / path).write_text(text)
        if pr_script is not None:
            (scripts / "check-no-godfiles.sh").write_text(pr_script)
            (scripts / "godfile-baseline.tsv").write_text("pr-raised-baseline\n")
        self.git("add", "-A", cwd=work)
        self.git("commit", "-qm", "pr", cwd=work)
        head = self.git("rev-parse", "HEAD", cwd=work)
        self.git("push", "-q", "origin", f"{head}:refs/pull/42/head", cwd=work)
        self.git("checkout", "-q", "feat-cmux-next", cwd=work)
        bun = directory / "bin/bun"
        bun.parent.mkdir()
        bun.write_text(
            "#!/bin/sh\n"
            "printf 'bun %s\\n' \"$*\" >> \"$CHECK_LOG\"\n"
            "if [ \"$1 $2 $3\" = 'x vp check' ] && [ -f vite.config.ts ] && [ ! -f ../config/vite-plus/check.ts ]; then\n"
            "  echo \"[UNRESOLVED_IMPORT] Could not resolve '../config/vite-plus/check' in $PWD/vite.config.ts\"; exit 1\n"
            "fi\n"
            "if [ \"$1 $2 $3\" = 'x vp check' ] && ls BAD*.tsx >/dev/null 2>&1; then echo 'error: Formatting issues found'; for f in BAD*.tsx; do echo \"$PWD/$f\"; done; exit 1; fi\n"
        )
        bun.chmod(0o755)
        return work, head, directory / "bin"

    def run_merge(self, directory, pr_files, *, fork=False, trust_head=False, extra_args=(), changed_files=None, full=True, **kwargs):
        global HEAD
        work, head, bin_dir = self.fixture(directory, pr_files, **kwargs)
        Path(directory, "pr-head").write_text(head)
        log = Path(directory) / "checks.log"
        log.touch()
        saved = HEAD, os.environ.get("GH_MERGE_GREEN_REPO_DIR"), os.environ["PATH"], os.environ.get("CHECK_LOG")
        HEAD = head
        os.environ.update(
            GH_MERGE_GREEN_REPO_DIR=str(work),
            CHECK_LOG=str(log),
            PATH=f"{directory}{os.pathsep}{bin_dir}{os.pathsep}{os.environ['PATH']}",
        )
        try:
            marker = Path(directory) / "merged"
            result = InstalledHelperRegression.run_helper(
                self, directory, marker, changed_files=tuple(changed_files or pr_files), is_cross_repository=fork,
                extra_args=((*extra_args, "--trust-fork-head", head) if trust_head else extra_args),
                full=full, rollup=() if full else InstalledHelperRegression.FAST_GREEN, rollup_head=head,
                reviews=reviews_fixture((f"Review (subagent, correctness first): SHIP at {head}", "2026-10-21T05:00:00Z"), head=head))
        finally:
            HEAD = saved[0]
            os.environ["PATH"] = saved[2]
            for name, value in (("GH_MERGE_GREEN_REPO_DIR", saved[1]), ("CHECK_LOG", saved[3])):
                if value is None:
                    os.environ.pop(name, None)
                else:
                    os.environ[name] = value
        return result, marker, log.read_text()

    def test_the_fast_gate_skips_the_merged_tree_checks_for_an_ordinary_cmux_next_pr(self):
        """leoli-f6 2026-10-19: the fast gate leaves the merged-tree checks to the
        post-merge suites, so a god type in an ordinary cmux-next PR merges."""
        with tempfile.TemporaryDirectory() as directory:
            result, marker, log = self.run_merge(directory, {"Packages/macOS/CmuxNext/Sources/GOD.swift": "x\n"}, full=False)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())
            self.assertEqual(log, "")

    def test_the_fast_gate_runs_the_merged_tree_checks_for_a_pr_touching_gate_paths(self):
        """leoli-f6 2026-10-19: a PR touching workflows, shared CI scripts, gh-merge-green
        or gate config gets the merged-tree checks back on the fast gate."""
        for protected in (".github/workflows/cmux-next.yml", "scripts/ci/merge_freeze.py", "scripts/gh-merge-green"):
            with self.subTest(protected=protected), tempfile.TemporaryDirectory() as directory:
                result, marker, log = self.run_merge(
                    directory, {"Packages/macOS/CmuxNext/Sources/GOD.swift": "x\n", protected: "# changed\n"}, full=False)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(marker.exists())
                self.assertIn("--only swift --base", log)
                self.assertIn("god-file", result.stderr)

    def test_fork_without_head_trust_refuses(self):
        with tempfile.TemporaryDirectory() as directory:
            result, marker, log = self.run_merge(directory, {"Packages/macOS/CmuxNext/Sources/A.swift": "struct A {}\n"}, fork=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(marker.exists())
            self.assertEqual(log, "")
            self.assertIn("--trust-fork-head", result.stderr)

    def test_reviewed_fork_runs_merged_checks_and_merges(self):
        with tempfile.TemporaryDirectory() as directory:
            result, marker, log = self.run_merge(directory, {"Packages/macOS/CmuxNext/Sources/A.swift": "struct A {}\n"}, fork=True, trust_head=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())
            self.assertIn("--only swift --base", log)
            events = (Path(directory) / "events").read_text().splitlines()
            self.assertLess(events.index("comment"), events.index("merge"))
            merge_args = (Path(directory) / "merge-args").read_text()
            expected_head = (Path(directory) / "pr-head").read_text()
            self.assertIn(f"--match-head-commit {expected_head}", merge_args)

    def test_reviewed_fork_cannot_replace_base_guard(self):
        with tempfile.TemporaryDirectory() as directory:
            result, marker, log = self.run_merge(
                directory, {"Packages/macOS/CmuxNext/Sources/GOD.swift": "x\n"}, fork=True, trust_head=True,
                pr_script="#!/usr/bin/env bash\nexit 0\n")
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(marker.exists())
            self.assertIn("--only swift --base", log)

    def test_stale_fork_trust_refuses_before_executing_checks(self):
        with tempfile.TemporaryDirectory() as directory:
            result, marker, log = self.run_merge(
                directory, {"Packages/macOS/CmuxNext/Sources/A.swift": "struct A {}\n"}, fork=True,
                extra_args=("--trust-fork-head", "f" * 40))
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(marker.exists())
            self.assertEqual(log, "")
            self.assertIn("reviewed fork head", result.stderr)

    def test_a_merged_head_that_grows_a_god_type_refuses(self):
        with tempfile.TemporaryDirectory() as directory:
            result, marker, log = self.run_merge(directory, {"Packages/macOS/CmuxNext/Sources/GOD.swift": "x\n"})
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("god", result.stderr)
            self.assertIn("--only swift --base", log)

    def test_a_clean_swift_change_merges_after_the_god_file_check(self):
        with tempfile.TemporaryDirectory() as directory:
            result, marker, log = self.run_merge(directory, {"Packages/macOS/CmuxNext/Sources/A.swift": "struct A {}\n"})
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())
            self.assertIn("--only swift --base", log)
            self.assertIn("--file Packages/macOS/CmuxNext/Sources/A.swift", log)
            self.assertNotIn("bun", log)

    def test_a_test_only_swift_change_uses_a_scoped_file(self):
        with tempfile.TemporaryDirectory() as directory:
            result, marker, log = self.run_merge(
                directory,
                {"Packages/macOS/CmuxNext/Tests/Only.swift": "struct Only {}\n"},
                base_script=self.SCOPED_GODFILES,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())
            self.assertIn("--file Packages/macOS/CmuxNext/Tests/Only.swift", log)

    def test_changed_source_and_same_module_extension_are_checked_together(self):
        with tempfile.TemporaryDirectory() as directory:
            result, marker, log = self.run_merge(
                directory,
                {
                    "Packages/macOS/CmuxNext/Sources/Feature/Feature.swift": "struct Feature {}\n",
                    "Packages/macOS/CmuxNext/Sources/Feature/Feature+Extra.swift": "extension Feature {}\n",
                },
                base_script=self.SCOPED_GODFILES,
            )
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("god type", result.stderr)
            self.assertIn("--file Packages/macOS/CmuxNext/Sources/Feature/Feature.swift", log)

    def test_unrelated_modules_are_not_scanned(self):
        with tempfile.TemporaryDirectory() as directory:
            result, marker, log = self.run_merge(
                directory,
                {"Packages/macOS/CmuxNext/Sources/Feature/Feature.swift": "struct Feature {}\n"},
                base_files={"Packages/macOS/CmuxNext/Sources/Other/GOD": "x\n"},
                base_script=self.SCOPED_GODFILES,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())
            self.assertIn("--file Packages/macOS/CmuxNext/Sources/Feature/Feature.swift", log)

    def test_missing_or_renamed_swift_path_refuses_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            result, marker, log = self.run_merge(
                directory,
                {"Packages/macOS/CmuxNext/Sources/Feature/Renamed.swift": "struct Renamed {}\n"},
                changed_files=("Packages/macOS/CmuxNext/Sources/Feature/Original.swift",),
                base_script=self.SCOPED_GODFILES,
            )
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("missing from the merged head", result.stderr)
            self.assertEqual(log, "")

    def test_the_base_copy_of_the_god_file_script_runs(self):
        with tempfile.TemporaryDirectory() as directory:
            result, marker, log = self.run_merge(
                directory, {"Packages/macOS/CmuxNext/Sources/GOD.swift": "x\n"}, pr_script="#!/usr/bin/env bash\nexit 0\n")
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())

    def test_a_webviews_change_that_fails_vp_check_refuses(self):
        with tempfile.TemporaryDirectory() as directory:
            result, marker, log = self.run_merge(directory, {"webviews/BAD.tsx": "x\n"})
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("vp check", result.stderr)
            self.assertIn("bun install --frozen-lockfile --ignore-scripts", log)

    def test_a_vp_check_red_already_on_the_base_does_not_block(self):
        with tempfile.TemporaryDirectory() as directory:
            result, marker, log = self.run_merge(
                directory, {"webviews/Good.tsx": "x\n"}, base_files={"webviews/BAD.tsx": "x\n"})
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())
            self.assertIn("base", result.stderr)

    def test_a_new_vp_check_failure_on_a_red_base_still_refuses(self):
        with tempfile.TemporaryDirectory() as directory:
            result, marker, log = self.run_merge(
                directory, {"webviews/BAD2.tsx": "x\n"}, base_files={"webviews/BAD.tsx": "x\n"})
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("BAD2.tsx", result.stderr)

    def test_vp_check_sees_the_shared_config_outside_webviews(self):
        # webviews/vite.config.ts imports ../config/vite-plus/check; without it
        # in the materialized tree vp check fails for every webviews PR.
        shared = {
            "webviews/vite.config.ts": "import { cmuxCheckConfig } from '../config/vite-plus/check';\n",
            "config/vite-plus/check.ts": "export const cmuxCheckConfig = {};\n",
        }
        with tempfile.TemporaryDirectory() as directory:
            result, marker, log = self.run_merge(directory, {"webviews/Good.tsx": "x\n"}, base_files=shared)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())
            self.assertIn("bun x vp check", log)

    def test_a_clean_webviews_change_merges_after_vp_check(self):
        with tempfile.TemporaryDirectory() as directory:
            result, marker, log = self.run_merge(directory, {"webviews/Good.tsx": "x\n"})
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())
            self.assertIn("bun x vp check", log)
            self.assertNotIn("--only swift", log)


FIXTURE_GH = "#!/usr/bin/env python3\n" + textwrap.dedent(r"""
    # A recorded GitHub: routes are (substring of the joined arguments, stdout) in order.
    import json, os, sys
    from pathlib import Path
    x = json.loads(Path(os.environ['FIXTURE']).read_text())
    a = sys.argv[1:]
    joined = ' '.join(a)
    with open(os.environ['QUERIES'], 'a') as f: f.write(joined + '\n')
    VALUE = {'--match-head-commit', '--subject', '-t', '--body', '-b', '--body-file', '-F', '--author-email', '-A'}
    FLAGS = {'--squash', '-s', '--merge', '-m', '--rebase', '-r', '--delete-branch', '-d', '--auto', '--admin', '--disable-auto'}
    if a[:2] == ['pr', 'view']:
        print(json.dumps({'headRefOid': x['head'], 'baseRefName': x['base'], 'state': 'OPEN', 'labels': [],
                          'isCrossRepository': False, 'title': 'fix', 'body': ''}))
    elif a[:2] == ['pr', 'comment']:
        Path(os.environ['MERGE_MARKER'] + '.comment').touch()
    elif a[:2] == ['pr', 'merge']:
        i = 2
        while i < len(a):
            arg = a[i].split('=', 1)[0]
            if arg in VALUE:
                i += 1 if '=' in a[i] else 2
                continue
            if arg in FLAGS or not arg.startswith('-') or arg == '--repo':
                i += 2 if arg == '--repo' else 1
                continue
            # gh's own refusal: one line, then its whole usage text.
            print('unknown flag: ' + a[i], file=sys.stderr)
            for n in range(38):
                print('  usage line %d' % n, file=sys.stderr)
            sys.exit(1)
        if x.get('merge_error'):
            print(x['merge_error'], file=sys.stderr)
            sys.exit(1)
        Path(os.environ['MERGE_MARKER']).write_text(joined)
    elif a[:2] == ['run', 'view']:
        print(x['logs'][a[a.index('--job') + 1]])
    elif a[0] == 'api' and any('contents/scripts/ci/check-paths.txt' in arg for arg in a):
        print('gh: Not Found (HTTP 404)', file=sys.stderr)
        sys.exit(1)
    elif a[0] == 'api' and any('/contents/' in arg for arg in a):
        print('HTTP/2.0 200')
    else:
        for needle, out in x['routes']:
            if needle in joined:
                if '--paginate' in a and '--slurp' not in a and isinstance(out, list) and all(isinstance(p, dict) for p in out):
                    # Real gh without --slurp prints each recorded page object back to back.
                    print(''.join(json.dumps(page) for page in out))
                else:
                    print(out if isinstance(out, str) else json.dumps(out))
                sys.exit(0)
        if a[0] == 'api' and '/files' in joined:
            print('docs/README.md')
            sys.exit(0)
        if a[0] == 'api':
            print('[]')
            sys.exit(0)
        sys.exit(2)
    """)

LINT = "cmux-next checks (god files, concurrency, crash safety, l10n)"
TIP = "1" * 40


def lint_job(job_id, run_id, sha, conclusion="failure"):
    steps = [{"name": "Set up runner", "status": "completed", "conclusion": "success"},
             {"name": "Main-thread concurrency", "status": "completed", "conclusion": "success"},
             {"name": "Type scale", "status": "completed", "conclusion": "success"},
             {"name": "God files and types (Swift)", "status": "completed", "conclusion": "success"},
             {"name": "Fail on any red check", "status": "completed", "conclusion": conclusion}]
    return {"id": job_id, "run_id": run_id, "head_sha": sha, "name": LINT, "status": "completed",
            "conclusion": conclusion, "steps": steps}


def lint_log(*red):
    lines = []
    for step in red:
        lines.append(f"{LINT}\t{step}\t2026-10-19T19:31:23.4759936Z Sources/Next/View.swift:41: {step} finding")
        lines.append(f"{LINT}\t{step}\t2026-10-19T19:31:23.4759936Z ##[error]Process completed with exit code 1.")
    lines.append(f"{LINT}\tFail on any red check\t2026-10-19T19:35:08.4268790Z ##[error]Process completed with exit code 1.")
    return "\n".join(lines)


class BaseRedAndReasonRegression(unittest.TestCase):
    """2026-10-19: three good merges were refused, and agents fell back to bare gh pr merge.

    #21807: its cmux-next checks (lint) job was red, and red on feat-cmux-next too, but lint
    never reached the base comparison. #21729: "no base verdict" with nothing about what was
    missing. cmuxterm-hq#2554: `--sha` went through to gh pr merge, whose usage text buried
    the reason under `| tail -5`."""

    def run_case(self, *, base_lint="failure", base_red=("Main-thread concurrency", "Type scale"),
                 head_red=("Main-thread concurrency",), args=("--full", "--squash"), merge_error=None, ci_status="success",
                 lint_conclusion="failure"):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            marker = directory / "merged"
            queries = directory / "queries"
            head_lint = lint_job(7, 900, HEAD, lint_conclusion)
            base_job = lint_job(8, 41, TIP, base_lint)
            check = lambda job, sha: {"id": job["id"], "name": LINT, "status": "completed", "conclusion": job["conclusion"],
                                      "head_sha": sha, "app": {"slug": "github-actions"},
                                      "details_url": f"https://github.com/manaflow-ai/cmux/actions/runs/{job['run_id']}/job/{job['id']}"}
            head_checks = [{"id": 1, "name": "ci-status", "status": "completed", "conclusion": ci_status,
                            "app": {"slug": "github-actions"}}, check(head_lint, HEAD)]
            routes = [
                [f"commits/{HEAD}/check-runs", [{"check_runs": head_checks}]],
                [f"commits/{TIP}/check-runs", [{"check_runs": [check(base_job, TIP)] if base_lint else []}]],
                ["workflows/cmux-next.yml/runs", {"workflow_runs": [
                    {"id": 900, "status": "completed", "conclusion": lint_conclusion, "run_attempt": 1,
                     "head_sha": HEAD, "event": "pull_request"}]}],
                ["actions/runs/900/jobs", [{"jobs": [head_lint]}]],
                ["actions/runs/900", {"id": 900, "workflow_id": 7}],
                ["actions/runs/41", {"id": 41, "workflow_id": 7}],
                ["actions/jobs/7", head_lint],
                ["actions/jobs/8", base_job],
                ["commits?sha=feat-cmux-next", [{"sha": TIP}]],
                ["/compare/", {"merge_base_commit": {"sha": TIP}}],
                ["actions/workflows/7/runs", {"workflow_runs": []}],
            ]
            fixture = directory / "fixture.json"
            fixture.write_text(json.dumps({"head": HEAD, "base": "feat-cmux-next", "routes": routes,
                                           "logs": {"7": lint_log(*head_red), "8": lint_log(*base_red)},
                                           "merge_error": merge_error}))
            gh = directory / "gh"
            gh.write_text(FIXTURE_GH)
            gh.chmod(0o755)
            result = subprocess.run(
                [str(ROOT / "scripts/gh-merge-green"), "manaflow-ai/cmux#42", *args],
                env={**os.environ, "PATH": str(directory) + os.pathsep + os.environ["PATH"], "FIXTURE": str(fixture),
                     "MERGE_MARKER": str(marker), "QUERIES": str(queries), "GH_MERGE_GREEN_NO_AUTO_UPDATE": "1"},
                capture_output=True, text=True)
            merged = marker.read_text() if marker.exists() else None
            return result, merged, queries.read_text() if queries.exists() else ""

    def tail(self, result, lines=5):
        return "\n".join(result.stderr.strip().splitlines()[-lines:])

    def test_a_lint_red_the_base_tip_has_too_merges(self):
        # #21807 at fba65e653cc: the same lint steps were red on feat-cmux-next.
        result, merged, _ = self.run_case()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(merged)
        self.assertIn(f"excused '{LINT}'", result.stderr)
        self.assertIn(TIP[:10], result.stderr)

    def test_a_lint_red_the_base_does_not_have_names_check_sha_and_base(self):
        result, merged, _ = self.run_case(head_red=("Main-thread concurrency", "God files and types (Swift)"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(merged)
        tail = self.tail(result)
        self.assertIn(LINT, tail)
        self.assertIn(HEAD[:10], tail)
        self.assertIn("God files and types (Swift)", result.stderr)
        self.assertIn(f"base tip {TIP[:10]}", result.stderr)

    def test_override_waives_a_lint_red_the_base_does_not_have(self):
        # #22203 (2026-10-20) made a red lint check waivable by --override; risk evidence stays unwaivable.
        reason = "the lint lane is a known base failure unrelated to this change"
        result, merged, _ = self.run_case(head_red=("God files and types (Swift)",),
                                          args=("--full", "--override", reason, "--squash"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(merged)
        self.assertIn("--override waives", result.stderr)

    def test_no_base_verdict_says_what_was_missing(self):
        # #21729: the checks job never runs on feat-cmux-next pushes.
        result, merged, _ = self.run_case(base_lint=None)
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(merged)
        self.assertIn(f"no feat-cmux-next verdict", result.stderr)
        self.assertIn(f"base tip ({TIP[:10]}", result.stderr)
        self.assertIn(HEAD[:10], self.tail(result))

    def test_sha_flag_pins_the_head_instead_of_reaching_gh(self):
        # cmuxterm-hq#2554: `--sha <head>` reached gh pr merge, which printed its usage and refused.
        result, merged, _ = self.run_case(ci_status="success", lint_conclusion="success", base_lint=None,
                                          head_red=(), args=("--full", "--sha", HEAD, "--squash"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(merged)
        self.assertNotIn("--sha", merged)

    def test_a_pinned_head_that_moved_refuses_before_any_check(self):
        result, merged, queries = self.run_case(lint_conclusion="success", args=("--full", "--sha", "b" * 40, "--squash"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(merged)
        self.assertIn("b" * 10, self.tail(result))
        self.assertIn(HEAD[:10], self.tail(result))
        self.assertNotIn("check-runs", queries)

    def test_an_unknown_option_refuses_before_querying_github(self):
        result, merged, queries = self.run_case(lint_conclusion="success", args=("--full", "--bogus", "--squash"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(merged)
        self.assertIn("--bogus", self.tail(result))
        self.assertEqual(queries, "")

    def test_a_github_merge_refusal_keeps_its_reason_in_the_last_lines(self):
        result, merged, _ = self.run_case(lint_conclusion="success", base_lint=None, head_red=(),
                                          merge_error="X Pull request manaflow-ai/cmux#42 is not mergeable: the merge commit cannot be cleanly created.\nhint one\nhint two\nhint three\nhint four")
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(merged)
        self.assertIn("is not mergeable", self.tail(result))
        self.assertIn(HEAD[:10], self.tail(result))

    def test_a_refusal_prints_no_generic_trap_line(self):
        # bash 3.2 runs the ERR trap inside $(...) even under `if !`, so a failed base
        # comparison printed the generic "inspect the failed GitHub query" line first.
        result, _, _ = self.run_case(ci_status="failure", lint_conclusion="success", base_lint=None, head_red=())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("'ci-status'", self.tail(result))
        self.assertNotIn("inspect the failed GitHub query", result.stderr)

    def test_dry_run_runs_every_gate_and_merges_nothing(self):
        result, merged, queries = self.run_case(args=("--full", "--dry-run", "--squash"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(merged)
        self.assertIn("dry-run", result.stdout + result.stderr)
        self.assertIn(f"excused '{LINT}'", result.stderr)
        self.assertNotIn("pr merge", queries)

    def test_dry_run_still_refuses_red(self):
        result, merged, _ = self.run_case(args=("--full", "--dry-run"), head_red=("God files and types (Swift)",))
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(merged)


class GhMergeGreenRestFallbackTests(unittest.TestCase):
    """Exercise only the quota-triggered REST escape hatch."""

    def run_rest_fixture(
        self,
        *,
        merge_args=(),
        metadata_error="API rate limit already exceeded",
        merge_error="API rate limit already exceeded",
        metadata_quota=True,
        merge_quota=True,
        fork=False,
        rest_merge_error=False,
        rest_quota=False,
    ):
        helper = ROOT / "scripts" / "gh-merge-green"
        head_repo = "fork/repo" if fork else "example/repo"
        with tempfile.TemporaryDirectory(prefix="gh-merge-green-rest-") as directory:
            root = Path(directory)
            log = root / "gh.log"
            fake_gh = root / "gh"
            fake_gh.write_text(
                textwrap.dedent(
                    f"""\
                    #!/bin/sh
                    set -eu
                    printf '%s\\n' "$*" >> "$GH_FAKE_LOG"
                    if [ "$1" = pr ] && [ "$2" = view ]; then
                      if [ "{int(metadata_quota)}" = 1 ]; then
                        echo "GraphQL: {metadata_error}" >&2
                        exit 1
                      fi
                      printf '{{"headRefOid":"{HEAD}","baseRefName":"main","labels":[],"isCrossRepository":{str(fork).lower()}}}\\n'
                      exit 0
                    fi
                    if [ "$1" = pr ] && [ "$2" = merge ]; then
                      if [ "{int(merge_quota)}" = 1 ]; then
                        echo "GraphQL: {merge_error}" >&2
                        exit 1
                      fi
                      printf 'merged via graphql\\n'
                      exit 0
                    fi
                    if [ "$1" = pr ] && [ "$2" = comment ]; then
                      exit 0
                    fi
                    if [ "$1" = api ]; then
                      path=""
                      for arg in "$@"; do
                        case "$arg" in
                          repos/*) path="$arg"; break ;;
                        esac
                      done
                      case "$path" in
                        repos/example/repo/pulls/123)
                          if [ "{int(rest_quota)}" = 1 ]; then
                            echo "gh: API rate limit exceeded for user ID 1. (HTTP 403)" >&2
                            exit 1
                          fi
                          cat <<'JSON'
                    {{"number":123,"state":"open","head":{{"sha":"{HEAD}","repo":{{"full_name":"{head_repo}"}}}},"base":{{"ref":"main","repo":{{"full_name":"example/repo"}}}},"labels":[]}}
                    JSON
                          ;;
                        repos/example/repo/contents/*)
                          printf 'HTTP/1.1 404 Not Found\\n'
                          exit 1
                          ;;
                        repos/example/repo/commits/*/check-runs*)
                          printf '[{{"check_runs":[{{"id":1,"name":"ci-status","status":"completed","conclusion":"success","app":{{"slug":"github-actions"}}}}]}}]\\n'
                          ;;
                        repos/example/repo/commits/*/statuses*)
                          printf '[]\\n'
                          ;;
                        repos/example/repo/pulls/123/files*)
                          printf ''
                          ;;
                        repos/example/repo/pulls/123/merge)
                          if [ "{int(rest_merge_error)}" = 1 ]; then
                            echo 'REST merge unavailable' >&2
                            exit 1
                          fi
                          printf '{{"sha":"merge-commit","merged":true,"message":"Pull Request successfully merged"}}\\n'
                          ;;
                        *)
                          echo "unexpected REST path: $path" >&2
                          exit 2
                          ;;
                      esac
                      exit 0
                    fi
                    echo "unexpected gh invocation: $*" >&2
                    exit 2
                    """
                ),
                encoding="utf-8",
            )
            fake_gh.chmod(0o755)
            env = os.environ.copy()
            env.update({
                "PATH": f"{root}:{env['PATH']}",
                "GH_FAKE_LOG": str(log),
                "GH_MERGE_GREEN_NO_AUTO_UPDATE": "1",
                "GH_MERGE_GREEN_TEST": "1",
            })
            result = subprocess.run(
                [str(helper), "example/repo#123", *merge_args],
                cwd=ROOT,
                env=env,
                text=True,
                capture_output=True,
            )
            calls = log.read_text(encoding="utf-8").splitlines() if log.exists() else []
            return result, calls

    def test_quota_error_uses_rest_for_metadata_and_merge_at_exact_head(self):
        result, calls = self.run_rest_fixture(merge_args=("--squash",))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any("repos/example/repo/pulls/123" in call for call in calls))
        self.assertTrue(any("repos/example/repo/pulls/123/merge" in call for call in calls))
        self.assertTrue(any("sha=" + HEAD in call for call in calls))
        self.assertTrue(any("merge_method=squash" in call for call in calls))

    def test_quota_error_with_unsupported_merge_flag_fails_closed(self):
        result, calls = self.run_rest_fixture(merge_args=("--squash", "--delete-branch"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsupported", result.stderr.lower())
        self.assertFalse(any("pulls/123/merge" in call for call in calls))

    def test_quota_error_with_wrong_explicit_head_fails_closed(self):
        result, calls = self.run_rest_fixture(
            merge_args=("--squash", "--match-head-commit", "b" * 40)
        )
        self.assertNotEqual(result.returncode, 0)
        # The pinned head is checked against the PR's before any gate or merge.
        self.assertIn("not the expected " + "b" * 40, result.stderr)
        self.assertFalse(any("pulls/123/merge" in call for call in calls))

    def test_quota_error_with_rest_failure_refuses_without_claiming_merge(self):
        result, calls = self.run_rest_fixture(merge_args=("--squash",), rest_merge_error=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("rest merge failed", result.stderr.lower())
        self.assertTrue(any("pulls/123/merge" in call for call in calls))

    def test_quota_error_on_graphql_and_rest_refuses_as_rate_limited(self):
        result, calls = self.run_rest_fixture(merge_args=("--squash",), rest_quota=True)
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertIn("rate-limited:", result.stderr)
        self.assertFalse(any("pulls/123/merge" in call for call in calls))

    def test_rest_fork_metadata_accepts_explicit_exact_head_trust(self):
        result, calls = self.run_rest_fixture(
            merge_args=("--trust-fork-head", HEAD, "--squash"), fork=True
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any("pulls/123" in call for call in calls))
        self.assertTrue(any("pr comment" in call for call in calls))

    def test_successful_graphql_merge_keeps_standard_merge_flags(self):
        result, calls = self.run_rest_fixture(
            merge_args=("--merge",), metadata_quota=False, merge_quota=False
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(call.startswith("pr merge") and "--merge" in call for call in calls))
        self.assertFalse(any("pulls/123/merge" in call for call in calls))

    def test_non_quota_graphql_error_does_not_fallback_to_rest(self):
        result, calls = self.run_rest_fixture(metadata_error="transport unavailable")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any("pulls/123" in call for call in calls if call.startswith("api ")))

    def test_remaining_zero_text_alone_does_not_trigger_rest_fallback(self):
        result, calls = self.run_rest_fixture(metadata_error="query failed with remaining=0")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any("pulls/123" in call for call in calls if call.startswith("api ")))


if __name__ == "__main__":
    unittest.main()
