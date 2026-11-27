#!/usr/bin/env python3
"""scripts/ci/ios_sim_logic_xctestrun.py drops the xctest-agent host so agent-sim runs package logic tests."""

from __future__ import annotations

import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/ios_sim_logic_xctestrun.py"
sys.path.insert(0, str(SCRIPT.parent))

import ios_sim_logic_xctestrun as m  # noqa: E402

AGENT = "__PLATFORMS__/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/xctest"


def v2(*targets: dict) -> dict:
    return {
        "TestConfigurations": [{"Name": "Test Scheme Action", "TestTargets": list(targets)}],
        "__xctestrun_metadata__": {"FormatVersion": 2},
    }


class RewriteTests(unittest.TestCase):
    def test_package_logic_targets_lose_the_agent_host(self) -> None:
        plist = v2(
            {
                "BlueprintName": "CmuxMobileModelTests",
                "TestBundlePath": "__TESTROOT__/Debug-iphonesimulator/CmuxMobileModelTests.xctest",
                "TestHostPath": AGENT,
                "TestHostBundleIdentifier": "com.apple.dt.xctest.tool",
                "EnvironmentVariables": {"A": "1"},
            },
            {
                "BlueprintName": "CmuxMobileAuthTests",
                "TestBundlePath": "__TESTROOT__/Debug-iphonesimulator/CmuxMobileAuthTests.xctest",
                "TestHostPath": AGENT,
            },
        )
        changed = m.rewrite(plist)
        self.assertEqual(len(changed), 2)
        for t in plist["TestConfigurations"][0]["TestTargets"]:
            self.assertNotIn("TestHostPath", t)
            self.assertNotIn("TestHostBundleIdentifier", t)
        self.assertEqual(plist["TestConfigurations"][0]["TestTargets"][0]["EnvironmentVariables"], {"A": "1"})

    def test_app_hosted_and_ui_targets_stay(self) -> None:
        app = {
            "BlueprintName": "AppTests",
            "TestBundlePath": "__TESTHOST__/PlugIns/AppTests.xctest",
            "TestHostPath": "__TESTROOT__/Debug-iphonesimulator/App.app",
        }
        ui = {
            "BlueprintName": "AppUITests",
            "IsUITestBundle": True,
            "TestBundlePath": "__TESTHOST__/PlugIns/AppUITests.xctest",
            "TestHostPath": "__TESTROOT__/Debug-iphonesimulator/AppUITests-Runner.app",
        }
        plist = v2(dict(app), dict(ui))
        self.assertEqual(m.rewrite(plist), [])
        self.assertEqual(plist["TestConfigurations"][0]["TestTargets"], [app, ui])

    def test_host_relative_bundle_is_left_alone(self) -> None:
        t = {"BlueprintName": "X", "TestBundlePath": "__TESTHOST__/X.xctest", "TestHostPath": AGENT}
        plist = v2(dict(t))
        self.assertEqual(m.rewrite(plist), [])
        self.assertEqual(plist["TestConfigurations"][0]["TestTargets"][0], t)

    def test_format_version_1(self) -> None:
        plist = {
            "KitTests": {"TestBundlePath": "__TESTROOT__/Debug-iphonesimulator/KitTests.xctest", "TestHostPath": AGENT},
            "__xctestrun_metadata__": {"FormatVersion": 1},
        }
        self.assertEqual(len(m.rewrite(plist)), 1)
        self.assertNotIn("TestHostPath", plist["KitTests"])

    def test_cli_writes_beside_the_input(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            src = Path(d) / "Kit.xctestrun"
            dst = Path(d) / "Kit.logic.xctestrun"
            src.write_bytes(
                plistlib.dumps(v2({"BlueprintName": "T", "TestBundlePath": "__TESTROOT__/T.xctest", "TestHostPath": AGENT}))
            )
            out = subprocess.run(
                [sys.executable, "-I", str(SCRIPT), str(src), str(dst)], capture_output=True, text=True, check=True
            ).stdout
            self.assertIn("1 logic-test target(s)", out)
            got = plistlib.loads(dst.read_bytes())
            self.assertNotIn("TestHostPath", got["TestConfigurations"][0]["TestTargets"][0])

    def test_linux_runner_uses_it(self) -> None:
        text = (ROOT / "scripts/ci/ios-sim-linux-test.sh").read_text()
        self.assertIn("ios_sim_logic_xctestrun.py", text)


if __name__ == "__main__":
    unittest.main()
