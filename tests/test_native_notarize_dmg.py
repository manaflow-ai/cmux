#!/usr/bin/env python3
"""Contract tests for the owned-Mac native DMG notarization wrapper."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/release-signer/native-notarize-dmg.sh"


UNAME = "#!/bin/sh\nprintf 'Darwin\\n'\n"
KEYCHAIN = "#!/bin/sh\nprintf 'keychain %s\\n' \"$*\" >> \"$FIXTURE_LOG\"\n"
SECURITY = r'''#!/usr/bin/env python3
import os, sys
if sys.argv[1:3] == ["find-identity", "-v"]:
    print(os.environ.get("FIXTURE_IDENTITIES", "  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA \"Developer ID Application: Fixture\""))
'''
CODESIGN = r'''#!/usr/bin/env python3
import os, pathlib, sys
args = sys.argv[1:]
log = pathlib.Path(os.environ["FIXTURE_LOG"])
with log.open("a") as f:
    f.write("codesign " + " ".join(args) + "\n")
if "--force" in args:
    pathlib.Path(args[-1]).write_bytes(b"signed")
elif "--verify" in args and os.environ.get("FIXTURE_VERIFY_FAIL"):
    raise SystemExit(1)
elif "--requirements" in args:
    print(os.environ.get("FIXTURE_REQUIREMENTS", "designated => identifier \"cmux-nightly\" and anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"7WLXT3NR37\""))
elif "--display" in args:
    print(os.environ.get("FIXTURE_DISPLAY", "Authority=Developer ID Application: Fixture\nIdentifier=cmux-nightly\nTeamIdentifier=7WLXT3NR37\nCodeDirectory v=20200 size=400 flags=0x0(none) hashes=1+2 location=embedded"))
'''
XCRUN = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
pathlib.Path(os.environ["FIXTURE_LOG"]).open("a").write("xcrun " + " ".join(args) + "\n")
if args[:2] == ["notarytool", "store-credentials"]:
    key = args[args.index("--key") + 1]
    data = pathlib.Path(key).read_bytes()
    pathlib.Path(os.environ["FIXTURE_KEY_BYTES"]).write_bytes(data)
    if os.environ.get("FIXTURE_STORE_FAIL"):
        raise SystemExit(1)
elif args[:2] == ["notarytool", "submit"]:
    print(json.dumps({"id": os.environ.get("FIXTURE_ID", "11111111-1111-4111-8111-111111111111"),
                      "status": os.environ.get("FIXTURE_STATUS", "Accepted")}))
    if os.environ.get("FIXTURE_SUBMIT_FAIL"):
        raise SystemExit(1)
elif args[:2] == ["stapler", "staple"]:
    if os.environ.get("FIXTURE_STAPLE_FAIL"):
        raise SystemExit(1)
elif args[:2] == ["stapler", "validate"] and os.environ.get("FIXTURE_VALIDATE_FAIL"):
    raise SystemExit(1)
'''


class NativeDmgTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="cmux-native-dmg-")
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name, body in (("uname", UNAME), ("security", SECURITY), ("codesign", CODESIGN), ("xcrun", XCRUN)):
            path = self.bin / name
            path.write_text(body)
            path.chmod(0o755)
        self.keychains = self.root / "keychains"
        self.keychains.mkdir()
        (self.keychains / "build.keychain-db").write_bytes(b"fixture-keychain")
        self.dmg = self.root / "cmux-nightly.dmg"
        self.dmg.write_bytes(b"unsigned")
        self.log = self.root / "calls.log"
        self.key_bytes = self.root / "key-bytes"
        self.key_tool = self.root / "keychain-tool"
        self.key_tool.write_text(KEYCHAIN)
        self.key_tool.chmod(0o755)
        self.env = dict(
            os.environ,
            PATH=f"{self.bin}:{os.environ.get('PATH', '')}",
            CMUX_CODESIGN_TOOL=str(self.bin / "codesign"),
            CMUX_SECURITY_TOOL=str(self.bin / "security"),
            CMUX_XCRUN_TOOL=str(self.bin / "xcrun"),
            CMUX_SIGNING_KEYCHAIN_TOOL=str(self.key_tool),
            CMUX_KEYCHAIN_DIR=str(self.keychains),
            CMUX_NATIVE_SIGNING_KEYCHAIN="build.keychain",
            CMUX_NATIVE_NOTARY_PROFILE="fixture-profile",
            APPLE_SIGNING_IDENTITY="Developer ID Application: Fixture",
            ASC_API_KEY_ID="FIXTUREKEY",
            ASC_API_ISSUER_ID="fixture-issuer",
            ASC_API_KEY_P8_BASE64="Zml4dHVyZS1wOA==",  # fixture-p8
            FIXTURE_LOG=str(self.log),
            FIXTURE_KEY_BYTES=str(self.key_bytes),
            FIXTURE_DISPLAY="Authority=Developer ID Application: Fixture\nIdentifier=cmux-nightly\nTeamIdentifier=7WLXT3NR37\nCodeDirectory v=20200 size=400 flags=0x0(none) hashes=1+2 location=embedded",
            FIXTURE_REQUIREMENTS="designated => identifier \"cmux-nightly\" and anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"7WLXT3NR37\"",
        )

    def run_dmg(self, **updates: str) -> subprocess.CompletedProcess[str]:
        env = dict(self.env, **updates)
        return subprocess.run([str(SCRIPT), str(self.dmg)], env=env, text=True, capture_output=True)

    def test_native_path_binds_profile_and_preserves_contract(self) -> None:
        result = self.run_dmg()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("submission ID: 11111111-1111-4111-8111-111111111111", result.stdout)
        self.assertEqual(self.key_bytes.read_bytes(), b"fixture-p8")
        calls = self.log.read_text()
        self.assertIn("--keychain ", calls)
        self.assertIn("--timeout 1200s", calls)

    def test_unique_cn_substring_is_accepted(self) -> None:
        result = self.run_dmg(APPLE_SIGNING_IDENTITY="Fixture")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--identifier cmux-nightly", self.log.read_text())

    def test_fingerprint_identity_is_accepted(self) -> None:
        result = self.run_dmg(
            APPLE_SIGNING_IDENTITY="A" * 40,
            FIXTURE_IDENTITIES="  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA \"Developer ID Application: Fixture\"",
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_identity_team_and_designated_requirement_are_required(self) -> None:
        for updates in (
            {"FIXTURE_DISPLAY": "Authority=Developer ID Application: Other\nIdentifier=cmux-nightly\nTeamIdentifier=7WLXT3NR37\nCodeDirectory v=20200 size=400 flags=0x0(none) hashes=1+2 location=embedded"},
            {"FIXTURE_DISPLAY": "Authority=Developer ID Application: Fixture\nIdentifier=cmux\nTeamIdentifier=WRONG"},
            {"FIXTURE_DISPLAY": "Authority=Developer ID Application: Fixture\nTeamIdentifier=7WLXT3NR37"},
            {"FIXTURE_REQUIREMENTS": "designated => anchor apple"},
        ):
            result = self.run_dmg(**updates)
            self.assertNotEqual(result.returncode, 0, updates)
            self.assertNotIn("notarytool submit", self.log.read_text(), updates)
            self.log.write_text("")

    def test_invalid_submission_or_staple_failure_does_not_succeed(self) -> None:
        for updates in ({"FIXTURE_ID": "not-a-uuid"}, {"FIXTURE_STAPLE_FAIL": "1"}):
            result = self.run_dmg(**updates)
            self.assertNotEqual(result.returncode, 0, updates)


if __name__ == "__main__":
    unittest.main()
