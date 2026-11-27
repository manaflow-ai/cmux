#!/usr/bin/env python3
"""Contract tests for the real Sparkle update matrix runner."""

import importlib.util
from pathlib import Path
import sys
import unittest


HERE = Path(__file__).resolve().parent
MATRIX = HERE / ".." / "update-harness" / "matrix.py"
spec = importlib.util.spec_from_file_location("update_harness_matrix", MATRIX)
matrix = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = matrix
spec.loader.exec_module(matrix)


class UpdateHarnessMatrixTests(unittest.TestCase):
    def test_matrix_covers_each_requested_failure_boundary(self):
        names = {case.name for case in matrix.CASES}
        self.assertEqual(names, {
            "shared-pref-on-download-on",
            "shared-pref-on-download-off",
            "feed-fault",
            "transfer-fault",
            "staged-corruption",
            "read-only-install",
            "required-update",
            "session-handoff",
        })

    def test_shared_preference_rows_keep_download_choice_explicit(self):
        rows = {case.name: case.flags for case in matrix.CASES}
        self.assertEqual(rows["shared-pref-on-download-on"], ("--sparkle-auto",))
        self.assertEqual(rows["shared-pref-on-download-off"], ("--sparkle-auto", "--downloads-off"))

    def test_expected_failures_are_checked_from_the_timeline(self):
        rows = {case.name: case for case in matrix.CASES}
        self.assertEqual(rows["feed-fault"].expected_failure_card, "check_failed")
        self.assertEqual(rows["transfer-fault"].expected_failure_card, "check_failed")
        self.assertEqual(rows["transfer-fault"].expected_failure_content, "downloadManually")

    def test_failure_card_accepts_the_status_json_shape(self):
        case = next(case for case in matrix.CASES if case.name == "feed-fault")
        self.assertTrue(matrix.case_passed(
            case,
            1,
            {"scenario": {"status": {"card": {"kind": "check_failed"}}}},
        ))
        self.assertFalse(matrix.case_passed(
            case,
            0,
            {"scenario": {"status": {"card": {"kind": "check_failed"}}}},
        ))

    def test_every_case_has_a_unique_runner_tag_and_output(self):
        paths = []
        tags = []
        for case in matrix.CASES:
            paths.append(Path("/tmp/matrix") / case.name)
            tags.append(matrix._slug(f"update-matrix-{case.name}"))
        self.assertEqual(len(paths), len(set(paths)))
        self.assertEqual(len(tags), len(set(tags)))


if __name__ == "__main__":
    unittest.main()
