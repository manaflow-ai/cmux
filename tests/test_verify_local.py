#!/usr/bin/env python3
"""Exercise the contributor preflight through subprocesses and temporary Git fixtures."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location("verify_local", ROOT / "scripts/verify-local.py")
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


@contextlib.contextmanager
def repo_fixture():
    with tempfile.TemporaryDirectory() as tmp:
        repo = Path(tmp)
        (repo / "scripts").mkdir()
        (repo / "tests").mkdir()
        for name in ("verify-local.py", "verification_receipt.py"):
            shutil.copyfile(ROOT / "scripts" / name, repo / "scripts" / name)
        (repo / "tracked").write_text("before")
        subprocess.run(["git", "init", "-q", tmp], check=True)
        subprocess.run(["git", "-C", tmp, "add", "."], check=True)
        subprocess.run(["git", "-C", tmp, "-c", "user.name=fixture", "-c",
                        "user.email=fixture@example.invalid", "commit", "-qm", "fixture"], check=True)
        yield repo


def cli(repo, *args):
    return subprocess.run(["python3", str(repo / "scripts/verify-local.py"), *args],
                          cwd=repo.parent, capture_output=True, text=True)


class PreflightTests(unittest.TestCase):
    def test_real_wiring_failure_then_repair_without_native_execution(self):
        with repo_fixture() as repo:
            shutil.copyfile(ROOT / "scripts/lint-pbxproj-test-wiring.sh", repo / "scripts/lint-pbxproj-test-wiring.sh")
            (repo / "cmuxTests").mkdir()
            (repo / "cmuxTests/UnwiredTests.swift").write_text("import Testing\n@Test func example() {}\n")
            (repo / "cmux.xcodeproj").mkdir()
            project = repo / "cmux.xcodeproj/project.pbxproj"
            project.write_text('''AAAA000000000000000000T1 /* cmuxTests */ = {
 isa = PBXNativeTarget;
 buildPhases = (AAAA000000000000000000S1 /* Sources */,);
};
AAAA000000000000000000S1 /* Sources */ = {
 isa = PBXSourcesBuildPhase;
 files = (
 );
};
''')
            with tempfile.TemporaryDirectory() as receipts:
                evidence = Path(receipts) / "receipt.json"
                failed = cli(repo, "--only", "test-wiring", "--receipt", str(evidence))
                self.assertEqual(failed.returncode, 1, failed.stdout + failed.stderr)
                self.assertIn("UnwiredTests.swift", failed.stdout)
                self.assertIn("--only test-wiring", failed.stdout)
                result = json.loads(evidence.read_text())
                self.assertEqual(result["outcome"]["status"], "failed")
                self.assertEqual(result["evidence"]["executions"][0]["argv"],
                                 ["bash", "scripts/lint-pbxproj-test-wiring.sh"])
                self.assertEqual(verify.receipt.check(result, "typechecking")["status"], "skipped")
                project.write_text(project.read_text().replace(" files = (", " files = (\n /* UnwiredTests.swift in Sources */"))
                fixed = cli(repo, "--only", "test-wiring", "--receipt", str(evidence))
                self.assertEqual(fixed.returncode, 0, fixed.stdout + fixed.stderr)
                result = json.loads(evidence.read_text())
                self.assertEqual(result["outcome"]["status"], "passed")
                self.assertFalse(result["assessment"]["exact_verification"])
                self.assertIsNone(result["artifacts"]["produced"])

    def test_zero_test_success_is_rejected(self):
        with repo_fixture() as repo:
            (repo / "tests/test_normalize_pbxproj.py").write_text('print("Ran 0 tests in 0.000s\\nOK")')
            result = verify.run(repo, ["project-tests"], 5, io.StringIO())
            self.assertEqual(result["outcome"]["status"], "failed")
            self.assertEqual(result["tests"]["executed"], 0)

    def test_nonzero_test_count_and_skips_are_kept(self):
        with repo_fixture() as repo:
            (repo / "tests/test_normalize_pbxproj.py").write_text(
                'import unittest\nclass T(unittest.TestCase):\n'
                ' def test_ok(self): self.assertTrue(True)\n'
                ' @unittest.skip("fixture")\n def test_skip(self): pass\nunittest.main()\n')
            result = verify.run(repo, ["project-tests"], 5, io.StringIO())
            self.assertEqual(result["outcome"]["status"], "passed")
            self.assertEqual(result["tests"]["executed"], 1)
            self.assertEqual(result["tests"]["runner_reported"], 2)
            self.assertEqual(result["tests"]["skipped"], 1)
            self.assertIsNone(result["tests"]["selected"])

    def test_drift_rejects_an_otherwise_passing_preflight(self):
        with repo_fixture() as repo:
            (repo / "scripts/lint-xcstrings.py").write_text('from pathlib import Path\nPath("tracked").write_text("after")\n')
            output = io.StringIO()
            result = verify.run(repo, ["xcstrings"], 5, output)
            self.assertEqual(result["outcome"]["status"], "interrupted")
            self.assertIn("Source changed", output.getvalue())
            self.assertEqual(result["source"]["before"]["commit"], result["source"]["after"]["commit"])

    def test_timeout_settles_process_and_reports_interrupted(self):
        with repo_fixture() as repo:
            (repo / "scripts/lint-xcstrings.py").write_text('import threading\nthreading.Event().wait()\n')
            result = verify.run(repo, ["xcstrings"], .1, io.StringIO())
            self.assertEqual(result["outcome"]["status"], "interrupted")
            self.assertIsNotNone(result["evidence"]["executions"][0]["exit_code"])

    def test_missing_executable_is_unsupported(self):
        with repo_fixture() as repo:
            with patch.object(verify.subprocess, "Popen", side_effect=FileNotFoundError("fixture executable unavailable")):
                execution, output = verify.execute(repo, verify.CHECKS[0], 5)
            self.assertEqual(execution["status"], "unsupported")
            self.assertFalse(execution["executed"])

    def test_failure_output_is_bounded_and_not_copied_into_receipt(self):
        with repo_fixture() as repo:
            (repo / "scripts/lint-xcstrings.py").write_text('print("private-output-fixture" * 10000)\nraise SystemExit(1)\n')
            output = io.StringIO()
            result = verify.run(repo, ["xcstrings"], 5, output)
            self.assertLess(len(output.getvalue()), 9500)
            self.assertIn("private-output-fixture", output.getvalue())
            self.assertNotIn("private-output-fixture", json.dumps(result))
            self.assertEqual(result["outcome"]["status"], "failed")

    def test_requested_subset_does_not_run_other_checks(self):
        with repo_fixture() as repo:
            (repo / "scripts/lint-xcstrings.py").write_text('print("ok")\n')
            result = verify.run(repo, ["xcstrings"], 5, io.StringIO())
            self.assertEqual([e["id"] for e in result["evidence"]["executions"]], ["xcstrings"])
            self.assertEqual(result["outcome"]["status"], "passed")
            self.assertEqual(verify.receipt.check(result, "tests")["status"], "skipped")

    def test_ctrl_c_skips_remaining_checks(self):
        with repo_fixture() as repo:
            execution = {"id": "xcstrings", "phase": "static_analysis", "argv": [], "tests": None,
                         "cancelled": True, "status": "interrupted", "executed": True, "elapsed_seconds": 0}
            with patch.object(verify, "execute", return_value=(execution, "interrupted")) as run:
                result = verify.run(repo, ["xcstrings", "localization"], 5, io.StringIO())
                self.assertEqual(run.call_count, 1)
            self.assertEqual(result["evidence"]["executions"][1]["status"], "skipped")
            self.assertEqual(result["outcome"]["status"], "interrupted")

    def test_cli_rejects_unknown_selection_and_lists_without_repo(self):
        with repo_fixture() as repo:
            self.assertEqual(cli(repo, "--only", "typo").returncode, 2)
            result = cli(repo, "--list", "--repo", "/does-not-exist")
            self.assertEqual(result.returncode, 0)
            self.assertIn("test-wiring:", result.stdout)


class SwiftSyntaxTests(unittest.TestCase):
    def test_no_files_is_an_error_not_a_passing_parse(self):
        with repo_fixture() as repo:
            result = cli(repo, "--only", "swift-syntax")
            self.assertEqual(result.returncode, 2)
            self.assertIn("requires --swift", result.stderr)

    def test_rejects_missing_non_swift_and_outside_paths(self):
        with repo_fixture() as repo:
            for path in ("missing.swift", "tracked", "../outside.swift"):
                with self.subTest(path=path):
                    result = cli(repo, "--only", "swift-syntax", "--swift", path)
                    self.assertEqual(result.returncode, 2)
                    self.assertIn("existing .swift file inside", result.stderr)

    def test_missing_compiler_is_unsupported(self):
        with repo_fixture() as repo:
            (repo / "Example.swift").write_text("let value = 1\n")
            with patch.object(verify.shutil, "which", return_value=None):
                result = verify.run(repo, ["swift-syntax"], 5, io.StringIO(),
                                    swift_files=["Example.swift"])
            self.assertEqual(result["outcome"]["status"], "unsupported")
            self.assertEqual(verify.receipt.check(result, "parsing")["status"], "unsupported")
            self.assertFalse(result["evidence"]["executions"][0]["executed"])

    def test_changed_untracked_input_interrupts_even_with_same_git_status(self):
        with repo_fixture() as repo:
            source = repo / "Example.swift"
            source.write_text("let value = 1\n")
            def changed(repo, item, timeout):
                source.write_text("let value = 2\n")
                return {"id": item[0], "phase": item[1], "argv": item[3], "tests": None,
                        "cancelled": False, "status": "passed", "executed": True,
                        "elapsed_seconds": 0}, ""
            with patch.object(verify, "execute", side_effect=changed):
                result = verify.run(repo, ["swift-syntax"], 5, io.StringIO(),
                                    swift_files=["Example.swift"])
            self.assertEqual(result["outcome"]["status"], "interrupted")
            self.assertIn("selected_swift_source_drift_observed", result["assessment"]["qualifications"])
            self.assertFalse(result["assessment"]["exact_verification"])

    @unittest.skipUnless(shutil.which("swiftc"), "Swift parser unavailable")
    def test_real_parser_catches_ci_raw_string_error_then_accepts_repair(self):
        with repo_fixture() as repo, tempfile.TemporaryDirectory() as output:
            source = repo / "Example with spaces.swift"
            source.write_text('let state = "ok"\nlet stdout = #"{"state":"#(state)"}"#\n')
            evidence = Path(output) / "parse.json"
            args = ("--only", "swift-syntax", "--swift", source.name, "--receipt", str(evidence))
            failed = cli(repo, *args)
            self.assertEqual(failed.returncode, 1, failed.stdout + failed.stderr)
            self.assertIn("Example with spaces.swift", failed.stdout)
            self.assertIn("--swift", failed.stdout)
            source.write_text('import UnavailableModule\nlet state = "ok"\nlet stdout = #"{"state":"\\#(state)"}"#\n')
            passed = cli(repo, *args)
            self.assertEqual(passed.returncode, 0, passed.stdout + passed.stderr)
            result = json.loads(evidence.read_text())
            self.assertEqual(verify.receipt.check(result, "parsing")["status"], "passed")
            self.assertEqual(verify.receipt.check(result, "typechecking")["status"], "skipped")
            self.assertEqual(verify.receipt.check(result, "tests")["status"], "skipped")
            self.assertEqual(len(result["evidence"]["swift_inputs"]["before"]), 1)
            self.assertIn("Swift", result["environment"]["toolchain"])
            self.assertFalse(result["assessment"]["exact_verification"])


if __name__ == "__main__":
    unittest.main()
