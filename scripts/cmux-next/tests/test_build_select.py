#!/usr/bin/env python3
"""build_select.py: the cheapest build per app (Mac, iPhone) for a change.

Runs on any host (Linux included): no app, no fleet.

    python3 -m unittest scripts/cmux-next/tests/test_build_select.py
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import build_select  # noqa: E402
import live_apply  # noqa: E402

ROOT = Path(__file__).resolve().parents[3]
KIT = "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileFeed/FeedView.swift"
HOST = "cmux-next-ios/rust/crates/cmux-mobile-host/src/pairing.rs"
VIEW = "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Home/HomeHostView.swift"


class SelectTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bundled = build_select.bundled_inputs(ROOT)
        cls.ios = staticmethod(build_select.ios_filter(ROOT))

    def pick(self, files, diffs=None):
        result = live_apply.classify([("M", p) for p in files], diffs or {})
        return build_select.select(result, list(files), self.bundled, self.ios)

    def test_an_iphone_only_change_needs_no_mac_build(self):
        # #53007 (iOS Feed: remove the Working now strip): 7 CmuxMobileKit files, and a full Mac build queued.
        out = self.pick([KIT])
        self.assertEqual((out["mac"], out["ios"]), ("none", "build"))

    def test_the_iphone_link_crates_are_a_mac_change_too(self):
        # cmux-mobile-host, which the Mac app bundles, builds from cmux-next-ios/rust (build-mobile-host.sh), so
        # live_apply's ios-only is not the Mac's answer here (#53160, #53163).
        self.assertIn("cmux-next-ios/rust", self.bundled)
        out = self.pick([HOST])
        self.assertEqual((out["mac"], out["ios"]), ("build", "build"))
        self.assertIn("bundled by the Mac app", out["why"]["mac"])

    def test_review_tools_and_the_mobile_worker_build_neither_app(self):
        # #52875, #53102, #53165, #53213: review.sh only, each queued an iPhone try build-ahead.
        for path in ("cmux-next-ios/scripts/review.sh", "cmux-next-ios/scripts/review_mac.py",
                     "cmux-next-ios/backend/src/relay.ts", "docs/cmux-next/x.md", "ios/tests/test_cnx_review.py"):
            with self.subTest(path=path):
                out = self.pick([path])
                self.assertEqual((out["mac"], out["ios"]), ("none", "none"))

    def test_scripts_the_iphone_build_reads_still_build_it(self):
        for path in ("cmux-next-ios/scripts/check-notification-extension.sh",
                     "cmux-next-ios/scripts/generate-launch-mark.swift"):
            with self.subTest(path=path):
                self.assertTrue(self.ios(path))

    def test_web_and_daemon_swap_into_a_copy_of_the_nightly(self):
        for path in ("webviews/src/settings/Page.tsx", "cmux-tui/crates/cmux-tui/src/cli/setup.rs"):
            with self.subTest(path=path):
                self.assertEqual(self.pick([path])["mac"], "swap")

    def test_swift_and_manifests_build_the_mac_app(self):
        diffs = {VIEW: [("+", "    let added: Int")]}
        self.assertEqual(self.pick([VIEW], diffs)["mac"], "build")
        self.assertEqual(self.pick(["cmux.xcodeproj/project.pbxproj"])["mac"], "build")


class PathFilterTests(unittest.TestCase):
    def test_last_match_decides(self):
        match = build_select.path_filter(["a/**", "!**/*.md", "!a/x/**", "a/x/keep.py"])
        self.assertTrue(match("a/b/c.swift"))
        self.assertFalse(match("a/b/README.md"))
        self.assertFalse(match("a/x/y.py"))
        self.assertTrue(match("a/x/keep.py"))
        self.assertFalse(match("b/c.swift"))

    def test_star_stays_in_one_folder(self):
        match = build_select.path_filter(["a/*.yml"])
        self.assertTrue(match("a/b.yml"))
        self.assertFalse(match("a/c/b.yml"))


if __name__ == "__main__":
    unittest.main()
