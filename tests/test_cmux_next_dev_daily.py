#!/usr/bin/env python3
"""Portable contract checks for the cmux NEXT DEV daily channel."""
from __future__ import annotations

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
CMUX_NEXT = ROOT / ".github/workflows/cmux-next.yml"
PUBLISHER = ROOT / ".github/workflows/cmux-next-dev-daily.yml"
UPDATER = ROOT / "scripts/cmux-next/update-dev-daily.sh"
ENTITLEMENTS = ROOT / "cmux.next-dev.entitlements"


class DevDailyWorkflowContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = yaml.safe_load(CMUX_NEXT.read_text(encoding="utf-8"))
        cls.publisher = yaml.safe_load(PUBLISHER.read_text(encoding="utf-8"))

    def test_source_run_only_packages_release_artifact_for_current_push(self):
        job = self.source["jobs"]["cmux-scheme-compile"]
        release = next(step for step in job["steps"] if step.get("id") == "compile-cmux-next-dev-release")
        self.assertIn("github.event_name == 'push'", release["if"])
        self.assertIn("refs/heads/feat-cmux-next", release["if"])
        self.assertIn("needs.push-head-preflight.outputs.current == 'true'", release["if"])
        self.assertEqual(release["env"]["CMUX_NEXT_CONFIGURATION"], "Release")
        self.assertEqual(release["env"]["CMUX_NEXT_PRODUCT_NAME"], "cmux NEXT DEV")
        self.assertEqual(release["env"]["CMUX_NEXT_BUNDLE_ID"], "com.cmuxterm.app.debug.next")
        self.assertEqual(release["env"]["CMUX_NEXT_AUTH_CALLBACK_SCHEME"], "cmux-next-dev")
        self.assertEqual(release["env"]["CMUX_NEXT_TUI_MODE"], "tree")

        upload = next(step for step in job["steps"] if step.get("name") == "Upload the cmux NEXT DEV Release app")
        self.assertIn("cmux-next-dev-daily-unsigned-${{ github.sha }}", upload["with"]["name"])
        self.assertEqual(upload["with"]["compression-level"], 0)

    def test_publisher_is_trusted_workflow_run_and_exact_head_gated(self):
        trigger = self.publisher[True]["workflow_run"]
        self.assertEqual(trigger["workflows"], ["cmux-next"])
        self.assertEqual(trigger["types"], ["completed"])
        publish = self.publisher["jobs"]["publish"]
        condition = publish["if"]
        for clause in (
            "github.event.workflow_run.event == 'push'",
            "github.event.workflow_run.conclusion == 'success'",
            "github.event.workflow_run.head_branch == 'feat-cmux-next'",
            "github.event.workflow_run.head_repository.full_name == github.repository",
        ):
            self.assertIn(clause, condition)
        self.assertEqual(publish["environment"], "release")
        self.assertEqual(publish["permissions"]["contents"], "write")

    def test_publisher_has_no_notarization_or_publication_crossing(self):
        text = PUBLISHER.read_text(encoding="utf-8")
        self.assertNotIn("notarytool", text)
        for forbidden in ("notarytool", "notarize-nightly", "scripts/ci/notarize"):
            self.assertNotIn(forbidden, text.lower())
        self.assertNotIn("syspolicy", text)
        self.assertIn("cmux-next-dev-daily-unsigned-${SOURCE_SHA}", text)
        self.assertIn("gh release upload", text)
        self.assertIn("--clobber", text)
        self.assertIn("RELEASE_TAG: cmux-next-dev", text)
        self.assertIn("APP_ARCHIVE_NAME: cmux-NEXT-DEV.zip", text)

    def test_identity_is_stable_and_updater_is_signed_download_only(self):
        entitlements = ENTITLEMENTS.read_text(encoding="utf-8")
        self.assertIn("com.apple.security.cs.allow-jit", entitlements)
        self.assertNotIn("com.apple.application-identifier", entitlements)
        updater = UPDATER.read_text(encoding="utf-8")
        self.assertIn("releases/download", updater)
        self.assertIn("CMUX_NEXT_DEV_TAG", updater)
        self.assertIn("shasum -a 256", updater)
        self.assertIn("codesign --verify --deep --strict", updater)
        self.assertIn("osascript -e 'tell application \"cmux NEXT DEV\" to quit'", updater)
        self.assertIn('exists process "cmux NEXT DEV"', updater)
        for forbidden in ("pkill", "killall", "pgrep"):
            self.assertNotIn(forbidden, updater)


if __name__ == "__main__":
    unittest.main()
