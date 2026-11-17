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
- cmux-remote (the supervisor and its two workers, docs/cmux-remote.md) ships in the same helper,
  Contents/MacOS/cmux-remote, with libWebRTC.dylib and the pinned Cua Driver SDK in its
  Contents/Frameworks (scripts/cmux-next/bundle-cmux-remote.sh). The layout check requires it in
  every release app, the nightly builds it in with no flag, and every signer signs its dylibs, then
  it with com.cmuxterm.cua, before it seals the helper. DEV's "cmux Computer Use (dev).app" carries
  it with com.cmuxterm.cua.dev.

    python3 tests/test_one_permission_identity.py
"""

from __future__ import annotations

import os
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERIFY = ROOT / "scripts/ci/verify-computer-use-helper.sh"
BUNDLE = ROOT / "scripts/cmux-next/bundle-screen-sharing-helper.sh"
ASSEMBLE = ROOT / "scripts/ci/nightly-steps/app-assemble-computer-use-helper.sh"
REMOTE_BUNDLE = ROOT / "scripts/cmux-next/bundle-cmux-remote.sh"
HELPER = "Contents/Library/cmux Computer Use.app"
HELPER_ID = "com.cmuxterm.cua"
REMOTE = "Contents/MacOS/cmux-remote"
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


def macho(cpu: int) -> bytes:
    """A thin 64-bit Mach-O header for one CPU type (enough for the layout check's slice read)."""
    return struct.pack("<IIi", 0xFEEDFACF, cpu, 0) + bytes(20)


ARM64, X86_64 = 0x0100000C, 0x01000007


def fat(*cpus: int) -> bytes:
    data = struct.pack(">II", 0xCAFEBABE, len(cpus))
    for cpu in cpus:
        data += struct.pack(">iiIII", cpu, 0, 0, 0, 0)
    return data


def make_app(root: Path, *, nested: bool = True, separate: bool = False, other: str = "",
             real: bool = False, remote: bytes | None = None, sdk: bool = True, webrtc: bool = True) -> Path:
    """A cmux NIGHTLY layout: the Computer Use helper with cmux-remote, its dylibs and resources
    inside (bundle-cmux-remote.sh), with or without the screen sharing executable, plus a
    separate "<app> Screen Sharing.app" or another app when asked. remote=b"" leaves cmux-remote out."""
    app = root / "cmux NIGHTLY.app"
    write_plist(app / "Contents/Info.plist", {"CFBundleIdentifier": "com.cmuxterm.app.nightly",
                                              "CFBundleName": "cmux NIGHTLY", "CFBundleExecutable": "cmux"})
    helper = app / HELPER
    write_plist(helper / "Contents/Info.plist", {"CFBundleIdentifier": HELPER_ID, "CFBundleExecutable": "cmux-cua",
                                                 "CFBundlePackageType": "APPL", "CFBundleVersion": "1"})
    executable(helper / "Contents/MacOS/cmux-cua", None if real else b"#!/bin/sh\n")
    if remote != b"":
        executable(helper / REMOTE, None if real else (remote or macho(ARM64)))
        resources = helper / "Contents/Resources/CmuxRemote_CmuxRemoteScreenSharing.bundle/Contents/Resources"
        resources.mkdir(parents=True, exist_ok=True)
        (resources / "strings.json").write_text("{}")
        for name, wanted in (("libWebRTC.dylib", webrtc), ("libcua_driver_sdk.dylib", sdk)):
            if wanted:
                (helper / "Contents/Frameworks").mkdir(parents=True, exist_ok=True)
                if real:  # signed Mach-O code, which the helper's real seal accepts as nested code
                    shutil.copy("/usr/bin/true", helper / "Contents/Frameworks" / name)
                else:
                    (helper / "Contents/Frameworks" / name).write_bytes(macho(ARM64))
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

    # cmux-remote, the supervisor and its workers, ships inside the helper in every Release, NIGHTLY
    # and RC app (scripts/cmux-next/bundle-cmux-remote.sh): there is no second bundle for it.

    def test_contents_library_holds_exactly_the_helper_and_it_carries_cmux_remote(self) -> None:
        app = make_app(self.tmp)
        self.assertEqual(sorted(p.name for p in (app / "Contents/Library").iterdir()), ["cmux Computer Use.app"])
        result = run("bash", VERIFY, "layout", app)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("cmux-remote (layout; arm64)", result.stdout)

    def test_a_helper_without_cmux_remote_fails(self) -> None:
        result = run("bash", VERIFY, "layout", make_app(self.tmp, remote=b""))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no executable Contents/MacOS/cmux-remote", result.stderr)

    def test_a_separate_cmux_remote_app_beside_the_helper_fails(self) -> None:
        # The bundle the supervisor used to ship in is a second permission identity.
        result = run("bash", VERIFY, "layout", make_app(self.tmp, other="cmux Supervisor.app"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("second permission identity", result.stderr)

    def test_cmux_remote_needs_what_it_loads(self) -> None:
        for kwargs, needle in (({"webrtc": False}, "libWebRTC.dylib"), ({"sdk": False}, "libcua_driver_sdk.dylib")):
            with self.subTest(**kwargs):
                shutil.rmtree(self.tmp / "cmux NIGHTLY.app", ignore_errors=True)
                result = run("bash", VERIFY, "layout", make_app(self.tmp, **kwargs))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(needle, result.stderr)

    def test_the_arm64_only_sdk_is_not_needed_without_an_arm64_slice(self) -> None:
        # The thin x86_64 variant drops the arm64-only Cua Driver SDK (drop-cua-sdk-without-arch.sh);
        # a universal cmux-remote still needs it.
        result = run("bash", VERIFY, "layout", make_app(self.tmp, remote=macho(X86_64), sdk=False))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("(layout; x86_64)", result.stdout)
        shutil.rmtree(self.tmp / "cmux NIGHTLY.app")
        result = run("bash", VERIFY, "layout", make_app(self.tmp, remote=fat(X86_64, ARM64), sdk=False))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("libcua_driver_sdk.dylib", result.stderr)

    def test_a_cmux_remote_that_is_not_mach_o_fails(self) -> None:
        result = run("bash", VERIFY, "layout", make_app(self.tmp, remote=b"#!/bin/sh\n"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cmux-remote is not a Mach-O executable", result.stderr)


class DropSdkWithoutArch(unittest.TestCase):
    """drop-cua-sdk-without-arch.sh: the x86_64 variant leaves the arm64-only SDK out before thinning."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="one-permission-identity-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.lipo = self.tmp / "lipo"
        # -verify_arch ARCH succeeds only for arm64, as the pinned SDK.
        self.lipo.write_text('#!/bin/sh\nif [ "$2" = -verify_arch ]; then [ "$3" = arm64 ]; exit; fi\necho arm64\n')
        self.lipo.chmod(0o755)

    def test_x86_64_drops_it_and_arm64_keeps_it(self) -> None:
        script = ROOT / "scripts/cmux-next/drop-cua-sdk-without-arch.sh"
        for arch, kept in (("arm64", True), ("x86_64", False)):
            with self.subTest(arch=arch):
                app = make_app(self.tmp)
                sdk = app / HELPER / "Contents/Frameworks/libcua_driver_sdk.dylib"
                result = run("bash", script, app, arch, env={"CMUX_LIPO_TOOL": str(self.lipo)})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(sdk.exists(), kept)
                self.assertTrue((app / HELPER / "Contents/Frameworks/libWebRTC.dylib").exists())
                shutil.rmtree(app)


class Wiring(unittest.TestCase):
    """The nightly and every signer put and sign the executable inside the Computer Use helper."""

    def test_the_nightly_moves_it_in_after_assembling_the_helper_and_before_the_layout_check(self) -> None:
        text = ASSEMBLE.read_text()
        built = text.index("build-cmux-cua.sh")
        moved = text.index("bundle-screen-sharing-helper.sh --into-computer-use")
        checked = text.index("verify-computer-use-helper.sh layout")
        self.assertLess(built, moved)
        self.assertLess(moved, checked)

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


class RemoteWiring(unittest.TestCase):
    """cmux-remote is built into the Computer Use helper on every Release path, and signed as it."""

    def test_the_nightly_bundles_cmux_remote_into_the_helper_before_the_layout_check(self) -> None:
        text = ASSEMBLE.read_text()
        built = text.index("build-cmux-cua.sh")
        bundled = text.index("bundle-cmux-remote.sh --into")
        checked = text.index("verify-computer-use-helper.sh layout")
        self.assertLess(built, bundled)
        self.assertLess(bundled, checked)
        call = text[bundled:checked]
        self.assertIn('"$app/Contents/Library/cmux Computer Use.app"', call)
        self.assertIn("--identifier com.cmuxterm.cua", call)
        self.assertIn('--archs "$archs"', call)
        self.assertNotIn("if ", call, "no flag: every Release, NIGHTLY and RC app carries it")

    def test_the_nightly_fetch_fills_the_sdk_cache_the_assembly_reads(self) -> None:
        text = (ROOT / "scripts/ci/nightly-steps/app-fetch-chromium-engine.sh").read_text()
        self.assertIn("ensure-cua-pinned-asset.sh scripts/cmux-next/cua-driver-sdk.pin.json", text)

    def test_the_bundle_script_signs_cmux_remote_with_the_given_identifier_after_its_dylibs(self) -> None:
        text = REMOTE_BUNDLE.read_text()
        dylibs = text.index('--force --sign - --timestamp=none "$dylib"')
        remote = text.index('--identifier "$identifier" "$contents/MacOS/$EXECUTABLE"')
        seal = text.index('--requirements "=designated => identifier \\"$identifier\\"" "$helper"')
        self.assertLess(dylibs, remote)
        self.assertLess(remote, seal)

    def test_the_dev_helper_carries_it_with_the_dev_identifier(self) -> None:
        build = (ROOT / "scripts/cmux-next/build-cua-helper-dev.sh").read_text()
        self.assertIn('bundle-cmux-remote.sh" --into "$app" --identifier "$BUNDLE_ID" --archs arm64 --no-seal', build)
        sign = (ROOT / "scripts/cmux-next/sign-cua-helper-dev.sh").read_text()
        nested = sign.index('sign --identifier com.cmuxterm.cua.dev "$app/Contents/MacOS/cmux-remote"')
        self.assertLess(sign.index('sign "$app/Contents/Frameworks/libWebRTC.dylib"'), nested)
        self.assertLess(nested, sign.index('sign "$app"\n'))

    def test_every_mac_signer_signs_cmux_remote_with_the_helper_identifier_before_the_helper(self) -> None:
        for script, helper in (
            ("scripts/sign-cmux-bundle.sh", '"$COMPUTER_USE_HELPER"\n  fi'),
            ("scripts/ci/notarize-computer-use-helper.sh",
             'for helper in "${NESTED_HELPERS[@]}"; do\n    # The Screen Sharing helper needs no entitlements.'),
        ):
            with self.subTest(script=script):
                text = (ROOT / script).read_text()
                loop = text.index("for nested_exe in cmux-screen-sharing cmux-remote" if "sign-cmux" in script
                                  else "for nested in cmux-screen-sharing cmux-remote")
                dylibs = text.index('Contents/Frameworks/"*.dylib')
                self.assertLess(dylibs, loop)
                self.assertLess(loop, text.index(helper))
                self.assertIn("--identifier com.cmuxterm.cua", text[loop:text.index(helper)])

    def test_the_rcodesign_signer_scopes_the_identifier_to_cmux_remote(self) -> None:
        text = (ROOT / "scripts/ci/rcodesign-sign-bundle.sh").read_text()
        self.assertIn("for nested_exe in cmux-screen-sharing cmux-remote", text)
        self.assertIn('"Contents/MacOS/$nested_exe:com.cmuxterm.cua"', text)
        self.assertIn('"Contents/MacOS/$nested_exe:runtime"', text)

    def test_the_architecture_gate_covers_cmux_remote_and_its_dylibs(self) -> None:
        text = (ROOT / "scripts/ci/nightly-steps/prepare-verify-binary-architectures.sh").read_text()
        self.assertIn("cmux Computer Use.app/Contents/MacOS/cmux-remote", text)
        self.assertIn("cmux Computer Use.app/Contents/Frameworks/libWebRTC.dylib", text)
        self.assertIn("cmux Computer Use.app/Contents/Frameworks/libcua_driver_sdk.dylib", text)
        thin = (ROOT / "scripts/ci/nightly-steps/prepare-thin-bundle.sh").read_text()
        self.assertLess(thin.index("drop-cua-sdk-without-arch.sh build-universal"), thin.index("thin-app-bundle.sh"))

    def test_a_helper_rebuild_keeps_cmux_remote_and_what_it_loads(self) -> None:
        text = (ROOT / "scripts/build-cmux-cua.sh").read_text()
        for kept in ('"$HELPER_APP/Contents/MacOS/cmux-remote"', '"$HELPER_APP/Contents/Frameworks"',
                     '"$HELPER_APP/Contents/Resources/"*.bundle'):
            self.assertIn(kept, text)
        self.assertIn("for _kept in cmux-screen-sharing cmux-remote; do", text)

    def test_no_build_phase_embeds_a_second_bundle(self) -> None:
        # The Xcode phase that embeds the DEV helper embeds nothing else into Contents/Library.
        project = (ROOT / "cmux.xcodeproj/project.pbxproj").read_text()
        phase = project[project.index("/* Embed Computer Use helper (dev) */ = {"):]
        phase = phase[:phase.index("};")]
        outputs = phase[phase.index("outputPaths = ("):]
        self.assertEqual([line.strip() for line in outputs.splitlines() if "Contents/Library/" in line],
                         ['"$(TARGET_BUILD_DIR)/$(WRAPPER_NAME)/Contents/Library/cmux Computer Use (dev).app",'])


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

    def test_cmux_remote_signed_as_the_helper_keeps_its_identity_through_the_screen_sharing_move(self) -> None:
        # bundle-cmux-remote.sh's signing order with the real codesign: the dylibs, cmux-remote with
        # the helper's identifier, the helper's seal; then the screen sharing executable moves in and
        # re-seals the helper. One app in Contents/Library, both executables the helper's identifier.
        app = make_app(self.tmp, nested=False, real=True)
        helper = app / HELPER
        sign = ROOT / "scripts/codesign-retry.sh"
        for dylib in sorted((helper / "Contents/Frameworks").iterdir()):
            result = run("bash", sign, "--force", "--sign", "-", "--timestamp=none", dylib)
            self.assertEqual(result.returncode, 0, result.stderr)
        result = run("bash", sign, "--force", "--sign", "-", "--timestamp=none", "--identifier", HELPER_ID, helper / REMOTE)
        self.assertEqual(result.returncode, 0, result.stderr)
        result = run("bash", sign, "--force", "--sign", "-", "--timestamp=none", "--identifier", HELPER_ID,
                     "--requirements", f'=designated => identifier "{HELPER_ID}"', helper)
        self.assertEqual(result.returncode, 0, result.stderr)
        result = run("bash", BUNDLE, "--into-computer-use", app, env={"CMUX_NEXT_SCREEN_HELPER_BIN": str(self.bin)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_one_identity(app)
        self.assertEqual(self.codesign_identifier(helper / REMOTE), HELPER_ID)
        result = run("/usr/bin/codesign", "--verify", "--strict", "-R", f'=identifier "{HELPER_ID}"', helper / REMOTE)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
