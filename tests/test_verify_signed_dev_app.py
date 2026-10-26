#!/usr/bin/env python3
"""scripts/ci/verify_signed_dev_app.py: the codesign -d checks of a Linux-signed cmux NEXT DEV app.

A fake codesign on PATH answers from per-path fixture data, so each case changes one fact about
a minimal fake .app and expects the check to fail naming it.
"""

from __future__ import annotations

import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/verify_signed_dev_app.py"
MACHO = bytes.fromhex("cffaedfe") + bytes(28)
GOOD_DISPLAY = ("Executable=x\nCodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1\n"
                "Authority=Developer ID Application: Manaflow, Inc. (7WLXT3NR37)\n")
FAKE_CODESIGN = textwrap.dedent("""\
    #!/usr/bin/env python3
    import json, os, plistlib, sys
    data = json.load(open(os.environ["FAKE_CODESIGN_DATA"]))
    entry = data.get(os.path.realpath(sys.argv[-1]), {})
    if "--verify" in sys.argv:
        sys.exit(entry.get("verify", 0))
    if "--entitlements" in sys.argv:
        sys.stdout.buffer.write(plistlib.dumps(entry.get("entitlements", {})))
    elif "-d" in sys.argv or "--display" in sys.argv or any(a.startswith("-dv") for a in sys.argv):
        sys.stderr.write(entry.get("display", ""))
    """)
WANTED = {"com.apple.security.cs.allow-jit": True,
          **{f"com.apple.security.personal-information.{k}": True
             for k in ("addressbook", "calendars", "location", "photos-library")}}


class VerifySignedDevApp(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        (bin_dir / "codesign").write_text(FAKE_CODESIGN)
        (bin_dir / "codesign").chmod(0o755)
        self.app = self.tmp / "cmux NEXT DEV.app"
        tools = self.app / "Contents/Resources/bin"
        tools.mkdir(parents=True)
        (self.app / "Contents/Resources/libexec").mkdir()
        self.cu = self.app / "Contents/Library/cmux Computer Use.app"
        (self.cu / "Contents").mkdir(parents=True)
        for path in (tools / "cmux", self.app / "Contents/Resources/libexec/helper"):
            path.write_bytes(MACHO)
            path.chmod(0o755)
        (tools / "cmux-tui").symlink_to("cmux")
        (tools / "acpmux").symlink_to("cmux")
        (tools / "script.sh").write_text("#!/bin/sh\n")  # not Mach-O: left to the bundle seal
        (tools / "script.sh").chmod(0o755)
        self.entitlements = self.tmp / "app.entitlements"
        self.entitlements.write_bytes(plistlib.dumps(WANTED))
        self.data = {str(p.resolve()): {"display": GOOD_DISPLAY, "entitlements": {}}
                     for p in (tools / "cmux", self.app / "Contents/Resources/libexec/helper", self.cu)}
        self.data[str(self.app.resolve())] = {"display": GOOD_DISPLAY, "entitlements": dict(WANTED)}
        self.env = {**os.environ, "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}", "CODESIGN": "codesign",
                    "FAKE_CODESIGN_DATA": str(self.tmp / "data.json")}

    def entry(self, path: Path) -> dict:
        return self.data[str(path.resolve())]

    def run_check(self) -> subprocess.CompletedProcess:
        (self.tmp / "data.json").write_text(json.dumps(self.data))
        return subprocess.run([sys.executable, str(SCRIPT), str(self.app), str(self.entitlements)],
                              capture_output=True, text=True, env=self.env)

    def assert_fails(self, message: str) -> None:
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stderr)

    def test_a_good_app_passes(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("signature checks OK", result.stdout)

    def test_a_missing_entitlement_fails(self):
        del self.entry(self.app)["entitlements"]["com.apple.security.cs.allow-jit"]
        self.assert_fails("signed app has com.apple.security.cs.allow-jit = None")

    def test_a_disabled_personal_information_entitlement_fails(self):
        self.entry(self.app)["entitlements"]["com.apple.security.personal-information.location"] = False
        self.assert_fails("signed app missing enabled com.apple.security.personal-information.location")

    def test_a_network_extension_entitlement_fails(self):
        self.entry(self.app)["entitlements"]["com.apple.developer.networking.networkextension"] = ["packet-tunnel-provider"]
        self.assert_fails("signed app carries a NetworkExtension entitlement")

    def test_a_system_extensions_directory_fails(self):
        (self.app / "Contents/Library/SystemExtensions").mkdir()
        self.assert_fails("Contents/Library/SystemExtensions exists")

    def test_cmux_tui_must_link_to_cmux(self):
        alias = self.app / "Contents/Resources/bin/cmux-tui"
        alias.unlink()
        alias.write_bytes(b"copy")
        self.assert_fails("bin/cmux-tui is not a symlink to cmux")

    def test_a_helper_with_application_identifier_fails(self):
        helper = self.app / "Contents/Resources/libexec/helper"
        self.entry(helper)["entitlements"] = {"com.apple.application-identifier": "7WLXT3NR37.com.cmuxterm.app"}
        self.assert_fails("helper unexpectedly carries application-identifier")

    def test_a_nested_item_without_developer_id_fails(self):
        self.entry(self.app / "Contents/Resources/bin/cmux")["display"] = GOOD_DISPLAY.replace(
            "Developer ID Application", "Apple Development")
        self.assert_fails("cmux is not Developer ID signed")

    def test_a_nested_item_without_the_hardened_runtime_fails(self):
        self.entry(self.cu)["display"] = GOOD_DISPLAY.replace("0x10000(runtime)", "0x0(none)")
        self.assert_fails("cmux Computer Use.app is not signed with the hardened runtime")

    def test_computer_use_failing_strict_verify_fails(self):
        self.entry(self.cu)["verify"] = 1
        self.assert_fails("the nested Computer Use app fails codesign --verify --strict")


if __name__ == "__main__":
    unittest.main()
