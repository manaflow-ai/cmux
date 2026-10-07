#!/usr/bin/env python3
"""Bind the app's Cloud pane reservations, including the macOS 14 fallback.

The reservations hold Foundation UUIDs. With the Xcode 26 SDK their size is
only known at run time, which sends an async TaskLocal.withValue binding down
the back-deployed code path that aborted cmux 0.65.0 on macOS 14 with "freed
pointer was not the last allocation". The test-only availability symbol from
tests/cloud_task_local forces that path on a modern host without replacing
Swift's task allocator. No source-text assertions or timing sleeps.
"""
import os
from pathlib import Path
import platform
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
FIXTURE = ROOT / "tests/surface_task_local"
LEGACY = ROOT / "tests/cloud_task_local/LegacyAvailability.c"
PRODUCTION = [ROOT / "Sources/Surfaces/CloudMachineLoadingReservation.swift"]
# Module imports the standalone stubs replace inside the probe module.
STUBBED_IMPORTS = re.compile(r"^import (CmuxCloud|CmuxSurfaceCatalogModel)\n", re.MULTILINE)


@unittest.skipUnless(platform.system() == "Darwin", "requires the macOS Swift runtime")
class SurfaceTaskLocalReservationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="cmux-surface-task-local-")
        cls.addClassCleanup(cls.temp.cleanup)
        directory = Path(cls.temp.name)
        target = platform.machine() + "-apple-macos14.0"
        flags = ["-target", target, "-swift-version", "5", "-warnings-as-errors"]
        subprocess.run([
            "xcrun", "clang", "-target", target, "-Werror", "-c",
            str(LEGACY), "-o", str(directory / "legacy.o"),
        ], check=True)
        copies = directory / "production"
        copies.mkdir()
        for source in PRODUCTION:
            (copies / source.name).write_text(STUBBED_IMPORTS.sub("", source.read_text()))
        cls.binary = directory / "surface-task-local-probe"
        subprocess.run([
            "xcrun", "swiftc", *flags, "-O", "-whole-module-optimization", "-g", "-parse-as-library",
            "-module-name", "SurfaceTaskLocalRegression", "-I", str(directory),
            *[str(copies / source.name) for source in PRODUCTION],
            str(FIXTURE / "Dependencies.swift"), str(FIXTURE / "Probe.swift"),
            str(directory / "legacy.o"), "-o", str(cls.binary),
        ], check=True)

    def run_probe(self, legacy):
        environment = os.environ.copy()
        environment.pop("CMUX_TEST_LEGACY_TASK_LOCAL", None)
        environment["SWIFT_BACKTRACE"] = "interactive=no,timeout=0s,symbolicate=off,color=no"
        if legacy:
            environment["CMUX_TEST_LEGACY_TASK_LOCAL"] = "1"
        result = subprocess.run(
            [str(self.binary)], env=environment, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS: 4 surface task-local reservation scenarios", result.stdout)
        if legacy:
            self.assertIn("TaskLocal: selected macOS 14 fallback", result.stderr)

    def test_native_runtime(self):
        self.run_probe(legacy=False)

    def test_macos14_back_deployment(self):
        self.run_probe(legacy=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
