#!/usr/bin/env python3
"""scripts/ci/release-signer: install.sh only puts the expected binary in place,
and notarize-dmg.sh signs with the matching Developer ID certificate, keeps every
key off command lines, and refuses a signature that is not the expected one.

A fake signer records its argv and environment. openssl is the real one: the
test makes a throwaway "Developer ID Application" certificate and PKCS#12.
"""

from __future__ import annotations

import base64
import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INSTALL = ROOT / "scripts/ci/release-signer/install.sh"
NOTARIZE_DMG = ROOT / "scripts/ci/release-signer/notarize-dmg.sh"
BUILD = ROOT / "scripts/ci/release-signer/build.sh"
PASSWORD = "throwaway-p12-password-41c7"
CN = "Developer ID Application: Example Corp (7WLXT3NR37)"
P8 = b"-----BEGIN PRIVATE KEY-----\nthrowaway\n-----END PRIVATE KEY-----\n"

FAKE_SIGNER = r'''#!/usr/bin/env python3
import json, os, sys
argv = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(json.dumps({"argv": argv, "config_env": sorted(k for k in os.environ if k.startswith("RCODESIGN_")),
                          "secret_env": sorted(k for k in ("APPLE_CERTIFICATE_PASSWORD", "APPLE_CERTIFICATE_BASE64") if k in os.environ)}) + "\n")
if argv and argv[0] == "--version":
    print("rcodesign 0.29.0")
elif argv[0] == "encode-app-store-connect-api-key":
    open(argv[argv.index("-o") + 1], "w").write("{}")
elif argv[0] == "print-signature-info":
    ident = os.path.basename(argv[-1])[:-4]
    team = os.environ.get("FAKE_TEAM", "7WLXT3NR37")
    print("version: '0x20200'\nflags: CodeSignatureFlags(0x0)\nidentifier: %s\nteam_name: %s" % (ident, team))
    print('designated(3): 0: (identifier "%s") and ((anchor apple generic) and ((certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */) and ((certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */) and (certificate leaf[subject.OU] = "%s"))));' % (ident, team))
'''


def run(args, env, cwd=None):
    return subprocess.run([str(a) for a in args], env=env, cwd=cwd, capture_output=True, text=True)


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin = self.tmp / "signer"
        self.bin.write_text(FAKE_SIGNER)
        self.log = self.tmp / "log.jsonl"
        self.env = dict(os.environ, FAKE_LOG=str(self.log), RCODESIGN_TEAM_ID="X")
        self.digest = subprocess.run(["shasum", "-a", "256", str(self.bin)], capture_output=True, text=True,
                                     check=True).stdout.split()[0]

    def test_prints_the_signer_variable_for_the_expected_binary(self):
        result = run(["bash", INSTALL, self.bin, self.digest], self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f"CMUX_SIGNER={self.bin}\n")
        self.assertTrue(os.access(self.bin, os.X_OK))
        # The version call ran with no RCODESIGN_* config variable.
        self.assertEqual(json.loads(self.log.read_text().splitlines()[-1])["config_env"], [])

    def test_refuses_another_binary(self):
        result = run(["bash", INSTALL, self.bin, "0" * 64], self.env)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("is not the expected", result.stderr)

    def test_refuses_a_malformed_digest(self):
        self.assertNotEqual(run(["bash", INSTALL, self.bin, "abc"], self.env).returncode, 0)


class NotarizeDmgTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.signer = self.tmp / "signer"
        self.signer.write_text(FAKE_SIGNER)
        self.signer.chmod(0o755)
        self.log = self.tmp / "log.jsonl"
        self.dmg = self.tmp / "cmux-nightly-next-macos-arm64.dmg"
        self.dmg.write_bytes(b"unsigned dmg")
        key, cert, p12 = self.tmp / "k.pem", self.tmp / "c.pem", self.tmp / "id.p12"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2", "-keyout", key,
                        "-out", cert, "-subj", f"/CN={CN}/OU=7WLXT3NR37/O=Example Corp/C=US"],
                       check=True, capture_output=True)
        subprocess.run(["openssl", "pkcs12", "-export", "-inkey", key, "-in", cert, "-out", p12,
                        "-passout", f"pass:{PASSWORD}"], check=True, capture_output=True)
        key.unlink()
        self.env = dict(
            os.environ, FAKE_LOG=str(self.log), CMUX_SIGNER=str(self.signer), RCODESIGN_CONFIG="x",
            APPLE_CERTIFICATE_BASE64=base64.b64encode(p12.read_bytes()).decode(),
            APPLE_CERTIFICATE_PASSWORD=PASSWORD, APPLE_SIGNING_IDENTITY="Developer ID Application: Example Corp",
            ASC_API_KEY_ID="KEYID12345", ASC_API_ISSUER_ID="issuer-uuid", ASC_API_KEY_P8_BASE64=base64.b64encode(P8).decode(),
            TMPDIR=str(self.tmp),
        )
        p12.unlink()

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_signs_notarizes_and_staples_with_keys_only_in_files(self):
        result = run(["bash", NOTARIZE_DMG, self.dmg], self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertEqual([c["argv"][0] for c in calls],
                         ["sign", "print-signature-info", "encode-app-store-connect-api-key", "notary-submit"])
        sign, submit = calls[0]["argv"], calls[-1]["argv"]
        self.assertIn("--pem-file", sign)
        self.assertEqual(sign[-1], str(self.dmg))
        self.assertIn("--staple", submit)
        for call in calls:
            self.assertEqual(call["config_env"], [])
            self.assertEqual(call["secret_env"], [])
            joined = " ".join(call["argv"])
            self.assertNotIn(PASSWORD, joined)
            self.assertNotIn(self.env["ASC_API_KEY_P8_BASE64"], joined)
        # The secrets directory is gone.
        self.assertEqual(sorted(p.name for p in self.tmp.glob("cmux-dmg-signer.*")), [])

    def test_refuses_a_signature_for_another_team(self):
        result = run(["bash", NOTARIZE_DMG, self.dmg], dict(self.env, FAKE_TEAM="OTHERTEAM1"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("lacks", result.stderr)
        self.assertNotIn("notary-submit", [c["argv"][0] for c in self.calls()])

    def test_refuses_a_certificate_that_is_not_the_named_identity(self):
        result = run(["bash", NOTARIZE_DMG, self.dmg], dict(self.env, APPLE_SIGNING_IDENTITY="Someone Else"))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists() and "sign" in [c["argv"][0] for c in self.calls()])

    def test_needs_the_signer_variable(self):
        env = dict(self.env)
        del env["CMUX_SIGNER"]
        self.assertNotEqual(run(["bash", NOTARIZE_DMG, self.dmg], env).returncode, 0)


class BuildTests(unittest.TestCase):
    def test_pins_the_crate_and_applies_the_patch_beside_it(self):
        text = BUILD.read_text()
        self.assertIn("CRATE_SHA256=f24e9ebdb70a2aee3ca1cea217009fb50776955f0d7678c31d22e48c1524667f", text)
        self.assertIn("--locked", text)
        self.assertTrue((BUILD.parent / "apple-codesign-0.29.0.patch").is_file())

    def test_scripts_are_executable(self):
        for script in (BUILD, INSTALL, NOTARIZE_DMG):
            self.assertTrue(script.stat().st_mode & stat.S_IXUSR, script)


if __name__ == "__main__":
    unittest.main()
