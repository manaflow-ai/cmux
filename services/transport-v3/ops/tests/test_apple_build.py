import importlib.util
import shutil
import tempfile
import unittest
from pathlib import Path


BUILD_PATH = Path(__file__).parents[1] / "apple" / "build.py"
SPEC = importlib.util.spec_from_file_location("cmux_v3_apple_build", BUILD_PATH)
BUILD = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(BUILD)


class AppleFrameworkLayoutTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.stage = Path(self.temp_dir.name)
        self.library = self.stage / "libcmux_v3_ffi.dylib"
        self.header = self.stage / "CmuxV3NativeFFI.h"
        self.library.write_bytes(b"binary")
        self.header.write_text("#pragma once\n")

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_macos_framework_uses_versioned_layout_without_root_info_plist(self):
        framework = BUILD.create_framework(
            self.stage, "macos-arm64_x86_64", self.library, self.header, versioned=True
        )
        version = framework / "Versions" / "A"

        self.assertTrue((version / "CmuxV3NativeFFI").is_file())
        self.assertTrue((version / "Headers" / "CmuxV3NativeFFI.h").is_file())
        self.assertTrue((version / "Modules" / "module.modulemap").is_file())
        self.assertTrue((version / "Resources" / "Info.plist").is_file())
        self.assertTrue((framework / "Versions" / "Current").is_symlink())
        for name in ("Headers", "Modules", "Resources", "CmuxV3NativeFFI"):
            self.assertTrue((framework / name).is_symlink(), name)
        self.assertFalse((framework / "Info.plist").exists())
        self.assertEqual(
            BUILD.framework_install_name(versioned=True),
            "@rpath/CmuxV3NativeFFI.framework/Versions/A/CmuxV3NativeFFI",
        )

    def test_ios_framework_is_shallow(self):
        for identifier in ("ios-arm64", "ios-arm64-simulator"):
            with self.subTest(identifier=identifier):
                framework = BUILD.create_framework(
                    self.stage, identifier, self.library, self.header, versioned=False
                )
                self.assertFalse((framework / "Versions").exists())
                binary = BUILD.framework_binary_path(framework, versioned=False)
                self.assertEqual(binary, framework / "CmuxV3NativeFFI")
                self.assertEqual(binary.read_bytes(), b"binary")
                self.assertFalse(binary.is_symlink())
                self.assertTrue((framework / "Headers" / "CmuxV3NativeFFI.h").is_file())
                self.assertTrue((framework / "Modules" / "module.modulemap").is_file())
                self.assertTrue((framework / "Info.plist").is_file())
                self.assertFalse((framework / "Info.plist").is_symlink())
        self.assertEqual(
            BUILD.framework_install_name(versioned=False),
            "@rpath/CmuxV3NativeFFI.framework/CmuxV3NativeFFI",
        )

    def test_copy_preserves_versioned_and_shallow_framework_topology(self):
        source = self.stage / "CmuxV3NativeFFI.xcframework"
        mac = BUILD.create_framework(
            source, "macos-arm64_x86_64", self.library, self.header, versioned=True
        )
        ios = BUILD.create_framework(
            source, "ios-arm64", self.library, self.header, versioned=False
        )
        destination = self.stage / "copied.xcframework"
        BUILD.copy_artifact(source, destination)

        expected = BUILD.artifact_manifest(source, [source])
        actual = BUILD.artifact_manifest(destination, [destination])
        self.assertEqual(actual, expected)
        copied_mac = destination / mac.relative_to(source)
        copied_ios = destination / ios.relative_to(source)
        self.assertTrue((copied_mac / "Versions" / "Current").is_symlink())
        self.assertTrue((copied_mac / "CmuxV3NativeFFI").is_symlink())
        self.assertFalse((copied_ios / "Versions").exists())
        self.assertFalse((copied_ios / "CmuxV3NativeFFI").is_symlink())

    def create_receipted_package(self):
        package = self.stage / "package"
        artifact = package / "Native" / "CmuxV3NativeFFI.xcframework"
        framework = BUILD.create_framework(
            artifact, "macos-arm64_x86_64", self.library, self.header, versioned=True
        )
        bindings = package / "Sources" / "CmuxV3Native" / "CmuxV3Native.swift"
        bindings.parent.mkdir(parents=True)
        bindings.write_text("// generated Swift bindings\n")
        receipt = {
            "source": "source-hash",
            "layout": BUILD.RECEIPT_LAYOUT_VERSION,
            **BUILD.artifact_manifest(package, [artifact, bindings]),
        }
        self.assertTrue(BUILD.receipt_matches(package, receipt, "source-hash"))
        return package, artifact, framework, bindings, receipt

    def test_receipt_rejects_dereferenced_symlinks(self):
        package, artifact, _, _, receipt = self.create_receipted_package()
        flattened = self.stage / "flattened.xcframework"
        # The default copytree behavior is the regression this receipt must
        # reject. It follows the versioned framework's root symlinks.
        shutil.copytree(artifact, flattened)
        shutil.rmtree(artifact)
        flattened.rename(artifact)
        self.assertFalse(BUILD.receipt_matches(package, receipt, "source-hash"))

    def test_receipt_rejects_retargeted_symlink_with_identical_content(self):
        package, _, framework, _, receipt = self.create_receipted_package()
        binary_link = framework / "CmuxV3NativeFFI"
        binary_link.unlink()
        binary_link.symlink_to("Versions/A/CmuxV3NativeFFI")
        self.assertEqual(binary_link.read_bytes(), b"binary")
        self.assertFalse(BUILD.receipt_matches(package, receipt, "source-hash"))

    def test_receipt_rejects_changed_bindings_and_added_files(self):
        package, artifact, _, bindings, receipt = self.create_receipted_package()
        original = bindings.read_bytes()
        bindings.write_text("// stale bindings\n")
        self.assertFalse(BUILD.receipt_matches(package, receipt, "source-hash"))
        bindings.write_bytes(original)
        self.assertTrue(BUILD.receipt_matches(package, receipt, "source-hash"))
        (artifact / "unexpected-file").write_text("unexpected")
        self.assertFalse(BUILD.receipt_matches(package, receipt, "source-hash"))

    def test_receipt_rejects_legacy_receipt_and_changed_sources(self):
        package, _, _, _, receipt = self.create_receipted_package()
        self.assertFalse(BUILD.receipt_matches(package, receipt, "other-source-hash"))
        del receipt["layout"]
        self.assertFalse(BUILD.receipt_matches(package, receipt, "source-hash"))


if __name__ == "__main__":
    unittest.main()
