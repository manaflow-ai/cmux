"""Fix-forward merging requires actual builds and same-base test evidence."""
import copy
import json
import importlib.util
from pathlib import Path
import unittest
import subprocess
import tempfile
import os
import shlex
import textwrap

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("merge_green", ROOT / "scripts/ci/main_fix_evidence.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
HEAD = "a" * 40
BASE = "b" * 40
ANCESTOR = "c" * 40
NAMES = ("cmux-next Release compile (Xcode 26)", "cmux app scheme compile (Debug)", "cmux-next swift test")
BUILD_STEPS = ("Release compile", "Compile the cmux scheme", "Build package and tests")
TEST_STEP = "Run WebKit driver package tests"
ISSUE = "✘ Test fragmentNavigation() recorded an issue at NavigationEdgeTests.swift:18:6: Caught error: Timeout waiting for load"
SUMMARY = "✘ Test run with 15 tests in 2 suites failed after 5.731 seconds with 1 issue."


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
jobs: {}
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

    def run_helper(self, directory, marker, *, check_name="ci-status", check_conclusion="success", extra_checks=(), extra_args=(), event_log=None, labels=(), cmux_next_runs=(("completed", "success", 1),), changed_files=("docs/README.md",), cmux_next_workflow=None):
        gh = Path(directory) / "gh"
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
        gh.write_text(
            "#!/bin/sh\n"
            "if [ \"$1 $2\" = 'pr view' ]; then "
            "printf '%s\\n' '{\"headRefOid\":\"" + HEAD + "\",\"baseRefName\":\"feat-cmux-next\",\"state\":\"OPEN\",\"labels\":" + json.dumps([{"name": label} for label in labels]) + "}'; exit 0; fi\n"
            "if [ \"$1 $2\" = 'pr comment' ]; then printf '%s\\n' comment >> \"$EVENT_LOG\"; exit 0; fi\n"
            "if [ \"$1 $2\" = 'pr merge' ]; then printf '%s\\n' merge >> \"$EVENT_LOG\"; touch \"$MERGE_MARKER\"; exit 0; fi\n"
            "if [ \"$1\" = api ] && printf '%s' \"$*\" | grep -q '/check-runs'; then "
            "printf '%s\\n' " + check_payload + "; exit 0; fi\n"
            "if [ \"$1\" = api ] && printf '%s' \"$*\" | grep -q 'workflows/cmux-next.yml/runs'; then "
            "printf '%s\\n' " + runs_payload + "; exit 0; fi\n"
            "if [ \"$1\" = api ] && printf '%s' \"$*\" | grep -q 'contents/.github/workflows/cmux-next.yml?ref=" + HEAD + "'; then "
            + workflow_route + "; fi\n"
            "if [ \"$1\" = api ] && printf '%s' \"$*\" | grep -q 'pulls/42/files'; then "
            "printf '%s\\n' " + " ".join(shlex.quote(f) for f in changed_files) + "; exit 0; fi\n"
            "if [ \"$1\" = api ] && printf '%s' \"$*\" | grep -q '/contents/'; then printf '%s\\n' 'HTTP/2.0 200'; exit 0; fi\n"
            "if [ \"$1\" = api ]; then printf '%s\\n' '[]'; exit 0; fi\n"
            "exit 2\n"
        )
        gh.chmod(0o755)
        return subprocess.run(
            [str(ROOT / "scripts/gh-merge-green"), "manaflow-ai/cmux#42", *extra_args, "--squash"],
            env={**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"], "MERGE_MARKER": str(marker), "EVENT_LOG": str(event_log or Path(directory) / "events"), "GH_MERGE_GREEN_NO_AUTO_UPDATE": "1"},
            capture_output=True,
            text=True,
        )

    def test_exploration_label_refuses_before_merging(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "merged"
            result = self.run_helper(directory, marker, labels=("exploration",))
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("exploration PR, needs a decision from Leo or the team before merging.", result.stderr)

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

    def test_override_cannot_bypass_god_file_l10n_or_concurrency_lint(self):
        reason = "the swift test lane is a known base failure unrelated to this change"
        for name in (
            "cmux-next checks (god files, concurrency, crash safety, l10n)",
            "cmux-next god files",
            "cmux-next l10n",
            "concurrency lint",
        ):
            for status, conclusion in (("completed", "failure"), ("in_progress", "")):
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
                 raw_content=None, app_workflow_body=None, extra_args=()):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            marker = directory / "merged"
            queries = directory / "queries"
            payload = {"head": HEAD, "workflow": workflow, "probe_status": probe_status,
                       "checks": checks if checks is not None else [{"id": 1, "name": "tests", "status": "completed", "conclusion": "success"}],
                       "statuses": statuses or [], "app_workflow": app_workflow, "files": files or [],
                       "workflow_body": workflow_body, "raw_content": raw_content, "app_workflow_body": app_workflow_body}
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
                elif a[-2:] == ['status', '--porcelain'] or a[-3:] == ['status', '--porcelain', '--untracked-files=all']:
                    if os.environ['MODE'] == 'dirty':
                        print(' M scripts/gh-merge-green')
                elif a[-2:] == ['branch', '--show-current']:
                    print('main')
                elif a[-2:] == ['rev-parse', 'refs/remotes/origin/main']:
                    print('b' * 40)
                elif a[-2:] == ['rev-parse', 'HEAD']:
                    print('a' * 40)
                elif 'merge-base' in a and '--is-ancestor' in a:
                    if os.environ['MODE'] == 'behind' and a[-2:] == ['a' * 40, 'b' * 40]:
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
                env={**os.environ, "PATH": str(directory) + os.pathsep + os.environ["PATH"],
                     "CHECKOUT": str(checkout), "GIT_LOG": str(log), "MODE": mode,
                     "UPDATE_MARKER": str(directory / "updated")},
                capture_output=True, text=True,
            )
            marker = directory / "updated"
            diagnostics = (result, marker.exists(), marker.read_text() if marker.exists() else "", log.read_text() if log.exists() else "", result.stderr)
            return diagnostics

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

    def test_diverged_checkout_warns_and_does_not_update(self):
        result, marker_exists, marker_content, log, stderr = self.invoke("diverged")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(marker_exists)
        self.assertIn("diverged", stderr)
        self.assertIn("REPAIR.md#merging", stderr)


if __name__ == "__main__":
    unittest.main()
