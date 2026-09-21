#!/usr/bin/env python3
import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("layers", Path(__file__).resolve().parents[1] / "scripts/ci/app_host_layered_products.py")
layers = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(layers)
IDENTITY = {"source_sha": "a" * 40, "workflow_run_id": "123", "workflow_run_attempt": "2",
            "toolchain": {"xcode": "Xcode 26.0", "architecture": "arm64", "developer": "/Applications/Xcode.app"}}


@unittest.skipUnless(shutil.which("aa"), "Apple Archive requires macOS")
class LayerRoundTrip(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix="app-host-layer-test-")
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        self.derived = self.root / "producer"
        self.products = self.derived / layers.ROOT
        files = {
            "Debug/cmux DEV.app/Contents/MacOS/cmux DEV": b"signed executable",
            "Debug/cmux DEV.app/Contents/_CodeSignature/CodeResources": b"sealed resources include cmuxTests.xctest",
            "Debug/cmux DEV.app/Contents/Resources/data": b"resource",
            "Debug/cmux DEV.app/Contents/PlugIns/cmuxTests.xctest/Contents/MacOS/test": b"tests",
            "Debug/cmux DEV.app/Contents/Frameworks/F.framework/Versions/A/F": b"runtime",
            "Debug/cmux DEV.app/Contents/Frameworks/F.framework/Versions/A/Modules/F.swiftmodule/arm64.swiftmodule": b"sealed framework module",
            "Debug/CmuxTerminalCoreTests.xctest/test": b"direct xctest consumer",
            "Debug/cmux": b"cli",
            "Debug/input.o": b"diagnostic object",
            "Debug/input.o.keep": b"unknown retained product",
            "Debug/cmux.dSYM/Contents/Resources/DWARF/cmux": b"symbols",
            "cmux-unit.xctestrun": b"manifest",
            "Debug/private": b"private",
            "Debug/prefix/child": b"nested",
            "Debug/prefix.ext": b"sibling",
        }
        for name, data in files.items():
            path = self.products / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        (self.products / "Debug/private").chmod(0o600)
        (self.products / "Debug/cmux").chmod(0o755)
        subprocess.run(["xattr", "-w", "com.cmux.test", "preserve", str(self.products / "Debug/cmux")], check=True)
        framework = self.products / "Debug/cmux DEV.app/Contents/Frameworks/F.framework"
        (framework / "Versions/Current").symlink_to("A")
        (framework / "F").symlink_to("Versions/Current/F")
        (framework / "Headers").symlink_to("Versions/Current/Headers")
        self.output = self.root / "layers"
        layers.pack(self.derived, self.output, IDENTITY)
        self.manifest_path = self.output / layers.MANIFEST
        self.manifest = json.loads(self.manifest_path.read_text())

    def write_manifest(self, value):
        self.manifest_path.write_text(json.dumps(value))

    def assert_rejected(self, expected=IDENTITY, selected=None):
        target = self.root / "restored"
        with self.assertRaises((ValueError, KeyError, TypeError)):
            layers.restore(self.manifest_path, target, expected, selected)
        self.assertFalse(target.exists())

    def test_round_trip_preserves_tree_modes_links_xattrs_and_signatures(self):
        before = layers.inventory(self.derived)
        destination = self.root / "restored"
        layers.restore(self.manifest_path, destination, IDENTITY)
        self.assertEqual(before, layers.inventory(destination))
        self.assertEqual(before, layers.inventory(self.derived), "pack must not mutate producer")
        owners = {entry["path"]: layer["name"] for layer in self.manifest["layers"] for entry in layer["entries"]}
        self.assertEqual(owners["Build/Products/Debug/input.o"], "diagnostics")
        self.assertEqual(owners["Build/Products/Debug/input.o.keep"], "app-cli")
        self.assertEqual(owners["Build/Products/Debug/CmuxTerminalCoreTests.xctest/test"], "tests")
        self.assertEqual(owners["Build/Products/Debug/cmux DEV.app/Contents/Frameworks/F.framework/Versions/A/Modules/F.swiftmodule/arm64.swiftmodule"], "runtime")

    def test_selected_consumer_subset_restores_complete_authorized_groups(self):
        (self.output / "diagnostics.aar").unlink()
        destination = self.root / "selected-restored"
        selected = ("app-cli", "runtime", "tests")
        layers.restore(self.manifest_path, destination, IDENTITY, selected)

        products = destination / layers.ROOT
        for relative in (
            "Debug/cmux DEV.app/Contents/MacOS/cmux DEV",
            "Debug/cmux DEV.app/Contents/PlugIns/cmuxTests.xctest/Contents/MacOS/test",
            "Debug/cmux DEV.app/Contents/Frameworks/F.framework/Versions/A/F",
            "Debug/cmux DEV.app/Contents/Frameworks/F.framework/Versions/A/Modules/F.swiftmodule/arm64.swiftmodule",
            "Debug/CmuxTerminalCoreTests.xctest/test",
            "Debug/cmux",
            "Debug/input.o.keep",
            "cmux-unit.xctestrun",
        ):
            self.assertTrue((products / relative).exists() or (products / relative).is_symlink(), relative)
        self.assertFalse((products / "Debug/input.o").exists())
        self.assertFalse((products / "Debug/cmux.dSYM").exists())

    def test_selected_consumer_subset_rejects_corrupt_required_layer(self):
        (self.output / "diagnostics.aar").unlink()
        with (self.output / "tests.aar").open("ab") as stream:
            stream.write(b"corrupt")
        self.assert_rejected(selected=("app-cli", "runtime", "tests"))

    def test_selected_consumer_subset_rejects_cross_layer_symlink_dependency(self):
        producer = self.root / "symlink-producer"
        products = producer / layers.ROOT
        (products / "Debug").mkdir(parents=True)
        (products / "Debug/cmux").write_bytes(b"cli")
        (products / "Debug/input.o").write_bytes(b"diagnostic")
        (products / "Debug/diagnostic-link").symlink_to("input.o")
        output = self.root / "symlink-layers"
        layers.pack(producer, output, IDENTITY)
        with self.assertRaisesRegex(ValueError, "symlink closure"):
            layers.restore(output / layers.MANIFEST, self.root / "symlink-restored", IDENTITY,
                           ("app-cli", "runtime", "tests"))
        self.assertFalse((self.root / "symlink-restored").exists())

    def test_selected_consumer_subset_still_validates_full_canonical_ownership(self):
        self.manifest["layers"][3]["entries"].append(copy.deepcopy(self.manifest["layers"][0]["entries"][0]))
        self.write_manifest(self.manifest)
        self.assert_rejected(selected=("app-cli", "runtime", "tests"))

    def test_corrupt_archive(self):
        with (self.output / "tests.aar").open("ab") as stream:
            stream.write(b"corrupt")
        self.assert_rejected()

    def test_mixed_layer_same_filename_from_other_producer(self):
        (self.products / "Debug/cmux").write_bytes(b"other build")
        other = self.root / "other"
        layers.pack(self.derived, other, IDENTITY)
        shutil.copyfile(other / "app-cli.aar", self.output / "app-cli.aar")
        self.assert_rejected()

    def test_wrong_provenance(self):
        expected = {**IDENTITY, "workflow_run_attempt": "3"}
        self.assert_rejected(expected)

    def test_partial_restore_rejected_even_for_app_only_signed_resources(self):
        self.manifest["required_layers"].remove("tests")
        self.manifest["layers"] = [x for x in self.manifest["layers"] if x["name"] != "tests"]
        self.write_manifest(self.manifest)
        self.assert_rejected()

    def test_overlapping_file_ownership(self):
        self.manifest["layers"][1]["entries"].append(copy.deepcopy(self.manifest["layers"][0]["entries"][0]))
        self.write_manifest(self.manifest)
        self.assert_rejected()

    def test_traversal_manifest_path(self):
        self.manifest["layers"][0]["entries"][0]["path"] = "Build/Products/../../escape"
        self.write_manifest(self.manifest)
        self.assert_rejected()

    def test_tampered_file_content_digest(self):
        self.manifest["layers"][0]["entries"][0]["sha256"] = "0" * 64
        self.write_manifest(self.manifest)
        self.assert_rejected()

    def test_tampered_link(self):
        entry = next(e for l in self.manifest["layers"] for e in l["entries"] if e["type"] == "symlink")
        entry["target"] = "../../../../../../../../outside"
        self.write_manifest(self.manifest)
        self.assert_rejected()

    def test_existing_destination_never_modified(self):
        destination = self.root / "restored"
        destination.mkdir()
        (destination / "user").write_text("keep")
        with self.assertRaises(ValueError):
            layers.restore(self.manifest_path, destination, IDENTITY)
        self.assertEqual((destination / "user").read_text(), "keep")

    def test_unsafe_source_links_rejected_without_mutation(self):
        path = self.products / "Debug/escape"
        path.symlink_to("../../../../outside")
        with self.assertRaises(ValueError):
            layers.pack(self.derived, self.root / "unsafe", IDENTITY)
        self.assertTrue(path.is_symlink())

    def replace_archive(self, name, source, *options):
        layer = next(item for item in self.manifest["layers"] if item["name"] == name)
        archive = self.output / layer["archive"]
        archive.unlink()
        layers.run("aa", "archive", "-d", str(source), "-subdir", layers.ROOT, "-o", str(archive),
                   "-a", "lzfse", "-exclude-field", "uid,gid", "-include-field", "sh2", *options)
        layer.update(sha256=layers.digest(archive), size=archive.stat().st_size)
        self.write_manifest(self.manifest)

    def test_rehashed_archive_with_unowned_files_rejected_before_extraction(self):
        self.replace_archive("app-cli", self.derived)
        self.assert_rejected()

    def test_unscoped_archive_path_rejected_before_extraction(self):
        self.replace_archive("app-cli", self.derived, "-rename", layers.ROOT, "escaped")
        self.assert_rejected()
        self.assertFalse((self.root / "escaped").exists())

    def test_archive_link_target_does_not_override_manifest(self):
        framework = self.products / "Debug/cmux DEV.app/Contents/Frameworks/F.framework"
        (framework / "F").unlink()
        (framework / "F").symlink_to("/etc/passwd")
        directories = self.manifest["directories"]
        entries = [e for l in self.manifest["layers"] for e in l["entries"]]
        self.replace_archive("runtime", self.derived, "-exclude-regex", layers.exclusions(directories, entries, "runtime"))
        self.assert_rejected()

    def test_empty_layers_round_trip(self):
        producer = self.root / "minimal"
        (producer / layers.ROOT).mkdir(parents=True)
        (producer / layers.ROOT / "unknown").write_text("retain")
        output = self.root / "minimal-layers"
        layers.pack(producer, output, IDENTITY)
        layers.restore(output / layers.MANIFEST, self.root / "minimal-restored", IDENTITY)
        self.assertEqual(layers.inventory(producer), layers.inventory(self.root / "minimal-restored"))

    def test_dangling_destination_links_are_never_replaced(self):
        for name in ("restore-link", "pack-link"):
            (self.root / name).symlink_to("missing-user-target")
        with self.assertRaises(ValueError):
            layers.restore(self.manifest_path, self.root / "restore-link", IDENTITY)
        with self.assertRaises(ValueError):
            layers.pack(self.derived, self.root / "pack-link", IDENTITY)
        for name in ("restore-link", "pack-link"):
            self.assertEqual(os.readlink(self.root / name), "missing-user-target")

    def test_atomic_publication_never_replaces_racing_destination(self):
        source = self.root / "ready"
        source.mkdir()
        (source / "product").write_text("ready")
        destination = self.root / "racing-owner"
        destination.mkdir()
        with self.assertRaises(OSError):
            layers.publish(source, destination)
        self.assertTrue(source.is_dir())
        self.assertEqual(list(destination.iterdir()), [])

    def test_entry_beneath_link_is_rejected_before_extraction(self):
        link = next(e for l in self.manifest["layers"] for e in l["entries"] if e["type"] == "symlink")
        entry = copy.deepcopy(self.manifest["layers"][0]["entries"][0])
        entry["path"] = link["path"] + "/hidden-child"
        self.manifest["layers"][0]["entries"].append(entry)
        self.write_manifest(self.manifest)
        self.assert_rejected()

    def test_cyclic_source_link_chain_is_rejected(self):
        (self.products / "Debug/cycle-a").symlink_to("cycle-b")
        (self.products / "Debug/cycle-b").symlink_to("cycle-a")
        with self.assertRaises(ValueError):
            layers.pack(self.derived, self.root / "cycle", IDENTITY)
        self.assertFalse((self.root / "cycle").exists())

    def test_pack_output_cannot_recursively_enter_its_input(self):
        target = self.products / "recursive-output"
        with self.assertRaises(ValueError):
            layers.pack(self.derived, target, IDENTITY)
        self.assertFalse(target.exists())

    def test_layer_names_cannot_misrepresent_file_ownership(self):
        self.manifest["layers"][1]["entries"].append(self.manifest["layers"][0]["entries"].pop())
        self.write_manifest(self.manifest)
        self.assert_rejected()

    def test_creator_local_provenance_transition_is_allowed(self):
        for entry in self.manifest["directories"] + [e for l in self.manifest["layers"] for e in l["entries"]]:
            entry["xattrs"]["com.apple.provenance"] = "0" * 64
        self.write_manifest(self.manifest)
        layers.restore(self.manifest_path, self.root / "restored", IDENTITY)
        self.assertTrue((self.root / "restored/Build/Products/Debug/cmux").is_file())

    def test_other_xattr_mismatches_still_fail(self):
        for attribute in ("com.apple.quarantine", "com.cmux.test", "com.apple.cs.CodeDirectory"):
            with self.subTest(attribute=attribute):
                manifest = copy.deepcopy(self.manifest)
                manifest["layers"][0]["entries"][0]["xattrs"][attribute] = "0" * 64
                self.write_manifest(manifest)
                self.assert_rejected()

    def test_manifest_cannot_choose_extra_metadata_exclusions(self):
        self.manifest["metadata_policy"]["platform_local_xattrs"].append("com.apple.quarantine")
        self.write_manifest(self.manifest)
        self.assert_rejected()


if __name__ == "__main__":
    unittest.main()
