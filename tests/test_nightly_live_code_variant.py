#!/usr/bin/env python3
"""The live code variant builds with the nightly's own flags (scripts/ci/nightly-steps/app-build-live-code.sh).

app-build-release.sh is run with every helper it calls stubbed and xcodebuild recording its arguments:
1. Without CMUX_LIVE_CODE_BUILD the nightly's xcodebuild arguments do not change (the default nightly stays
   byte-identical).
2. With it, the live code settings are passed, and the one OTHER_SWIFT_FLAGS keeps decide's -DCMUX_NO_* import
   defines and the nightly-next defines beside the live code define (a second OTHER_SWIFT_FLAGS on the command line
   would replace the first).
3. The variant never uses the nightly's kept build root or the fleet compilation cache.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RELEASE = "scripts/ci/nightly-steps/app-build-release.sh"
LIVE = "scripts/ci/nightly-steps/app-build-live-code.sh"
# The live code settings are the real ones (scripts/live-code/lib/xcodebuild-args.sh, which reads Package.swift).
REAL = (RELEASE, LIVE, "scripts/live-code/lib/xcodebuild-args.sh", "Packages/macOS/CmuxNext/Package.swift")
VARIANT = ROOT / "scripts/ci/nightly-steps/app-build-live-code.sh"

STUBS = {
    "scripts/ci/fleet-compilation-cache.sh": "",
    "scripts/cmux-next/lib/compilation-cache.sh": "cmux_next_runtime_cas_failed() { return 1; }\n",
    "scripts/ci/nightly-steps/app-host-build-root.sh": 'host_root=""\nbuild_root="$PWD"\nderived_data=dd\n',
    "scripts/cmux-next/lib/nightly-swift-defines.sh": 'CMUX_NIGHTLY_NEXT_SWIFT_DEFINES="-DCMUX_BLOCKING_CHECKS"\n',
    "scripts/ci/run-with-helper-prebuild.py": (
        "import os, sys\nargs = sys.argv[sys.argv.index('--') + 1:]\nos.execvp(args[0], args)\n"),
    "scripts/cmux-next/cef-cache-root.sh": "#!/bin/sh\necho /tmp/cef\n",
    "scripts/ci/run-xcodebuild-with-diagnostics.sh": '#!/bin/bash\nshift\nexec "$@"\n',
}


class NightlyLiveCodeVariant(unittest.TestCase):
    def build(self, **env: str) -> list[str]:
        with tempfile.TemporaryDirectory() as temp:
            tree = Path(temp) / "tree"
            (tree / RELEASE).parent.mkdir(parents=True)
            for rel in REAL:
                (tree / rel).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy(ROOT / rel, tree / rel)
            for rel, text in STUBS.items():
                (tree / rel).parent.mkdir(parents=True, exist_ok=True)
                (tree / rel).write_text(text)
                (tree / rel).chmod(0o755)
            bindir = Path(temp) / "bin"
            bindir.mkdir()
            record = Path(temp) / "args"
            xcodebuild = bindir / "xcodebuild"
            xcodebuild.write_text(f'#!/bin/sh\nfor a in "$@"; do printf "%s\\n" "$a"; done > "{record}"\n')
            xcodebuild.chmod(0o755)
            full = {"PATH": f"{bindir}:{os.environ['PATH']}", "HOME": temp, "RUNNER_TEMP": temp,
                    "IMPORT_VARIANT": "compiled-out", "SWIFT_IMPORT_FLAGS": "-DCMUX_NO_BROWSER_IMPORT",
                    "EMPTY_BROWSER_SOURCES": "false", "BUILD_TRACK": "", "NIGHTLY_COMPILE_ARCHS": "arm64",
                    "CHANNEL_ICON_NAME": "AppIcon", "DECIDE_COLD_CACHE_DISABLE": "", **env}
            subprocess.run(["bash", RELEASE], cwd=tree, env=full, check=True, capture_output=True, text=True)
            return record.read_text().splitlines()

    def test_the_default_nightly_build_is_unchanged(self) -> None:
        args = self.build()
        self.assertEqual([a for a in args if a.startswith("OTHER_SWIFT_FLAGS=")],
                         ["OTHER_SWIFT_FLAGS=$(inherited) -DCMUX_NO_BROWSER_IMPORT"])
        self.assertFalse([a for a in args if a.startswith(("SWIFT_OPTIMIZATION_LEVEL=", "OTHER_LDFLAGS=",
                                                           "LD_EXPORT_SYMBOLS=", "CMUX_LIVE_CODE_"))])
        self.assertEqual(args[-1], "build")

    def test_the_variant_keeps_the_nightly_defines_in_one_swift_flags(self) -> None:
        for track, defines in (("", "-DCMUX_NO_BROWSER_IMPORT -DCMUX_LIVE_CODE"),
                               ("nightly-next", "-DCMUX_NO_BROWSER_IMPORT -DCMUX_BLOCKING_CHECKS -DCMUX_LIVE_CODE")):
            with self.subTest(track=track):
                args = self.build(CMUX_LIVE_CODE_BUILD="1", BUILD_TRACK=track)
                self.assertEqual([a for a in args if a.startswith("OTHER_SWIFT_FLAGS=")],
                                 [f"OTHER_SWIFT_FLAGS=$(inherited) {defines}"])
                self.assertIn("CMUX_LIVE_CODE_OPT_CmuxNextApp=-Onone", args)
                self.assertIn("CMUX_LIVE_CODE_OPT_CmuxNextAgentPane=-Onone", args)
                self.assertIn("LD_EXPORT_SYMBOLS=YES", args)
                self.assertIn("OTHER_LDFLAGS=$(inherited) -Xlinker -no_fixup_chains", args)
                self.assertEqual(args[-1], "build")

    def test_the_relink_passes_the_list(self) -> None:
        args = self.build(CMUX_LIVE_CODE_BUILD="1", CMUX_LIVE_CODE_INTERPOSABLE_LIST="/tmp/list.txt")
        self.assertIn("OTHER_LDFLAGS=$(inherited) -Xlinker -no_fixup_chains -Xlinker -interposable_list "
                      "-Xlinker \"/tmp/list.txt\"", args)

    def variant(self, check_status: int) -> subprocess.CompletedProcess:
        """app-build-live-code.sh with the release build and the two passes stubbed: each release build records
        whether it got the list, and live_code_check returns check_status."""
        with tempfile.TemporaryDirectory() as temp:
            tree = Path(temp) / "tree"
            (tree / LIVE).parent.mkdir(parents=True)
            shutil.copy(ROOT / LIVE, tree / LIVE)
            builds = Path(temp) / "builds"
            (tree / RELEASE).write_text(
                "set -eu\napp=build-universal/Build/Products/Release/cmux.app/Contents/MacOS\nmkdir -p $app\n"
                ": > $app/cmux\necho log > \"$RUNNER_TEMP/nightly-release-build.log\"\n"
                f'echo "${{CMUX_LIVE_CODE_BUILD:-}} ${{CMUX_NIGHTLY_HOST_BUILD_ROOT:-}} '
                f'${{CMUX_LIVE_CODE_INTERPOSABLE_LIST:-none}}" >> "{builds}"\n')
            lib = tree / "scripts/live-code/lib/two-pass.sh"
            lib.parent.mkdir(parents=True)
            lib.write_text('live_code_list() { echo sym > "$2/interposable.txt"; }\n'
                           f'live_code_check() {{ echo {{}} > "$2/cost.json"; return {check_status}; }}\n')
            out = Path(temp) / "out"
            result = subprocess.run(["bash", LIVE, str(out)], cwd=tree, capture_output=True, text=True,
                                    env={"PATH": os.environ["PATH"], "RUNNER_TEMP": temp})
            result.builds = builds.read_text().splitlines() if builds.exists() else []  # type: ignore[attr-defined]
            result.files = sorted(p.name for p in out.iterdir()) if out.exists() else []  # type: ignore[attr-defined]
            return result

    def test_the_variant_builds_twice_then_checks(self) -> None:
        result = self.variant(0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.builds[0], "1 0 none")
        self.assertTrue(result.builds[1].startswith("1 0 /") and result.builds[1].endswith("/interposable.txt"))
        self.assertEqual(len(result.builds), 2)
        self.assertIn("app-path", result.files)
        self.assertIn("xcodebuild.log", result.files)

    def test_a_failed_bind_check_fails_the_variant(self) -> None:
        result = self.variant(1)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("app-path", result.files)

    def test_the_variant_keeps_off_the_nightly_build_state(self) -> None:
        text = VARIANT.read_text()
        self.assertIn("CMUX_NIGHTLY_HOST_BUILD_ROOT=0", text)
        self.assertIn("DECIDE_COLD_CACHE_DISABLE=1", text)
        self.assertNotIn("codesign", text)


if __name__ == "__main__":
    unittest.main()
