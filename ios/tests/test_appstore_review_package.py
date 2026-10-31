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
        project = PROJECT_FILE.read_text()
        self.assertRegex(
            project,
            r"/\* PrivacyInfo\.xcprivacy \*/ = \{isa = PBXFileReference; [^}]*path = PrivacyInfo\.xcprivacy;",
        )
        resources_phase = project[project.index("/* Begin PBXResourcesBuildPhase section */"):]
        self.assertIn("PrivacyInfo.xcprivacy in Resources", resources_phase)

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


    def test_storekit_purchases_are_declared(self):
        types = collected_types()
        self.assertIn("PurchaseHistory", types)
        self.assertTrue(types["PurchaseHistory"]["NSPrivacyCollectedDataTypeLinked"])

    def test_required_reason_apis_used_by_linked_packages_are_declared(self):
        manifest = plistlib.loads(PRIVACY_MANIFEST.read_bytes())
        prefix = "NSPrivacyAccessedAPICategory"
        declared = {
            entry["NSPrivacyAccessedAPIType"].removeprefix(prefix): set(entry["NSPrivacyAccessedAPITypeReasons"])
            for entry in manifest["NSPrivacyAccessedAPITypes"]
        }
        # ProcessInfo.systemUptime / mach_absolute_time for in-app timings.
        self.assertIn("35F9.1", declared.get("SystemBootTime", set()))
        # UITextInputMode.activeInputModes picks the emoji keyboard.
        self.assertIn("54BD.1", declared.get("ActiveKeyboards", set()))
        # Chat caches evict app-container files by modification date.
        self.assertIn("C617.1", declared.get("FileTimestamp", set()))
        self.assertIn("CA92.1", declared.get("UserDefaults", set()))


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
