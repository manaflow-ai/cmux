#!/usr/bin/env python3
"""Compile and exercise the production aggregate sampler without an app host.

The process snapshot is a fixed login-backed tree; coalition reads and aggregate
policy are production code. The live regression uses this probe's own coalition
on macOS 27, never a running cmux instance or a memory-pressure responder.
"""

import json
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(platform.system() == "Darwin", "requires macOS coalition accounting")
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
        cls.compile([
            *flags, "-I", str(directory),
            str(ROOT / "Sources/App/MemoryPressureAggregateSampler.swift"),
            str(ROOT / "Sources/App/MemoryPressureAggregatePolicy.swift"),
            str(ROOT / "Sources/App/MemoryPressureSeverity.swift"),
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

    def test_macos27_is_supported_but_unknown_layouts_stay_disabled(self):
        supported = self.probe("supported-os")
        for version in (14, 15, 26, 27):
            with self.subTest(version=version):
                self.assertTrue(supported[str(version)])
        for version in (13, 16, 25, 28, 99):
            with self.subTest(version=version):
                self.assertFalse(supported[str(version)])

    def test_live_macos27_coalition_covers_an_unreadable_login(self):
        version = subprocess.check_output(["sw_vers", "-productVersion"], text=True)
        if int(version.split(".")[0]) != 27:
            self.skipTest("live regression requires macOS 27; the ABI gate is tested on every Mac")
        sample = self.probe("live")
        self.assertEqual(sample["source"], "coalition")
        self.assertGreater(sample["aggregate_bytes"], 0)
        self.assertEqual(sample["missing_process_count"], 0)
        self.assertTrue(sample["complete"])
        self.assertTrue(sample["actionable"])

    def test_unreadable_login_still_fails_closed_without_a_coalition(self):
        sample = self.probe("unavailable")
        self.assertEqual(sample["source"], "unavailable")
        self.assertIsNone(sample["aggregate_bytes"])
        self.assertEqual(sample["missing_process_count"], 1)
        self.assertFalse(sample["complete"])
        self.assertFalse(sample["actionable"])

    def test_complete_tree_remains_a_valid_fallback(self):
        sample = self.probe("complete-tree")
        self.assertEqual(sample["source"], "descendantProcessTree")
        self.assertEqual(sample["aggregate_bytes"], 2110)
        self.assertEqual(sample["process_count"], 3)
        self.assertTrue(sample["complete"])
        self.assertTrue(sample["actionable"])

    def test_invalid_process_ids_have_no_coalition_sample(self):
        self.assertEqual(self.probe("invalid-pids"), [True, True])


if __name__ == "__main__":
    unittest.main(verbosity=2)
