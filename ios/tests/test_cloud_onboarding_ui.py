#!/usr/bin/env python3
"""Regression coverage for the App Store Cloud onboarding surface."""

from __future__ import annotations

import unittest
from pathlib import Path


SOURCE = (
    Path(__file__).resolve().parents[2]
    / "Packages/iOS/CmuxMobileCloudUI/Sources/CmuxMobileCloudUI/CloudOnboardingView.swift"
).read_text()


class CloudOnboardingUITests(unittest.TestCase):
    def test_system_vpn_page_is_conditional_and_page_count_matches(self):
        self.assertIn("private var pageCount: Int", SOURCE)
        self.assertIn("systemVPN == nil ? 2 : 3", SOURCE)

        vpn_start = SOURCE.index("if let systemVPN")
        vpn_end = SOURCE.index(".tag(1)", vpn_start)
        vpn_page = SOURCE[vpn_start:vpn_end]
        self.assertIn('defaultValue: "System VPN"', vpn_page)
        self.assertIn("topic: .vpn", vpn_page)
        self.assertIn("CloudOnboardingVPNControl(controller: systemVPN)", vpn_page)

        key_start = SOURCE.index("CloudOnboardingPage(", vpn_end)
        key_page = SOURCE[key_start:SOURCE.index(".tag(systemVPN == nil ? 1 : 2)", key_start)]
        self.assertIn("mobile.cloud.onboarding.key.title", key_page)
        self.assertNotIn("topic: .vpn", key_page)

    def test_onboarding_uses_contiguous_tags_for_both_build_variants(self):
        self.assertIn(".tag(0)", SOURCE)
        self.assertIn(".tag(1)", SOURCE)
        self.assertIn(".tag(systemVPN == nil ? 1 : 2)", SOURCE)

        self.assertIn("primaryTitle: page < pageCount - 1", SOURCE)
        primary_action_start = SOURCE.index("onPrimary:")
        primary_action_end = SOURCE.index("onSecondary:", primary_action_start)
        self.assertIn(
            "if page < pageCount - 1",
            SOURCE[primary_action_start:primary_action_end],
        )


if __name__ == "__main__":
    unittest.main()
