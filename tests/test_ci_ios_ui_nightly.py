"""The nightly run of every iOS UI test: the run it reports, its issue body, and its wiring."""

import importlib.util
import pathlib
import re
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/ios_ui_nightly.py"
NIGHTLY = ROOT / ".github/workflows/ios-ui-tests-nightly.yml"
TEST_IOS = ROOT / ".github/workflows/test-ios.yml"
sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("ios_ui_nightly", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


def run(**overrides):
    base = {
        "id": 7,
        "path": ".github/workflows/test-ios.yml",
        "event": "workflow_dispatch",
        "head_branch": "main",
        "head_sha": "a" * 40,
        "html_url": "https://github.com/o/r/actions/runs/7",
        "status": "completed",
        "conclusion": "failure",
        "display_title": "iOS tests · main · simulator · cmuxUITests · both · iOS default · on auto",
    }
    base.update(overrides)
    return base


class WholeUiRunTests(unittest.TestCase):
    def test_a_whole_target_dispatch_on_main_is_reported(self):
        self.assertTrue(MODULE.is_whole_ui_run(run(), "main"))

    def test_one_class_a_pull_request_or_another_branch_is_not(self):
        one_class = "iOS tests · main · simulator · cmuxUITests/PushReadinessUITests · both · iOS default · on auto"
        self.assertFalse(MODULE.is_whole_ui_run(run(display_title=one_class), "main"))
        self.assertFalse(MODULE.is_whole_ui_run(run(event="pull_request"), "main"))
        self.assertFalse(MODULE.is_whole_ui_run(run(head_branch="feat"), "main"))
        self.assertFalse(MODULE.is_whole_ui_run(run(path=".github/workflows/ci.yml"), "main"))
        full_suite = "iOS tests · main · simulator · full suite · both · iOS default · on auto"
        self.assertFalse(MODULE.is_whole_ui_run(run(display_title=full_suite), "main"))

    def test_run_name_renders_the_filter_the_selector_reads(self):
        # The selector depends on test-ios.yml's run-name putting the filter between ` · `.
        text = TEST_IOS.read_text()
        self.assertIn("${{ inputs.ref || github.ref_name }} · ${{ inputs.swift_package || 'simulator' }} ·", text)
        self.assertIn("${{ inputs.test_filter || 'full suite' }} ·", text)


class IssueBodyTests(unittest.TestCase):
    def test_body_names_the_commit_run_and_failing_jobs(self):
        jobs = [{"name": "ios-simulator (iphone)", "html_url": "https://x/j/1", "conclusion": "failure"}]
        body = MODULE.failure_body(run(), jobs)
        self.assertIn("a" * 40, body)
        self.assertIn("https://github.com/o/r/actions/runs/7", body)
        self.assertIn("[ios-simulator (iphone)](https://x/j/1)", body)
        self.assertIn("test_filter=cmuxUITests/<Class>", body)

    def test_red_opens_and_green_closes(self):
        self.assertEqual(MODULE.issue_plan("failure", False, False), "open")
        self.assertEqual(MODULE.issue_plan("failure", True, True), "none")
        self.assertEqual(MODULE.issue_plan("success", True, False), "close")
        self.assertEqual(MODULE.issue_plan("cancelled", True, False), "none")


class WiringTests(unittest.TestCase):
    def test_nightly_dispatches_the_whole_ui_target_on_main(self):
        text = NIGHTLY.read_text()
        self.assertRegex(text, r'cron: "[^"]+"')
        self.assertIn("actions/workflows/test-ios.yml/dispatches", text)
        self.assertIn("-f ref=main -f 'inputs[test_filter]=cmuxUITests'", text)
        self.assertIn("workflows: [iOS simulator tests]", text)
        self.assertIn("contains(github.event.workflow_run.display_title, ' · cmuxUITests · ')", text)
        self.assertIn('python3 scripts/ci/ios_ui_nightly.py report --run-id "$RUN_ID"', text)

    def test_test_ios_names_the_workflow_the_report_listens_to(self):
        self.assertRegex(TEST_IOS.read_text(), r"(?m)^name: iOS simulator tests$")

    def test_test_ios_runs_the_whole_target_as_a_ui_run(self):
        text = TEST_IOS.read_text()
        # The producer builds the UI plan, both stage steps stamp it, and the
        # consumer selects the target instead of skipping it.
        self.assertIn(
            '[[ "${TEST_FILTER:-}" == cmuxUITests || "${TEST_FILTER:-}" == cmuxUITests/* ]]', text,
        )
        plan = "(inputs.test_filter == 'cmuxUITests' || startsWith(inputs.test_filter, 'cmuxUITests/')) && 'cmux-ui'"
        self.assertEqual(text.count(plan), 2)
        self.assertNotIn("startsWith(inputs.test_filter, 'cmuxUITests/') && 'cmux-ui'", text.replace(plan, ""))
        self.assertIn('[[ "$TEST_FILTER" != cmuxUITests && "$TEST_FILTER" != cmuxUITests/* ]]', text)
        self.assertIn('XCODEBUILD_ARGS+=(-only-testing:"$TEST_FILTER")', text)

    def test_whole_target_gets_room_inside_its_job_cap(self):
        text = TEST_IOS.read_text()
        cap = re.search(r"timeout-minutes: \$\{\{ inputs\.test_filter == 'cmuxUITests' && (\d+) \|\| 25 \}\}", text)
        bound = re.search(
            r"XCODEBUILD_TIMEOUT_SECONDS: \$\{\{ inputs\.test_filter == 'cmuxUITests' && '(\d+)' \|\| '900' \}\}", text,
        )
        self.assertIsNotNone(cap)
        self.assertIsNotNone(bound)
        self.assertLess(int(bound.group(1)), int(cap.group(1)) * 60)


if __name__ == "__main__":
    unittest.main()
