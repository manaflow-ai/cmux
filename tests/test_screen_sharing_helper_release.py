#!/usr/bin/env python3
"""scripts/ci/screen_sharing_helper_release.py: the NIGHTLY's signed Screen Sharing helper `cmux app try` carries.

One identity (cmux#47409): the bundle id com.cmuxterm.app.nightly.screen-sharing, Developer ID team
7WLXT3NR37, and a designated requirement that is, byte for byte, the Developer ID form codesign prints
for the NIGHTLY's own helper, with its intermediate and leaf clauses (ss-host-helper's ask (a)); never a
cdhash. The same string is helper.rs's developer_id_requirement (cmux-tui app try tests hold it there).
"""
from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
import plistlib
import re
import shutil
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("screen_sharing_helper_release",
                                              ROOT / "scripts/ci/screen_sharing_helper_release.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)

NIGHTLY_REQUIREMENT = ('identifier "com.cmuxterm.app.nightly.screen-sharing" and anchor apple generic and '
                       "certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and "
                       "certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and "
                       'certificate leaf[subject.OU] = "7WLXT3NR37"')
KEY = "c" * 16  # a helper source key: 16 hex, not a secret
COMMIT = "a" * 40


class Release(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.helper = self.tmp / "cmux NIGHTLY Screen Sharing.app"
        (self.helper / "Contents/MacOS").mkdir(parents=True)
        (self.helper / "Contents/MacOS/cmux-screen-sharing").write_bytes(b"host")
        self.write_id(release.BUNDLE_ID)
        self.codesign = self.tmp / "codesign"
        self.say(NIGHTLY_REQUIREMENT)
        os.environ["CMUX_CODESIGN_TOOL"] = str(self.codesign)
        self.addCleanup(os.environ.pop, "CMUX_CODESIGN_TOOL", None)
        self.zip = self.tmp / "helper.zip"
        self.zip.write_bytes(b"zip bytes")

    def write_id(self, bundle_id):
        with open(self.helper / "Contents/Info.plist", "wb") as f:
            plistlib.dump({"CFBundleIdentifier": bundle_id}, f)

    def say(self, requirement):
        """A codesign that prints REQUIREMENT as `-d -r-` does (on stdout, after its Executable line)."""
        self.codesign.write_text(f"#!/bin/sh\necho 'Executable=x' >&2\necho '# designated => ignored'\n"
                                 f"printf '%s\\n' {json.dumps('designated => ' + requirement)}\n")
        self.codesign.chmod(0o755)

    def run_main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = release.main(list(argv))
        return code, out.getvalue(), err.getvalue()

    def test_the_requirement_is_the_nightly_helpers_byte_for_byte(self):
        self.assertEqual(release.requirement(release.BUNDLE_ID, release.TEAM), NIGHTLY_REQUIREMENT)

    def test_the_pins_are_the_identity_guards(self):
        # cmux#47409's check-screen-share-identity.sh pins the same id and team; once it is on this branch,
        # its pins must stay equal to these.
        guard = ROOT / "scripts/ci/check-screen-share-identity.sh"
        if guard.exists():
            text = guard.read_text()
            self.assertIn(f"SHIPPED_TEAM={release.TEAM}", text)
            self.assertIn(f"{release.APP_ID}) echo {release.BUNDLE_ID} ;;", text)
        self.assertEqual((release.BUNDLE_ID, release.TEAM), ("com.cmuxterm.app.nightly.screen-sharing", "7WLXT3NR37"))

    def test_check_passes_the_nightlys_helper(self):
        code, out, err = self.run_main("check", str(self.helper), "--team", "7WLXT3NR37")
        self.assertEqual(code, 0, err)
        self.assertEqual(out.strip(), NIGHTLY_REQUIREMENT)

    def test_check_refuses_another_requirement_id_or_team(self):
        short = 'identifier "com.cmuxterm.app.nightly.screen-sharing" and anchor apple generic and ' \
                'certificate leaf[subject.OU] = "7WLXT3NR37"'
        for name, requirement in (("short", short), ("cdhash", 'cdhash H"0123"'),
                                  ("extra", NIGHTLY_REQUIREMENT + " and cdhash H\"00\"")):
            self.say(requirement)
            with self.subTest(name):
                self.assertEqual(self.run_main("check", str(self.helper), "--team", "7WLXT3NR37")[0], 1)
        self.say(NIGHTLY_REQUIREMENT)
        self.assertEqual(self.run_main("check", str(self.helper), "--team", "ABCDEFGHIJ")[0], 1)
        self.write_id("com.cmuxterm.cua")
        self.assertEqual(self.run_main("check", str(self.helper), "--team", "7WLXT3NR37")[0], 1)

    def test_record_verify_and_objects(self):
        record = self.tmp / "helper.json"
        code, _, err = self.run_main("record", "--zip", str(self.zip), "--helper", str(self.helper), "--team",
                                     "7WLXT3NR37", "--key", KEY, "--commit", COMMIT, "--out", str(record))
        self.assertEqual(code, 0, err)
        value = json.loads(record.read_text())
        self.assertEqual(value["sha256"], hashlib.sha256(b"zip bytes").hexdigest())
        self.assertEqual(value["designated_requirement"], NIGHTLY_REQUIREMENT)
        self.assertEqual(self.run_main("verify-record", str(record), "--key", KEY, "--zip", str(self.zip))[0], 0)
        self.assertEqual(self.run_main("verify-record", str(record), "--key", "f" * 16)[0], 1)
        code, out, _ = self.run_main("objects", str(record), str(self.zip))
        self.assertEqual(code, 0)
        lines = out.splitlines()
        # The zip by its own sha256 first, helper.json last.
        self.assertEqual(lines[0].split()[0], f"{release.PREFIX}/{KEY}/{value['sha256']}/{release.ZIP}")
        self.assertEqual(lines[1].split()[0], f"{release.PREFIX}/{KEY}/helper.json")
        self.zip.write_bytes(b"other")
        self.assertEqual(self.run_main("verify-record", str(record), "--zip", str(self.zip))[0], 1)

    def test_stub_app_has_the_nightlys_id_and_name(self):
        code, out, _ = self.run_main("stub-app", str(self.tmp / "stub"))
        self.assertEqual(code, 0)
        app = Path(out.strip())
        self.assertEqual(app.name, "cmux NIGHTLY.app")
        with open(app / "Contents/Info.plist", "rb") as f:
            info = plistlib.load(f)
        self.assertEqual((info["CFBundleIdentifier"], info["CFBundleName"]), ("com.cmuxterm.app.nightly", "cmux NIGHTLY"))

    def test_the_cli_and_ci_name_the_same_zip(self):
        helper_rs = (ROOT / "cmux-tui/crates/cmux-tui/src/cli/app/try_cmd/helper.rs").read_text()
        self.assertIn(f'pub(super) const ZIP: &str = "{release.ZIP}";', helper_rs)
        self.assertIn('pub(super) const KEY: &str = "screen_sharing_helper";', helper_rs)
        copy = (ROOT / "scripts/ci/mac-live-screen-sharing-helper.sh").read_text()
        self.assertEqual(set(re.findall(r"cmux-screen-sharing-helper-[a-z0-9_-]+\.zip", copy)), {release.ZIP})


if __name__ == "__main__":
    unittest.main()
