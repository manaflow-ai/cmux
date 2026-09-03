#!/usr/bin/env python3
"""Behavior tests for scripts/reconcile-entitlements-with-profile.py.

A release signed before the Apple portal grants the Cloud tunnel capability must
still launch: the tunnel entitlements are dropped from the effective plist and
the summary says so. Once the profile grants them, they pass through untouched.
"""
import json
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "reconcile-entitlements-with-profile.py"

DESIRED = {
    "com.apple.application-identifier": "7WLXT3NR37.com.cmuxterm.app",
    "com.apple.developer.team-identifier": "7WLXT3NR37",
    "keychain-access-groups": ["7WLXT3NR37.com.cmuxterm.app"],
    "com.apple.developer.web-browser.public-key-credential": True,
    "com.apple.developer.networking.networkextension": ["packet-tunnel-provider-systemextension"],
    "com.apple.developer.system-extension.install": True,
    "com.apple.security.application-groups": ["7WLXT3NR37.com.cmuxterm.app"],
    "com.apple.security.cs.allow-jit": True,
}

PROFILE_WITHOUT_TUNNEL = {
    "Entitlements": {
        "com.apple.application-identifier": "7WLXT3NR37.com.cmuxterm.app",
        "com.apple.developer.team-identifier": "7WLXT3NR37",
        "keychain-access-groups": ["7WLXT3NR37.*"],
        "com.apple.developer.web-browser.public-key-credential": True,
    },
    "ProvisionsAllDevices": True,
}

PROFILE_WITH_TUNNEL = {
    "Entitlements": {
        **PROFILE_WITHOUT_TUNNEL["Entitlements"],
        "com.apple.developer.networking.networkextension": [
            "packet-tunnel-provider-systemextension",
            "app-proxy-provider-systemextension",
        ],
        "com.apple.developer.system-extension.install": True,
        "com.apple.security.application-groups": ["7WLXT3NR37.com.cmuxterm.app"],
    },
    "ProvisionsAllDevices": True,
}


def run(entitlements, profile=None, no_profile=False):
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        desired = tmp_path / "desired.plist"
        output = tmp_path / "effective.plist"
        with desired.open("wb") as handle:
            plistlib.dump(entitlements, handle)
        cmd = [sys.executable, str(SCRIPT), "--entitlements", str(desired), "--output", str(output), "--json"]
        if no_profile:
            cmd.append("--no-profile")
        else:
            profile_path = tmp_path / "embedded.provisionprofile"
            with profile_path.open("wb") as handle:
                plistlib.dump(profile, handle)
            cmd += ["--profile", str(profile_path)]
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
        effective = plistlib.load(output.open("rb")) if output.exists() else None
        return proc, effective


class ReconcileEntitlementsTests(unittest.TestCase):
    def test_profile_without_tunnel_drops_only_the_tunnel_feature_set(self):
        proc, effective = run(DESIRED, PROFILE_WITHOUT_TUNNEL)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        summary = json.loads(proc.stdout)
        self.assertFalse(summary["tunnel_supported"])
        self.assertEqual(
            sorted(summary["dropped"]),
            sorted([
                "com.apple.developer.networking.networkextension",
                "com.apple.developer.system-extension.install",
                "com.apple.security.application-groups",
            ]),
        )
        self.assertNotIn("com.apple.developer.networking.networkextension", effective)
        self.assertNotIn("com.apple.developer.system-extension.install", effective)
        self.assertNotIn("com.apple.security.application-groups", effective)
        # Everything unrelated to the tunnel is byte-for-byte the desired state.
        for key in ("com.apple.application-identifier", "keychain-access-groups",
                    "com.apple.developer.web-browser.public-key-credential", "com.apple.security.cs.allow-jit"):
            self.assertEqual(effective[key], DESIRED[key])
        self.assertIn("::warning::", proc.stderr)
        self.assertEqual(summary["profile_app_id"], "7WLXT3NR37.com.cmuxterm.app")

    def test_profile_with_tunnel_keeps_everything(self):
        proc, effective = run(DESIRED, PROFILE_WITH_TUNNEL)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        summary = json.loads(proc.stdout)
        self.assertTrue(summary["tunnel_supported"])
        self.assertEqual(summary["dropped"], [])
        self.assertEqual(effective, DESIRED)
        self.assertNotIn("::warning::", proc.stderr)

    def test_network_extension_without_install_entitlement_is_not_supported(self):
        profile = {"Entitlements": {**PROFILE_WITH_TUNNEL["Entitlements"]}}
        del profile["Entitlements"]["com.apple.developer.system-extension.install"]
        proc, effective = run(DESIRED, profile)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse(json.loads(proc.stdout)["tunnel_supported"])
        self.assertNotIn("com.apple.developer.networking.networkextension", effective)

    def test_app_extension_flavor_does_not_count(self):
        profile = {"Entitlements": {**PROFILE_WITH_TUNNEL["Entitlements"],
                                    "com.apple.developer.networking.networkextension": ["packet-tunnel-provider"]}}
        proc, _ = run(DESIRED, profile)
        self.assertFalse(json.loads(proc.stdout)["tunnel_supported"])

    def test_no_profile_drops_the_tunnel_feature_set(self):
        proc, effective = run(DESIRED, no_profile=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        summary = json.loads(proc.stdout)
        self.assertFalse(summary["tunnel_supported"])
        self.assertNotIn("com.apple.developer.networking.networkextension", effective)
        self.assertIsNone(summary["profile_app_id"])

    def test_entitlements_without_tunnel_are_untouched(self):
        plain = {k: v for k, v in DESIRED.items() if k not in (
            "com.apple.developer.networking.networkextension",
            "com.apple.developer.system-extension.install",
            "com.apple.security.application-groups",
        )}
        proc, effective = run(plain, PROFILE_WITHOUT_TUNNEL)
        summary = json.loads(proc.stdout)
        self.assertFalse(summary["tunnel_requested"])
        self.assertEqual(summary["dropped"], [])
        self.assertEqual(effective, plain)

    def test_missing_restricted_entitlement_is_reported_not_dropped(self):
        profile = {"Entitlements": {k: v for k, v in PROFILE_WITH_TUNNEL["Entitlements"].items()
                                    if k != "com.apple.developer.web-browser.public-key-credential"}}
        proc, effective = run(DESIRED, profile)
        summary = json.loads(proc.stdout)
        self.assertEqual(summary["missing_restricted"], ["com.apple.developer.web-browser.public-key-credential"])
        self.assertIn("com.apple.developer.web-browser.public-key-credential", effective)

    def test_repo_entitlement_files_request_the_tunnel(self):
        for name in ("cmux.release.entitlements", "cmux.nightly.entitlements"):
            desired = plistlib.load((ROOT / name).open("rb"))
            proc, effective = run(desired, PROFILE_WITHOUT_TUNNEL)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertTrue(json.loads(proc.stdout)["tunnel_requested"], name)
            self.assertNotIn("com.apple.developer.networking.networkextension", effective, name)


if __name__ == "__main__":
    unittest.main()
