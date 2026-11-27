#!/usr/bin/env python3
"""scripts/ci/release-signer: install.sh only puts the expected binary in place,
and notarize-dmg.sh signs with the matching Developer ID certificate, keeps every
key off command lines, and refuses a signature that is not the expected one.

A fake signer records its argv and environment. openssl is the real one: the
test makes a throwaway "Developer ID Application" certificate and PKCS#12.
"""

from __future__ import annotations

import base64
import hashlib
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
SUBMIT_APP = ROOT / "scripts/ci/release-signer/submit-app.sh"
WAIT_APP = ROOT / "scripts/ci/release-signer/wait-app-notary.sh"
SUBMISSION = "965c103d-b321-45bf-bacc-aac02dd2e648"
BUILD = ROOT / "scripts/ci/release-signer/build.sh"
PASSWORD = "throwaway-p12-password-41c7"
CN = "Developer ID Application: Example Corp (7WLXT3NR37)"

FAKE_SIGNER = r'''#!/usr/bin/env python3
# A stand-in signer that checks what the real one would need: a PEM whose key
# is the certificate's, a P8 that parses, a signature before a staple.
import json, os, stat, subprocess, sys
argv = sys.argv[1:]
def opt(name):
    return argv[argv.index(name) + 1]
def ssl(*args, stdin=None):
    return subprocess.run(["openssl", *args], input=stdin, capture_output=True, check=True).stdout
record = {"argv": argv, "config_env": sorted(k for k in os.environ if k.startswith("RCODESIGN_")),
          "secret_env": sorted(k for k in ("APPLE_CERTIFICATE_PASSWORD", "APPLE_CERTIFICATE_BASE64", "ASC_API_KEY_P8_BASE64") if k in os.environ)}
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(json.dumps(record) + "\n")
if record["config_env"]:
    sys.exit("configuration file error: UnknownField")
cmd = argv[0]
if cmd == "--version":
    print("rcodesign 0.29.0")
elif cmd == "sign":
    pem = opt("--pem-file")
    assert stat.S_IMODE(os.stat(pem).st_mode) & 0o077 == 0 and stat.S_IMODE(os.stat(os.path.dirname(pem)).st_mode) == 0o700
    data = open(pem, "rb").read()
    assert ssl("x509", "-noout", "-pubkey", stdin=data) == ssl("pkey", "-pubout", stdin=data), "key is not the certificate's"
    ou = ssl("x509", "-noout", "-subject", "-nameopt", "multiline", stdin=data).decode().split("organizationalUnitName")[1].split("=")[1].split()[0]
    open(argv[-1], "ab").write(b"\nSIGNED:" + ou.encode())
elif cmd == "print-signature-info":
    body = open(argv[-1], "rb").read()
    assert b"\nSIGNED:" in body, "not signed"
    team = os.environ.get("FAKE_TEAM") or body.rsplit(b"SIGNED:", 1)[1].split(b"\n")[0].decode()
    ident = os.path.basename(argv[-1])[:-4]
    print("version: '0x20200'\nflags: CodeSignatureFlags(0x0)\nidentifier: %s\nteam_name: %s" % (ident, team))
    print('designated(3): 0: (identifier "%s") and ((anchor apple generic) and ((certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */) and ((certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */) and (certificate leaf[subject.OU] = "%s"))));' % (ident, team))
elif cmd == "encode-app-store-connect-api-key":
    issuer, key_id, p8 = argv[-3:]
    assert os.path.basename(p8) == "AuthKey_%s.p8" % key_id
    ssl("pkey", "-in", p8, "-noout")
    out = opt("-o")
    json.dump({"issuer_id": issuer, "key_id": key_id, "private_key": open(p8).read()}, open(out, "w"))
elif cmd == "notary-submit":
    refusals = os.environ.get("FAKE_RATE_LIMITS")
    left = int(open(refusals).read() or 0) if refusals else 0
    if left > 0:
        open(refusals, "w").write(str(left - 1))
        print('Error: appstore connect error:\nPOST https://appstoreconnect.apple.com/notary/v2/submissions\n'
              '{"errors": [{"code": "RATE_LIMIT", "detail": "Exceeded daily limit for notarizations. '
              'Try again in 0:04:11.", "status": "429", "title": "Too many notarizations"}]}')
        sys.exit(1)
    if os.environ.get("FAKE_SUBMIT_FAILS"):
        sys.exit("Error: the submission was rejected")
    key = json.load(open(opt("--api-key-file")))
    ssl("pkey", "-noout", stdin=key["private_key"].encode())
    if os.path.isdir(argv[-1]):
        # submit-app.sh: an app bundle, uploaded without waiting for Apple.
        assert "--staple" not in argv and "--wait" not in argv
        print("created submission ID: " + os.environ.get("FAKE_SUBMISSION", "965c103d-b321-45bf-bacc-aac02dd2e648"))
        sys.exit(0)
    assert b"\nSIGNED:" in open(argv[-1], "rb").read(), "submitted unsigned"
    assert "--staple" in argv
    open(argv[-1], "ab").write(b"\nSTAPLED")
elif cmd in ("notary-wait", "notary-log"):
    key = json.load(open(opt("--api-key-file")))
    ssl("pkey", "-noout", stdin=key["private_key"].encode())
    status = os.environ.get("FAKE_STATUS", "Accepted")
    if cmd == "notary-wait":
        print("poll state after 0s: " + status)
    else:
        print(json.dumps({"jobId": argv[-1], "status": status}))
else:
    sys.exit("unexpected command " + cmd)
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
        self.env = dict(os.environ, FAKE_LOG=str(self.log), RCODESIGN_TEAM_ID="X", **{"RCODESIGN_-BAD": "1"})
        self.digest = hashlib.sha256(self.bin.read_bytes()).hexdigest()

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
    def test_notarize_dmg_uses_bash_3_2_compatible_case_normalization(self):
        text = NOTARIZE_DMG.read_text()
        self.assertNotIn("${want^^}", text)
        self.assertNotIn("${want,,}", text)
        self.assertIn("tr '[:upper:]' '[:lower:]'", text)

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
        p8 = subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256"],
                            check=True, capture_output=True).stdout
        self.env = dict(
            os.environ, FAKE_LOG=str(self.log), CMUX_SIGNER=str(self.signer), RCODESIGN_CONFIG="x",
            **{"RCODESIGN_-BAD": "1"},
            APPLE_CERTIFICATE_BASE64=base64.b64encode(p12.read_bytes()).decode(),
            APPLE_CERTIFICATE_PASSWORD=PASSWORD, APPLE_SIGNING_IDENTITY="Developer ID Application: Example Corp",
            ASC_API_KEY_ID="KEYID12345", ASC_API_ISSUER_ID="issuer-uuid", ASC_API_KEY_P8_BASE64=base64.b64encode(p8).decode(),
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
        self.assertTrue(self.dmg.read_bytes().endswith(b"\nSIGNED:7WLXT3NR37\nSTAPLED"))
        for call in calls:
            self.assertEqual(call["config_env"], [])
            self.assertEqual(call["secret_env"], [])
            joined = " ".join(call["argv"])
            self.assertNotIn(PASSWORD, joined)
            self.assertNotIn(self.env["ASC_API_KEY_P8_BASE64"], joined)
        # The secrets directory is gone.
        self.assertEqual(sorted(p.name for p in self.tmp.glob("cmux-dmg-signer.*")), [])

    def rate_limited(self, refusals, **env):
        """Runs notarize-dmg.sh with Apple refusing the first `refusals`
        submissions as rate limited; a stand-in sleep records each wait."""
        (self.tmp / "refusals").write_text(str(refusals))
        tools = self.tmp / "tools"
        tools.mkdir(exist_ok=True)
        (tools / "sleep").write_text('#!/bin/sh\necho "$1" >> "$FAKE_SLEEPS"\n')
        (tools / "sleep").chmod(0o755)
        self.sleeps = self.tmp / "sleeps"
        return run(["bash", NOTARIZE_DMG, self.dmg], dict(
            self.env, PATH=f"{tools}:{self.env['PATH']}", FAKE_RATE_LIMITS=str(self.tmp / "refusals"),
            FAKE_SLEEPS=str(self.sleeps), **env))

    def submits(self):
        return [c for c in self.calls() if c["argv"][0] == "notary-submit"]

    def test_waits_out_a_notary_rate_limit_and_submits_again(self):
        result = self.rate_limited(1)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.submits()), 2)
        # Apple's "Try again in 0:04:11", plus 15 s.
        self.assertEqual(self.sleeps.read_text().split(), ["266"])
        self.assertIn("rate limited (429 RATE_LIMIT); submitting again in 266s", result.stderr)
        self.assertTrue(self.dmg.read_bytes().endswith(b"\nSTAPLED"))
        self.assertEqual(sorted(p.name for p in self.tmp.glob("cmux-notary-submit.*")), [])

    def test_stops_when_the_rate_limit_outlasts_the_budget(self):
        result = self.rate_limited(1, CMUX_NOTARY_RATE_LIMIT_SECONDS="200")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.submits()), 1)
        self.assertFalse(self.sleeps.exists())
        self.assertIn("rate limit asks for 266s more", result.stderr)

    def test_stops_after_the_budget_is_spent_across_refusals(self):
        result = self.rate_limited(3)
        self.assertNotEqual(result.returncode, 0)
        # 266 + 266 fits in 600 s; a third wait would not.
        self.assertEqual(self.sleeps.read_text().split(), ["266", "266"])
        self.assertEqual(len(self.submits()), 3)

    def test_does_not_retry_a_failure_that_is_not_a_rate_limit(self):
        result = self.rate_limited(0, FAKE_SUBMIT_FAILS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.submits()), 1)
        self.assertFalse(self.sleeps.exists())

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

    def test_the_patch_is_the_pinned_one(self):
        digest = hashlib.sha256((BUILD.parent / "apple-codesign-0.29.0.patch").read_bytes()).hexdigest()
        self.assertIn(f"PATCH_SHA256={digest}", BUILD.read_text())

    def test_refuses_a_changed_patch_before_any_download(self):
        tmp = Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(shutil.rmtree, tmp, True)
        copy = tmp / "release-signer"
        shutil.copytree(BUILD.parent, copy)
        with open(copy / "apple-codesign-0.29.0.patch", "a") as patch:
            patch.write("+tampered\n")
        tools = tmp / "bin"
        tools.mkdir()
        for tool in ("cargo", "curl"):
            (tools / tool).write_text("#!/bin/sh\necho ran >> \"$FAKE_RAN\"\nexit 1\n")
            (tools / tool).chmod(0o755)
        env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}", FAKE_RAN=str(tmp / "ran"))
        result = run(["bash", copy / "build.sh", tmp / "out"], env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match its pinned sha256", result.stderr)
        self.assertFalse((tmp / "ran").exists())

    def test_scripts_are_executable(self):
        for script in (BUILD, INSTALL, NOTARIZE_DMG, SUBMIT_APP, WAIT_APP):  # signer-env.sh is sourced
            self.assertTrue(script.stat().st_mode & stat.S_IXUSR, script)


class AppNotarizationTests(unittest.TestCase):
    """submit-app.sh uploads the app in the background and hands on Apple's id; wait-app-notary.sh
    passes only an Accepted answer. Neither puts the notary key on a command line or in the signer's
    environment, and both remove its directory."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.signer = self.tmp / "signer"
        self.signer.write_text(FAKE_SIGNER)
        self.signer.chmod(0o755)
        self.log = self.tmp / "log.jsonl"
        self.app = self.tmp / "cmux NEXT.app"
        (self.app / "Contents").mkdir(parents=True)
        p8 = subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256"],
                            check=True, capture_output=True).stdout
        self.env = dict(
            os.environ, FAKE_LOG=str(self.log), CMUX_SIGNER=str(self.signer), RCODESIGN_CONFIG="x",
            ASC_API_KEY_ID="KEYID12345", ASC_API_ISSUER_ID="issuer-uuid", ASC_API_KEY_P8_BASE64=base64.b64encode(p8).decode(),
            TMPDIR=str(self.tmp), RUNNER_TEMP=str(self.tmp / "runner"), CMUX_NOTARY_LOG_RETRY_SECONDS="0",
        )
        (self.tmp / "runner").mkdir()

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def assert_keys_stayed_in_files(self, prefix):
        for call in self.calls():
            self.assertEqual(call["config_env"], [])
            self.assertEqual(call["secret_env"], [])
            self.assertNotIn(self.env["ASC_API_KEY_P8_BASE64"], " ".join(call["argv"]))
        self.assertEqual(sorted(p.name for p in self.tmp.glob(prefix + ".*")), [])

    def test_submits_in_the_background_and_hands_on_the_id(self):
        start = run(["bash", SUBMIT_APP, "start", self.app], self.env)
        self.assertEqual(start.returncode, 0, start.stderr)
        finish = run(["bash", SUBMIT_APP, "finish"], {k: v for k, v in self.env.items() if k != "ASC_API_KEY_P8_BASE64"})
        self.assertEqual(finish.returncode, 0, finish.stderr)
        self.assertEqual(finish.stdout, f"submission_id={SUBMISSION}\n")
        submit = [c["argv"] for c in self.calls() if c["argv"][0] == "notary-submit"]
        self.assertEqual(len(submit), 1)
        self.assertEqual(submit[0][-1], str(self.app))
        self.assert_keys_stayed_in_files("cmux-app-submit")

    def test_finish_fails_when_the_upload_failed(self):
        self.assertEqual(run(["bash", SUBMIT_APP, "start", self.app], dict(self.env, FAKE_SUBMIT_FAILS="1")).returncode, 0)
        finish = run(["bash", SUBMIT_APP, "finish"], self.env)
        self.assertNotEqual(finish.returncode, 0)
        self.assertNotIn("submission_id=", finish.stdout)

    def test_finish_fails_without_a_submission_id(self):
        self.assertEqual(run(["bash", SUBMIT_APP, "start", self.app], dict(self.env, FAKE_SUBMISSION="none")).returncode, 0)
        finish = run(["bash", SUBMIT_APP, "finish"], self.env)
        self.assertNotEqual(finish.returncode, 0)
        self.assertIn("names no submission id", finish.stderr)

    def test_finish_without_a_start_fails(self):
        self.assertNotEqual(run(["bash", SUBMIT_APP, "finish"], self.env).returncode, 0)

    def test_wait_passes_an_accepted_submission(self):
        result = run(["bash", WAIT_APP, SUBMISSION], self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([c["argv"][0] for c in self.calls()], ["encode-app-store-connect-api-key", "notary-wait", "notary-log"])
        self.assertEqual(self.calls()[1]["argv"][-1], SUBMISSION)
        self.assert_keys_stayed_in_files("cmux-app-wait")

    def test_wait_fails_on_any_other_answer(self):
        for status in ("Invalid", "Rejected", "In Progress"):
            with self.subTest(status=status):
                result = run(["bash", WAIT_APP, SUBMISSION], dict(self.env, FAKE_STATUS=status))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"Apple answered '{status}'", result.stderr)

    def test_wait_refuses_a_malformed_id(self):
        result = run(["bash", WAIT_APP, "--staple"], self.env)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())


if __name__ == "__main__":
    unittest.main()
