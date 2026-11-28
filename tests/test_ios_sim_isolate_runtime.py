#!/usr/bin/env python3
"""Regression: the isolated simulator helper picks a runtime that supports the base device."""

from __future__ import annotations

import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "lib" / "ios-sim-isolate.sh"

# Mirrors the Xcode 27.2 layout from #38748: iOS 27.1 lists no iPhone 17.
RUNTIMES = {
    "runtimes": [
        {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-0", "platform": "iOS", "version": "26.0",
         "isAvailable": True, "supportedDeviceTypes": [{"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17"}]},
        {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "platform": "iOS", "version": "27.0",
         "isAvailable": True, "supportedDeviceTypes": [{"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17"}]},
        {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-1", "platform": "iOS", "version": "27.1",
         "isAvailable": True, "supportedDeviceTypes": []},
    ]
}
DEVICE_TYPES = {
    "devicetypes": [
        {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17", "name": "iPhone 17"},
        {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-Air", "name": "iPhone Air"},
    ]
}

FAKE_XCRUN = """#!/bin/bash
# Fake xcrun: serves canned simctl JSON and records `simctl create` calls.
if [ "$1" = "simctl" ] && [ "$2" = "list" ]; then
  case "$3" in
    devices) echo '{"devices": {}}' ;;
    devicetypes) cat "$FAKE_DIR/devicetypes.json" ;;
    runtimes) cat "$FAKE_DIR/runtimes.json" ;;
  esac
  exit 0
fi
if [ "$1" = "simctl" ] && [ "$2" = "create" ]; then
  echo "$@" >> "$FAKE_DIR/create.log"
  echo "UDID-FAKE"
  exit 0
fi
exit 1
"""


class IsolatedSimRuntimeTests(unittest.TestCase):
    def run_helper(self, base: str | None = None) -> tuple[subprocess.CompletedProcess, str]:
        with tempfile.TemporaryDirectory() as tmp:
            fake_dir = Path(tmp)
            (fake_dir / "runtimes.json").write_text(json.dumps(RUNTIMES))
            (fake_dir / "devicetypes.json").write_text(json.dumps(DEVICE_TYPES))
            xcrun = fake_dir / "xcrun"
            xcrun.write_text(FAKE_XCRUN)
            xcrun.chmod(xcrun.stat().st_mode | stat.S_IEXEC)
            env = dict(os.environ, PATH=f"{fake_dir}:{os.environ['PATH']}", FAKE_DIR=str(fake_dir))
            env.pop("CMUX_IOS_SIM_BASE_DEVICE", None)
            if base is not None:
                env["CMUX_IOS_SIM_BASE_DEVICE"] = base
            script = f'source "{HELPER}"; cmux_ios_isolated_sim_udid tag1'
            result = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True, timeout=60)
            log = (fake_dir / "create.log").read_text() if (fake_dir / "create.log").exists() else ""
            return result, log

    def test_create_uses_newest_runtime_that_supports_base_device(self) -> None:
        result, log = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        # iOS 27.1 has no iPhone-17 support, so the newest usable runtime is 27.0.
        self.assertIn("com.apple.CoreSimulator.SimRuntime.iOS-27-0", log)
        self.assertNotIn("iOS-27-1", log)

    def test_fails_naming_base_device_when_no_runtime_supports_it(self) -> None:
        # iPhone Air exists as a device type but no fake runtime lists it.
        result, log = self.run_helper(base="iPhone Air")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CMUX_IOS_SIM_BASE_DEVICE", result.stderr)
        self.assertEqual(log, "")


if __name__ == "__main__":
    unittest.main()
