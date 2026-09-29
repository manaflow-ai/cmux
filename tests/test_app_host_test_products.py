#!/usr/bin/env python3
"""Exercise the build-product handoff across different runner paths and identities."""

import importlib.util
import os
import plistlib
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HELPER = Path(__file__).resolve().parents[1] / "scripts/ci/app_host_test_products.py"
spec = importlib.util.spec_from_file_location("app_host_test_products", HELPER)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class TestProductHandoff(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name).resolve()
        self.producer = root / "producer" / "derived"
        self.consumer = root / "consumer" / "different-temp" / "derived"
        self.identity = {"revision": "abc123", "architecture": "arm64", "xcode": "Xcode 26.5\nBuild 123",
                         "developer": "/producer/Xcode.app/Contents/Developer", "checkout": "/producer/work/cmux"}
        products = self.producer / "Build/Products"
        # The app scheme builds plainly and writes no test manifest; only its
        # bundle is in the product.
        executable = products / "Debug/cmux DEV.app/Contents/MacOS/cmux DEV"
        executable.parent.mkdir(parents=True)
        executable.write_text("binary")
        self.bundle = Path("Debug/cmuxCLITests.xctest")
        (products / self.bundle).mkdir(parents=True)
        # A unit-test target without TEST_HOST is loaded by the platform's own
        # xctest agent, which is not in Build/Products.
        target = {
            "TestHostPath": "__PLATFORMS__/MacOSX.platform/Developer/Library/Xcode/Agents/xctest",
            "TestBundlePath": "__TESTROOT__/Debug/cmuxCLITests.xctest",
            "EnvironmentVariables": {"SOURCE": "/producer/work/cmux/fixtures"},
            "DependentProductPaths": [str(products / self.bundle)],
        }
        value = {"TestConfigurations": [{"TestTargets": [target]}]}
        (products / "cmux-cli-tests_macosx26.5-arm64.xctestrun").write_bytes(plistlib.dumps(value))

    def test_every_profile_needs_only_the_cli_test_manifest(self):
        # The app scheme compiles with a plain build, so both profiles expect
        # exactly the CLI test manifest, and a product without it is partial.
        products = self.producer / "Build/Products"
        for profile in ("cli", "app-host"):
            with self.subTest(profile=profile), mock.patch.dict(os.environ, {"CMUX_PRODUCT_PROFILE": profile}):
                self.assertEqual(list(module.manifests(products)), ["cmux-cli-tests"])
        (products / "cmux-cli-tests_macosx26.5-arm64.xctestrun").unlink()
        with mock.patch.dict(os.environ, {"CMUX_PRODUCT_PROFILE": "app-host"}):
            with self.assertRaises(ValueError) as caught:
                module.manifests(products)
        self.assertIn("cmux-cli-tests", str(caught.exception))

    def transfer(self):
        module.stamp(self.producer, self.identity)
        shutil.copytree(self.producer / "Build/Products", self.consumer / "Build/Products")
        shutil.rmtree(self.producer)

    def test_relocation_preserves_nested_bundles_and_publishes_all_manifests(self):
        self.transfer()
        current = {**self.identity, "checkout": "/consumer/work/cmux", "developer": "/consumer/Xcode.app/Contents/Developer"}
        outputs = module.restore(self.consumer, current)
        self.assertEqual(set(outputs), {"CMUX_CLI_TESTS_XCTESTRUN"})
        for path in outputs.values():
            value = plistlib.loads(Path(path).read_bytes())
            target = list(module.targets(value))[0]
            self.assertEqual(target["EnvironmentVariables"]["SOURCE"], "/consumer/work/cmux/fixtures")
            self.assertFalse(module.hosted_by_product(target))
            self.assertEqual(target["DependentProductPaths"], [str(self.consumer / "Build/Products" / self.bundle)])
            self.assertTrue(Path(target["DependentProductPaths"][0]).exists())

    def test_manifest_outputs_name_the_cli_tests(self):
        self.assertEqual(module.SCHEME_OUTPUTS, {"cmux-cli-tests": "CMUX_CLI_TESTS_XCTESTRUN"})

    def test_canonical_producer_relocates_through_admission_then_shard(self):
        canonical = {**self.identity, "checkout": "/private/tmp/cmux-ci/src"}
        products = self.producer / "Build/Products"
        for manifest in module.manifests(products).values():
            value = module.map_strings(plistlib.loads(manifest.read_bytes()),
                                       [(self.identity["checkout"], canonical["checkout"])])
            manifest.write_bytes(plistlib.dumps(value))
        module.stamp(self.producer, canonical)
        # Fresh admission relocates before its common packaging stamp. Exact
        # product reuse takes the same second leg without a canonical rebuild.
        module.restore(self.producer, self.identity)
        self.transfer()
        shard = {**self.identity, "checkout": "/shard/work/cmux"}
        outputs = module.restore(self.consumer, shard)
        for path in outputs.values():
            target = list(module.targets(plistlib.loads(Path(path).read_bytes())))[0]
            self.assertEqual(target["EnvironmentVariables"]["SOURCE"], "/shard/work/cmux/fixtures")
            self.assertTrue(all(Path(path).exists() for path in target["DependentProductPaths"]))

    def test_rejects_mismatched_source_toolchain_or_architecture(self):
        self.transfer()
        for key in ("revision", "xcode", "architecture"):
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, key):
                module.restore(self.consumer, {**self.identity, key: "different"})

    def test_accepts_another_point_release_of_the_same_xcode(self):
        self.transfer()
        module.restore(self.consumer, {**self.identity, "xcode": "Xcode 26.6\nBuild version 17F113"})

    def test_rejects_an_xcode_older_than_the_producers(self):
        # Xcode 26.3's Testing.framework lacks symbols a 26.6-linked bundle
        # imports; refuse with both versions named instead of a dlopen crash.
        self.identity["xcode"] = "Xcode 26.6\nBuild version 17F113"
        self.transfer()
        with self.assertRaisesRegex(ValueError, r"xcode.*26\.6.*26\.3"):
            module.restore(self.consumer, {**self.identity, "xcode": "Xcode 26.3\nBuild version 17C529"})

    def test_rejects_another_major_xcode(self):
        self.transfer()
        with self.assertRaisesRegex(ValueError, "xcode"):
            module.restore(self.consumer, {**self.identity, "xcode": "Xcode 27.0\nBuild version 18A1"})

    def test_missing_bundle_fails_in_producer_and_consumer(self):
        self.transfer()
        shutil.rmtree(self.consumer / "Build/Products" / self.bundle)
        with self.assertRaisesRegex(ValueError, "missing or unscoped"):
            module.restore(self.consumer, self.identity)

    def test_missing_or_ambiguous_manifest_is_rejected(self):
        products = self.producer / "Build/Products"
        manifest = next(products.glob("cmux-cli-tests_*.xctestrun"))
        shutil.copy2(manifest, products / "cmux-cli-tests_old.xctestrun")
        with self.assertRaisesRegex(ValueError, "found 2"):
            module.stamp(self.producer, self.identity)
        for path in products.glob("cmux-cli-tests_*.xctestrun"):
            path.unlink()
        with self.assertRaisesRegex(ValueError, "found 0"):
            module.stamp(self.producer, self.identity)

    def test_empty_manifest_cannot_claim_success(self):
        products = self.producer / "Build/Products"
        next(products.glob("cmux-cli-tests_*.xctestrun")).write_bytes(plistlib.dumps({}))
        with self.assertRaisesRegex(ValueError, "no test targets"):
            module.stamp(self.producer, self.identity)


if __name__ == "__main__":
    unittest.main()
