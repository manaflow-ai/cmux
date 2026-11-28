#!/usr/bin/env python3
"""scripts/ci/ios_sim_bundles.py: RFD 0051's per-bundle simsdk cutover. In shadow both sides run every bundle, as
before; with "on" the Mac runs only scripts/ci/ios-sim-mac-bundles.txt and the pool runs the rest, and the Mac
fallback runs the pool's share; the pool part works on the scripts/ci-only checkout of the kit-sim-pool jobs."""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/ios_sim_bundles.py"
SKIPS = ["CmuxMobileInstantPerfTests", "CmuxMobileDesignCoreTests", "CmuxMobileRealtimeTests", "CmuxMobileTransportTests"]

PACKAGE = textwrap.dedent("""\
    let package = Package(targets: [
        .testTarget(name: "CmuxMobileAuthTests", dependencies: []),
        .testTarget(
            name: "CmuxMobileLiveTests",
            dependencies: []),
        .testTarget(name: "CmuxMobileShellTests"),
        .testTarget(name: "CmuxMobileInstantPerfTests"),
        .testTarget(name: "CmuxMobileDesignCoreTests"),
        .testTarget(name: "CmuxMobileRealtimeTests"),
        .testTarget(name: "CmuxMobileTransportTests"),
    ])
    #if os(Linux)
    package.targets = [.testTarget(name: "CmuxMobileLinkFFILinuxTests")]
    #endif
""")


class Bundles(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        (self.tmp / "Package.swift").write_text(PACKAGE)
        self.stays = self.tmp / "stays.txt"

    def run_part(self, part, mode, stays=(), package=True):
        self.stays.write_text("# comment\n" + "".join(f"{s}  # why\n" for s in stays))
        env = dict(os.environ, CMUX_IOS_SIM_MAC_BUNDLES=str(self.stays),
                   CMUX_IOS_SIM_BUNDLES=str(self.tmp / ("Package.swift" if package else "missing.swift")))
        if mode is None:
            env.pop("CMUX_IOS_SIM_LINUX", None)
        else:
            env["CMUX_IOS_SIM_LINUX"] = mode
        r = subprocess.run([sys.executable, "-I", str(SCRIPT), part], env=env, capture_output=True, text=True)
        return r.returncode, r.stdout.split()

    def test_shadow_is_the_old_skips_on_every_side(self):
        for mode in (None, "", "shadow"):
            for part in ("mac", "fallback"):
                self.assertEqual(self.run_part(part, mode, ["CmuxMobileAuthTests"]), (0, [f"-skip-testing:{s}" for s in SKIPS]))
            rc, out = self.run_part("pool", mode, ["CmuxMobileAuthTests"])
            self.assertEqual((rc, out[1::2]), (0, [f"skip={s}" for s in SKIPS]))

    def test_on_splits_by_the_list(self):
        stays = ["CmuxMobileAuthTests"]
        self.assertEqual(self.run_part("mac", "on", stays), (0, ["-only-testing:CmuxMobileAuthTests"]))
        self.assertEqual(self.run_part("fallback", "on", stays),
                         (0, ["-only-testing:CmuxMobileLiveTests", "-only-testing:CmuxMobileShellTests"]))
        rc, out = self.run_part("pool", "on", stays)
        self.assertEqual(rc, 0)
        self.assertEqual(out[0::2], ["--arg"] * 5)
        self.assertEqual(out[1::2], [f"skip={s}" for s in SKIPS + stays])

    def test_on_with_every_bundle_listed_leaves_the_pool_nothing(self):
        stays = ["CmuxMobileAuthTests", "CmuxMobileLiveTests", "CmuxMobileShellTests"]
        self.assertEqual(self.run_part("pool", "on", stays), (3, []))
        self.assertEqual(self.run_part("fallback", "on", stays), (0, []))
        self.assertEqual(self.run_part("mac", "on", stays), (0, [f"-skip-testing:{s}" for s in SKIPS]))

    def test_on_with_an_empty_list_runs_nothing_on_the_mac(self):
        self.assertEqual(self.run_part("mac", "on", []), (0, []))
        self.assertEqual(self.run_part("fallback", "on", []), (0, [f"-skip-testing:{s}" for s in SKIPS]))

    def test_off_never_submits_the_pool(self):
        self.assertEqual(self.run_part("pool", "off"), (3, []))
        self.assertEqual(self.run_part("mac", "off"), (0, [f"-skip-testing:{s}" for s in SKIPS]))

    def test_a_linux_only_test_target_is_not_a_simulator_bundle(self):
        rc, _ = self.run_part("mac", "on", ["CmuxMobileLinkFFILinuxTests"])
        self.assertEqual(rc, 2)

    def test_an_unknown_bundle_in_the_list_fails(self):
        self.assertEqual(self.run_part("mac", "on", ["CmuxMobileNoSuchTests"])[0], 2)

    def test_the_pool_part_needs_no_package(self):
        rc, out = self.run_part("pool", "on", ["CmuxMobileAuthTests"], package=False)
        self.assertEqual((rc, out[1::2]), (0, [f"skip={s}" for s in SKIPS + ["CmuxMobileAuthTests"]]))
        self.assertEqual(self.run_part("mac", "on", package=False)[0], 2)

    def test_the_real_list_names_only_real_bundles(self):
        env = dict(os.environ, CMUX_IOS_SIM_LINUX="on")
        r = subprocess.run([sys.executable, "-I", str(SCRIPT), "mac"], env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)


class Wiring(unittest.TestCase):
    """Every simulator run reads its share from the script: no copy of the skips is left to drift."""

    def test_no_hand_copied_skips(self):
        for rel in (".github/workflows/cmux-next-ios-kit.yml", "scripts/ci/kit_sim_fleet.sh",
                    "scripts/ci/ios-kit-sim-mac-test.sh"):
            text = (ROOT / rel).read_text()
            self.assertNotIn("skip=CmuxMobile", text, rel)
            self.assertNotIn("-skip-testing:CmuxMobile", text, rel)

    def test_the_mac_steps_pass_their_part_and_the_mode(self):
        text = (ROOT / ".github/workflows/cmux-next-ios-kit.yml").read_text()
        self.assertIn("KIT_SIM_PART: mac", text)
        self.assertIn("KIT_SIM_PART: fallback", text)
        self.assertGreaterEqual(text.count("CMUX_IOS_SIM_LINUX: ${{ vars.CMUX_IOS_SIM_LINUX || 'shadow' }}"), 4)


if __name__ == "__main__":
    unittest.main()
