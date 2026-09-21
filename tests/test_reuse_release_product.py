#!/usr/bin/env python3
import copy
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import reuse_release_product as reuse


class FakeGitHub:
    repository = "manaflow-ai/cmux"

    def __init__(self, contract):
        self.tree = contract["tree"]
        self.run = {
            "id": 12,
            "path": ".github/workflows/ci.yml",
            "event": "pull_request",
            "head_repository": {"full_name": self.repository},
            "run_attempt": 2,
            "head_sha": "a" * 40,
            "html_url": "https://github.com/manaflow-ai/cmux/actions/runs/12",
        }
        self.artifact = {
            "id": 42,
            "name": reuse.PREFIX + reuse.app_host_reuse.key(contract) + "-1",
            "size_in_bytes": 100,
            "expired": False,
            "workflow_run": {"id": 12},
        }
        self.job = {"name": "release-build", "conclusion": "success", "status": "completed"}
        self.archive = None

    def get(self, path):
        if path.startswith("actions/artifacts?"):
            return {"artifacts": [] if self.artifact is None else [self.artifact]}
        if path.startswith("actions/runs/") and "/attempts/" in path:
            return {"jobs": [self.job]}
        if path.startswith("actions/runs/"):
            return self.run
        if path.startswith("git/commits/"):
            return {"tree": {"sha": self.tree}}
        raise AssertionError(path)

    def download(self, artifact_id, target):
        if self.archive is None:
            raise AssertionError("missing fixture archive")
        shutil.copyfile(self.archive, target)


class ReleaseProductReuseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cmux-release-product-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.producer = self.root / "producer"
        self.consumer = self.root / "consumer"
        self.contract = {
            "tree": "c" * 40,
            "xcode": "Xcode 26.3",
            "sdk": "26C123",
            "release_architectures": "arm64 x86_64",
            "package_resolved_sha256": "d" * 64,
            "build_flags": dict(reuse.BUILD_FLAGS),
            "ghostty_helper": {"sha256": "e" * 64, "toolchain_sha256": "f" * 64, "sdk": "15.5"},
            "cmux_tui": {"commit": "1" * 40, "manifest_sha256": "2" * 64},
        }
        self.api = FakeGitHub(self.contract)
        self._make_product()

    def _make_product(self, receipt_mutator=None):
        app = self.producer / Path(reuse.APP_REL)
        binary = app / "Contents/MacOS/cmux"
        binary.parent.mkdir(parents=True, exist_ok=True)
        binary.write_bytes(b"release-app-bytes")
        binary.chmod(0o755)
        resources = app / "Contents/Resources/bin"
        resources.mkdir(parents=True)
        helper = resources / "ghostty"
        helper.write_bytes(b"helper-bytes")
        helper.chmod(0o755)
        versions = app / "Contents/Frameworks/Test.framework/Versions/A"
        versions.mkdir(parents=True)
        (versions / "Test").write_bytes(b"framework")
        current = app / "Contents/Frameworks/Test.framework/Versions/Current"
        current.symlink_to("A")
        receipt = {
            "schema_version": 1,
            "contract": self.contract,
            "revision": "a" * 40,
            "run_id": "12",
            "run_attempt": "1",
            "product_sha256": reuse.product_digest(app),
        }
        if receipt_mutator:
            receipt_mutator(receipt)
        receipt_path = self.producer / Path(reuse.RECEIPT_REL)
        receipt_path.parent.mkdir(parents=True, exist_ok=True)
        receipt_path.write_text(json.dumps(receipt))
        inner = self.root / "release.tar.gz"
        reuse.pack(self.producer, inner)
        outer = self.root / "artifact.zip"
        with zipfile.ZipFile(outer, "w") as archive:
            archive.write(inner, reuse.ARCHIVE_NAME)
        self.api.archive = outer
        self.api.artifact["digest"] = "sha256:" + hashlib.sha256(outer.read_bytes()).hexdigest()
        self.api.artifact["size_in_bytes"] = outer.stat().st_size

    def restore(self, contract=None, current_run="12", current_attempt=2):
        return reuse.restore(self.api, contract or self.contract, self.consumer, current_run, current_attempt)

    def assert_rebuild_for_contract_change(self, mutator):
        changed = copy.deepcopy(self.contract)
        mutator(changed)
        result = self.restore(changed)
        self.assertFalse(result["hit"])
        self.assertEqual(result["outcome"], "restore_miss")
        self.assertFalse((self.consumer / Path(reuse.APP_REL)).exists())

    def test_exact_hit_restores_prior_attempt_and_preserves_symlinks(self):
        result = self.restore()
        self.assertTrue(result["hit"])
        self.assertEqual(result["outcome"], "exact_restore")
        self.assertEqual(result["producer_run_attempt"], "1")
        app = self.consumer / Path(reuse.APP_REL)
        self.assertEqual((app / "Contents/MacOS/cmux").read_bytes(), b"release-app-bytes")
        self.assertTrue((app / "Contents/Frameworks/Test.framework/Versions/Current").is_symlink())
        provenance = json.loads((self.consumer / "Build/Products" / reuse.PROVENANCE).read_text())
        self.assertEqual(provenance["artifact_id"], 42)

    def test_source_mismatch_forces_rebuild(self):
        self.assert_rebuild_for_contract_change(lambda value: value.__setitem__("tree", "9" * 40))

    def test_xcode_or_sdk_mismatch_forces_rebuild(self):
        for field in ("xcode", "sdk"):
            with self.subTest(field=field):
                self.assert_rebuild_for_contract_change(
                    lambda value, field=field: value.__setitem__(field, "different")
                )

    def test_architecture_mismatch_forces_rebuild(self):
        self.assert_rebuild_for_contract_change(
            lambda value: value.__setitem__("release_architectures", "arm64")
        )

    def test_build_flag_mismatch_forces_rebuild(self):
        self.assert_rebuild_for_contract_change(
            lambda value: value["build_flags"].__setitem__("CODE_SIGNING_ALLOWED", "YES")
        )

    def test_dependency_mismatch_forces_rebuild(self):
        self.assert_rebuild_for_contract_change(
            lambda value: value.__setitem__("package_resolved_sha256", "8" * 64)
        )

    def test_missing_artifact_is_restore_miss(self):
        self.api.artifact = None
        result = self.restore()
        self.assertEqual(result["outcome"], "restore_miss")
        self.assertEqual(result["reason"], "no_exact_artifact")

    def test_corrupt_artifact_falls_back_without_populating_destination(self):
        self.api.archive.write_bytes(b"corrupt")
        self.api.artifact["digest"] = "sha256:" + hashlib.sha256(b"corrupt").hexdigest()
        result = self.restore()
        self.assertFalse(result["hit"])
        self.assertEqual(result["outcome"], "fallback_rebuild")
        self.assertFalse((self.consumer / Path(reuse.APP_REL)).exists())

    def test_bad_receipt_falls_back(self):
        shutil.rmtree(self.producer)
        self._make_product(lambda receipt: receipt.__setitem__("run_id", "99"))
        result = self.restore()
        self.assertFalse(result["hit"])
        self.assertEqual(result["outcome"], "fallback_rebuild")
        self.assertFalse((self.consumer / Path(reuse.APP_REL)).exists())

    def test_current_attempt_is_never_its_own_source(self):
        self.api.artifact["name"] = reuse.PREFIX + reuse.app_host_reuse.key(self.contract) + "-2"
        result = self.restore(current_attempt=2)
        self.assertFalse(result["hit"])
        self.assertEqual(result["outcome"], "fallback_rebuild")

    def test_product_digest_rejects_content_tampering(self):
        receipt_path = self.producer / Path(reuse.RECEIPT_REL)
        receipt = json.loads(receipt_path.read_text())
        receipt["product_sha256"] = "0" * 64
        receipt_path.write_text(json.dumps(receipt))
        inner = self.root / "tampered.tar.gz"
        reuse.pack(self.producer, inner)
        with zipfile.ZipFile(self.api.archive, "w") as archive:
            archive.write(inner, reuse.ARCHIVE_NAME)
        self.api.artifact["digest"] = "sha256:" + hashlib.sha256(self.api.archive.read_bytes()).hexdigest()
        result = self.restore()
        self.assertEqual(result["outcome"], "fallback_rebuild")


if __name__ == "__main__":
    unittest.main()
