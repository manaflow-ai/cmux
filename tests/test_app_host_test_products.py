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
        for scheme in module.SCHEMES:
            target = {
                "TestHostPath": "__TESTROOT__/Debug/cmux DEV.app",
                "TestBundlePath": "__TESTHOST__/Contents/PlugIns/cmuxTests.xctest",
                "EnvironmentVariables": {"SOURCE": "/producer/work/cmux/fixtures"},
                "DependentProductPaths": [str(products / self.bundle)],
            }
            # Cover both manifest versions Xcode has shipped.
            value = {"cmuxTests": target} if scheme == "cmux-unit" else {"TestConfigurations": [{"TestTargets": [target]}]}
            (products / f"{scheme}_macosx26.5-arm64.xctestrun").write_bytes(plistlib.dumps(value))

    def transfer(self):
        module.stamp(self.producer, self.identity)
        shutil.copytree(self.producer / "Build/Products", self.consumer / "Build/Products")
        shutil.rmtree(self.producer)

    def test_relocation_preserves_nested_bundle_and_publishes_both_manifests(self):
        self.transfer()
        current = {**self.identity, "checkout": "/consumer/work/cmux", "developer": "/consumer/Xcode.app/Contents/Developer"}
        outputs = module.restore(self.consumer, current)
        self.assertEqual(set(outputs), set(module.SCHEMES.values()))
        for path in outputs.values():
            value = plistlib.loads(Path(path).read_bytes())
            target = list(module.targets(value))[0]
            self.assertEqual(target["EnvironmentVariables"]["SOURCE"], "/consumer/work/cmux/fixtures")
            self.assertEqual(target["DependentProductPaths"], [str(self.consumer / "Build/Products" / self.bundle)])
            self.assertTrue(Path(target["DependentProductPaths"][0]).exists())

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

    def test_empty_manifest_cannot_claim_success(self):
        products = self.producer / "Build/Products"
        next(products.glob("cmux-unit_*.xctestrun")).write_bytes(plistlib.dumps({}))
        with self.assertRaisesRegex(ValueError, "no test targets"):
            module.stamp(self.producer, self.identity)


if __name__ == "__main__":
    unittest.main()
