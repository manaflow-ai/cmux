#!/usr/bin/env python3
"""Regression coverage for the iOS Simulator build-once product contract."""

from __future__ import annotations

import importlib.util
import plistlib
import re
import shutil
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "test-ios.yml"
PRODUCT_HELPER = ROOT / "scripts" / "ci" / "ios_simulator_test_product.py"


def job_block(name: str) -> str:
    text = WORKFLOW.read_text(encoding="utf-8")
    marker = f"  {name}:\n"
    start = text.index(marker)
    match = re.search(r"(?m)^  [A-Za-z0-9_-]+:\n", text[start + len(marker) :])
    if match is None:
        return text[start:]
    return text[start : start + len(marker) + match.start()]


def load_product_helper():
    spec = importlib.util.spec_from_file_location("ios_simulator_test_product", PRODUCT_HELPER)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class IOSSimulatorWorkflowTests(unittest.TestCase):
    def test_one_producer_feeds_runtime_only_consumers(self) -> None:
        producer = job_block("ios-simulator-build")
        consumer = job_block("ios-simulator")

        self.assertIn(" build-for-testing", producer)
        self.assertEqual(producer.count(" build-for-testing"), 1)
        self.assertIn("-configuration Debug", producer)
        self.assertIn("-testPlan cmux-ui", producer)
        self.assertIn("ios_simulator_test_product.py stamp", producer)
        self.assertIn("actions/upload-artifact@", producer)
        self.assertIn("steps.upload-product.outputs.artifact-id", producer)

        self.assertIn("needs:", consumer)
        self.assertIn("- ios-simulator-build", consumer)
        self.assertIn("artifact-ids: ${{ needs.ios-simulator-build.outputs.artifact_id }}", consumer)
        self.assertIn("ios_simulator_test_product.py restore", consumer)
        self.assertIn('-xctestrun "$CMUX_IOS_XCTESTRUN"', consumer)
        self.assertIn("test-without-building", consumer)
        self.assertNotIn("build-for-testing", consumer)
        self.assertNotIn("-resolvePackageDependencies", consumer)
        self.assertNotIn("Provision GhosttyKit", consumer)
        self.assertNotIn("Install zig", consumer)
        self.assertNotIn(".github/actions/cache-restore", consumer)

    def test_existing_runtime_selectors_and_retry_contract_are_preserved(self) -> None:
        producer = job_block("ios-simulator-build")
        consumer = job_block("ios-simulator")

        self.assertIn('[[ "${TEST_FILTER:-}" == cmuxUITests/* ]]', producer)
        self.assertIn("-testPlan cmux-ui", producer)
        self.assertIn('-only-testing:"$TEST_FILTER"', consumer)
        self.assertIn("-skip-testing:cmuxUITests", consumer)
        self.assertIn("-collect-test-diagnostics never", consumer)
        self.assertIn("-test-timeouts-enabled YES", consumer)
        self.assertIn("require_selected_test_execution.sh", consumer)
        self.assertIn(
            "Timed out while launching application via Xcode|Failed to send signal 19|DTXMessage",
            consumer,
        )
        self.assertIn("selected_tests_passed_despite_xcodebuild_status", consumer)

    def test_focused_family_and_package_only_routing(self) -> None:
        producer = job_block("ios-simulator-build")
        consumer = job_block("ios-simulator")
        matrix = 'format(\'["{0}"]\', inputs.device_family)'

        self.assertIn("inputs.swift_package == ''", producer)
        self.assertIn("inputs.swift_package == ''", consumer)
        self.assertIn("inputs.device_family != 'both'", consumer)
        self.assertIn(matrix, consumer)
        self.assertIn('["iphone","ipad"]', consumer)

    def test_compatibility_runtime_identity_and_cleanup_are_preserved(self) -> None:
        producer = job_block("ios-simulator-build")
        consumer = job_block("ios-simulator")

        for block in (producer, consumer):
            self.assertIn("IOS_VERSION: ${{ inputs.ios_version }}", block)
            self.assertIn("xcodebuild -downloadPlatform iOS -buildVersion", block)
            self.assertIn("Remove compatibility simulator", block)
        self.assertIn("CMUX_IOS_VERSION: ${{ inputs.ios_version }}", producer)
        self.assertIn("CMUX_IOS_VERSION: ${{ inputs.ios_version }}", consumer)


class IOSSimulatorProductTests(unittest.TestCase):
    def setUp(self) -> None:
        self.product = load_product_helper()
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root / "source-derived"
        self.stage = self.root / "stage"
        self.consumer = self.root / "consumer"
        products = self.source / "Build" / "Products"
        app = products / "Debug-iphonesimulator" / "cmux.app"
        tests = products / "Debug-iphonesimulator" / "cmuxTests.xctest"
        app.mkdir(parents=True)
        tests.mkdir(parents=True)
        (app / "cmux").write_bytes(b"app")
        (tests / "cmuxTests").write_bytes(b"tests")
        manifest = {
            "TestConfigurations": [
                {
                    "TestTargets": [
                        {
                            "TestHostPath": str(app),
                            "TestBundlePath": str(tests),
                        }
                    ]
                }
            ]
        }
        (products / "cmux-ios_iphonesimulator.xctestrun").write_bytes(plistlib.dumps(manifest))
        shutil.copytree(products, self.stage / "Build" / "Products")

        self.producer_identity = {
            key: f"value-{key}"
            for key in self.product.IDENTITY_KEYS
        }
        self.producer_identity.update(
            {
                "checkout": str(self.root / "producer-checkout"),
                "developer": str(self.root / "producer-xcode"),
            }
        )
        self.consumer_identity = {
            **self.producer_identity,
            "checkout": str(self.root / "consumer-checkout"),
            "developer": str(self.root / "consumer-xcode"),
        }

    def tearDown(self) -> None:
        self.temp.cleanup()

    def stamp_and_copy(self) -> None:
        self.product.identity = lambda: dict(self.producer_identity)
        self.product.stamp(self.stage, self.source)
        shutil.copytree(self.stage, self.consumer)

    def test_stamp_and_restore_verify_and_relocate_exact_product(self) -> None:
        self.stamp_and_copy()
        self.product.identity = lambda: dict(self.consumer_identity)

        self.product.restore(self.consumer)

        manifest = next((self.consumer / "Build" / "Products").glob("*.xctestrun"))
        value = plistlib.loads(manifest.read_bytes())
        targets = list(self.product.targets(value))
        self.assertEqual(len(targets), 1)
        self.assertIn(str(self.consumer), targets[0]["TestHostPath"])
        self.assertIn(str(self.consumer), targets[0]["TestBundlePath"])

    def test_corrupt_product_fails_closed(self) -> None:
        self.stamp_and_copy()
        test_binary = self.consumer / "Build" / "Products" / "Debug-iphonesimulator" / "cmuxTests.xctest" / "cmuxTests"
        test_binary.write_bytes(b"corrupt")
        self.product.identity = lambda: dict(self.consumer_identity)

        with self.assertRaisesRegex(ValueError, "digest mismatch"):
            self.product.restore(self.consumer)

    def test_identity_mismatch_fails_closed(self) -> None:
        self.stamp_and_copy()
        mismatched = dict(self.consumer_identity)
        mismatched["sdk_build_version"] = "different-sdk"
        self.product.identity = lambda: mismatched

        with self.assertRaisesRegex(ValueError, "sdk_build_version mismatch"):
            self.product.restore(self.consumer)


if __name__ == "__main__":
    unittest.main()
