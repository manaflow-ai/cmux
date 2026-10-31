#!/usr/bin/env python3
"""A tip_swift_suite dispatch of cmux-next.yml runs the whole Swift suite on the feat-cmux-next tip.

A feat-cmux-next push skips swift-test (push CI is the app build only), so a Swift suite red on
the base stayed invisible: on 2026-10-21 the CmuxNextAppTests run had ended mid-way with status 0
for over a day before anyone looked. main's cmux-next-tip-swift-suite-dispatch.yml asks for this
mode every few hours; its run is the base verdict scripts/ci/base_red_excuse.py compares a pull
request's swift-test red with.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = (ROOT / ".github/workflows/cmux-next.yml").read_text()


def job(name: str) -> str:
    match = re.search(rf"^  {re.escape(name)}:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)", WORKFLOW, re.MULTILINE | re.DOTALL)
    assert match, f"no {name} job"
    return match.group(1)


def tip_branch() -> str:
    route = job("path_route")
    # Up to the next branch: the tip daemon suite's elif, or the router's else.
    match = re.search(r'elif \[\[ "\$EVENT_NAME" == workflow_dispatch && "\$TIP_SWIFT_SUITE" == true \]\]; then\n(.*?)\n          el(?:se|if)\b',
                      route, re.DOTALL)
    assert match, "path_route has no tip_swift_suite branch"
    return match.group(1)


class TipSwiftSuite(unittest.TestCase):
    def test_the_dispatch_input_exists_and_names_the_run(self):
        self.assertRegex(WORKFLOW, r"\n      tip_swift_suite:\n(?:        .*\n)*?        type: boolean\n")
        self.assertIn("format('cmux-next tip Swift suite · {0}', github.sha)", WORKFLOW)

    def test_it_routes_only_the_whole_swift_suite(self):
        outputs = dict(re.findall(r"echo '(\w+)=([^']*)'", tip_branch()))
        self.assertEqual(outputs.get("swift"), "true")
        self.assertEqual(outputs.get("swift_targets"), "all")
        self.assertEqual(outputs.get("swift_filter"), "")
        # macos lets the Mac placement run; every other tier stays off.
        self.assertEqual(outputs.get("macos"), "true")
        for tier in ("native", "scheme", "generated", "daemon", "full", "swift_canary", "cmuxnext_swift"):
            self.assertEqual(outputs.get(tier), "false", tier)

    def test_it_runs_only_on_feat_cmux_next(self):
        self.assertIn('[[ "$GITHUB_REF" == refs/heads/feat-cmux-next ]]', tip_branch())

    def test_swift_test_is_not_skipped_for_it(self):
        condition = re.search(r"^    if: (.*)$", job("swift-test"), re.MULTILINE).group(1)
        self.assertNotIn("tip_swift_suite", condition)
        self.assertIn("github.event_name == 'push' && github.ref == 'refs/heads/feat-cmux-next'", condition)

    def test_a_tip_run_is_never_cancelled_by_another_dispatch(self):
        group = re.search(r"^concurrency:\n(?:  #.*\n)*  group: (.*)$", WORKFLOW, re.MULTILINE).group(1)
        # Dispatches on feat-cmux-next get a group of their own run id.
        self.assertIn("github.ref != 'refs/heads/feat-cmux-next'", group)


def tip_daemon_branch() -> str:
    route = job("path_route")
    match = re.search(r'elif \[\[ "\$EVENT_NAME" == workflow_dispatch && "\$TIP_DAEMON_SUITE" == true \]\]; then\n(.*?)\n          else\n',
                      route, re.DOTALL)
    assert match, "path_route has no tip_daemon_suite branch"
    return match.group(1)


class TipDaemonSuite(unittest.TestCase):
    """A feat-cmux-next push never runs daemon-test, so main's tip suite dispatcher asks for a
    tip_daemon_suite run: the base daemon-test verdict base_red_excuse.py compares with (#27692)."""

    def test_the_dispatch_input_exists_and_names_the_tested_commit(self):
        self.assertRegex(WORKFLOW, r"\n      tip_daemon_suite:\n(?:        .*\n)*?        type: boolean\n")
        # A same-tree run tests inputs.same_tree_sha while github.sha is the tip by then.
        self.assertIn("format('cmux-next tip daemon suite · {0}', inputs.same_tree_sha || github.sha)", WORKFLOW)

    def test_it_routes_only_the_daemon_tier(self):
        outputs = dict(re.findall(r"echo '(\w+)=([^']*)'", tip_daemon_branch()))
        self.assertEqual(outputs.get("daemon"), "true")
        self.assertEqual(outputs.get("macos"), "true")
        for tier in ("native", "scheme", "generated", "swift", "full", "swift_canary", "cmuxnext_swift"):
            self.assertEqual(outputs.get(tier), "false", tier)
        self.assertIn('[[ "$GITHUB_REF" == refs/heads/feat-cmux-next ]]', tip_daemon_branch())

    def test_its_tree_wait_marker_is_a_tip_suite(self):
        route = job("path_route")
        self.assertIn("TIP_DAEMON_SUITE: ${{ inputs.tip_daemon_suite || false }}", route)
        self.assertIn('marker.update(tip_suite="daemon")', route)

    def test_daemon_test_runs_for_a_dispatch_and_its_same_tree_run(self):
        condition = re.search(r"^    if: (.*)$", job("daemon-test"), re.MULTILINE).group(1)
        # Only a push's same-tree run is skipped; the tip suite's is origin dispatch.
        self.assertIn("inputs.same_tree_origin != 'push'", condition)
        self.assertNotIn("tip_daemon_suite", condition)


if __name__ == "__main__":
    unittest.main()
