#!/usr/bin/env python3
"""Regression tests for App Store Connect main-app entitlements."""

from __future__ import annotations

import importlib.util
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
FILTER_SCRIPT = REPO_ROOT / "ios/scripts/filter-ios-appstore-entitlements.py"
UPLOAD_SCRIPT = REPO_ROOT / "ios/scripts/upload-testflight.sh"


def load_filter_module():
    spec = importlib.util.spec_from_file_location("appstore_entitlements", FILTER_SCRIPT)
    if spec is None or spec.loader is None:
        raise AssertionError(f"could not load {FILTER_SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class AppStoreEntitlementTests(unittest.TestCase):
    def test_app_store_export_resigns_cloud_vpn_from_packet_tunnel_profile(self):
        script = UPLOAD_SCRIPT.read_text()

        self.assertIn("resign_cloud_vpn_extension()", script)
        function_start = script.index("resign_cloud_vpn_extension()")
        function_end = script.index("\n}\n\nverify_ipa_bundle_identity", function_start)
        function = script[function_start:function_end]
        self.assertIn('security cms -D -i "$extension/embedded.mobileprovision"', function)
        self.assertIn('packet-tunnel-provider', function)
        self.assertIn('codesign --force --sign "$identity" --entitlements "$merged_entitlements"', function)

        call = script.index('resign_cloud_vpn_extension \\\n', function_end)
        self.assertIn('if [[ "$LANE" == "appstore" ]]', script[call - 80:call])
        host_resign = script.index('codesign --force --sign "$RESIGN_IDENTITY" --entitlements "$MERGED_ENTITLEMENTS"', call)
        self.assertLess(call, host_resign)

    def test_profile_only_network_capabilities_are_removed(self):
        module = load_filter_module()
        source = {
            "application-identifier": "7WLXT3NR37.com.cmux.app",
            "aps-environment": "production",
            "com.apple.developer.applesignin": ["Default"],
            "com.apple.developer.networking.networkextension": [
                "packet-tunnel-provider",
                "hotspot-provider",
            ],
            "com.apple.developer.networking.vpn.api": ["allow-vpn"],
            "com.apple.developer.usernotifications.time-sensitive": True,
            "keychain-access-groups": ["7WLXT3NR37.com.cmux.app"],
        }

        filtered, removed = module.filter_app_store_entitlements(source)

        self.assertEqual(
            removed,
            [
                "com.apple.developer.networking.networkextension[hotspot-provider]",
            ],
        )
        self.assertEqual(
            filtered["com.apple.developer.networking.networkextension"],
            ["packet-tunnel-provider"],
        )
        self.assertEqual(filtered["com.apple.developer.networking.vpn.api"], ["allow-vpn"])
        self.assertEqual(filtered["aps-environment"], "production")
        self.assertEqual(filtered["keychain-access-groups"], ["7WLXT3NR37.com.cmux.app"])

    def test_filter_cli_rewrites_a_profile_baseline(self):
        source = {
            "com.apple.developer.networking.networkextension": [
                "packet-tunnel-provider",
                "hotspot-provider",
            ],
            "com.apple.developer.networking.vpn.api": ["allow-vpn"],
            "aps-environment": "production",
        }
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "entitlements.plist"
            path.write_bytes(plistlib.dumps(source))

            result = subprocess.run(
                [sys.executable, str(FILTER_SCRIPT), str(path)],
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            filtered = plistlib.loads(path.read_bytes())
            self.assertEqual(
                filtered["com.apple.developer.networking.networkextension"],
                ["packet-tunnel-provider"],
            )
            self.assertEqual(filtered["com.apple.developer.networking.vpn.api"], ["allow-vpn"])
            self.assertIn("removed unsupported iOS main-app entitlement", result.stderr)


if __name__ == "__main__":
    unittest.main()
