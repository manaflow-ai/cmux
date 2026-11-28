#!/usr/bin/env python3
"""The PR router skips pr-pipeline.yml's ios fast verdict runner where its plan would answer run=false
(pr_router.py ios_fast_skip).

Leo, 2026-11-28: "de facto, im asking for 99% fewer minutes of ci time, period." The runner took a Linux runner on
every pipeline only to read the diff; the router already has the diff. A head that reaches an iOS target, an
unknown diff, an error, or vars.CI_IOS_FAST_ROUTER_SKIP=0 still starts it.
"""
from __future__ import annotations

import os
import re
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import ios_fast_verdict  # noqa: E402
import pr_router  # noqa: E402

DOC = "docs/handbook/README.md"
KIT_SOURCE = "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileKit/Thing.swift"


class IosFastSkip(unittest.TestCase):
    def setUp(self):
        env = mock.patch.dict(os.environ, {}, clear=False)
        env.start()
        self.addCleanup(env.stop)
        os.environ.pop("CI_IOS_FAST_ROUTER_SKIP", None)

    def test_a_head_that_reaches_no_ios_target_skips(self):
        with mock.patch.object(ios_fast_verdict, "affects", return_value=False):
            skip, why = pr_router.ios_fast_skip([DOC])
        self.assertTrue(skip, why)

    def test_a_head_that_reaches_an_ios_target_plans(self):
        with mock.patch.object(ios_fast_verdict, "affects", return_value=True):
            self.assertFalse(pr_router.ios_fast_skip([KIT_SOURCE])[0])

    def test_the_real_check_agrees_with_the_plan_on_plain_paths(self):
        for paths in ([DOC], [KIT_SOURCE], [DOC, KIT_SOURCE]):
            plan = ios_fast_verdict.plan(paths)
            self.assertEqual(pr_router.ios_fast_skip(paths)[0], not plan["run"], paths)

    def test_unknown_or_empty_diff_plans(self):
        self.assertFalse(pr_router.ios_fast_skip(None)[0])
        self.assertFalse(pr_router.ios_fast_skip([])[0])

    def test_the_switch_turns_it_off(self):
        os.environ["CI_IOS_FAST_ROUTER_SKIP"] = "0"
        with mock.patch.object(ios_fast_verdict, "affects", return_value=False):
            self.assertFalse(pr_router.ios_fast_skip([DOC])[0])

    def test_an_error_plans(self):
        with mock.patch.object(ios_fast_verdict, "affects", side_effect=RuntimeError("boom")):
            self.assertFalse(pr_router.ios_fast_skip([DOC])[0])

    def test_a_rust_file_marked_at_the_base_plans(self):
        rust = "cmux-next/crates/x/src/lib.rs"
        with mock.patch.object(ios_fast_verdict, "affects", return_value=False), \
                mock.patch.object(ios_fast_verdict, "rust_inner", return_value=True), \
                mock.patch.object(ios_fast_verdict, "routes_ios", return_value=True), \
                mock.patch.object(ios_fast_verdict, "base_marked_paths", return_value={rust}):
            self.assertFalse(pr_router.ios_fast_skip([rust])[0])


class Wiring(unittest.TestCase):
    def test_the_runner_reads_the_input_and_the_router_passes_it(self):
        pipeline = (ROOT / ".github/workflows/pr-pipeline.yml").read_text()
        router = (ROOT / ".github/workflows/pr-router.yml").read_text()
        runner_if = re.search(r"ios-fast-runner:\n(?:.*\n)*?    if: (.*)", pipeline).group(1)
        self.assertIn("!inputs.ios_fast_skip", runner_if)
        self.assertIn("ios_fast_skip: ${{ needs.route.outputs.ios_fast_skip == 'true' }}", router)
        self.assertIn("ios_fast_skip: ${{ steps.route.outputs.ios_fast_skip }}", router)
        self.assertIn("CI_IOS_FAST_ROUTER_SKIP: ${{ vars.CI_IOS_FAST_ROUTER_SKIP || '1' }}", router)


if __name__ == "__main__":
    unittest.main()
