#!/usr/bin/env python3
"""Exercise the contributor preflight through subprocesses and temporary Git fixtures."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import git_fixture_env  # noqa: F401  (disables git auto maintenance)

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
            for name in ("lint-pbxproj-test-wiring.sh", "sync-test-wiring",
                         "sync_test_wiring.py", "normalize-pbxproj.py"):
                shutil.copy2(ROOT / "scripts" / name, repo / "scripts" / name)
            for name in ("test_ci_pbxproj_test_wiring.sh", "test_sync_test_wiring.py"):
                shutil.copy2(ROOT / "tests" / name, repo / "tests" / name)
            shutil.copytree(ROOT / "tests/fixtures/pbxproj-test-wiring",
                            repo / "tests/fixtures/pbxproj-test-wiring")
            (repo / "cmuxTests").mkdir()
            (repo / "cmuxTests/ExistingTests.swift").write_text("import Testing\n")
            (repo / "cmux.xcodeproj").mkdir()
            project = repo / "cmux.xcodeproj/project.pbxproj"
            shutil.copyfile(ROOT / "tests/fixtures/pbxproj-test-wiring/base.pbxproj", project)
            sync = [str(repo / "scripts/sync-test-wiring"), "--repo-root", str(repo)]
            subprocess.run(sync, check=True, capture_output=True, text=True)
            (repo / "cmuxTests/UnwiredTests.swift").write_text("import Testing\n@Test func example() {}\n")
            with tempfile.TemporaryDirectory() as receipts:
                evidence = Path(receipts) / "receipt.json"
                failed = cli(repo, "--only", "test-wiring", "--receipt", str(evidence))
                self.assertEqual(failed.returncode, 1, failed.stdout + failed.stderr)
                self.assertIn("UnwiredTests.swift", failed.stdout)
                self.assertIn("--only test-wiring", failed.stdout)
                result = json.loads(evidence.read_text())
                self.assertEqual(result["outcome"]["status"], "failed")
                self.assertEqual(result["evidence"]["executions"][0]["argv"],
                                 ["bash", "tests/test_ci_pbxproj_test_wiring.sh"])
                self.assertEqual(verify.receipt.check(result, "typechecking")["status"], "skipped")
                subprocess.run(sync, check=True, capture_output=True, text=True)
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
    def test_swift_option_adds_parse_without_broadening_selected_static_checks(self):
        with repo_fixture() as repo:
            (repo / "Example.swift").write_text("let value = 1\n")
            (repo / "scripts/lint-xcstrings.py").write_text('print("ok")\n')
            with patch.object(verify.shutil, "which", return_value=None):
                result = verify.run(repo, ["xcstrings"], 5, io.StringIO(),
                                    swift_files=["Example.swift", "Example.swift"])
            self.assertEqual([e["id"] for e in result["evidence"]["executions"]],
                             ["swift-syntax", "xcstrings"])
            self.assertEqual(len(result["evidence"]["swift_inputs"]["before"]), 1)
            self.assertIn("--swift", result["recipe"]["argv"])

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
            self.assertNotIn(str(repo), json.dumps(result))
            self.assertEqual(result["evidence"]["executions"][0]["argv"][0], "swiftc")
            self.assertIn("./" + source.name, result["evidence"]["executions"][0]["argv"])
            self.assertFalse(result["assessment"]["exact_verification"])


class SwiftSelectionTests(unittest.TestCase):
    def git(self, repo, *args):
        return subprocess.check_output(["git", "-C", str(repo), *args]).decode().strip()

    def commit(self, repo):
        self.git(repo, "add", ".")
        self.git(repo, "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid",
                 "commit", "-qm", "baseline")

    def test_changed_selection_includes_staged_unstaged_untracked_and_renames(self):
        with repo_fixture() as repo:
            for name in ("Staged.swift", "Unstaged.swift", "Old.swift", "Deleted.swift"):
                (repo / name).write_text("let value = 1\n")
            (repo / ".gitignore").write_text("Ignored.swift\n")
            self.commit(repo)
            (repo / "Staged.swift").write_text("let value = 2\n")
            self.git(repo, "add", "Staged.swift")
            (repo / "Unstaged.swift").write_text("let value = 3\n")
            self.git(repo, "mv", "Old.swift", "Renamed.swift")
            (repo / "Deleted.swift").unlink()
            for name in ("New with spaces\nand newline.swift", "Ignored.swift", "note.md"):
                (repo / name).write_text("let value = 4\n")
            cache = repo / ".glaeda/apple-build/pkg.derived/runner.swift"
            cache.parent.mkdir(parents=True)
            cache.write_text("let generated = true\n")
            names, evidence = verify.changed_swift_files(repo, "HEAD")
            self.assertEqual(set(names), {"Staged.swift", "Unstaged.swift", "Renamed.swift",
                                          "New with spaces\nand newline.swift"})
            self.assertEqual(evidence["merge_base_sha"], self.git(repo, "rev-parse", "HEAD"))

    def test_base_includes_committed_branch_changes_and_working_tree(self):
        with repo_fixture() as repo:
            (repo / "OnlyBaseEdits.swift").write_text("let value = 1\n")
            self.commit(repo)
            common = self.git(repo, "rev-parse", "HEAD")
            self.git(repo, "branch", "base")
            (repo / "Committed.swift").write_text("let value = 1\n")
            self.commit(repo)
            feature = self.git(repo, "rev-parse", "HEAD")
            self.git(repo, "checkout", "-q", "base")
            (repo / "OnlyBaseEdits.swift").write_text("let value = 2\n")
            self.commit(repo)
            self.git(repo, "checkout", "-q", "--detach", feature)
            (repo / "Dirty.swift").write_text("let value = 2\n")
            names, evidence = verify.changed_swift_files(repo, "base")
            self.assertEqual(set(names), {"Committed.swift", "Dirty.swift"})
            self.assertEqual(evidence["base_sha"], self.git(repo, "rev-parse", "base"))
            self.assertEqual(evidence["merge_base_sha"], common)
            self.assertNotEqual(evidence["base_sha"], self.git(repo, "rev-parse", "HEAD"))
            self.assertEqual(verify.changed_swift_files(repo, "HEAD")[0], ["Dirty.swift"])

    def test_missing_base_fails_closed(self):
        with repo_fixture() as repo:
            result = cli(repo, "--swift-changed", "missing-base")
            self.assertEqual(result.returncode, 2)
            self.assertIn("Cannot select changed Swift files", result.stderr)

    def test_changed_empty_selection_is_a_json_noop_not_a_parse_pass(self):
        with repo_fixture() as repo:
            result = cli(repo, "--only", "swift-syntax", "--swift-changed", "--receipt", "-")
            self.assertEqual(result.returncode, 0, result.stderr)
            evidence = json.loads(result.stdout)
            self.assertEqual(evidence["outcome"]["status"], "skipped")
            self.assertEqual(verify.receipt.check(evidence, "parsing")["status"], "skipped")
            self.assertFalse(evidence["evidence"]["executions"][0]["executed"])
            self.assertEqual(evidence["evidence"]["swift_selection"]["paths"], [])
            self.assertIn("SKIPPED", result.stderr)
            self.assertFalse((repo.parent / "-").exists())

    def test_stdin0_filters_non_swift_and_rejects_unterminated_input(self):
        with repo_fixture() as repo:
            argv = ["python3", str(repo / "scripts/verify-local.py"), "--only", "swift-syntax",
                    "--swift-stdin0", "--receipt", "-"]
            empty = subprocess.run(argv, input=b"note.md\0", capture_output=True)
            self.assertEqual(empty.returncode, 0, empty.stderr)
            self.assertEqual(json.loads(empty.stdout)["outcome"]["status"], "skipped")
            bad = subprocess.run(argv, input=b"File.swift\n", capture_output=True)
            self.assertEqual(bad.returncode, 2)
            self.assertIn(b"NUL-terminated", bad.stderr)
            missing = subprocess.run(argv, input=b"Missing.swift\0", capture_output=True)
            self.assertEqual(missing.returncode, 2)
            self.assertIn(b"existing .swift file inside", missing.stderr)

    def test_empty_swift_selection_does_not_skip_other_selected_checks(self):
        with repo_fixture() as repo:
            (repo / "scripts/lint-xcstrings.py").write_text('print("ok")\n')
            result = cli(repo, "--only", "xcstrings", "--swift-changed", "--receipt", "-")
            self.assertEqual(result.returncode, 0, result.stderr)
            evidence = json.loads(result.stdout)
            self.assertEqual(evidence["outcome"]["status"], "passed")
            self.assertEqual(verify.receipt.check(evidence, "parsing")["status"], "skipped")
            self.assertEqual([e["status"] for e in evidence["evidence"]["executions"]], ["skipped", "passed"])

    def test_json_stdout_preserves_failed_check_exit_and_stderr_diagnostic(self):
        with repo_fixture() as repo:
            (repo / "scripts/lint-xcstrings.py").write_text('print("fixture diagnostic"); raise SystemExit(1)\n')
            result = cli(repo, "--only", "xcstrings", "--receipt", "-")
            self.assertEqual(result.returncode, 1)
            self.assertEqual(json.loads(result.stdout)["outcome"]["status"], "failed")
            self.assertIn("fixture diagnostic", result.stderr)
            self.assertNotIn("fixture diagnostic", result.stdout)

    @unittest.skipUnless(shutil.which("swiftc"), "Swift parser unavailable")
    def test_real_nul_pipeline_preserves_filename_and_json_stdout(self):
        with repo_fixture() as repo:
            name = 'Space and\nnewline "quoted".swift'
            (repo / name).write_text("let value = 1\n")
            producer = subprocess.run(["git", "-C", str(repo), "ls-files", "--others",
                                       "--exclude-standard", "-z"], check=True, capture_output=True)
            consumer = subprocess.run(["python3", str(repo / "scripts/verify-local.py"),
                                       "--only", "swift-syntax", "--swift-stdin0", "--receipt", "-"],
                                      input=producer.stdout, capture_output=True)
            self.assertEqual(consumer.returncode, 0, consumer.stderr)
            evidence = json.loads(consumer.stdout)
            self.assertEqual(evidence["outcome"]["status"], "passed")
            self.assertEqual(evidence["evidence"]["swift_selection"]["paths"], [name])
            self.assertEqual(evidence["evidence"]["swift_inputs"]["before"][0]["path"], name)
            self.assertIn(b"PASSED", consumer.stderr)



class AffectedChecksTests(unittest.TestCase):
    def commit(self, repo):
        subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
        subprocess.run(["git", "-C", str(repo), "-c", "user.name=fixture",
                        "-c", "user.email=fixture@example.invalid", "commit", "-qm", "inputs"], check=True)

    def test_catalog_selects_both_consumers_and_time_sensitive_check(self):
        with repo_fixture() as repo:
            (repo / "Resources").mkdir()
            (repo / "Resources" / "odd name\nstrings.xcstrings").write_text("{}")
            selected, evidence = verify.affected_checks(repo, "HEAD")
            self.assertEqual(selected, ["xcstrings", "localization", "feature-flags"])
            self.assertEqual(evidence["paths"], ["Resources/odd name\nstrings.xcstrings"])
            self.assertIn("time_sensitive", evidence["reasons"]["feature-flags"])

    def test_shared_normalizer_selects_tests_and_production_check(self):
        with repo_fixture() as repo:
            (repo / "scripts/normalize-pbxproj.py").write_text("# changed helper")
            selected, _ = verify.affected_checks(repo, "HEAD")
            self.assertEqual(selected, ["project-tests", "project", "test-wiring-sync", "feature-flags"])

    def test_current_ci_schema_and_sync_inputs_select_their_checks(self):
        for path, expected in (
            ("web/data/cmux.schema.json", "config-schema"),
            ("Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/ConfigValidation/CmuxConfigSchema.generated.swift", "config-schema"),
            ("scripts/sync-test-wiring", "test-wiring-sync"),
            ("scripts/sync_test_wiring.py", "test-wiring-sync"),
            ("tests/fixtures/pbxproj-test-wiring/new.pbxproj", "test-wiring-sync"),
        ):
            with self.subTest(path=path), repo_fixture() as repo:
                target = repo / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("changed")
                selected, evidence = verify.affected_checks(repo, "HEAD")
                self.assertIn(expected, selected)
                self.assertIn(path, evidence["reasons"][expected])
                self.assertEqual(evidence["fallback_paths"], [])

    def test_configuration_and_generated_outputs_are_dependencies(self):
        with repo_fixture() as repo:
            (repo / "scripts/claude-launch-environment-policy.json").write_text("{}")
            selected, _ = verify.affected_checks(repo, "HEAD")
            self.assertEqual(selected, ["launch-policy", "feature-flags"])
            output = repo / "Packages/macOS/CMUXAgentLaunch/Sources/CMUXAgentLaunch/ClaudeSessionEnvironmentPolicy+Generated.swift"
            output.parent.mkdir(parents=True)
            output.write_text("// edited generated output")
            selected, _ = verify.affected_checks(repo, "HEAD")
            self.assertIn("launch-policy", selected)
            self.assertIn("package-groups", selected)

    def test_deleted_input_and_rename_keep_old_and_new_dependencies(self):
        with repo_fixture() as repo:
            old = repo / "scripts/localization-plurals.json"
            old.write_text("{}")
            self.commit(repo)
            old.rename(repo / "scripts/claude-launch-environment-policy.json")
            selected, evidence = verify.affected_checks(repo, "HEAD")
            self.assertEqual(selected, ["localization", "launch-policy", "feature-flags"])
            self.assertIn("scripts/localization-plurals.json", evidence["paths"])

    def test_unknown_input_mixed_with_known_input_falls_back_to_full_recipe(self):
        with repo_fixture() as repo:
            (repo / "scripts/localization-plurals.json").write_text("{}")
            (repo / "unmodeled-input").write_text("new")
            selected, evidence = verify.affected_checks(repo, "HEAD")
            self.assertEqual(selected, [c[0] for c in verify.CHECKS])
            self.assertEqual(evidence["fallback_paths"], ["unmodeled-input"])

    def test_unchanged_or_docs_only_still_runs_date_sensitive_policy(self):
        with repo_fixture() as repo:
            self.assertEqual(verify.affected_checks(repo, "HEAD")[0], ["feature-flags"])
            (repo / "README.md").write_text("docs")
            selected, evidence = verify.affected_checks(repo, "HEAD")
            self.assertEqual(selected, ["feature-flags"])
            self.assertIn("xcstrings", evidence["omitted"])

    def test_base_includes_committed_changes_and_dirty_source(self):
        with repo_fixture() as repo:
            subprocess.run(["git", "-C", str(repo), "branch", "base"], check=True)
            (repo / "scripts/localization-plurals.json").write_text("{}")
            self.commit(repo)
            (repo / ".xcode-version").write_text("26")
            selected, evidence = verify.affected_checks(repo, "base")
            self.assertEqual(selected, ["localization", "project", "feature-flags"])
            self.assertEqual(evidence["base_ref"], "base")
            self.assertEqual(len(evidence["merge_base_sha"]), 40)

    def test_plan_does_not_execute_scripts_and_missing_ref_fails(self):
        with repo_fixture() as repo:
            (repo / "README.md").write_text("docs")
            result = cli(repo, "--affected", "--list")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("feature-flags", result.stdout)
            self.assertIn("time_sensitive", result.stdout)
            self.assertEqual(cli(repo, "--affected", "missing-ref", "--list").returncode, 2)
            self.assertEqual(cli(repo, "--affected", "--only", "project").returncode, 2)

    def test_cli_executes_only_selected_checks_and_emits_selection_in_json(self):
        with repo_fixture() as repo:
            (repo / "scripts/lint-feature-flags.py").write_text("print('policy ok')")
            self.commit(repo)
            (repo / "README.md").write_text("docs edit")
            result = cli(repo, "--affected", "--receipt", "-")
            self.assertEqual(result.returncode, 0, result.stderr)
            data = json.loads(result.stdout)
            self.assertEqual([e["id"] for e in data["evidence"]["executions"]], ["feature-flags"])
            self.assertEqual(data["evidence"]["affected_selection"]["paths"], ["README.md"])
            self.assertFalse(data["assessment"]["exact_verification"])
            self.assertIsNone(data["tests"]["executed"])

    def test_untracked_input_drift_interrupts_selected_run(self):
        with repo_fixture() as repo:
            (repo / "scripts/lint-feature-flags.py").write_text("print('ok')")
            self.commit(repo)
            target = repo / "README.md"
            target.write_text("before")
            original = verify.execute
            def mutate(*args):
                value = original(*args)
                target.write_text("after")
                return value
            with patch.object(verify, "execute", side_effect=mutate):
                data = verify.run(repo, [], 5, stream=io.StringIO(), affected="HEAD")
            self.assertEqual(data["outcome"]["status"], "interrupted")
            self.assertIn("affected_input_drift_observed", data["assessment"]["qualifications"])

class AutomaticSelectionTests(unittest.TestCase):
    def remote_default(self, repo, remote="origin"):
        subprocess.run(["git", "-C", str(repo), "update-ref",
                        f"refs/remotes/{remote}/main", "HEAD"], check=True)
        subprocess.run(["git", "-C", str(repo), "symbolic-ref",
                        f"refs/remotes/{remote}/HEAD", f"refs/remotes/{remote}/main"], check=True)

    def test_prefers_upstream_default_and_falls_back_to_origin(self):
        with repo_fixture() as repo:
            self.remote_default(repo)
            self.assertEqual(verify.automatic_scope(repo, {})["base_ref"], "refs/remotes/origin/main")
            self.remote_default(repo, "upstream")
            self.assertEqual(verify.automatic_scope(repo, {})["base_ref"], "refs/remotes/upstream/main")

    def test_missing_base_and_ci_use_full_static_recipe(self):
        with repo_fixture() as repo:
            self.assertEqual(verify.automatic_scope(repo, {})["mode"], "full_fallback")
            self.remote_default(repo)
            for env in ({"CI": "true"}, {"GITHUB_ACTIONS": "true"}):
                self.assertEqual(verify.automatic_scope(repo, env)["mode"], "ci_full")
            self.assertEqual(verify.automatic_scope(repo, {"CI": "false"})["mode"], "affected")

    def test_stale_remote_default_uses_full_recipe(self):
        with repo_fixture() as repo:
            subprocess.run(["git", "-C", str(repo), "symbolic-ref",
                            "refs/remotes/origin/HEAD", "refs/remotes/origin/missing"], check=True)
            self.assertEqual(verify.automatic_scope(repo, {})["mode"], "full_fallback")

    def test_plain_command_selects_branch_edits_and_reports_base(self):
        with repo_fixture() as repo:
            (repo / "scripts/lint-feature-flags.py").write_text("print('policy ok')")
            AffectedChecksTests().commit(repo)
            self.remote_default(repo)
            (repo / "README.md").write_text("branch documentation")
            AffectedChecksTests().commit(repo)
            with patch.dict(os.environ, {"CI": "", "GITHUB_ACTIONS": ""}):
                result = cli(repo, "--receipt", "-")
            self.assertEqual(result.returncode, 0, result.stderr)
            data = json.loads(result.stdout)
            self.assertEqual(data["evidence"]["automatic_selection"]["base_ref"], "refs/remotes/origin/main")
            self.assertEqual(data["evidence"]["affected_selection"]["paths"], ["README.md"])
            executions = {e["id"]: e for e in data["evidence"]["executions"]}
            self.assertEqual(executions["feature-flags"]["status"], "passed")
            self.assertEqual(executions["swift-syntax"]["status"], "skipped")

    def test_plain_preview_selects_swift_without_running_compiler(self):
        with repo_fixture() as repo:
            self.remote_default(repo)
            (repo / "Sources").mkdir()
            (repo / "Sources/Changed.swift").write_text("not valid Swift")
            with patch.dict(os.environ, {"CI": "", "GITHUB_ACTIONS": ""}):
                result = cli(repo, "--list")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Sources/Changed.swift", result.stdout)
            self.assertIn("swift-syntax", result.stdout)
            self.assertNotIn("RUN ", result.stdout)

    def test_preview_respects_explicit_check_and_swift_file_selection(self):
        with repo_fixture() as repo:
            self.remote_default(repo)
            (repo / "Example.swift").write_text("invalid Swift")
            result = cli(repo, "--only", "swift-syntax", "--swift", "Example.swift", "--list")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Example.swift", result.stdout)
            self.assertNotIn("xcstrings:", result.stdout)
            self.assertNotIn("RUN ", result.stdout)

    def test_all_and_ci_preserve_full_recipe_and_explicit_selection_wins(self):
        with repo_fixture() as repo:
            self.remote_default(repo)
            for args, env in [(("--all", "--list"), {"CI": ""}),
                              (("--list",), {"GITHUB_ACTIONS": "true"})]:
                with patch.dict(os.environ, env):
                    result = cli(repo, *args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("xcstrings:", result.stdout)
                self.assertIn("project-tests:", result.stdout)
            result = cli(repo, "--all", "--affected")
            self.assertEqual(result.returncode, 2)
            result = cli(repo, "--only", "feature-flags", "--receipt", "-")
            self.assertNotIn("automatic_selection", json.loads(result.stdout)["evidence"])


if __name__ == "__main__":
    unittest.main()
