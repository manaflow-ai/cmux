#!/usr/bin/env python3
"""scripts/ci/ios_link_ffi.sh: a Mac build is marked with its input key, so the job's next step reuses it.

The `ios` job runs ios-kit (`ios_link_ffi.sh 8`) and then ios-phone-cells (`ios_link_ffi.sh 4`) in one checkout. Only
a fleet copy was marked, so after a Mac fallback the second step built the framework again (1.9 min of Blacksmith run
45720177041). The test runs the script in a throwaway repo with the key script and the build script stubbed.
"""
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/ios_link_ffi.sh"

KEY_STUB = """import os, sys
k = os.environ.get("STUB_KEY", "")
if not k:
    sys.exit(1)
print(k)
"""

BUILD_STUB = """#!/usr/bin/env bash
echo build >> "$STUB_COUNT"
[[ "${STUB_BUILD_FAIL:-0}" == 1 ]] && exit 7
d=cmux-next-ios/CmuxMobileKit/Frameworks/CmuxMobileLinkFFI.xcframework
mkdir -p "$d"
echo plist > "$d/Info.plist"
"""


class MacBuildMarkTest(unittest.TestCase):
    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir)
        (self.dir / "scripts/ci").mkdir(parents=True)
        shutil.copy(SCRIPT, self.dir / "scripts/ci/ios_link_ffi.sh")
        (self.dir / "scripts/ci/ios_link_ffi_key.py").write_text(KEY_STUB)
        build = self.dir / "cmux-next-ios/rust/scripts/build-xcframework.sh"
        build.parent.mkdir(parents=True)
        build.write_text(BUILD_STUB)
        self.tmp = self.dir / "runner-temp"
        self.tmp.mkdir()
        self.count = self.dir / "builds.txt"

    def run_step(self, key="k1", **extra):
        env = {
            "PATH": os.environ["PATH"],
            "HOME": str(self.dir),
            "RUNNER_TEMP": str(self.tmp),
            "RUNNER_NAME": "blacksmith-6vcpu-macos-26-test",  # a hosted runner: always the Mac build
            "STUB_KEY": key,
            "STUB_COUNT": str(self.count),
            **extra,
        }
        return subprocess.run(["bash", "scripts/ci/ios_link_ffi.sh", "4"], cwd=self.dir, env=env,
                              capture_output=True, text=True)

    def builds(self):
        return len(self.count.read_text().splitlines()) if self.count.exists() else 0

    def test_second_step_reuses_a_mac_build(self):
        first = self.run_step()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.assertIn("Mac fallback", first.stdout)
        self.assertEqual((self.tmp / "link-ffi-fleet.key").read_text().strip(), "k1")
        second = self.run_step()
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertIn("an earlier step's copy", second.stdout)
        self.assertEqual(self.builds(), 1)

    def test_changed_inputs_build_again(self):
        self.assertEqual(self.run_step(key="k1").returncode, 0)
        self.assertEqual(self.run_step(key="k2").returncode, 0)
        self.assertEqual(self.builds(), 2)
        self.assertEqual((self.tmp / "link-ffi-fleet.key").read_text().strip(), "k2")

    def test_a_failed_build_marks_nothing_and_keeps_its_exit(self):
        r = self.run_step(STUB_BUILD_FAIL="1")
        self.assertEqual(r.returncode, 7, r.stdout + r.stderr)
        self.assertFalse((self.tmp / "link-ffi-fleet.key").exists())

    def test_no_key_marks_nothing(self):
        r = self.run_step(key="")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertFalse((self.tmp / "link-ffi-fleet.key").exists())
        self.assertEqual(self.run_step(key="").returncode, 0)
        self.assertEqual(self.builds(), 2)


if __name__ == "__main__":
    unittest.main()
