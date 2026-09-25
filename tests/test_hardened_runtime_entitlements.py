#!/usr/bin/env python3
"""Inspect real codesign artifacts without building or launching the app."""
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PREFIX = "com.apple.security.cs."


@unittest.skipUnless(sys.platform == "darwin", "requires macOS codesign")
class SignedEntitlementsTests(unittest.TestCase):
    def test_production_app_signatures_preserve_jit_without_broad_relaxations(self):
        for channel in ("release", "nightly", "rc"):
            with self.subTest(channel=channel), tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                source = ROOT / f"cmux.{channel}.entitlements"
                desired = plistlib.loads(source.read_bytes())
                profile = directory / "profile.plist"
                profile.write_bytes(plistlib.dumps({"Entitlements": desired}))
                effective = directory / "effective.plist"
                subprocess.run([
                    sys.executable, str(ROOT / "scripts/reconcile-entitlements-with-profile.py"),
                    "--entitlements", str(source), "--profile", str(profile),
                    "--output", str(effective), "--json",
                ], check=True, capture_output=True)
                signed = self.sign_and_read(directory, effective)
                self.assertEqual(signed.get(PREFIX + "allow-jit"), True,
                                 "In-process JavaScriptCore must retain JIT compilation")
                self.assertNotIn(PREFIX + "disable-library-validation", signed)
                self.assertNotIn(PREFIX + "allow-unsigned-executable-memory", signed)
                self.assertEqual(signed["com.apple.application-identifier"],
                                 desired["com.apple.application-identifier"])
                self.assertEqual(signed.get("com.apple.developer.web-browser.public-key-credential"),
                                 desired.get("com.apple.developer.web-browser.public-key-credential"))

    def test_helper_signature_has_no_runtime_relaxations_or_application_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            signed = self.sign_and_read(Path(temporary), ROOT / "cmux-helper.entitlements")
            self.assertNotIn("com.apple.application-identifier", signed)
            for key in ("allow-jit", "disable-library-validation", "allow-unsigned-executable-memory"):
                self.assertNotIn(PREFIX + key, signed)

    def sign_and_read(self, directory, entitlements):
        binary = directory / "signed-fixture"
        shutil.copyfile("/usr/bin/true", binary)
        binary.chmod(0o755)
        subprocess.run([
            "/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime",
            "--timestamp=none", "--entitlements", str(entitlements), str(binary),
        ], check=True, capture_output=True)
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(binary)],
                       check=True, capture_output=True)
        details = subprocess.run([
            "/usr/bin/codesign", "--display", "--verbose=4", "--entitlements", ":-",
            "--xml", str(binary),
        ], check=True, capture_output=True)
        self.assertIn(b"runtime", details.stderr)
        return plistlib.loads(details.stdout)


if __name__ == "__main__":
    unittest.main()
