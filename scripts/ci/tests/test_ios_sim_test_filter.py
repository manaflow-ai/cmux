#!/usr/bin/env python3
"""ios_sim_test_filter.py: a filter that selects no test fails the run.

Run: python3 scripts/ci/tests/test_ios_sim_test_filter.py
"""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/ci/ios_sim_test_filter.py"


def case(name, result="Passed"):
    return {"nodeType": "Test Case", "name": name, "result": result}


def tree(*bundles):
    return {"testNodes": [{"nodeType": "Test Plan", "name": "CmuxMobileKit", "children": list(bundles)}]}


def bundle(name, *suites, kind="Unit test bundle"):
    return {"nodeType": kind, "name": name, "children": list(suites)}


def suite(name, *children):
    return {"nodeType": "Test Suite", "name": name, "children": list(children)}


LIVE = bundle(
    "CmuxMobileLiveTests",
    suite("LinkRecoveryTests", case("testRedial()"), case("testRoam()")),
    suite("DaemonTerminalSessionTests", case("testAttach()", "Skipped")),
)


def run(test_tree, *items):
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "kit-tests.json"
        if test_tree is not None:
            path.write_text(json.dumps(test_tree))
        done = subprocess.run(
            [sys.executable, "-I", str(SCRIPT), str(path), *items], capture_output=True, text=True
        )
    return done.returncode, done.stdout + done.stderr


class FilterTests(unittest.TestCase):
    def test_a_filter_that_ran_tests_passes(self):
        for item in (
            "CmuxMobileLiveTests",
            "CmuxMobileLiveTests/LinkRecoveryTests",
            "-only-testing:CmuxMobileLiveTests/LinkRecoveryTests/testRoam",
            "CmuxMobileLiveTests/LinkRecoveryTests/testRoam()",
        ):
            code, out = run(tree(LIVE), item)
            self.assertEqual(code, 0, (item, out))

    def test_a_suite_named_under_the_wrong_target_fails_naming_it(self):
        # The measured miss: the suite lives in CmuxMobileLiveTests, so xcodebuild ran nothing and exited 0.
        code, out = run(tree(), "CmuxMobileTerminalTests/DaemonTerminalSessionTests")
        self.assertEqual(code, 1, out)
        self.assertIn("CmuxMobileTerminalTests/DaemonTerminalSessionTests", out)

    def test_one_dead_item_among_live_ones_fails_naming_only_it(self):
        code, out = run(tree(LIVE), "CmuxMobileLiveTests/LinkRecoveryTests", "CmuxMobileLiveTests/NoSuchTests")
        self.assertEqual(code, 1, out)
        self.assertIn("CmuxMobileLiveTests/NoSuchTests matched no test", out)
        self.assertNotIn("LinkRecoveryTests matched", out)

    def test_an_unknown_test_method_fails(self):
        code, out = run(tree(LIVE), "CmuxMobileLiveTests/LinkRecoveryTests/testNope")
        self.assertEqual(code, 1, out)

    def test_a_filter_whose_tests_were_all_skipped_fails(self):
        code, out = run(tree(LIVE), "CmuxMobileLiveTests/DaemonTerminalSessionTests")
        self.assertEqual(code, 1, out)
        self.assertIn("none ran", out)

    def test_a_missing_result_tree_fails(self):
        code, out = run(None, "CmuxMobileLiveTests/LinkRecoveryTests")
        self.assertEqual(code, 1, out)
        self.assertIn("no test case ran", out)

    def test_ui_bundles_match_too(self):
        ui = bundle("CmuxMobileAppUITests", suite("LaunchTTIUITests", case("testLaunch()")), kind="UI test bundle")
        self.assertEqual(run(tree(ui), "CmuxMobileAppUITests/LaunchTTIUITests")[0], 0)
        self.assertEqual(run(tree(ui), "CmuxMobileAppUITests/LaunchTTIUITestz")[0], 1)

    def test_the_sim_script_checks_kit_and_ui_filters(self):
        text = (ROOT / "scripts/ci/cmux-next-ios-sim.sh").read_text()
        self.assertIn('ios_sim_test_filter.py "$out/kit-tests.json" "${kit_only[@]}"', text)
        self.assertIn('ios_sim_test_filter.py "$out/ui-tests.json" "${ui_suites[@]}"', text)


if __name__ == "__main__":
    unittest.main()
