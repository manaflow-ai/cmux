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

    def test_workflow_approval_is_only_for_the_approval_label_event(self):
        workflow = (ROOT / ".github/workflows/test-integrity.yml").read_text(encoding="utf-8")
        self.assertIn("github.event.action == 'labeled'", workflow)
        self.assertIn("github.event.label.name == 'test-integrity-approved'", workflow)
        self.assertIn("github.event.action == 'unlabeled'", workflow)
        self.assertIn("github.event.action == 'opened'", workflow)
        self.assertIn("github.event.action == 'synchronize'", workflow)
        self.assertIn("github.event.action == 'reopened'", workflow)
        self.assertNotIn("github.event.action != 'synchronize'", workflow)
        self.assertNotIn("contains(github.event.pull_request.labels.*.name, 'test-integrity-approved')", workflow)


if __name__ == "__main__":
    unittest.main()
