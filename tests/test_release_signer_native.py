#!/usr/bin/env python3
"""Native notary command contracts; real keychain imports are tested on a Mac."""
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SUBMISSION = "0f1e2d3c-4b5a-6978-8a9b-acbdcedfe0f1"
FIXTURE = b"nonsecret fd import unit fixture"
TOOL = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ["CALLS"], "a") as stream:
    stream.write(json.dumps(args) + "\n")
if args[:2] == ["notarytool", "store-credentials"]:
    assert pathlib.Path(args[args.index("--key") + 1]).read_bytes() == b"nonsecret fd import unit fixture"
    assert "--keychain" in args
    print("Credentials stored in the keychain.")
elif args[:2] == ["notarytool", "submit"]:
    assert "--keychain-profile" in args and "--keychain" in args
    print(os.environ["NOTARY_RESULT"])
    sys.exit(int(os.environ.get("NOTARY_EXIT", "0")))
elif args[:2] == ["stapler", "staple"]:
    pathlib.Path(args[-1], "Contents", "CodeResources").write_text("unit fixture ticket")
    print("The staple action worked!")
elif args[:2] == ["stapler", "validate"]:
    print("The validate action worked!")
    sys.exit(int(os.environ.get("STAPLE_EXIT", "0")))
else:
    sys.exit("unexpected native tool call: " + repr(args))
'''


class NativeNotaryContract(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.app = self.root / "fixture.app"
        (self.app / "Contents").mkdir(parents=True)
        self.calls = self.root / "calls"
        self.keychains = self.root / "keychains"
        self.keychains.mkdir()
        self.keychain = self.keychains / "build.keychain-db"
        self.keychain.touch()  # The mocked notary tool reads no real keychain.
        for name, source in {"uname": "#!/bin/sh\necho Darwin\n", "xcrun": TOOL,
                             "ditto": "#!/bin/sh\nfor last do :; done\ntouch \"$last\"\n"}.items():
            tool = self.bin / name
            tool.write_text(source)
            tool.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}", CALLS=str(self.calls),
                        RUNNER_TEMP=str(self.root), CMUX_XCRUN_TOOL=str(self.bin / "xcrun"),
                        CMUX_DITTO_TOOL=str(self.bin / "ditto"), CMUX_STAPLER_TOOL=str(self.bin / "xcrun"),
                        CMUX_NATIVE_SIGNING_KEYCHAIN="build.keychain",
                        CMUX_KEYCHAIN_DIR=str(self.keychains),
                        CMUX_NATIVE_NOTARY_PROFILE="nightly-native", ASC_API_KEY_ID="FIXTURE1234",
                        ASC_API_ISSUER_ID="fixture-issuer", ASC_API_KEY_P8_BASE64=base64.b64encode(FIXTURE).decode(),
                        NOTARY_MAX_WAIT_SECONDS="1200", NOTARY_RESULT=json.dumps({"id": SUBMISSION, "status": "Accepted"}))

    def run_notary(self, **changes):
        return subprocess.run(["bash", str(ROOT / "scripts/ci/release-signer/native-notarize-app.sh"),
                               str(self.app), str(self.root / "notary.log")], env={**self.env, **changes},
                              capture_output=True, text=True, timeout=30)

    def recorded(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def test_accepted_submission_is_bound_to_job_keychain_bounded_and_stapled(self):
        result = self.run_notary()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, f"submission_id={SUBMISSION}\n")
        calls = self.recorded()
        for args in calls:
            if args[0] == "notarytool":
                self.assertEqual(args[args.index("--keychain") + 1], str(self.keychain))
        submit = next(args for args in calls if args[:2] == ["notarytool", "submit"])
        self.assertIn("--wait", submit)
        self.assertEqual(submit[submit.index("--timeout") + 1], "1200s")
        self.assertEqual([args[:2] for args in calls][-2:], [["stapler", "staple"], ["stapler", "validate"]])
        self.assertEqual(list(self.root.glob("cmux-native-app-notary.*")), [])
        self.assertEqual(list(self.root.rglob("*.p8")), [])

    def test_invalid_or_missing_submission_never_staples(self):
        for payload in ({"status": "Accepted"}, {"id": "not-a-uuid", "status": "Accepted"},
                        {"id": SUBMISSION, "status": "Invalid"}, {"id": SUBMISSION, "status": "In Progress"}):
            with self.subTest(payload=payload):
                self.calls.unlink(missing_ok=True)
                result = self.run_notary(NOTARY_RESULT=json.dumps(payload))
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(any(args[0] == "stapler" for args in self.recorded()))
                self.assertFalse((self.app / "Contents/CodeResources").exists())
                self.assertEqual(list(self.root.glob("cmux-native-app-notary.*")), [])

    def test_transport_and_staple_failures_cannot_report_success(self):
        for changes in ({"NOTARY_EXIT": "1"}, {"STAPLE_EXIT": "1"}):
            with self.subTest(changes=changes):
                result = self.run_notary(**changes)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(list(self.root.glob("cmux-native-app-notary.*")), [])


if __name__ == "__main__":
    unittest.main()
