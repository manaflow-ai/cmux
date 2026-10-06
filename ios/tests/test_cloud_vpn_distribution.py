#!/usr/bin/env python3
"""Exercise both public iOS exports with fake Apple signing tools."""

from __future__ import annotations

import plistlib
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests"))
import test_ios_appstore_lane_identity as fixtures


class CloudVPNDistributionTests(unittest.TestCase):
    def export(self, lane, overrides=None):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        path = Path(temp.name)
        fakebin = path / "bin"
        fixtures._install_fake_tools(fakebin)
        env = fixtures._base_env(path, fakebin)
        env.update({
            "CMUX_IOS_UPLOAD_DIR": str(path / "upload"),
            "CMUX_FAKE_INCLUDE_NOTIFICATION_EXTENSION": "1" if lane == "beta" else "0",
        })
        env.update(overrides or {})
        result = fixtures._run([
            "bash", str(ROOT / "ios/scripts/upload-testflight.sh"),
            "--lane", lane, "--signing", "manual", "--export-only",
            "--build-number", "20261006000100",
        ], env=env, tmp=path, log_failure=False)
        return path, result

    def test_both_exports_share_host_keychain_and_packet_tunnel(self):
        for lane, host in (("appstore", "com.cmux.app"), ("beta", "dev.cmux.app.beta")):
            with self.subTest(lane=lane):
                path, result = self.export(lane)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                options = plistlib.loads((path / "ExportOptions.plist").read_bytes())
                self.assertIn(host + ".CloudVPN", options["provisioningProfiles"])
                ipa = next((path / "upload/export").glob("*-resigned.ipa"))
                with zipfile.ZipFile(ipa) as archive:
                    for component in ("", "PlugIns/CloudVPN.appex/"):
                        ent = plistlib.loads(archive.read(
                            "Payload/cmux.app/" + component + "FakeSignedEntitlements.plist"
                        ))
                        self.assertEqual(ent["keychain-access-groups"], [fixtures.TEAM_ID + "." + host])
                        self.assertIn("packet-tunnel-provider", ent["com.apple.developer.networking.networkextension"])

    def test_both_exports_reject_empty_signed_vpn_group(self):
        self.assert_rejected("CMUX_FAKE_VPN_EMPTY_SIGNED_GROUP", "keychain")

    def test_both_exports_reject_unauthorized_profile_group(self):
        self.assert_rejected("CMUX_FAKE_VPN_UNAUTHORIZED_GROUP", "keychain")

    def test_both_exports_reject_host_without_packet_tunnel(self):
        self.assert_rejected("CMUX_FAKE_HOST_MISSING_PACKET_TUNNEL", "packet-tunnel")

    def assert_rejected(self, override, diagnostic):
        for lane in ("appstore", "beta"):
            with self.subTest(lane=lane):
                _, result = self.export(lane, {override: "1"})
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(diagnostic, result.stderr.lower())


if __name__ == "__main__":
    unittest.main()
