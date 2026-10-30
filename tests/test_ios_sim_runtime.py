#!/usr/bin/env python3
"""scripts/ci/ios_sim_runtime.py: cmux-next-ios-sim.sh runs the declared iOS runtime, not the newest.

2026-10-29: on Blacksmith macOS, which has iOS 26.5 (23F77) and iOS 27.0, the step picked the newest
available runtime and ran iOS 27.0 instead of the 23F77 the fleet declares. Run: python3 -I THIS.
"""
import json
import os
import pathlib
import subprocess
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts/ci/ios_sim_runtime.py"
SCRIPT = ROOT / "scripts/ci/cmux-next-ios-sim.sh"


def runtime(version, build, phones=("iPhone 17 Pro", "iPhone 17"), available=True):
    ident = "com.apple.CoreSimulator.SimRuntime.iOS-" + version.replace(".", "-")
    return {
        "isAvailable": available, "platform": "iOS", "version": version, "buildversion": build,
        "identifier": ident, "name": f"iOS {version}",
        "supportedDeviceTypes": [
            {"name": p, "identifier": "com.apple.CoreSimulator.SimDeviceType." + p.replace(" ", "-")} for p in phones
        ],
    }


BLACKSMITH = {"runtimes": [runtime("26.5", "23F77"), runtime("27.0", "24A434")], "devicetypes": []}


def run(listing, declared=None):
    env = {k: v for k, v in os.environ.items() if k != "CMUX_CI_IOS_SIM_RUNTIME"}
    if declared is not None:
        env["CMUX_CI_IOS_SIM_RUNTIME"] = declared
    return subprocess.run([sys.executable, "-I", str(HELPER)], input=json.dumps(listing), env=env,
                          capture_output=True, text=True)


class IOSSimRuntimeTest(unittest.TestCase):
    def test_declared_runtime_wins_over_a_newer_one(self):
        p = run(BLACKSMITH, "23F77")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.split(), ["com.apple.CoreSimulator.SimRuntime.iOS-26-5",
                                            "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"])

    def test_declared_list_takes_the_newest_declared(self):
        listing = {"runtimes": [runtime("26.3", "23D8133"), runtime("26.5", "23F77"), runtime("27.0", "24A434")]}
        p = run(listing, "23D8133, 23F77")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.split()[0], "com.apple.CoreSimulator.SimRuntime.iOS-26-5")

    def test_missing_declared_runtime_fails_clearly(self):
        listing = {"runtimes": [runtime("26.5", "23F77", available=False), runtime("27.0", "24A434")]}
        p = run(listing, "23F77")
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(p.stdout, "")
        self.assertIn("declared iOS simulator runtime 23F77", p.stderr)
        self.assertIn("iOS 27.0 (24A434)", p.stderr)

    def test_bad_declaration_is_refused(self):
        p = run(BLACKSMITH, "iOS-26-5")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("wants simulator runtime builds", p.stderr)

    def test_unset_keeps_the_newest_outside_the_fleet(self):
        for declared in (None, ""):
            p = run(BLACKSMITH, declared)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(p.stdout.split()[0], "com.apple.CoreSimulator.SimRuntime.iOS-27-0")

    def test_falls_back_to_another_iphone(self):
        p = run({"runtimes": [runtime("26.5", "23F77", phones=("iPad Pro", "iPhone Air"))]}, "23F77")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.split()[1], "com.apple.CoreSimulator.SimDeviceType.iPhone-Air")

    def test_step_script_selects_through_the_helper(self):
        text = SCRIPT.read_text()
        self.assertIn("python3 -I scripts/ci/ios_sim_runtime.py", text)
        # Chosen before the build, so a host without the runtime fails in seconds.
        self.assertLess(text.index("scripts/ci/ios_sim_runtime.py"), text.index("# --- Build ---"))
        self.assertNotIn('rts.sort(', text)


if __name__ == "__main__":
    unittest.main()
