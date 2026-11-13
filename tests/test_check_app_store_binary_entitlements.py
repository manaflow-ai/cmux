#!/usr/bin/env python3
"""Tests for ios/scripts/check_app_store_binary_entitlements.py (static, no build)."""

from __future__ import annotations

import importlib.util
import plistlib
import shutil
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "ios/scripts/check_app_store_binary_entitlements.py"


def load():
    spec = importlib.util.spec_from_file_location("check_app_store_binary_entitlements", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


M = load()


class FixtureCase(unittest.TestCase):
    """Copies the files the check reads into a scratch ios/ and mutates them."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.ios = Path(self._tmp.name) / "ios"
        for rel in ("Config", "cmux-ios.xcodeproj/project.pbxproj", "scripts/upload-testflight.sh"):
            src = ROOT / "ios" / rel
            dst = self.ios / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            if src.is_dir():
                shutil.copytree(src, dst)
            else:
                shutil.copy2(src, dst)

    def tearDown(self):
        self._tmp.cleanup()

    def edit(self, rel: str, old: str, new: str):
        path = self.ios / rel
        text = path.read_text()
        self.assertIn(old, text, f"fixture drifted: {old!r} not in {rel}")
        path.write_text(text.replace(old, new, 1))

    def add_entitlement(self, rel: str, key: str, value):
        path = self.ios / rel
        body = plistlib.loads(path.read_bytes())
        body[key] = value
        path.write_bytes(plistlib.dumps(body))

    def problems(self):
        return M.check(self.ios)


class RepositoryTests(unittest.TestCase):
    def test_checked_in_app_store_build_is_vpn_free(self):
        self.assertEqual(M.check(), [])

    def test_project_parser_finds_the_embedded_extensions(self):
        project = M.parse_pbxproj(M.PROJECT.read_text())
        extensions = {e.product: e for e in M.embedded_extensions(project, M.IOS_DIR)}
        self.assertEqual(extensions["CloudVPN.appex"].entitlements, "Config/CloudVPN.entitlements")
        self.assertEqual(
            extensions["NotificationService.appex"].entitlements, "Config/NotificationService.entitlements"
        )


class MutationTests(FixtureCase):
    def test_unmodified_fixture_passes(self):
        self.assertEqual(self.problems(), [])

    def test_network_extension_in_app_store_host_fails(self):
        self.add_entitlement(
            "Config/cmux-appstore-release.entitlements", M.NETWORK_EXTENSION_KEY, ["packet-tunnel-provider"]
        )
        problems = self.problems()
        self.assertEqual(len(problems), 1)
        self.assertIn("cmux-appstore-release.entitlements carries VPN entitlements", problems[0])

    def test_personal_vpn_in_app_store_host_fails(self):
        self.add_entitlement("Config/cmux-appstore-release.entitlements", M.PERSONAL_VPN_KEY, ["allow-vpn"])
        self.assertTrue(any("carries VPN entitlements" in p for p in self.problems()))

    def test_vpn_entitlement_in_an_unstripped_extension_fails(self):
        self.add_entitlement(
            "Config/NotificationService.entitlements", M.NETWORK_EXTENSION_KEY, ["packet-tunnel-provider"]
        )
        problems = self.problems()
        self.assertTrue(any("NotificationService.appex" in p and "does not strip it" in p for p in problems), problems)

    def test_app_store_archive_that_keeps_cloud_vpn_fails(self):
        self.edit(
            "scripts/upload-testflight.sh",
            'rm -rf "$ARCHIVE_APP/PlugIns/CloudVPN.appex"',
            'echo keep "$ARCHIVE_APP/PlugIns/CloudVPN.appex"',
        )
        self.assertTrue(any("CloudVPN.appex" in p and "does not strip it" in p for p in self.problems()))

    def test_ipa_check_that_stops_rejecting_cloud_vpn_fails(self):
        self.edit(
            "scripts/upload-testflight.sh",
            '"${CLOUD_VPN_REQUIRED:-0}" -eq 0 && -d "$app/PlugIns/CloudVPN.appex"',
            '"${CLOUD_VPN_REQUIRED:-0}" -eq 0 && -d "$app/PlugIns/Other.appex"',
        )
        self.assertTrue(any("no longer rejects an embedded CloudVPN.appex" in p for p in self.problems()))

    def test_app_store_host_signed_with_beta_entitlements_fails(self):
        self.edit(
            "scripts/upload-testflight.sh",
            "    CODE_SIGN_ENTITLEMENTS=Config/cmux-appstore-release.entitlements\n",
            "    CODE_SIGN_ENTITLEMENTS=Config/cmux-release.entitlements\n",
        )
        self.assertTrue(any("CODE_SIGN_ENTITLEMENTS=" in p for p in self.problems()))

    def test_vpn_turned_on_outside_the_beta_lane_fails(self):
        self.edit(
            "scripts/upload-testflight.sh",
            'APPSTORE_SYSTEM_VPN_DISABLED=0\n',
            'APPSTORE_SYSTEM_VPN_DISABLED=0\nif [[ -n "${IOS_APPSTORE_ENABLE_CLOUD_VPN:-}" ]]; then\n  CLOUD_VPN_REQUIRED=1\nfi\n',
        )
        self.assertTrue(any("outside the beta-lane guard" in p for p in self.problems()))

    def test_provider_declaration_kept_fails(self):
        self.edit(
            "scripts/upload-testflight.sh",
            "Delete :CMUXCloudVPNProviderBundleIdentifier",
            "Print :CMUXCloudVPNProviderBundleIdentifier",
        )
        self.assertTrue(any("CMUXCloudVPNProviderBundleIdentifier" in p for p in self.problems()))


class EntitlementRuleTests(unittest.TestCase):
    def test_vpn_entitlements(self):
        self.assertEqual(M.vpn_entitlements({"aps-environment": "production"}), [])
        self.assertTrue(M.vpn_entitlements({M.NETWORK_EXTENSION_KEY: ["app-proxy-provider"]}))
        self.assertTrue(M.vpn_entitlements({M.PERSONAL_VPN_KEY: ["allow-vpn"]}))


if __name__ == "__main__":
    unittest.main()
