#!/usr/bin/env python3
"""Screen sharing and computer use ask for their permissions as one app: cmux Computer Use.

Lawrence: "ensure screen sharing + computer use uses same app for permissions, unless there's a
good reason for having different apps for requesting screen sharing/accessibility". A separate
helper process from the main app is the reason to stay out of cmux (a grant never relaunches it);
it is no reason for the two to differ. So a release, NIGHTLY or RC app carries one helper in
Contents/Library, "cmux Computer Use.app" (com.cmuxterm.cua, the same for every channel), and the
screen sharing executable ships inside it as Contents/MacOS/cmux-screen-sharing, signed with the
helper's identifier (scripts/cmux-next/bundle-screen-sharing-helper.sh --into-computer-use).

- scripts/ci/verify-computer-use-helper.sh (run by the nightly before and after signing, by the
  signer's Apple checks and by the re-identification scripts) fails an app whose Contents/Library
  holds any other app, such as a "<app> Screen Sharing.app" beside the Computer Use helper.
- bundle-screen-sharing-helper.sh --into-computer-use moves the executable in, signs it with the
  helper's identifier (real codesign, on a Mac) and leaves the helper's signature valid.
- The nightly moves it in after it assembles the helper and before the layout check, and every
  release signer signs it with com.cmuxterm.cua before it seals the helper.

    python3 tests/test_one_permission_identity.py
"""

from __future__ import annotations

import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERIFY = ROOT / "scripts/ci/verify-computer-use-helper.sh"
BUNDLE = ROOT / "scripts/cmux-next/bundle-screen-sharing-helper.sh"
ASSEMBLE = ROOT / "scripts/ci/nightly-steps/app-assemble-computer-use-helper.sh"
HELPER = "Contents/Library/cmux Computer Use.app"
HELPER_ID = "com.cmuxterm.cua"
ON_A_MAC = sys.platform == "darwin" and Path("/usr/bin/codesign").exists()


def write_plist(path: Path, values: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(values))


