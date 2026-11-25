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


# Identifiers that are not the name with dashes for spaces (Xcode 26 simctl list devicetypes).
REAL_IDS = {"iPhone SE (3rd generation)": "iPhone-SE-3rd-generation", "iPad mini (A17 Pro)": "iPad-mini-A17-Pro"}


def runtime(version, build, phones=("iPhone 17 Pro", "iPhone 17"), available=True):
    ident = "com.apple.CoreSimulator.SimRuntime.iOS-" + version.replace(".", "-")
    return {
        "isAvailable": available, "platform": "iOS", "version": version, "buildversion": build,
        "identifier": ident, "name": f"iOS {version}",
        "supportedDeviceTypes": [
            {"name": p, "identifier": "com.apple.CoreSimulator.SimDeviceType." + REAL_IDS.get(p, p.replace(" ", "-"))}
            for p in phones
        ],
    }


BLACKSMITH = {"runtimes": [runtime("26.5", "23F77"), runtime("27.0", "24A434")], "devicetypes": []}


def run(listing, declared=None, args=()):
    env = {k: v for k, v in os.environ.items() if k != "CMUX_CI_IOS_SIM_RUNTIME"}
    if declared is not None:
        env["CMUX_CI_IOS_SIM_RUNTIME"] = declared
    return subprocess.run([sys.executable, "-I", str(HELPER), *args], input=json.dumps(listing), env=env,
                          capture_output=True, text=True)


APPSTORE = ("--phone-class", "appstore-6.9")

SIZES = ("iPhone 17 Pro", "iPhone 17", "iPhone 16e", "iPhone 17 Pro Max", "iPhone SE (3rd generation)",
         "iPad Pro 11-inch (M5)", "iPad mini (A17 Pro)")
FLEET = {"runtimes": [runtime("26.5", "23F77", phones=SIZES)]}


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

    def test_appstore_class_takes_the_69_inch_iphone(self):
        phones = ("iPhone 17 Pro", "iPhone 16 Pro Max", "iPhone 17 Pro Max")
        p = run({"runtimes": [runtime("26.5", "23F77", phones=phones)]}, "23F77", APPSTORE)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.split()[1], "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max")

    def test_appstore_class_never_falls_back_to_another_size(self):
        p = run({"runtimes": [runtime("26.5", "23F77")]}, "23F77", APPSTORE)
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(p.stdout, "")
        self.assertIn("iPhone 17 Pro Max", p.stderr)

    def test_unknown_argument_is_refused(self):
        p = run(BLACKSMITH, "23F77", ("--phone-class", "6.7"))
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(p.stdout, "")

    def test_step_script_shoots_app_store_screens_on_the_69_inch_iphone(self):
        text = SCRIPT.read_text()
        self.assertIn("--phone-class appstore-6.9", text)
        self.assertIn("status_bar \"$udid\" override --time 9:41", text)
        self.assertIn("1320x2868", text)

    def test_default_device_is_unchanged_without_device(self):
        p = run(FLEET, "23F77")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.split(), ["com.apple.CoreSimulator.SimRuntime.iOS-26-5",
                                            "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"])
        p = run(FLEET, "23F77", ["--with-name"])
        self.assertEqual(p.stdout.split(" ", 2)[2].strip(), "iPhone 17 Pro")

    def test_device_by_name_by_commas_and_by_identifier(self):
        for want, ident, name in (
            ("iPhone 16e", "iPhone-16e", "iPhone 16e"),
            ("iPhone,17,Pro,Max", "iPhone-17-Pro-Max", "iPhone 17 Pro Max"),
            ("iPhone 17", "iPhone-17", "iPhone 17"),
            ("iPhone-SE-3rd-generation", "iPhone-SE-3rd-generation", "iPhone SE (3rd generation)"),
            ("iPhone SE (3rd generation)", "iPhone-SE-3rd-generation", "iPhone SE (3rd generation)"),
        ):
            p = run(FLEET, "23F77", ["--device", want, "--with-name"])
            self.assertEqual(p.returncode, 0, (want, p.stderr))
            rt, dt, got = p.stdout.rstrip("\n").split(" ", 2)
            self.assertEqual(dt, "com.apple.CoreSimulator.SimDeviceType." + ident, want)
            self.assertEqual(got, name, want)

    def test_unknown_device_fails_with_the_iphone_types_and_no_fallback(self):
        p = run(FLEET, "23F77", ["--device", "iPhone 99 Ultra"])
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(p.stdout, "")
        self.assertIn("device=iPhone 99 Ultra", p.stderr)
        self.assertIn("available iPhone types: iPad mini (A17 Pro), iPhone 16e, iPhone 17, iPhone 17 Pro, "
                      "iPhone 17 Pro Max, iPhone SE (3rd generation)", p.stderr)
        self.assertNotIn("iPad Pro", p.stderr.split("available iPhone types:")[1])

    def test_an_ipad_is_not_an_iphone(self):
        p = run(FLEET, "23F77", ["--device", "iPad Pro 11-inch (M5)"])
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(p.stdout, "")
        self.assertIn("no such iPhone or iPad mini device type", p.stderr)

    def test_an_ipad_mini_stands_in_for_an_unfolded_foldable(self):
        for want in ("iPad mini (A17 Pro)", "iPad-mini-A17-Pro"):
            p = run(FLEET, "23F77", ["--device", want, "--with-name"])
            self.assertEqual(p.returncode, 0, (want, p.stderr))
            self.assertEqual(p.stdout.rstrip("\n").split(" ", 2)[2], "iPad mini (A17 Pro)", want)

    def test_step_script_selects_through_the_helper(self):
        text = SCRIPT.read_text()
        self.assertIn("python3 -I scripts/ci/ios_sim_runtime.py", text)
        # Chosen before the build, so a host without the runtime fails in seconds.
        self.assertLess(text.index("scripts/ci/ios_sim_runtime.py"), text.index("# --- Build ---"))
        self.assertNotIn('rts.sort(', text)


if __name__ == "__main__":
    unittest.main()
