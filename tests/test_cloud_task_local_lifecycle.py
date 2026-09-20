#!/usr/bin/env python3
"""Execute production Cloud task-local scopes, including the macOS 14 fallback.

This small optimized executable links the real context and recorder without the
app/UI or authentication runtime. The test-only availability symbol forces the
back-deployed standard-library code to run on modern hosted CI; it does not
replace Swift's task allocator. No source-text assertions or timing sleeps.
"""
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
FIXTURE = ROOT / "tests/cloud_task_local"
CLOUD = ROOT / "Sources/Cloud"


@unittest.skipUnless(platform.system() == "Darwin", "requires the macOS Swift runtime")
class CloudTaskLocalLifecycleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="cmux-task-local-")
        cls.addClassCleanup(cls.temp.cleanup)
        directory = Path(cls.temp.name)
        target = platform.machine() + "-apple-macos14.0"
        flags = ["-target", target, "-swift-version", "5", "-warnings-as-errors"]
        subprocess.run([
            "xcrun", "swiftc", *flags, "-emit-module", "-emit-object", "-parse-as-library",
            "-module-name", "CmuxAuthRuntime", str(FIXTURE / "AuthFixture.swift"),
            "-emit-module-path", str(directory / "CmuxAuthRuntime.swiftmodule"),
            "-o", str(directory / "auth.o"),
        ], check=True, timeout=90)
        subprocess.run([
            "xcrun", "clang", "-target", target, "-Werror", "-c",
            str(FIXTURE / "LegacyAvailability.c"), "-o", str(directory / "legacy.o"),
        ], check=True, timeout=30)
        cls.binary = directory / "cloud-task-local-probe"
        production = [
            "CloudOperationContext.swift", "CloudOperationRecorder.swift",
            "CloudOperationKind.swift", "CloudOperationPhase.swift",
            "CloudOperationSnapshot.swift", "CloudRemoteOperationStep.swift",
            "CloudTelemetrySpan.swift", "CloudTelemetrySending.swift",
        ]
        subprocess.run([
            "xcrun", "swiftc", *flags, "-O", "-whole-module-optimization", "-g", "-parse-as-library",
            "-module-name", "CloudTaskLocalRegression", "-I", str(directory),
            *[str(CLOUD / source) for source in production],
            str(FIXTURE / "Dependencies.swift"), str(FIXTURE / "Probe.swift"),
            str(directory / "auth.o"), str(directory / "legacy.o"),
            "-o", str(cls.binary),
        ], check=True, timeout=120)

    def run_probe(self, legacy):
        environment = os.environ.copy()
        environment.pop("CMUX_TEST_LEGACY_TASK_LOCAL", None)
        environment["SWIFT_BACKTRACE"] = "interactive=no,timeout=0s,symbolicate=off,color=no"
        if legacy:
            environment["CMUX_TEST_LEGACY_TASK_LOCAL"] = "1"
        result = subprocess.run(
            [str(self.binary)], env=environment, capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS: 4 Cloud task-local lifecycle scenarios", result.stdout)
        if legacy:
            self.assertIn("TaskLocal: selected macOS 14 fallback", result.stderr)

    def test_native_runtime(self):
        self.run_probe(legacy=False)

    def test_macos14_back_deployment(self):
        self.run_probe(legacy=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
