#!/usr/bin/env python3
"""Portable behavioral checks for the exact-run SwiftPM product transport."""
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
spec = importlib.util.spec_from_file_location("swiftpm_test_product", ROOT / "scripts/ci/swiftpm_test_product.py")
product = importlib.util.module_from_spec(spec)
spec.loader.exec_module(product)


class ProductTests(unittest.TestCase):
    def setUp(self):
        git_environment = mock.patch.dict(os.environ, {"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull})
        git_environment.start()
        self.addCleanup(git_environment.stop)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.checkout = self.root / "checkout"
        for name in product.INPUT_ROOTS:
            folder = self.checkout / name
            folder.mkdir(parents=True)
            (folder / "input.swift").write_text("let value = 1\n")
        self.git("init", "-q")
        self.git("add", "Packages")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "Fixture")
        self.git("remote", "add", "origin", "https://github.com/manaflow-ai/cmux.git")
        self.scratch = self.root / "scratch"
        self.scratch.mkdir()
        debug = self.scratch / "arm64-apple-macosx/debug"
        debug.mkdir(parents=True)
        binary = debug / "CmuxNextPackageTests.xctest/Contents/MacOS/tests"
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"test-executable")
        binary.chmod(0o755)
        (debug / "CmuxNext_Settings.bundle").mkdir()
        (debug / "CmuxNext_Settings.bundle/en.strings").write_text("translated")
        (self.scratch / "build.db").write_bytes(b"private database")
        (self.scratch / "workspace-state.json").write_text("{}")
        (self.scratch / "debug").symlink_to("arm64-apple-macosx/debug")
        self.identity = {
            "schema": product.SCHEMA, "run_id": "123", "run_attempt": "1",
            "repository": "https://github.com/manaflow-ai/cmux.git",
            "revision": self.git("rev-parse", "HEAD"), "tree": self.git("rev-parse", "HEAD^{tree}"), "dirty": False,
            "checkout": str(self.checkout), "scratch": str(self.scratch),
            "xcode": "Xcode 26.6\nBuild version 17F20", "swift": "Swift 6.3.3",
            "swift_path": "/Applications/Xcode.app/Contents/Developer/Toolchains/default/usr/bin/swift",
            "developer": "/Applications/Xcode.app/Contents/Developer",
            "sdk": "/Applications/Xcode.app/Contents/Developer/SDKs/MacOSX26.6.sdk",
            "sdk_version": "26.6", "architecture": "arm64", "configuration": "debug",
            "flags": ["--build-tests"], "environment": {k: "" for k in product.ENV_KEYS},
            "inputs": {name: product.input_digest(self.checkout / name) for name in product.INPUT_ROOTS},
        }
        self.archive = self.root / "product.tar.gz"

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.checkout, text=True, stderr=subprocess.DEVNULL).strip()

    def seal(self):
        return product.seal(self.scratch, self.archive, self.identity)["sha256"]

    def release_destination(self):
        self.scratch.rename(self.root / "producer-scratch")

    def rewrite(self, transform):
        with tarfile.open(self.archive, "r:gz") as tar:
            rows = [(m, tar.extractfile(m).read() if m.isfile() else None) for m in tar]
        rows = transform(rows)
        with tarfile.open(self.archive, "w:gz") as tar:
            for member, data in rows:
                tar.addfile(member, io.BytesIO(data) if data is not None else None)
        return product.digest_file(self.archive)

    def test_round_trip_preserves_executables_resources_links_and_private_database(self):
        sha = self.seal()
        self.release_destination()
        receipt = product.restore(self.archive, self.identity, sha, self.scratch)
        self.assertEqual(receipt["outcome"], "restored")
        self.assertEqual((self.scratch / "debug/CmuxNext_Settings.bundle/en.strings").read_text(), "translated")
        binary = self.scratch / "debug/CmuxNextPackageTests.xctest/Contents/MacOS/tests"
        self.assertTrue(os.access(binary, os.X_OK))
        self.assertTrue((self.scratch / "debug").is_symlink())
        self.assertNotEqual((self.scratch / "build.db").stat().st_ino, (self.root / "producer-scratch/build.db").stat().st_ino)
        (self.scratch / "build.db").write_bytes(b"consumer writes")
        self.assertEqual((self.root / "producer-scratch/build.db").read_bytes(), b"private database")

    def test_every_identity_dimension_invalidates_without_creating_destination(self):
        sha = self.seal()
        self.release_destination()
        for key in self.identity:
            if key == "schema":
                continue
            expected = copy.deepcopy(self.identity)
            if key in ("inputs", "environment"):
                first = next(iter(expected[key]))
                expected[key][first] = "f" * 64 if key == "inputs" else "changed"
            elif key == "flags":
                expected[key] += ["-debug-info-format", "none"]
            elif key == "dirty":
                expected[key] = True
            else:
                expected[key] += "-changed"
            with self.subTest(key=key), self.assertRaises((product.Miss, ValueError)):
                product.restore(self.archive, expected, sha, self.scratch)
            self.assertFalse(self.scratch.exists())

    def test_existing_directory_and_dangling_symlink_are_untouched(self):
        sha = self.seal()
        with self.assertRaisesRegex(product.Miss, "already exists"):
            product.restore(self.archive, self.identity, sha, self.scratch)
        self.assertEqual((self.scratch / "build.db").read_bytes(), b"private database")
        self.release_destination()
        self.scratch.symlink_to(self.root / "absent-warm-cache")
        with self.assertRaisesRegex(product.Miss, "already exists"):
            product.restore(self.archive, self.identity, sha, self.scratch)
        self.assertTrue(self.scratch.is_symlink())

    def test_corruption_and_partial_product_leave_output_absent(self):
        sha = self.seal()
        self.release_destination()
        with self.archive.open("ab") as output:
            output.write(b"corrupt")
        with self.assertRaisesRegex(product.Miss, "digest"):
            product.restore(self.archive, self.identity, sha, self.scratch)
        sha = self.rewrite(lambda rows: [row for row in rows if row[0].name != "scratch/build.db"])
        with self.assertRaisesRegex(product.Miss, "contents mismatch"):
            product.restore(self.archive, self.identity, sha, self.scratch)
        self.assertFalse(self.scratch.exists())

    def test_payload_change_with_new_transport_digest_is_rejected(self):
        self.seal()
        self.release_destination()
        def change(rows):
            return [(m, b"wrong database!!" if m.name == "scratch/build.db" else b) for m, b in rows]
        sha = self.rewrite(change)
        with self.assertRaisesRegex(product.Miss, "contents mismatch"):
            product.restore(self.archive, self.identity, sha, self.scratch)
        self.assertFalse(self.scratch.exists())

    def test_unsafe_and_duplicate_archive_members_are_rejected(self):
        self.seal()
        self.release_destination()
        original = self.archive.read_bytes()
        for name, kind, link in (("scratch/../../escape", tarfile.REGTYPE, ""),
                                  ("/absolute", tarfile.REGTYPE, ""),
                                  ("scratch/bad", tarfile.SYMTYPE, "../../escape"),
                                  ("scratch/bad", tarfile.LNKTYPE, "scratch/build.db"),
                                  ("scratch/build.db", tarfile.REGTYPE, "")):
            self.archive.write_bytes(original)
            member = tarfile.TarInfo(name)
            member.type, member.linkname = kind, link
            sha = self.rewrite(lambda rows: [(member, b"" if kind == tarfile.REGTYPE else None), *rows])
            with self.subTest(name=name, kind=kind), self.assertRaises((product.Miss, OSError)):
                product.restore(self.archive, self.identity, sha, self.scratch)
            self.assertFalse(self.scratch.exists())
            self.assertFalse((self.root / "escape").exists())

    def test_seal_refuses_external_links_partial_roots_and_overwrite(self):
        (self.scratch / "external").symlink_to("../outside")
        with self.assertRaisesRegex(product.Miss, "escaping"):
            self.seal()
        (self.scratch / "external").unlink()
        self.seal()
        original = self.archive.read_bytes()
        with self.assertRaises(FileExistsError):
            self.seal()
        self.assertEqual(self.archive.read_bytes(), original)
        self.archive.unlink()
        shutil.rmtree(self.scratch / "arm64-apple-macosx")
        (self.scratch / "debug").unlink()
        with self.assertRaisesRegex(product.Miss, "no built test"):
            self.seal()

    def test_materialized_ignored_resources_change_identity_hash(self):
        package = self.checkout / product.INPUT_ROOTS[0]
        before = product.input_digest(package)
        generated = package / "Sources/Resources/generated.js"
        generated.parent.mkdir(parents=True)
        generated.write_text("generated ignored bytes")
        self.assertNotEqual(product.input_digest(package), before)
        after = product.input_digest(package)
        (package / ".build").mkdir()
        (package / ".build/output").write_bytes(b"scratch output")
        self.assertEqual(product.input_digest(package), after)
        with self.assertRaisesRegex(product.Miss, "inputs changed"):
            self.seal()

    def test_framework_symlink_chains_remain_inside_the_snapshot(self):
        framework = self.scratch / "artifacts/Example.framework"
        (framework / "Versions/A").mkdir(parents=True)
        (framework / "Versions/A/Example").write_bytes(b"framework binary")
        (framework / "Versions/Current").symlink_to("A")
        (framework / "Example").symlink_to("Versions/Current/Example")
        sha = self.seal()
        self.release_destination()
        product.restore(self.archive, self.identity, sha, self.scratch)
        self.assertEqual((self.scratch / "artifacts/Example.framework/Example").read_bytes(), b"framework binary")

    def test_git_credentials_and_repository_caches_are_not_packaged(self):
        for name in ("repositories/bare/config", "downloads/cache", "checkouts/dependency/.git/config"):
            path = self.scratch / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("credential-bearing cache")
        (self.scratch / "checkouts/dependency/Package.swift").write_text("dependency manifest")
        sha = self.seal()
        self.release_destination()
        product.restore(self.archive, self.identity, sha, self.scratch)
        for name in ("repositories", "downloads", "checkouts/dependency/.git"):
            self.assertFalse((self.scratch / name).exists())
        self.assertTrue((self.scratch / "checkouts/dependency/Package.swift").exists())

    def test_producer_scratch_symlink_is_read_without_replacing_it(self):
        warm_link = self.root / ".build"
        warm_link.symlink_to(self.scratch)
        product.seal(warm_link, self.archive, self.identity)
        self.assertTrue(warm_link.is_symlink())
        self.assertEqual((warm_link / "build.db").read_bytes(), b"private database")

    def test_archive_limits_fail_before_destination_install(self):
        sha = self.seal()
        self.release_destination()
        with mock.patch.object(product, "MAX_ARCHIVE", 1), self.assertRaises(product.Miss):
            product.restore(self.archive, self.identity, sha, self.scratch)
        with mock.patch.object(product, "MAX_EXPANDED", 1), self.assertRaises((product.Miss, ValueError)):
            product.restore(self.archive, self.identity, sha, self.scratch)
        self.assertFalse(self.scratch.exists())

    def test_stale_identity_cannot_restore_after_overlay_or_head_changes(self):
        sha = self.seal()
        self.release_destination()
        overlay = self.checkout / product.INPUT_ROOTS[0] / "generated.js"
        overlay.write_text("new consumer overlay")
        with self.assertRaisesRegex(product.Miss, "inputs changed"):
            product.restore(self.archive, self.identity, sha, self.scratch)
        overlay.unlink()
        (self.checkout / "unrelated.txt").write_text("different exact source revision")
        self.git("add", "unrelated.txt")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "New head")
        with self.assertRaisesRegex(product.Miss, "source revision"):
            product.restore(self.archive, self.identity, sha, self.scratch)
        self.assertFalse(self.scratch.exists())

    def test_generated_overlay_in_local_ios_dependency_invalidates(self):
        sha = self.seal()
        self.release_destination()
        generated = self.checkout / "Packages/iOS/CmuxMobileSSH/Sources/generated.swift"
        generated.parent.mkdir(parents=True)
        generated.write_text("ignored local dependency input")
        with self.assertRaisesRegex(product.Miss, "inputs changed"):
            product.restore(self.archive, self.identity, sha, self.scratch)
        self.assertFalse(self.scratch.exists())

    def test_identity_uses_the_swift_executable_that_the_build_will_run(self):
        def output(argv, **kwargs):
            if argv[0] == "git":
                return self.git(*argv[1:])
            if argv[0].endswith("swift-shadow"):
                return "Shadow Swift 6.3.3"
            return {("xcodebuild", "-version"): "Xcode 26.6",
                    ("xcode-select", "-p"): "/Applications/Xcode.app/Contents/Developer",
                    ("xcrun", "--sdk", "macosx", "--show-sdk-path"): "/SDK/MacOSX26.6.sdk",
                    ("xcrun", "--sdk", "macosx", "--show-sdk-version"): "26.6"}[tuple(argv)]
        # Keep Git real while mocking only the native tool probes.
        original_check_output = subprocess.check_output
        def probe(argv, **kwargs):
            return original_check_output(argv, **kwargs) if argv[0] == "git" else output(argv, **kwargs)
        with mock.patch.dict(os.environ, {k: "" for k in product.ENV_KEYS}), \
                mock.patch.object(product.shutil, "which", return_value="/toolchain/swift-shadow"), \
                mock.patch.object(product.subprocess, "check_output", side_effect=probe):
            captured = product.identity(self.checkout, self.scratch, "123", "1", "debug", ["--build-tests"])
        self.assertEqual(captured["swift_path"], "/toolchain/swift-shadow")
        self.assertEqual(captured["swift"], "Shadow Swift 6.3.3")

    def test_identity_requires_complete_contract_and_supported_build_options(self):
        for key in self.identity:
            missing = dict(self.identity)
            del missing[key]
            with self.subTest(key=key), self.assertRaises(product.Miss):
                product.validate_identity(missing)
        unsupported = copy.deepcopy(self.identity)
        unsupported["flags"] = ["-Xlinker", "-L/other/cache"]
        with self.assertRaisesRegex(product.Miss, "unsupported"):
            product.validate_identity(unsupported)
        unsupported = copy.deepcopy(self.identity)
        unsupported["environment"]["LDFLAGS"] = "-L/other/cache"
        with self.assertRaisesRegex(product.Miss, "unsupported"):
            product.validate_identity(unsupported)

    def test_concurrent_destination_claim_does_not_replace_other_owner(self):
        sha = self.seal()
        self.release_destination()
        original_inspect = product.inspect
        def inspect_then_claim(*args):
            receipt = original_inspect(*args)
            self.scratch.mkdir()
            (self.scratch / "owner").write_text("other job")
            return receipt
        with mock.patch.object(product, "inspect", side_effect=inspect_then_claim), self.assertRaises(FileExistsError):
            product.restore(self.archive, self.identity, sha, self.scratch)
        self.assertEqual((self.scratch / "owner").read_text(), "other job")
        self.assertFalse((self.scratch / "build.db").exists())


if __name__ == "__main__":
    unittest.main()
