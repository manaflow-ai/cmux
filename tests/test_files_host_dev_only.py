#!/usr/bin/env python3
"""cmux Files (dev) never reaches a shipped build (docs/cmux-files-host.md, "Production").

The helper is dev only (Aziz, 2026-11-17): stable, NIGHTLY, RC, staging, the NEXT DEV daily,
TestFlight and every other Release-configuration product must not embed it, look for it or
change a spawn path. Two independent gates make that true by construction, and this test fails
when either one opens:

- the build: embed-files-host-dev.sh embeds only into a Debug configuration whose bundle id is
  com.cmuxterm.app.debug[.<tag>], and removes a stale copy otherwise;
- the app: FilesHost resolves the helper only in a `#if DEBUG` compile of a DEV bundle, and is
  the only place that names the launcher or the embedded path.

A normal regression test, run by hand (python3 tests/test_files_host_dev_only.py), not a CI gate.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EMBED = ROOT / "scripts/cmux-next/embed-files-host-dev.sh"
FILES_HOST_SWIFT = ROOT / "Packages/macOS/CmuxNext/Sources/CmuxNextCompat/FilesHost.swift"
PBXPROJ = ROOT / "cmux.xcodeproj/project.pbxproj"
NAME = "cmux Files (dev).app"

SHIPPED = [
    ("Release", "com.cmuxterm.app"),                     # stable
    ("Release", "com.cmuxterm.app.nightly"),             # NIGHTLY
    ("Release", "com.cmuxterm.app.nightly.cmux-next"),   # NIGHTLY (cmux NEXT)
    ("Release", "com.cmuxterm.app.rc"),                  # RC
    ("Release", "com.cmuxterm.app.staging"),             # staging
    ("Release", "com.cmuxterm.app.debug.next"),          # the NEXT DEV daily (a Release build)
    ("Release", "com.cmuxterm.app.debug.files-tcc"),     # a --release dogfood tag
    ("Debug", "com.cmuxterm.app"),                       # a Debug compile of a shipped bundle id
    ("Debug", "com.cmuxterm.app.nightly"),
    ("Debug", "com.cmuxterm.app.staging"),
    ("Debug", "com.cmuxterm.app.staging.one"),
    ("Debug", "com.cmuxterm.app.debugger"),              # not a DEV prefix
    ("Bench", "com.cmuxterm.app.debug.x"),               # any other configuration name
    ("", "com.cmuxterm.app.debug.x"),
]


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("ditto"), "the embed phase runs on macOS")
class EmbedPhaseTests(unittest.TestCase):
    """Runs the real embed script against a stub asset source that always has the helper."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        scripts = self.tmp / "scripts"
        scripts.mkdir()
        shutil.copy(EMBED, scripts / EMBED.name)
        (scripts / "files-host-dev.pin.json").write_text('{"sha256": "0", "asset": "x.zip"}\n')
        # An unsigned stand-in bundle, zipped: the asset the stub hands out for any pin.
        bundle = self.tmp / "asset" / NAME / "Contents/MacOS"
        bundle.mkdir(parents=True)
        (bundle / "cmux-files-host").write_text("#!/bin/sh\nexit 0\n")
        self.zip = self.tmp / "helper.zip"
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(self.tmp / "asset" / NAME), str(self.zip)], check=True)
        stub = scripts / "ensure-signed-pinned-asset.sh"
        stub.write_text(f"#!/bin/sh\necho '{self.zip}'\n")
        stub.chmod(0o755)
        self.script = scripts / EMBED.name
        self.build = self.tmp / "build"

    def run_phase(self, configuration: str, bundle_id: str, stale: bool = False) -> tuple[subprocess.CompletedProcess, Path]:
        app = self.build / "cmux DEV.app"
        dest = app / "Contents/Library" / NAME
        shutil.rmtree(self.build, ignore_errors=True)
        (app / "Contents").mkdir(parents=True)
        if stale:
            (dest / "Contents").mkdir(parents=True)
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": str(self.tmp),
            "TARGET_BUILD_DIR": str(self.build),
            "TARGET_TEMP_DIR": str(self.tmp / "temp"),
            "WRAPPER_NAME": "cmux DEV.app",
            "CONFIGURATION": configuration,
            "PRODUCT_BUNDLE_IDENTIFIER": bundle_id,
            "ARCHS": "arm64",
        }
        result = subprocess.run(["/bin/bash", str(self.script)], env=env, capture_output=True, text=True)
        return result, dest

    def test_no_shipped_configuration_or_bundle_embeds_it_and_a_stale_copy_goes(self) -> None:
        for configuration, bundle_id in SHIPPED:
            with self.subTest(configuration=configuration, bundle_id=bundle_id):
                result, dest = self.run_phase(configuration, bundle_id, stale=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("not embedding cmux Files (dev)", result.stdout)
                self.assertFalse(dest.exists(), "a shipped build must hold no cmux Files (dev).app")

    def test_a_debug_dev_build_takes_the_asset(self) -> None:
        # The gate opens: the unsigned stand-in is unpacked, then refused by the signature check,
        # which fails the build and leaves nothing behind.
        for bundle_id in ["com.cmuxterm.app.debug", "com.cmuxterm.app.debug.files-tcc-a"]:
            with self.subTest(bundle_id=bundle_id):
                result, dest = self.run_phase("Debug", bundle_id)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("is not signed as", result.stderr)
                self.assertFalse(dest.exists())

    def test_there_is_no_release_override(self) -> None:
        text = EMBED.read_text()
        self.assertNotRegex(text, r"IN_RELEASE|ALLOW_RELEASE|FORCE")
        result, dest = self.run_phase("Release", "com.cmuxterm.app.debug.x")
        self.assertFalse(dest.exists())


class AppGateTests(unittest.TestCase):
    def test_files_host_resolves_only_in_a_debug_compile_of_a_dev_bundle(self) -> None:
        text = FILES_HOST_SWIFT.read_text()
        flag = re.search(r"public static var isDebugBuild: Bool \{(.*?)\n    \}", text, re.S)
        self.assertIsNotNone(flag, "FilesHost.isDebugBuild is gone")
        self.assertRegex(flag.group(1), r"#if DEBUG\s+true\s+#else\s+false\s+#endif")
        init = text[text.index("public init?("):]
        guard = init[init.index("guard"):init.index("else { return nil }")]
        self.assertRegex(guard, r"^guard isDebugBuild,", "the Debug check must come first, before any disk access")
        self.assertIn('developmentBundlePrefix = "com.cmuxterm.app.debug"', text)
        self.assertNotIn("com.cmuxterm.app.staging\"", text.split("public init?(")[0].split("static let developmentBundlePrefix")[1].split("\n")[0])

    def test_only_files_host_names_the_helper_or_its_launcher(self) -> None:
        out = subprocess.run(
            ["git", "grep", "-l", "-e", '"CMUX_TUI_OWNER_LAUNCHER"', "-e", "cmux Files (dev).app/", "--",
             "Packages/macOS", "Sources", ":!*Tests*"],
            cwd=ROOT, capture_output=True, text=True,
        ).stdout.split()
        self.assertEqual(out, ["Packages/macOS/CmuxNext/Sources/CmuxNextCompat/FilesHost.swift"])

    def test_the_embed_phase_reruns_when_the_configuration_or_bundle_id_changes(self) -> None:
        text = PBXPROJ.read_text()
        phase = text[text.index("/* Embed cmux Remote (dev) */ = {"):]
        phase = phase[:phase.index("\n\t\t};")]
        inputs = phase[:phase.index("runOnlyForDeploymentPostprocessing")]
        for key in ["$(CONFIGURATION)", "$(PRODUCT_BUNDLE_IDENTIFIER)", "embed-files-host-dev.sh", "files-host-dev.pin.json"]:
            self.assertIn(key, inputs)
        # The phase runs it, before cmux Remote's script (which ends the phase with exec).
        script = phase[phase.index("shellScript = "):]
        self.assertLess(script.index("embed-files-host-dev.sh"), script.index("embed-cmux-remote-dev.sh"))

    def test_release_and_nightly_workflows_never_mention_it(self) -> None:
        workflows = ROOT / ".github/workflows"
        for path in workflows.glob("*.yml"):
            text = path.read_text()
            for needle in ["files-host", "cmux Files (dev)", "CMUX_NEXT_FILES_HOST", "CMUX_TUI_OWNER_LAUNCHER"]:
                self.assertNotIn(needle, text, f"{path.name} mentions {needle}")


if __name__ == "__main__":
    unittest.main()
