"""Fix-forward merging requires actual builds and same-base test evidence."""
import copy
import importlib.util
from pathlib import Path
import unittest
import subprocess
import tempfile
import os

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("merge_green", ROOT / "scripts/ci/main_fix_evidence.py")
module = importlib.util.module_from_spec(spec)
if Path(spec.origin).exists():
    spec.loader.exec_module(module)
else:
    module = None
HEAD = "a" * 40
BASE = "b" * 40
NAMES = ("cmux-next Release compile (Xcode 26)", "cmux app scheme compile (Debug)", "cmux-next swift test")
BUILD_STEPS = ("Release compile", "Compile the cmux scheme", "Build package and tests")
TEST_STEP = "Run WebKit driver package tests"
ISSUE = "✘ Test fragmentNavigation() recorded an issue at NavigationEdgeTests.swift:18:6: Caught error: Timeout waiting for load"
SUMMARY = "✘ Test run with 15 tests in 2 suites failed after 5.731 seconds with 1 issue."


def test_log(issue=ISSUE):
    return "\n".join(f"cmux-next swift test\t{TEST_STEP}\t2026-10-02T19:10:10Z {line}" for line in (issue, SUMMARY))


class FakeGitHub:
    def __init__(self):
        self.pr = {"state": "open", "head": {"sha": HEAD}, "base": {"sha": BASE, "ref": "feat-cmux-next"}, "mergeable": True}
        self.head_checks = []
        self.base_checks = []
        self.jobs = {}
        self.logs = {}
        for i, (name, step) in enumerate(zip(NAMES, BUILD_STEPS), 1):
            check = {"id": i, "name": name, "status": "completed", "conclusion": "success", "app": {"slug": "github-actions"}, "details_url": f"https://github.com/manaflow-ai/cmux/actions/runs/10/job/{i}"}
            self.head_checks.append(check)
            self.jobs[i] = {"id": i, "head_sha": HEAD, "run_id": 10, "status": "completed", "conclusion": "success", "name": name, "steps": [{"name": step, "status": "completed", "conclusion": "success"}]}
        self.head_checks.append({"id": 4, "name": "ci-status", "status": "completed", "conclusion": "success", "app": {"slug": "github-actions"}})
        self.files = []

    def json(self, route, *, paginate=False):
        if route.endswith("pulls/42"):
            return copy.deepcopy(self.pr)
        if "/commits/" in route:
            return [{"check_runs": copy.deepcopy(self.head_checks if HEAD in route else self.base_checks)}]
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


@unittest.skipIf(module is None, "evidence validator not implemented yet")
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
    def run_normal_helper(self, *, files, checks):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            gh = directory / "gh"
            marker = directory / "merged"
            gh.write_text(
                """#!/bin/sh
case "$*" in
*'pr view'*) printf '%s\\n' "$HEAD feat-cmux-next" ;;
*'commits/'*) printf '%b\\n' "$CHECKS" ;;
*'pulls/42/files'*) printf '%b\\n' "$FILES" ;;
*'pr merge'*) touch "$MERGE_MARKER" ;;
*) echo "unexpected gh invocation: $*" >&2; exit 1 ;;
esac
""",
                encoding="utf-8",
            )
            gh.chmod(0o755)
            env = {
                **os.environ,
                "PATH": str(directory) + os.pathsep + os.environ["PATH"],
                "HEAD": HEAD,
                "CHECKS": checks,
                "FILES": files,
                "MERGE_MARKER": str(marker),
            }
            result = subprocess.run(
                [str(ROOT / "scripts/gh-merge-green"), "manaflow-ai/cmux#42", "--squash"],
                env=env,
                capture_output=True,
                text=True,
            )
            return result, marker.exists()

    def test_feat_cmux_next_swift_requires_compile_success(self):
        result, merged = self.run_normal_helper(
            files="Packages/macOS/CmuxNext/Sources/Example.swift",
            checks="ci-status\\tcompleted\\tsuccess",
        )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("exact-head success", result.stderr)
        self.assertFalse(merged)

    def test_feat_cmux_next_package_manifest_requires_compile_success(self):
        result, merged = self.run_normal_helper(
            files="Packages/macOS/CmuxNext/Package.swift",
            checks="ci-status\\tcompleted\\tsuccess",
        )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(merged)

    def test_feat_cmux_next_swift_accepts_release_compile(self):
        result, merged = self.run_normal_helper(
            files="Packages/macOS/CmuxNext/Sources/Example.swift",
            checks="ci-status\\tcompleted\\tsuccess\\n"
                   "cmux-next Release compile (Xcode 26)\\tcompleted\\tsuccess",
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(merged)

    def test_feat_cmux_next_swift_accepts_compile_admission(self):
        result, merged = self.run_normal_helper(
            files="Packages/macOS/CmuxNext/Sources/Example.swift",
            checks="ci-status\\tcompleted\\tsuccess\\n"
                   "macos / macOS compile admission\\tcompleted\\tsuccess",
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(merged)

    def test_feat_cmux_next_docs_do_not_require_compile(self):
        result, merged = self.run_normal_helper(
            files="docs/ci.md",
            checks="ci-status\\tcompleted\\tsuccess",
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(merged)

    def test_main_fix_without_any_compile_evidence_refuses_to_merge(self):
        with tempfile.TemporaryDirectory() as directory:
            gh = Path(directory) / "gh"
            marker = Path(directory) / "merged"
            gh.write_text("#!/bin/sh\ncase \"$*\" in\n*'pr view'*) echo '" + HEAD + " feat-cmux-next';;\n*'pulls/42') echo '{\"state\":\"open\",\"head\":{\"sha\":\"" + HEAD + "\"},\"base\":{\"sha\":\"" + BASE + "\",\"ref\":\"feat-cmux-next\"}}';;\n*'pr merge'*) touch \"$MERGE_MARKER\";;\n*) echo '[]';;\nesac\n")
            gh.chmod(0o755)
            result = subprocess.run([str(ROOT / "scripts/gh-merge-green"), "manaflow-ai/cmux#42", "--main-fix", "--squash"], env={**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"], "MERGE_MARKER": str(marker)}, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists(), "the helper merged without any compile evidence")


if __name__ == "__main__":
    unittest.main()
