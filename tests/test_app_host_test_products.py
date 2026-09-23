#!/usr/bin/env python3
"""Exercise the build-product handoff across different runner paths and identities."""

import importlib.util
import plistlib
import shutil
import tempfile
import unittest
from pathlib import Path

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
        self.bundle = Path("Debug/cmux DEV.app/Contents/PlugIns/cmuxTests.xctest")
        (products / self.bundle).mkdir(parents=True)
        executable = products / "Debug/cmux DEV.app/Contents/MacOS/cmux DEV"
        executable.parent.mkdir(parents=True)
        executable.write_text("binary")
        for scheme in ("cmux", "cmux-unit", "cmux-numeric-locale"):
            target = {
                "TestHostPath": "__TESTROOT__/Debug/cmux DEV.app",
                "TestBundlePath": "__TESTHOST__/Contents/PlugIns/cmuxTests.xctest",
                "EnvironmentVariables": {"SOURCE": "/producer/work/cmux/fixtures"},
                "DependentProductPaths": [str(products / self.bundle)],
            }
            if scheme == "cmux":
                self.ui_bundle = Path("Debug/cmuxUITests-Runner.app/Contents/PlugIns/cmuxUITests.xctest")
                (products / self.ui_bundle).mkdir(parents=True)
                target.update({
                    "TestHostPath": "__TESTROOT__/Debug/cmuxUITests-Runner.app",
                    "TestBundlePath": "__TESTHOST__/Contents/PlugIns/cmuxUITests.xctest",
                    "UITargetAppPath": "__TESTROOT__/Debug/cmux DEV.app",
                    "DependentProductPaths": [str(products / self.ui_bundle)],
                })
            # Cover both manifest versions Xcode has shipped.
            value = {"cmuxTests": target} if scheme == "cmux-unit" else {"TestConfigurations": [{"TestTargets": [target]}]}
            (products / f"{scheme}_macosx26.5-arm64.xctestrun").write_bytes(plistlib.dumps(value))

    def transfer(self):
        module.stamp(self.producer, self.identity)
        shutil.copytree(self.producer / "Build/Products", self.consumer / "Build/Products")
        shutil.rmtree(self.producer)

    def test_relocation_preserves_nested_bundles_and_publishes_all_manifests(self):
        self.transfer()
        current = {**self.identity, "checkout": "/consumer/work/cmux", "developer": "/consumer/Xcode.app/Contents/Developer"}
        outputs = module.restore(self.consumer, current)
        self.assertEqual(set(outputs), {"CMUX_APP_HOST_XCTESTRUN", "CMUX_NUMERIC_LOCALE_XCTESTRUN", "CMUX_UI_XCTESTRUN"})
        for path in outputs.values():
            value = plistlib.loads(Path(path).read_bytes())
            target = list(module.targets(value))[0]
            self.assertEqual(target["EnvironmentVariables"]["SOURCE"], "/consumer/work/cmux/fixtures")
            bundle = self.ui_bundle if "UITargetAppPath" in target else self.bundle
            self.assertEqual(target["DependentProductPaths"], [str(self.consumer / "Build/Products" / bundle)])
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

    def test_missing_bundle_fails_in_producer_and_consumer(self):
        self.transfer()
        shutil.rmtree(self.consumer / "Build/Products" / self.bundle)
        with self.assertRaisesRegex(ValueError, "missing or unscoped"):
            module.restore(self.consumer, self.identity)

    def test_missing_or_ambiguous_manifest_is_rejected(self):
        products = self.producer / "Build/Products"
        manifest = next(products.glob("cmux-unit_*.xctestrun"))
        shutil.copy2(manifest, products / "cmux-unit_old.xctestrun")
        with self.assertRaisesRegex(ValueError, "found 2"):
            module.stamp(self.producer, self.identity)
        for path in products.glob("cmux-unit_*.xctestrun"):
            path.unlink()
        with self.assertRaisesRegex(ValueError, "found 0"):
            module.stamp(self.producer, self.identity)

    def test_missing_ui_bundle_is_rejected(self):
        self.transfer()
        shutil.rmtree(self.consumer / "Build/Products" / self.ui_bundle)
        with self.assertRaisesRegex(ValueError, "missing or unscoped"):
            module.restore(self.consumer, self.identity)

    def test_unscoped_ui_target_is_rejected(self):
        products = self.producer / "Build/Products"
        manifest = next(products.glob("cmux_*.xctestrun"))
        value = plistlib.loads(manifest.read_bytes())
        list(module.targets(value))[0]["UITargetAppPath"] = str(self.producer.parent)
        manifest.write_bytes(plistlib.dumps(value))
        with self.assertRaisesRegex(ValueError, "missing or unscoped"):
            module.stamp(self.producer, self.identity)

    def test_empty_manifest_cannot_claim_success(self):
        products = self.producer / "Build/Products"
        next(products.glob("cmux-unit_*.xctestrun")).write_bytes(plistlib.dumps({}))
        with self.assertRaisesRegex(ValueError, "no test targets"):
            module.stamp(self.producer, self.identity)


if __name__ == "__main__":
    unittest.main()