def executable(path: Path, data: bytes | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if data is None:
        shutil.copy("/usr/bin/true", path)
    else:
        path.write_bytes(data)
    path.chmod(0o755)


def make_app(root: Path, *, nested: bool = True, separate: bool = False, other: str = "",
             real: bool = False) -> Path:
    """A cmux NIGHTLY layout: the Computer Use helper, with or without the screen sharing
    executable inside, plus a separate "<app> Screen Sharing.app" or another app when asked."""
    app = root / "cmux NIGHTLY.app"
    write_plist(app / "Contents/Info.plist", {"CFBundleIdentifier": "com.cmuxterm.app.nightly",
                                              "CFBundleName": "cmux NIGHTLY", "CFBundleExecutable": "cmux"})
    helper = app / HELPER
    write_plist(helper / "Contents/Info.plist", {"CFBundleIdentifier": HELPER_ID, "CFBundleExecutable": "cmux-cua",
                                                 "CFBundlePackageType": "APPL", "CFBundleVersion": "1"})
    executable(helper / "Contents/MacOS/cmux-cua", None if real else b"#!/bin/sh\n")
    if nested:
        executable(helper / "Contents/MacOS/cmux-screen-sharing", None if real else b"#!/bin/sh\n")
    if separate:
        share = app / "Contents/Library/cmux NIGHTLY Screen Sharing.app"
        write_plist(share / "Contents/Info.plist", {"CFBundleIdentifier": "com.cmuxterm.app.nightly.screen-sharing",
                                                    "CFBundleExecutable": "cmux-screen-sharing"})
        executable(share / "Contents/MacOS/cmux-screen-sharing", None if real else b"#!/bin/sh\n")
    if other:
        write_plist(app / "Contents/Library" / other / "Contents/Info.plist", {"CFBundleIdentifier": "com.example.other"})
    return app


def run(*args: object, env: dict | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run([str(a) for a in args], capture_output=True, text=True, check=False,
                          env={**os.environ, **(env or {})})


class LayoutCheck(unittest.TestCase):
    """verify-computer-use-helper.sh layout: one helper identity in Contents/Library."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="one-permission-identity-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def test_the_helper_carrying_the_screen_sharing_executable_passes(self) -> None:
        result = run("bash", VERIFY, "layout", make_app(self.tmp))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("cmux-screen-sharing (layout)", result.stdout)

    def test_a_separate_screen_sharing_helper_beside_it_fails(self) -> None:
        result = run("bash", VERIFY, "layout", make_app(self.tmp, separate=True))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cmux NIGHTLY Screen Sharing.app", result.stderr)
        self.assertIn("second permission identity", result.stderr)

    def test_any_other_app_in_contents_library_fails(self) -> None:
        result = run("bash", VERIFY, "layout", make_app(self.tmp, other="Other Helper.app"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Other Helper.app (com.example.other)", result.stderr)

    def test_a_non_executable_screen_sharing_file_fails(self) -> None:
        app = make_app(self.tmp)
        (app / HELPER / "Contents/MacOS/cmux-screen-sharing").chmod(0o644)
        result = run("bash", VERIFY, "layout", app)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cmux-screen-sharing is not an executable file", result.stderr)


class Wiring(unittest.TestCase):
    """The nightly and every signer put and sign the executable inside the Computer Use helper."""

    def test_the_nightly_moves_it_in_after_assembling_the_helper_and_before_the_layout_check(self) -> None:
        # Two paths put the helper in place (a verified prebuilt, else a source build); each moves the
        # executable in right before its layout check, and the source build keeps its prebuilt zip
        # before that, so a reused helper never carries another build's screen sharing executable.
        text = ASSEMBLE.read_text()
        self.assertIn("bundle-screen-sharing-helper.sh --into-computer-use", text)
        code = [line.strip() for line in text.splitlines() if line.strip() and not line.lstrip().startswith("#")]
        checks = [i for i, line in enumerate(code) if line.startswith("./scripts/ci/verify-computer-use-helper.sh layout")]
        self.assertEqual(len(checks), 2, checks)
        for i in checks:
            self.assertEqual(code[i - 1], "move_screen_sharing_in", code[i - 1])
        built = text.index("./scripts/build-cmux-cua.sh")
        kept = text.index('ditto -c -k --norsrc --keepParent "$helper"')
        moved_last = text.rindex("\nmove_screen_sharing_in\n")
        self.assertLess(text.index('install_prebuilt "$zip"; then\n  move_screen_sharing_in'), built)
        self.assertLess(built, kept)
        self.assertLess(kept, moved_last)

    def test_the_architecture_gate_reads_the_executable_inside_the_helper(self) -> None:
        text = (ROOT / "scripts/ci/nightly-steps/prepare-verify-binary-architectures.sh").read_text()
        self.assertIn('cmux Computer Use.app/Contents/MacOS/cmux-screen-sharing', text)
        self.assertNotIn('" Screen Sharing.app/Contents/MacOS', text)

    def test_every_mac_signer_signs_it_with_the_helper_identifier_before_the_helper(self) -> None:
        for script, nested, helper in (
            ("scripts/sign-cmux-bundle.sh", '--identifier com.cmuxterm.cua', '"$COMPUTER_USE_HELPER"\n  fi'),
            ("scripts/ci/notarize-computer-use-helper.sh", '--identifier com.cmuxterm.cua',
             'for helper in "${NESTED_HELPERS[@]}"; do\n    # The Screen Sharing helper needs no entitlements.'),
        ):
            with self.subTest(script=script):
                text = (ROOT / script).read_text()
                self.assertIn(nested, text)
                self.assertLess(text.index(nested), text.index(helper))

    def test_the_rcodesign_signers_scope_the_identifier_to_the_executable(self) -> None:
        for script in ("scripts/ci/rcodesign-sign-bundle.sh", "scripts/ci/release-signer/sign-app.sh"):
            with self.subTest(script=script):
                text = (ROOT / script).read_text()
                self.assertIn("cmux-screen-sharing", text)
                self.assertIn("com.cmuxterm.cua", text)


@unittest.skipUnless(ON_A_MAC, "real codesign: macOS only (cmux-next-cua-helper-identity.yml)")
class IntoComputerUse(unittest.TestCase):
    """bundle-screen-sharing-helper.sh with the real codesign."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="one-permission-identity-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin = self.tmp / "bin/cmux-screen-sharing"
        executable(self.bin)

    def codesign_identifier(self, path: Path) -> str:
        result = run("/usr/bin/codesign", "-d", "--verbose=2", path)
        self.assertEqual(result.returncode, 0, result.stderr)
        return next(line.split("=", 1)[1] for line in result.stderr.splitlines() if line.startswith("Identifier="))

    def assert_one_identity(self, app: Path) -> None:
        helper = app / HELPER
        nested = helper / "Contents/MacOS/cmux-screen-sharing"
        self.assertTrue(os.access(nested, os.X_OK))
        self.assertEqual(sorted(p.name for p in (app / "Contents/Library").iterdir()), ["cmux Computer Use.app"])
        self.assertEqual(self.codesign_identifier(nested), HELPER_ID)
        self.assertEqual(self.codesign_identifier(helper), HELPER_ID)
        result = run("/usr/bin/codesign", "--verify", "--deep", "--strict", helper)
        self.assertEqual(result.returncode, 0, result.stderr)
        result = run("bash", VERIFY, "layout", app)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_the_separate_helper_the_release_build_bundled_moves_into_the_computer_use_helper(self) -> None:
        app = make_app(self.tmp, nested=False, real=True)
        # The Release build's phase, before the Computer Use helper existed: its own app.
        shutil.rmtree(app / HELPER)
        result = run("bash", BUNDLE, "--app", app, env={"CONFIGURATION": "Release", "CMUX_NEXT_SCREEN_HELPER_BIN": str(self.bin),
                                                       "CMUX_NEXT_REQUIRE_SCREEN_HELPER": "1"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((app / "Contents/Library/cmux NIGHTLY Screen Sharing.app/Contents/MacOS/cmux-screen-sharing").exists())
        # Then the helper is assembled, and the executable moves in.
        make_app(self.tmp, nested=False, real=True)
        run("/usr/bin/codesign", "--force", "--sign", "-", "--identifier", HELPER_ID, app / HELPER)
        result = run("bash", BUNDLE, "--into-computer-use", app)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_one_identity(app)
        # Release signing's --stamp then has nothing to rename.
        result = run("bash", BUNDLE, "--stamp", app)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("nothing to stamp", result.stdout)
        self.assert_one_identity(app)

    def test_from_the_build_binary_and_again(self) -> None:
        app = make_app(self.tmp, nested=False, real=True)
        run("/usr/bin/codesign", "--force", "--sign", "-", "--identifier", HELPER_ID, app / HELPER)
        for _ in range(2):
            result = run("bash", BUNDLE, "--into-computer-use", app, env={"CMUX_NEXT_SCREEN_HELPER_BIN": str(self.bin)})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assert_one_identity(app)

    def test_no_computer_use_helper_is_an_error_not_a_second_identity(self) -> None:
        app = make_app(self.tmp, nested=False, real=True)
        shutil.rmtree(app / HELPER)
        result = run("bash", BUNDLE, "--into-computer-use", app, env={"CMUX_NEXT_SCREEN_HELPER_BIN": str(self.bin)})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("build-cmux-cua.sh --helper-app first", result.stderr)

    def test_an_app_without_the_executable_is_left_alone(self) -> None:
        app = make_app(self.tmp, nested=False, real=True)
        result = run("bash", BUNDLE, "--into-computer-use", app, env={"CMUX_NEXT_SCREEN_HELPER_BIN": ""})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("carries no Screen Sharing helper", result.stdout)
        self.assertFalse((app / HELPER / "Contents/MacOS/cmux-screen-sharing").exists())


if __name__ == "__main__":
    unittest.main()
