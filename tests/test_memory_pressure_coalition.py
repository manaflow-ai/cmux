#!/usr/bin/env python3
"""Exercise aggregate-memory coverage with production sampler code."""

import json
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(platform.system() == "Darwin", "requires Darwin coalition accounting")
class MemoryPressureCoalitionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="cmux-coalition-test-")
        cls.addClassCleanup(cls.temp.cleanup)
        directory = Path(cls.temp.name)
        cls.binary = directory / "aggregate-memory-probe"
        flags = [
            "-target", platform.machine() + "-apple-macos14.0",
            "-swift-version", "6", "-parse-as-library",
            "-module-cache-path", str(directory / "cache"),
        ]
        foundation = ROOT / "Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/Process/DarwinSystemMemorySnapshot.swift"
        cls.compile([
            *flags, "-emit-module", "-emit-object", "-module-name", "CmuxFoundation",
            str(foundation), "-emit-module-path", str(directory / "CmuxFoundation.swiftmodule"),
            "-o", str(directory / "foundation.o"),
        ])
        package_sources = sorted(
            (ROOT / "Packages/macOS/CmuxMemoryPressure/Sources/CmuxMemoryPressure").glob("*.swift")
        )
        cls.compile([
            *flags, "-I", str(directory),
            *(str(source) for source in package_sources),
            str(ROOT / "tests/fixtures/MemoryPressureCoalitionFixture.swift"),
            str(directory / "foundation.o"), "-o", str(cls.binary),
        ])

    @staticmethod
    def compile(arguments):
        result = subprocess.run(
            ["xcrun", "swiftc", *arguments], capture_output=True, text=True, timeout=180,
        )
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)

    def probe(self, scenario):
        result = subprocess.run(
            [str(self.binary), scenario], capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def test_unverified_macos27_and_unknown_layouts_stay_disabled(self):
        supported = self.probe("supported-os")
        for version in (14, 15, 26):
            with self.subTest(version=version):
                self.assertTrue(supported[str(version)])
        for version in (13, 16, 25, 27, 28, 99):
            with self.subTest(version=version):
                self.assertFalse(supported[str(version)])

    def test_live_macos27_coalition_includes_a_real_child(self):
        version = subprocess.check_output(["sw_vers", "-productVersion"], text=True)
        if int(version.split(".")[0]) != 27:
            self.skipTest("live coalition regression requires macOS 27")
        if not self.probe("supported-os")["27"]:
            self.skipTest("macOS 27 coalition ABI remains disabled pending kernel validation")
        sample = self.probe("live")
        self.assertEqual(sample["source"], "coalition")
        self.assertEqual(sample["coverage"], "complete")
        self.assertGreater(sample["child_delta_bytes"], 32 * 1024 * 1024)
        self.assertGreater(sample["aggregate_bytes"], sample["baseline_aggregate_bytes"])

    def test_root_owned_login_eperm_is_a_non_actionable_lower_bound(self):
        sample = self.probe("unreadable-login")
        self.assertEqual(sample["coverage"], "lower_bound")
        self.assertEqual(sample["source"], "descendantProcessTree")
        self.assertEqual(sample["aggregate_bytes"], 4_200)
        self.assertEqual(sample["missing_process_count"], 1)
        self.assertEqual(sample["missing_reason"], "unreadable_process_record")
        self.assertEqual(sample["severity"], "warning")
        self.assertFalse(sample["complete"])
        self.assertFalse(sample["actionable"])

    def test_unreadable_child_is_a_non_actionable_lower_bound(self):
        sample = self.probe("unreadable-child")
        self.assertEqual(sample["coverage"], "lower_bound")
        self.assertEqual(sample["aggregate_bytes"], 1_300)
        self.assertEqual(sample["missing_process_count"], 1)
        self.assertFalse(sample["actionable"])

    def test_exiting_process_keeps_partial_sample_non_actionable(self):
        sample = self.probe("exiting-child")
        self.assertEqual(sample["coverage"], "lower_bound")
        self.assertEqual(sample["missing_process_count"], 2)
        self.assertEqual(sample["missing_reason"], "incomplete_enumeration")
        self.assertFalse(sample["actionable"])

    def test_reused_pid_outside_tree_is_not_counted(self):
        sample = self.probe("pid-reuse")
        self.assertEqual(sample["coverage"], "complete")
        self.assertEqual(sample["aggregate_bytes"], 1_300)
        self.assertEqual(sample["process_count"], 3)
        self.assertTrue(sample["actionable"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
