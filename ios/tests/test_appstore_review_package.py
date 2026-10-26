#!/usr/bin/env python3
"""Regression tests for the App Store privacy manifest and public metadata."""

from __future__ import annotations

import json
import plistlib
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
APP_SOURCE = REPO_ROOT / "ios/cmux"
PRIVACY_MANIFEST = APP_SOURCE / "PrivacyInfo.xcprivacy"
PROJECT_FILE = REPO_ROOT / "ios/cmux-ios.xcodeproj/project.pbxproj"
APP_PACKAGE = REPO_ROOT / "ios/cmuxPackage/Package.swift"
METADATA_DIR = REPO_ROOT / "ios/AppStoreReview/metadata"


def collected_types() -> dict[str, dict]:
    manifest = plistlib.loads(PRIVACY_MANIFEST.read_bytes())
    prefix = "NSPrivacyCollectedDataType"
    return {
        entry[prefix].removeprefix(prefix): entry
        for entry in manifest["NSPrivacyCollectedDataTypes"]
    }


class PrivacyManifestTests(unittest.TestCase):
    def test_app_target_bundles_the_only_manifest(self):
        manifests = sorted(APP_SOURCE.rglob("PrivacyInfo.xcprivacy"))
        self.assertEqual(manifests, [PRIVACY_MANIFEST])
        self.assertIn("PrivacyInfo.xcprivacy in Resources", PROJECT_FILE.read_text())

    def test_manifest_declares_no_tracking(self):
        manifest = plistlib.loads(PRIVACY_MANIFEST.read_bytes())
        self.assertFalse(manifest["NSPrivacyTracking"])
        self.assertEqual(manifest["NSPrivacyTrackingDomains"], [])
        for name, entry in collected_types().items():
            self.assertFalse(entry["NSPrivacyCollectedDataTypeTracking"], name)

    def test_manifest_declares_account_identity(self):
        types = collected_types()
        for name in ("UserID", "EmailAddress", "DeviceID", "ProductInteraction"):
            self.assertIn(name, types)
            self.assertTrue(types[name]["NSPrivacyCollectedDataTypeLinked"], name)

    def test_linked_crash_reporter_is_declared(self):
        if '"CmuxMobileCrashReporting"' not in APP_PACKAGE.read_text():
            self.skipTest("crash reporter is not linked into the app package")
        types = collected_types()
        for name in ("CrashData", "PerformanceData", "OtherDiagnosticData"):
            self.assertIn(name, types)
            self.assertFalse(types[name]["NSPrivacyCollectedDataTypeLinked"], name)


class PublicMetadataTests(unittest.TestCase):
    REVIEW_ONLY_PHRASES = (
        "App Review",
        "demo account",
        "Review Information",
        "app-review-ok",
        "Tailscale Only",
    )

    def test_public_metadata_has_no_review_instructions(self):
        for path in sorted(METADATA_DIR.rglob("*.json")):
            text = " ".join(
                value for value in json.loads(path.read_text()).values() if isinstance(value, str)
            )
            for phrase in self.REVIEW_ONLY_PHRASES:
                self.assertNotIn(phrase.lower(), text.lower(), f"{path}: {phrase}")


if __name__ == "__main__":
    unittest.main()
