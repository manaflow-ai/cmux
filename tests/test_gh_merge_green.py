"""Fix-forward merging requires actual builds and same-base test evidence."""
import copy
import importlib.util
from pathlib import Path
import unittest
import subprocess
import tempfile
import os
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
            result = subprocess.run(
                [str(symlink), "manaflow-ai/cmux#42", "--main-fix", "--squash"],
                cwd=directory,
                env={
                    **os.environ,
                    "PATH": str(directory) + os.pathsep + os.environ["PATH"],
                    "VALIDATOR_MARKER": str(marker),
                },
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists(), result.stderr)

    def run_helper(self, directory, marker, *, check_name="ci-status", check_conclusion="success", extra_args=(), event_log=None):
        gh = Path(directory) / "gh"
        gh.write_text(
            "#!/bin/sh\n"
            "if [ \"$1 $2\" = 'pr view' ]; then "
            "printf '%s\\n' '{\"headRefOid\":\"" + HEAD + "\",\"baseRefName\":\"feat-cmux-next\",\"state\":\"OPEN\"}'; exit 0; fi\n"
            "if [ \"$1 $2\" = 'pr comment' ]; then printf '%s\\n' comment >> \"$EVENT_LOG\"; exit 0; fi\n"
            "if [ \"$1 $2\" = 'pr merge' ]; then printf '%s\\n' merge >> \"$EVENT_LOG\"; touch \"$MERGE_MARKER\"; exit 0; fi\n"
            "if [ \"$1\" = api ] && printf '%s' \"$*\" | grep -q '/check-runs'; then "
            "printf '%s\\n' '[{\"check_runs\":[{\"id\":1,\"name\":\"" + check_name + "\",\"status\":\"completed\",\"conclusion\":\"" + check_conclusion + "\"}]}]'; exit 0; fi\n"
            "if [ \"$1\" = api ]; then printf '%s\\n' '[]'; exit 0; fi\n"
            "exit 2\n"
        )
        gh.chmod(0o755)
        return subprocess.run(
            [str(ROOT / "scripts/gh-merge-green"), "manaflow-ai/cmux#42", *extra_args, "--squash"],
            env={**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"], "MERGE_MARKER": str(marker), "EVENT_LOG": str(event_log or Path(directory) / "events")},
            capture_output=True,
            text=True,
        )

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
            gh.write_text("#!/bin/sh\ncase \"$*\" in\n*'pr view'*) echo '" + HEAD + " feat-cmux-next';;\n*'pulls/42') echo '{\"state\":\"open\",\"head\":{\"sha\":\"" + HEAD + "\"},\"base\":{\"sha\":\"" + BASE + "\",\"ref\":\"feat-cmux-next\"}}';;\n*'pr merge'*) touch \"$MERGE_MARKER\";;\n*) echo '[]';;\nesac\n")
            gh.chmod(0o755)
            result = subprocess.run([str(ROOT / "scripts/gh-merge-green"), "manaflow-ai/cmux#42", "--main-fix", "--squash"], env={**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"], "MERGE_MARKER": str(marker)}, capture_output=True, text=True)
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
                env={**os.environ, "PATH": str(directory) + os.pathsep + os.environ["PATH"], "MERGE_MARKER": str(marker), "INCLUDE_CONFLICT": "0"},
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(marker.exists())

            marker.unlink()
            result = subprocess.run(
                [str(ROOT / "scripts/gh-merge-green"), "manaflow-ai/cmux#42", "--squash"],
                env={**os.environ, "PATH": str(directory) + os.pathsep + os.environ["PATH"], "MERGE_MARKER": str(marker), "INCLUDE_CONFLICT": "1"},
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists())
            self.assertIn("conflict", result.stderr)


if __name__ == "__main__":
    unittest.main()
