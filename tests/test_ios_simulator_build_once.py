#!/usr/bin/env python3
"""Regression coverage for the iOS Simulator build-once product contract."""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys

import yaml
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

        self.assertIn("inputs.swift_package == ''", producer)
        self.assertIn("inputs.swift_package == ''", consumer)
        self.assertIn("fromJSON(needs.detect-ios-changes.outputs.device_families)", consumer)

    def test_producer_compiles_only_the_selected_test_plan(self) -> None:
        workflow = yaml.safe_load(WORKFLOW.read_text())
        step = next(
            step for step in workflow["jobs"]["ios-simulator-build"]["steps"]
            if step.get("id") == "compile-product"
        )
        for selected, expected in (
            ("", "cmux"),
            ("cmuxFeatureTests/TerminalViewportSpacingTests", "cmux"),
            ("cmuxUITests/cmuxUITests/testComputerPickerSelectionSurvivesAppRelaunch", "cmux-ui"),
        ):
            with self.subTest(selected=selected), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                binary = root / "xcodebuild"
                binary.write_text(
                    f"#!{sys.executable}\n"
                    "import json, os, sys\n"
                    "from pathlib import Path\n"
                    "Path(os.environ['CAPTURE_ARGS']).write_text(json.dumps(sys.argv[1:]))\n"
                )
                binary.chmod(0o755)
                (root / "derived" / "logs").mkdir(parents=True)
                capture = root / "arguments.json"
                env = {
                    **os.environ,
                    "PATH": f"{root}:{os.environ['PATH']}",
                    "CAPTURE_ARGS": str(capture),
                    "TEST_FILTER": selected,
                    "SIMULATOR_ID": "fixture-simulator",
                    "IOS_DERIVED_DATA": str(root / "derived"),
                    "IOS_SPM_CACHE": str(root / "packages"),
                    "GITHUB_OUTPUT": str(root / "output"),
                    "GITHUB_STEP_SUMMARY": str(root / "summary"),
                }
                result = subprocess.run(
                    ["bash", "-e", "-c", step["run"]],
                    env=env, text=True, capture_output=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                arguments = json.loads(capture.read_text())
                # build-for-testing otherwise emits all three scheme plans,
                # even though ordinary test defaults to cmux.
                self.assertEqual(arguments.count("-testPlan"), 1)
                self.assertEqual(arguments[arguments.index("-testPlan") + 1], expected)
                self.assertIn("build-for-testing", arguments)

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

    def configure_platform_test_host(self) -> Path:
        relative = Path("Platforms/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/xctest")
        for identity in (self.producer_identity, self.consumer_identity):
            runner = Path(identity["developer"]) / relative
            runner.parent.mkdir(parents=True, exist_ok=True)
            runner.write_bytes(b"fixture XCTest runner")
            runner.chmod(0o755)
        manifest = next((self.stage / "Build" / "Products").glob("*.xctestrun"))
        value = plistlib.loads(manifest.read_bytes())
        target = next(self.product.targets(value))
        target["TestHostPath"] = "__PLATFORMS__/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/xctest"
        manifest.write_bytes(plistlib.dumps(value))
        return Path(self.consumer_identity["developer"]) / relative

    def add_compile_outputs(self) -> tuple[Path, Path, Path]:
        root = self.stage / "Build" / "Products" / "Debug-iphonesimulator"
        archive = root / "libUnused.a"
        archive.write_bytes(b"static library" * 10)
        obj = root / "Unused.o"
        obj.write_bytes(b"object" * 10)
        module = root / "Unused.swiftmodule"
        module.mkdir()
        (module / "arm64.swiftmodule").write_bytes(b"compiler metadata" * 10)
        return archive, obj, module

    def update_manifest_target(self, **fields) -> None:
        path = next((self.stage / "Build" / "Products").glob("*.xctestrun"))
        value = plistlib.loads(path.read_bytes())
        next(self.product.targets(value)).update(fields)
        path.write_bytes(plistlib.dumps(value))

    def test_pruned_product_restores_with_complete_runtime_bundles(self) -> None:
        archive, obj, module = self.add_compile_outputs()
        root = archive.parent
        preserved = []
        for bundle in ("cmux.app", "cmuxTests.xctest", "Support.framework", "Resources.bundle", "cmux.app.dSYM"):
            child = root / bundle / "nested" / "Keep.a"
            child.parent.mkdir(parents=True, exist_ok=True)
            child.write_bytes(b"keep whole bundle")
            preserved.append(child.relative_to(self.stage))
        # Runtime loader search roots must not pin static compiler metadata.
        self.update_manifest_target(EnvironmentVariables={"DYLD_FRAMEWORK_PATH": "__TESTROOT__/Debug-iphonesimulator"})
        self.stamp_and_copy()
        self.product.identity = lambda: dict(self.consumer_identity)
        self.product.restore(self.consumer)
        for candidate in (archive, obj, module):
            self.assertFalse(candidate.exists())
        for path in preserved:
            self.assertEqual((self.consumer / path).read_bytes(), b"keep whole bundle")
        receipt = json.loads((self.stage / "Build" / "Products" / self.product.RECEIPT).read_text())
        report = receipt["staging"]
        self.assertEqual(report["removed_count"], 3)
        self.assertEqual(report["removed_bytes"], 370)
        self.assertEqual(report["before_bytes"] - report["after_bytes"], 370)

    def test_manifest_references_protect_loose_compile_products(self) -> None:
        archive, obj, module = self.add_compile_outputs()
        self.update_manifest_target(
            DependentProductPaths=["__TESTROOT__/Debug-iphonesimulator/libUnused.a", str(module / "arm64.swiftmodule")],
            FutureProductReference="Debug-iphonesimulator/Unused.o",
        )
        self.stamp_and_copy()
        self.product.identity = lambda: dict(self.consumer_identity)
        self.product.restore(self.consumer)
        for candidate in (archive, obj, module):
            self.assertTrue((self.consumer / candidate.relative_to(self.stage)).exists())
        # Referenced compiler outputs remain covered by the product digest.
        (self.consumer / archive.relative_to(self.stage)).write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "digest mismatch"):
            self.product.restore(self.consumer)

    def assert_pruning_skipped_and_product_verified(self, reference: str, reason: str) -> None:
        candidates = self.add_compile_outputs()
        self.update_manifest_target(DependentProductPaths=[reference])
        self.stamp_and_copy()
        self.product.identity = lambda: dict(self.consumer_identity)
        self.product.restore(self.consumer)
        self.assertTrue(all(path.exists() for path in candidates))
        for path in candidates:
            self.assertTrue((self.consumer / path.relative_to(self.stage)).exists())
        receipt = json.loads((self.stage / "Build" / "Products" / self.product.RECEIPT).read_text())
        self.assertEqual(receipt["staging"]["skipped_reason"], reason)
        self.assertEqual(receipt["staging"]["removed_count"], 0)
        (self.consumer / candidates[0].relative_to(self.stage)).write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "digest mismatch"):
            self.product.restore(self.consumer)

    def test_unfamiliar_reference_preserves_verified_complete_product(self) -> None:
        self.assert_pruning_skipped_and_product_verified(
            "__FUTURE_ROOT__/required.a", "unfamiliar manifest macro",
        )

    def test_wildcard_reference_preserves_verified_complete_product(self) -> None:
        self.assert_pruning_skipped_and_product_verified(
            "__TESTROOT__/Debug-iphonesimulator/*.a", "wildcard manifest reference",
        )

    def test_reference_through_symlink_protects_module_contents(self) -> None:
        _, _, module = self.add_compile_outputs()
        alias = module.parent / "CompilerAlias"
        alias.symlink_to(module.name)
        self.update_manifest_target(
            DependentProductPaths=["__TESTROOT__/Debug-iphonesimulator/CompilerAlias/arm64.swiftmodule"]
        )
        self.stamp_and_copy()
        self.assertTrue(module.is_dir())
        self.assertEqual((module / "arm64.swiftmodule").read_bytes(), b"compiler metadata" * 10)

    def test_unknown_directory_reference_protects_all_children(self) -> None:
        candidates = self.add_compile_outputs()
        self.update_manifest_target(FutureProductDirectory="__TESTROOT__/Debug-iphonesimulator")
        self.stamp_and_copy()
        self.product.identity = lambda: dict(self.consumer_identity)
        self.product.restore(self.consumer)
        self.assertTrue(all(path.exists() for path in candidates))

    def test_nested_non_bundle_outputs_and_symlinks_are_not_pruned(self) -> None:
        root = self.stage / "Build" / "Products" / "Debug-iphonesimulator"
        nested = root / "UnknownProduct" / "Keep.o"
        nested.parent.mkdir()
        nested.write_bytes(b"unclassified")
        link = root / "Alias.o"
        link.symlink_to("UnknownProduct/Keep.o")
        self.stamp_and_copy()
        self.assertTrue(nested.exists())
        self.assertTrue(link.is_symlink())

    def test_platform_xctest_host_survives_stamp_and_consumer_relocation(self) -> None:
        self.configure_platform_test_host()
        self.stamp_and_copy()
        self.product.identity = lambda: dict(self.consumer_identity)
        self.product.restore(self.consumer)
        manifest = next((self.consumer / "Build" / "Products").glob("*.xctestrun"))
        target = next(self.product.targets(plistlib.loads(manifest.read_bytes())))
        self.assertEqual(
            target["TestHostPath"],
            "__PLATFORMS__/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/xctest",
        )
        self.assertIn(str(self.consumer), target["TestBundlePath"])

    def test_platform_runner_must_exist_on_consumer(self) -> None:
        runner = self.configure_platform_test_host()
        self.stamp_and_copy()
        runner.unlink()
        self.product.identity = lambda: dict(self.consumer_identity)
        with self.assertRaisesRegex(ValueError, "missing or non-executable platform test host"):
            self.product.restore(self.consumer)

    def test_platform_runner_must_be_executable_on_producer(self) -> None:
        self.configure_platform_test_host()
        runner = Path(self.producer_identity["developer"]) / "Platforms/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/xctest"
        runner.chmod(0o644)
        self.product.identity = lambda: dict(self.producer_identity)
        with self.assertRaisesRegex(ValueError, "missing or non-executable platform test host"):
            self.product.stamp(self.stage, self.source)

    def test_platform_host_exception_does_not_allow_other_paths(self) -> None:
        self.configure_platform_test_host()
        manifest = next((self.stage / "Build" / "Products").glob("*.xctestrun"))
        original = manifest.read_bytes()
        self.product.identity = lambda: dict(self.producer_identity)
        for field, path in (
            ("TestHostPath", "__PLATFORMS__/iPhoneOS.platform/Developer/Library/Xcode/Agents/xctest"),
            ("TestHostPath", "__PLATFORMS__/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/other"),
            ("TestHostPath", "__PLATFORMS__/../Library/Xcode/Agents/xctest"),
            ("TestHostPath", "/tmp/external-test-host"),
            ("TestBundlePath", "__PLATFORMS__/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/xctest"),
            ("UITargetAppPath", "__PLATFORMS__/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/xctest"),
        ):
            with self.subTest(field=field, path=path):
                value = plistlib.loads(original)
                next(self.product.targets(value))[field] = path
                manifest.write_bytes(plistlib.dumps(value))
                with self.assertRaisesRegex(ValueError, "unscoped test"):
                    self.product.stamp(self.stage, self.source)

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
