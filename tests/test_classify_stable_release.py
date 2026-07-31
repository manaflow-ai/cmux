#!/usr/bin/env python3
import importlib.util
import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts/ci/classify_stable_release.py"
SPEC = importlib.util.spec_from_file_location("classify_stable_release", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class StableReleaseOrderTests(unittest.TestCase):
    def test_candidate_is_included_before_github_lists_it(self) -> None:
        result = MODULE.classify("v0.64.21", [{"tagName": "v0.64.20"}])
        self.assertEqual(result["is_latest"], "true")
        self.assertEqual(result["latest_tag"], "v0.64.21")

    def test_backport_is_never_latest(self) -> None:
        result = MODULE.classify("v0.63.9", [{"tagName": "v0.64.20"}])
        self.assertEqual(result["make_latest"], "false")
        self.assertEqual(result["latest_tag"], "v0.64.20")

    def test_nonstable_existing_tags_do_not_contaminate_order(self) -> None:
        result = MODULE.classify(
            "v0.64.21",
            [{"tagName": "nightly"}, {"tagName": "v99.0.0-rc.1"}],
        )
        self.assertEqual(result["is_latest"], "true")

    def test_nonstable_candidate_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            MODULE.classify("v0.65.0-rc.1", [])


if __name__ == "__main__":
    unittest.main()
