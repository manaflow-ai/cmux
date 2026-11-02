#!/usr/bin/env python3
"""scripts/ci/release-signer: nightly_next_identity.py makes the plist edits of
nightly.yml's identity step for cmux NEXT, and notarize-app.sh notarizes and
staples a bundle with the notary key kept out of argv and the signer's
environment, failing unless Apple accepted it."""

from __future__ import annotations

import base64
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IDENTITY = ROOT / "scripts/ci/release-signer/nightly_next_identity.py"
NOTARIZE_APP = ROOT / "scripts/ci/release-signer/notarize-app.sh"
SUBMISSION = "0f1e2d3c-4b5a-6978-8a9b-acbdcedfe0f1"

FAKE_SIGNER = r'''#!/usr/bin/env python3
import json, os, subprocess, sys
argv = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(json.dumps({"argv": argv, "config_env": sorted(k for k in os.environ if k.startswith("RCODESIGN_")),
                          "p8_env": "ASC_API_KEY_P8_BASE64" in os.environ}) + "\n")
if argv[0] == "encode-app-store-connect-api-key":
    p8 = argv[-1]
    subprocess.run(["openssl", "pkey", "-in", p8, "-noout"], check=True)
    json.dump({"private_key": open(p8).read()}, open(argv[argv.index("-o") + 1], "w"))
elif argv[0] == "notary-submit":
    key = json.load(open(argv[argv.index("--api-key-file") + 1]))
    subprocess.run(["openssl", "pkey", "-noout"], input=key["private_key"].encode(), check=True)
    if os.environ["FAKE_SUBMISSION"]:
        print("created submission ID: %s" % os.environ["FAKE_SUBMISSION"])
    status = os.environ.get("FAKE_STATUS", "Accepted")
    print("poll state after 3s: %s" % status)
    if status != "Accepted":
        sys.exit(1)
    open(os.path.join(argv[-1], "Contents", "CodeResources"), "w").write("ticket")
'''


class IdentityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.plist = self.tmp / "Info.plist"
        self.base = {
            "CFBundleName": "cmux", "CFBundleDisplayName": "cmux", "CFBundleIdentifier": "com.cmuxterm.app",
            "CFBundleURLTypes": [{"CFBundleURLName": "com.cmuxterm.app", "CFBundleURLSchemes": ["cmux"]},
                                 {"CFBundleURLName": "com.cmuxterm.app.auth", "CFBundleURLSchemes": ["cmux"]}],
            "SUPublicEDKey": "old", "SUFeedURL": "https://old", "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1", "CMUXCommit": "old",
        }
        self.env = dict(os.environ, CHANNEL_APP_NAME="cmux NEXT", CHANNEL_BUNDLE_ID="com.cmuxterm.app.nightly.cmux-next",
                        CHANNEL_URL_SCHEME="cmux-next", FEED_URL="https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml",
                        SPARKLE_PUBLIC_KEY="IOPItMLjtc4NsROTNZ6a/jsUW+C4fcicl6SNjVVvzRM=",
                        NIGHTLY_MARKETING_VERSION="1.2.3-nightly.9", NIGHTLY_BUILD="99", SHORT_SHA="abc1234")

    def stamp(self, plist, fmt=plistlib.FMT_BINARY, **env):
        self.plist.write_bytes(plistlib.dumps(plist, fmt=fmt))
        return subprocess.run(["python3", "-I", str(IDENTITY), str(self.plist)], env=dict(self.env, **env),
                              capture_output=True, text=True)

    def test_stamps_every_entry_and_keeps_the_format(self):
        result = self.stamp(self.base)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.plist.read_bytes().startswith(b"bplist00"))
        out = plistlib.loads(self.plist.read_bytes())
        self.assertEqual((out["CFBundleName"], out["CFBundleDisplayName"], out["CFBundleIdentifier"]),
                         ("cmux NEXT", "cmux NEXT", "com.cmuxterm.app.nightly.cmux-next"))
        self.assertEqual(out["CFBundleURLTypes"][1]["CFBundleURLSchemes"], ["cmux-next"])
        self.assertEqual(out["CFBundleURLTypes"][0]["CFBundleURLSchemes"], ["cmux"])
        self.assertEqual(out["LSEnvironment"], {"CMUX_AUTH_CALLBACK_SCHEME": "cmux-next"})
        self.assertEqual(out["SUPublicEDKey"], self.env["SPARKLE_PUBLIC_KEY"])
        self.assertEqual(out["SUFeedURL"], self.env["FEED_URL"])
        self.assertEqual((out["CFBundleShortVersionString"], out["CFBundleVersion"], out["CMUXCommit"]),
                         ("1.2.3-nightly.9", "99", "abc1234"))
        # Delete + Add moves the entry last, as PlistBuddy does.
        self.assertEqual(list(out)[-1], "CMUXCommit")

    def test_keeps_other_launch_environment_entries(self):
        result = self.stamp(dict(self.base, LSEnvironment={"OTHER": "1", "CMUX_AUTH_CALLBACK_SCHEME": "cmux"}),
                            fmt=plistlib.FMT_XML)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.plist.read_bytes().startswith(b"<?xml"))
        self.assertEqual(plistlib.loads(self.plist.read_bytes())["LSEnvironment"],
                         {"OTHER": "1", "CMUX_AUTH_CALLBACK_SCHEME": "cmux-next"})

    def test_refuses_a_second_url_type_that_is_not_auth(self):
        plist = dict(self.base)
        plist["CFBundleURLTypes"] = [plist["CFBundleURLTypes"][1], plist["CFBundleURLTypes"][0]]
        result = self.stamp(plist)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("auth URL type", result.stderr)

    def test_refuses_a_missing_entry_that_plistbuddy_would_only_set(self):
        for key in ("CFBundleName", "CFBundleDisplayName", "CFBundleIdentifier", "CFBundleVersion"):
            with self.subTest(key=key):
                plist = dict(self.base)
                del plist[key]
                result = self.stamp(plist)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(key, result.stderr)

    def test_refuses_a_launch_environment_that_is_not_a_dictionary(self):
        result = self.stamp(dict(self.base, LSEnvironment="x"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("LSEnvironment", result.stderr)

    def test_refuses_an_empty_input(self):
        self.assertNotEqual(self.stamp(self.base, NIGHTLY_BUILD="").returncode, 0)


class NotarizeAppTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.signer = self.tmp / "signer"
        self.signer.write_text(FAKE_SIGNER)
        self.signer.chmod(0o755)
        self.app = self.tmp / "cmux NEXT.app"
        (self.app / "Contents").mkdir(parents=True)
        self.log = self.tmp / "calls.jsonl"
        p8 = subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256"],
                            check=True, capture_output=True).stdout
        self.p8 = base64.b64encode(p8).decode()
        self.env = dict(os.environ, FAKE_LOG=str(self.log), FAKE_SUBMISSION=SUBMISSION, CMUX_SIGNER=str(self.signer),
                        ASC_API_KEY_ID="KEY123", ASC_API_ISSUER_ID="issuer", ASC_API_KEY_P8_BASE64=self.p8,
                        TMPDIR=str(self.tmp), RCODESIGN_CONFIG="x", **{"RCODESIGN_-BAD": "1"})

    def run_script(self, **env):
        return subprocess.run(["bash", str(NOTARIZE_APP), str(self.app), str(self.tmp / "notary.log")],
                              env=dict(self.env, **env), capture_output=True, text=True)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_notarizes_and_staples_with_the_key_only_in_a_file(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f"submission_id={SUBMISSION}\n")
        self.assertTrue((self.app / "Contents/CodeResources").is_file())
        calls = self.calls()
        self.assertEqual([c["argv"][0] for c in calls], ["encode-app-store-connect-api-key", "notary-submit"])
        self.assertIn("--staple", calls[1]["argv"])
        self.assertEqual(calls[1]["argv"][-1], str(self.app))
        for call in calls:
            self.assertEqual(call["config_env"], [])
            self.assertFalse(call["p8_env"])
            self.assertNotIn(self.p8, " ".join(call["argv"]))
        self.assertEqual(list(self.tmp.glob("cmux-app-notary.*")), [])

    def test_fails_when_apple_does_not_accept(self):
        result = self.run_script(FAKE_STATUS="Invalid")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"submission_id={SUBMISSION}", result.stdout)
        self.assertIn("was not notarized", result.stderr)
        self.assertFalse((self.app / "Contents/CodeResources").exists())

    def test_fails_when_the_log_names_no_submission(self):
        result = self.run_script(FAKE_SUBMISSION="")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("no submission id", result.stderr)

    def test_refuses_a_path_that_is_not_a_bundle(self):
        result = subprocess.run(["bash", str(NOTARIZE_APP), str(self.tmp / "missing.app"), str(self.tmp / "l")],
                                env=self.env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())


if __name__ == "__main__":
    unittest.main()
