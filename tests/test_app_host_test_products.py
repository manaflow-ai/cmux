#!/usr/bin/env python3
"""Exercise the build-product handoff across different runner paths and identities."""

import importlib.util
import os
import plistlib
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HELPER = Path(__file__).resolve().parents[1] / "scripts/ci/app_host_test_products.py"
spec = importlib.util.spec_from_file_location("app_host_test_products", HELPER)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


# The real profile has no test scheme left, so the manifest handoff is
# exercised through a synthetic host-free test scheme.
FIXTURE_SCHEME = "fixture-tests"
FIXTURE_OUTPUT = "FIXTURE_TESTS_XCTESTRUN"


class TestProductHandoff(unittest.TestCase):
    def setUp(self):
        for patch in (
            mock.patch.dict(module.product_inputs.PRODUCT_PROFILES, {"app-host": ("cmux", FIXTURE_SCHEME)}),
            mock.patch.object(module.product_inputs, "TEST_SCHEMES", frozenset({FIXTURE_SCHEME})),
            mock.patch.dict(module.SCHEME_OUTPUTS, {FIXTURE_SCHEME: FIXTURE_OUTPUT}),
            mock.patch.dict(os.environ, {"CMUX_PRODUCT_PROFILE": "app-host"}),
            # reuse_app_host_products imports its own copy of this module.
            *([mock.patch.dict(sys.modules["app_host_test_products"].SCHEME_OUTPUTS,
                               {FIXTURE_SCHEME: FIXTURE_OUTPUT})]
              if "app_host_test_products" in sys.modules
              and sys.modules["app_host_test_products"] is not module else []),
        ):
            patch.start()
            self.addCleanup(patch.stop)
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
        self.bundle = Path("Debug/FixtureTests.xctest")
        (products / self.bundle).mkdir(parents=True)
        # A unit-test target without TEST_HOST is loaded by the platform's own
        # xctest agent, which is not in Build/Products.
        target = {
            "TestHostPath": "__PLATFORMS__/MacOSX.platform/Developer/Library/Xcode/Agents/xctest",
            "TestBundlePath": "__TESTROOT__/Debug/FixtureTests.xctest",
            "EnvironmentVariables": {"SOURCE": "/producer/work/cmux/fixtures"},
            "DependentProductPaths": [str(products / self.bundle)],
        }
        value = {"TestConfigurations": [{"TestTargets": [target]}]}
        (products / f"{FIXTURE_SCHEME}_macosx26.5-arm64.xctestrun").write_bytes(plistlib.dumps(value))

    def test_profile_needs_exactly_its_test_manifests(self):
        # The app scheme compiles with a plain build, so the profile expects
        # exactly its test scheme's manifest, and a product without it is partial.
        products = self.producer / "Build/Products"
        self.assertEqual(list(module.manifests(products)), [FIXTURE_SCHEME])
        (products / f"{FIXTURE_SCHEME}_macosx26.5-arm64.xctestrun").unlink()
        with self.assertRaises(ValueError) as caught:
            module.manifests(products)
        self.assertIn(FIXTURE_SCHEME, str(caught.exception))

    def transfer(self):
        module.stamp(self.producer, self.identity)
        shutil.copytree(self.producer / "Build/Products", self.consumer / "Build/Products")
        shutil.rmtree(self.producer)

    def test_relocation_preserves_nested_bundles_and_publishes_all_manifests(self):
        self.transfer()
        current = {**self.identity, "checkout": "/consumer/work/cmux", "developer": "/consumer/Xcode.app/Contents/Developer"}
        outputs = module.restore(self.consumer, current)
        self.assertEqual(set(outputs), {FIXTURE_OUTPUT})
        for path in outputs.values():
            value = plistlib.loads(Path(path).read_bytes())
            target = list(module.targets(value))[0]
            self.assertEqual(target["EnvironmentVariables"]["SOURCE"], "/consumer/work/cmux/fixtures")
            self.assertFalse(module.hosted_by_product(target))
            self.assertEqual(target["DependentProductPaths"], [str(self.consumer / "Build/Products" / self.bundle)])
            self.assertTrue(Path(target["DependentProductPaths"][0]).exists())


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
        manifest = next(products.glob(f"{FIXTURE_SCHEME}_*.xctestrun"))
        shutil.copy2(manifest, products / f"{FIXTURE_SCHEME}_old.xctestrun")
        with self.assertRaisesRegex(ValueError, "found 2"):
            module.stamp(self.producer, self.identity)
        for path in products.glob(f"{FIXTURE_SCHEME}_*.xctestrun"):
            path.unlink()
        with self.assertRaisesRegex(ValueError, "found 0"):
            module.stamp(self.producer, self.identity)

    def test_empty_manifest_cannot_claim_success(self):
        products = self.producer / "Build/Products"
        next(products.glob(f"{FIXTURE_SCHEME}_*.xctestrun")).write_bytes(plistlib.dumps({}))
        with self.assertRaisesRegex(ValueError, "no test targets"):
            module.stamp(self.producer, self.identity)


class RealProfileTests(unittest.TestCase):
    def test_app_only_product_needs_no_manifest(self):
        # Every real test scheme publishes a manifest output; the app scheme
        # builds plainly, so an app-only product stamps and restores its receipt alone.
        self.assertEqual(set(module.SCHEME_OUTPUTS), set(module.product_inputs.TEST_SCHEMES))
        with tempfile.TemporaryDirectory() as temp:
            derived = Path(temp) / "derived"
            (derived / "Build/Products").mkdir(parents=True)
            identity = {"revision": "abc", "architecture": "arm64", "xcode": "Xcode 26.5\nBuild 1",
                        "developer": "/Xcode.app/Contents/Developer", "checkout": "/work"}
            with mock.patch.dict(os.environ, {"CMUX_PRODUCT_PROFILE": "app-host"}):
                module.stamp(derived, identity)
                self.assertEqual(module.restore(derived, identity), {})


if __name__ == "__main__":
    unittest.main()
