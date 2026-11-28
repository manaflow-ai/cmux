#!/usr/bin/env python3
"""The kit job's simulator tests reuse the pool build (Xcode's build/test split) instead of building twice.

"Build the iOS simulator tests for the pool" runs `xcodebuild build-for-testing` into the job's DerivedData. The
simulator test step, its Mac fallback and the iOS bench then ran `xcodebuild test`, which built it all again for the
concrete destination: base run 46148625284 spent 209 s building, 478 s in the test step (200 to 260 s of tests) and
197 s in the bench step. With the products there, scripts/ci/ios-kit-sim-mac-test.sh and the bench run
`test-without-building`; without them they build and test as before.
Leo, 2026-11-27 (ask-3ff6f851cf): "potentially the build/test dichotomy that xcode sometimes have too...".

  python3 tests/test_ios_kit_sim_test_without_building.py
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/ios-kit-sim-mac-test.sh"
WORKFLOW = ROOT / ".github/workflows/cmux-next-ios-kit.yml"

FAKE_XCRUN = """#!/bin/bash
if [[ "$1 $2" == "simctl list" ]]; then
  echo '{"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-0": [{"name": "iPhone 17", "udid": "U-1"}]}}'
fi
exit 0
"""
FAKE_XCODEBUILD = """#!/bin/bash
echo "$1" >> "$XCB_LOG"
exit 0
"""


def steps() -> dict:
    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    return {s.get("id") or s.get("name"): s for s in workflow["jobs"]["kit-tests"]["steps"]}


class ScriptTest(unittest.TestCase):
    def run_script(self, prebuilt: str, xctestrun: bool) -> list[str]:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            bin_dir = tmp_path / "bin"
            bin_dir.mkdir()
            for name, body in (("xcrun", FAKE_XCRUN), ("xcodebuild", FAKE_XCODEBUILD)):
                (bin_dir / name).write_text(body, encoding="utf-8")
                (bin_dir / name).chmod(0o755)
            derived = tmp_path / "dd"
            (derived / "Build/Products").mkdir(parents=True)
            if xctestrun:
                (derived / "Build/Products/CmuxMobileKit-Package_iphonesimulator26.0-arm64.xctestrun").write_text(
                    "", encoding="utf-8")
            log = tmp_path / "xcb.log"
            env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", RUNNER_TEMP=tmp,
                       CMUX_DERIVED_DATA_SLOT=str(derived), GITHUB_OUTPUT=str(tmp_path / "out"),
                       GITHUB_STEP_SUMMARY=str(tmp_path / "summary"), XCB_LOG=str(log),
                       KIT_SIM_PART="mac", CMUX_IOS_SIM_LINUX="shadow", KIT_SIM_PREBUILT=prebuilt)
            done = subprocess.run(["bash", str(SCRIPT)], cwd=ROOT / "cmux-next-ios/CmuxMobileKit", env=env,
                                  capture_output=True, text=True, timeout=60)
            self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
            return log.read_text(encoding="utf-8").split()

    @unittest.skipUnless(shutil.which("python3"), "needs python3")
    def test_pool_build_products_run_without_building(self):
        self.assertEqual(self.run_script("success", True), ["test-without-building"])

    def test_no_products_build_and_test_as_before(self):
        self.assertEqual(self.run_script("success", False), ["test"])
        self.assertEqual(self.run_script("skipped", True), ["test"])
        self.assertEqual(self.run_script("", True), ["test"])


class WorkflowTest(unittest.TestCase):
    def test_each_simulator_step_reads_the_pool_build_outcome(self):
        by_id = steps()
        self.assertIn("build-for-testing", by_id["sim-pack"]["run"])
        for step_id in ("ios-sim", "ios-sim-fallback", "bench-ios"):
            self.assertEqual(by_id[step_id]["env"]["KIT_SIM_PREBUILT"], "${{ steps.sim-pack.outcome }}", step_id)
        self.assertIn('xcodebuild "$action"', by_id["bench-ios"]["run"])
        self.assertIn("test-without-building", by_id["bench-ios"]["run"])


if __name__ == "__main__":
    unittest.main()
