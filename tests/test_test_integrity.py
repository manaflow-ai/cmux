from __future__ import annotations

import importlib.util
import sys
import unittest
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("test_integrity", ROOT / "scripts/ci/test_integrity.py")
assert SPEC and SPEC.loader
module = importlib.util.module_from_spec(SPEC)
sys.modules["test_integrity"] = module
SPEC.loader.exec_module(module)


class TestIntegrity(unittest.TestCase):
    def test_checker_file_deletion_is_blocked(self):
        findings = module.analyze("D\tscripts/ci/test_integrity.py\n", "")
        self.assertEqual([f.kind for f in findings], ["deleted-test-file"])

    def test_checker_cannot_exempt_a_different_test_file_with_same_name(self):
        findings = module.analyze("D\ttests/test_integrity.py\n", "")
        self.assertEqual([f.kind for f in findings], ["deleted-test-file"])

    def test_deleted_test_file_is_blocked(self):
        findings = module.analyze("D\ttests/test_deleted.py\n", "")
        self.assertEqual([f.kind for f in findings], ["deleted-test-file"])

    def test_assertion_replacement_with_same_count_is_allowed(self):
        diff = """diff --git a/tests/test_math.py b/tests/test_math.py
--- a/tests/test_math.py
+++ b/tests/test_math.py
@@ -1 +1 @@
-    self.assertEqual(result, 1)
+    self.assertEqual(result, 2)
"""
        self.assertEqual(module.analyze("M\ttests/test_math.py\n", diff), [])

    def test_assertion_loss_and_new_skip_are_blocked(self):
        marker = "pytest.mark." + "skip"
        diff = f"""diff --git a/tests/test_math.py b/tests/test_math.py
--- a/tests/test_math.py
+++ b/tests/test_math.py
@@ -1,3 +1,2 @@
-    self.assertEqual(result, 1)
-    self.assertTrue(result)
+    {marker}(reason=temporary)
"""
        self.assertEqual(
            [f.kind for f in module.analyze("M\ttests/test_math.py\n", diff)],
            ["weakened-assertions", "new-skip"],
        )

    def test_rename_from_test_to_non_test_is_blocked(self):
        findings = module.analyze("R100\ttests/test_old.py\tsrc/old.py\n", "")
        self.assertEqual([f.kind for f in findings], ["deleted-test-file"])

    def test_non_test_files_are_ignored(self):
        diff = """diff --git a/src/math.py b/src/math.py
--- a/src/math.py
+++ b/src/math.py
@@ -1 +1 @@
-    assert value
+    return value
"""
        self.assertEqual(module.analyze("M\tsrc/math.py\n", diff), [])

    def test_common_tests_directories_and_scripts_are_test_paths(self):
        self.assertTrue(module.is_test_path("cmuxCLITests/CLIAgentMessageCommandTests.swift"))
        self.assertTrue(module.is_test_path("Examples/FooTests/Bar.swift"))
        self.assertTrue(module.is_test_path("tools/freestyle-workflow/test.mjs"))
        self.assertTrue(module.is_test_path("tools/test.sh"))
        self.assertFalse(module.is_test_path("latest/fetchLatest.ts"))
        self.assertFalse(module.is_test_path("src/contest.json"))

    def test_same_line_assertion_removal_is_detected(self):
        diff = """diff --git a/tests/test_x.py b/tests/test_x.py
--- a/tests/test_x.py
+++ b/tests/test_x.py
@@ -1 +1 @@
-assert a; assert b
+assert a
"""
        findings = module.analyze("M\ttests/test_x.py\n", diff)
        self.assertTrue(any(f.kind == "weakened-assertions" for f in findings))

    def test_comment_text_is_not_counted_as_an_assertion(self):
        diff = """diff --git a/tests/test_x.py b/tests/test_x.py
--- a/tests/test_x.py
+++ b/tests/test_x.py
@@ -1 +1 @@
-# assert this fixture is documented
+# fixture is documented
"""
        findings = module.analyze("M\ttests/test_x.py\n", diff)
        self.assertFalse(any(f.kind == "weakened-assertions" for f in findings))

    def test_swift_and_rust_assertions_are_counted(self):
        diff = """diff --git a/tests/test_x.swift b/tests/test_x.swift
--- a/tests/test_x.swift
+++ b/tests/test_x.swift
@@ -1,2 +1,1 @@
-#expect(value == 1)
-XCTAssertEqual(value, 1)
+#expect(value == 2)
"""
        findings = module.analyze("M\ttests/test_x.swift\n", diff)
        self.assertTrue(any(f.kind == "weakened-assertions" for f in findings))

        rust = """diff --git a/tests/x_test.rs b/tests/x_test.rs
--- a/tests/x_test.rs
+++ b/tests/x_test.rs
@@ -1,2 +1,1 @@
-assert_eq!(value, 1);
-assert_ne!(value, 2);
+assert_eq!(value, 2);
"""
        findings = module.analyze("M\ttests/x_test.rs\n", rust)
        self.assertTrue(any(f.kind == "weakened-assertions" for f in findings))

    def test_swift_and_rust_test_definitions_are_counted(self):
        diff = """diff --git a/tests/x_test.rs b/tests/x_test.rs
--- a/tests/x_test.rs
+++ b/tests/x_test.rs
@@ -1,2 +1 @@
-#[test] fn test_value() { assert_eq!(1, 1); }
+fn helper() {}
"""
        findings = module.analyze("M\ttests/x_test.rs\n", diff)
        self.assertTrue(any(f.kind == "deleted-test-case" for f in findings))

    def test_quoted_diff_header_keeps_content_checks(self):
        diff = 'diff --git "a/tests/test_\\t.py" "b/tests/test_\\t.py"\n--- "a/tests/test_\\t.py"\n+++ "b/tests/test_\\t.py"\n@@ -1,2 +1,1 @@\n-assert value\n-assert other\n+pass\n'
        findings = module.analyze("M\ttests/test_\t.py\n", diff)
        self.assertTrue(any(f.kind == "weakened-assertions" for f in findings))

    def test_hunk_content_cannot_fake_a_new_file_header(self):
        diff = """diff --git a/tests/test_x.py b/tests/test_x.py
--- a/tests/test_x.py
+++ b/tests/test_x.py
@@ -1,3 +1,2 @@
-assert value
-assert other
+text = \"+++ b/src/not-a-file.py\"
"""
        findings = module.analyze("M\ttests/test_x.py\n", diff)
        self.assertTrue(any(f.kind == "weakened-assertions" for f in findings))

    def test_unicode_diff_path_keeps_content_checks(self):
        diff = """diff --git a/tests/test_ä.py b/tests/test_ä.py
--- a/tests/test_ä.py
+++ b/tests/test_ä.py
@@ -1,2 +1,1 @@
-assert value
-assert other
+pass
"""
        findings = module.analyze("M\ttests/test_ä.py\n", diff)
        self.assertTrue(any(f.kind == "weakened-assertions" for f in findings))

    def test_diff_commands_disable_attributes_and_text_conversion(self):
        calls = []

        def fake_git(*args):
            calls.append(args)
            return "" if "--name-status" in args else "HEAD"

        with mock.patch.object(module, "_git", side_effect=fake_git):
            module.run("base")
        self.assertEqual(calls[0][0:6], ("-c", "core.quotePath=false", "diff", "--name-status", "--find-renames", "--text"))
        self.assertIn("--no-ext-diff", calls[0])
        self.assertIn("--no-textconv", calls[0])

    def test_a_binary_file_in_the_diff_does_not_crash_the_check(self):
        """#40110 added .webp images to main; `git diff --text` printed their raw bytes and the strict UTF-8
        decode raised UnicodeDecodeError, so the guard failed on every pull request whose base predated it
        (run 42752938602, 2026-11-10). The check must still run, and still see a weakened test beside it."""
        import os
        import subprocess
        import tempfile

        with tempfile.TemporaryDirectory() as repo:
            env = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}

            def git(*args):
                subprocess.run(["git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", *args],
                               check=True, capture_output=True, env=env)

            git("init", "-q")
            Path(repo, "tests").mkdir()
            Path(repo, "tests/test_math.py").write_text("    self.assertEqual(result, 1)\n")
            git("add", "-A")
            git("commit", "-q", "-m", "base")
            base = subprocess.check_output(["git", "-C", repo, "rev-parse", "HEAD"], text=True, env=env).strip()
            Path(repo, "image.webp").write_bytes(b"RIFF\x00\x00WEBPVP8 \xee\xff\xfe\x80\x00binary")
            Path(repo, "tests/test_math.py").write_text("    pass\n")
            git("add", "-A")
            git("commit", "-q", "-m", "head")
            cwd = os.getcwd()
            os.chdir(repo)
            try:
                with mock.patch.dict(os.environ, {"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}):
                    findings = module.run(base)
            finally:
                os.chdir(cwd)
        self.assertEqual([f.kind for f in findings], ["weakened-assertions"])

    def test_findings_print_on_a_stdout_that_cannot_encode_them(self):
        """After #40143 a path or line that is not UTF-8 reaches a finding as U+FFFD, and a test path can hold
        any character. A runner whose stdout encoding is ASCII (PYTHONIOENCODING, a C locale) must not turn
        that finding into a UnicodeEncodeError crash (ci-rev-1 on #40143): the guard prints it escaped and
        keeps its own exit status."""
        import os
        import subprocess
        import tempfile

        with tempfile.TemporaryDirectory() as repo:
            env = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}

            def git(*args):
                subprocess.run(["git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", *args],
                               check=True, capture_output=True, env=env)

            git("init", "-q")
            Path(repo, "tests").mkdir()
            Path(repo, "tests/test_r\u00e9sum\u00e9.py").write_text("    self.assertEqual(result, 1)\n")
            git("add", "-A")
            git("commit", "-q", "-m", "base")
            base = subprocess.check_output(["git", "-C", repo, "rev-parse", "HEAD"], text=True, env=env).strip()
            Path(repo, "tests/test_r\u00e9sum\u00e9.py").write_text("    pass\n")
            git("add", "-A")
            git("commit", "-q", "-m", "head")
            script = str(ROOT / "scripts/ci/test_integrity.py")
            for extra in ([], ["--strict"]):
                # No -I: it would ignore PYTHONIOENCODING. CI runs the guard as `python3 scripts/ci/...`.
                result = subprocess.run([sys.executable, script, "--base", base, *extra], cwd=repo,
                                        capture_output=True, env={**env, "PYTHONIOENCODING": "ascii"})
                stdout = result.stdout.decode("ascii", errors="replace")
                stderr = result.stderr.decode("ascii", errors="replace")
                self.assertNotIn("Traceback", stderr, stderr)
                self.assertEqual(result.returncode, 1 if extra else 0, stdout + stderr)
                self.assertIn("weakened-assertions: tests/test_r\\xe9sum\\xe9.py", stderr)
                self.assertIn("::warning file=tests/test_r\\xe9sum\\xe9.py", stdout)

    def test_skip_reason_update_is_not_new_skip(self):
        diff = """diff --git a/tests/test_x.py b/tests/test_x.py
--- a/tests/test_x.py
+++ b/tests/test_x.py
@@ -1 +1 @@
-marker = "pytest.mark." + "skip('old')"
+marker = "pytest.mark." + "skip('new')"
"""
        self.assertFalse(any(f.kind == "new-skip" for f in module.analyze("M\ttests/test_x.py\n", diff)))

    def test_approved_findings_can_be_recorded_without_blocking(self):
        with mock.patch.object(module, "resolve_base", return_value="base"), \
                mock.patch.object(module, "run", return_value=[module.Finding("new-skip", "tests/x.py", "fixture")]), \
                mock.patch.object(module, "_git", return_value="head"):
            self.assertEqual(module.main(["--base", "base", "--allow-all"]), 0)

    def test_workflow_scopes_approval_and_unrelated_label_events(self):
        workflow = (ROOT / ".github/workflows/test-integrity.yml").read_text(encoding="utf-8")
        self.assertIn("types: [opened, synchronize, reopened, labeled, unlabeled]", workflow)
        self.assertIn("github.run_id", workflow)
        self.assertIn("TEST_INTEGRITY_HEAD_SHA", workflow)
        self.assertIn('"$TEST_INTEGRITY_HEAD_SHA"', workflow)
        self.assertIn("deleted-or-weakened-tests-label-noop", workflow)
        self.assertIn("github.event.label.name == 'test-integrity-approved'", workflow)
        self.assertIn('args+=(--strict)', workflow)
        self.assertIn('args+=(--allow-all)', workflow)


if __name__ == "__main__":
    unittest.main()
