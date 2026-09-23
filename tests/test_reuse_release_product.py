#!/usr/bin/env python3
import ast
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
import unittest
from unittest import mock
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
        if path.startswith(f"actions/runs/{self.run['id']}/artifacts?"):
            return {"artifacts": [] if self.artifact is None else [self.artifact]}
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
            # Model a PR checkout: the built synthetic merge tree differs from
            # the branch head revision reported by workflow_run.head_sha.
            "tree": "c" * 40,
            "source_revision": "a" * 40,
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

    def test_reusable_macos_job_name_restores_release_product(self):
        self.api.job["name"] = "macos / release-build"
        result = self.restore()
        self.assertTrue(result["hit"], result)
        self.assertEqual(result["outcome"], "exact_restore")

    def test_unrelated_reusable_job_name_cannot_authorize_release_product(self):
        self.api.job["name"] = "untrusted / release-build"
        result = self.restore()
        self.assertFalse(result["hit"], result)
        self.assertFalse((self.consumer / Path(reuse.APP_REL)).exists())

    def test_product_digest_ignores_symlink_permission_bits_with_mock_metadata(self):
        app = self.producer / Path(reuse.APP_REL)
        link = app / "Contents/Frameworks/Test.framework/Versions/Current"
        baseline = reuse.product_digest(app)
        original_lstat = Path.lstat

        def lstat(path):
            metadata = original_lstat(path)
            if path == link:
                values = list(metadata)
                values[0] = (metadata.st_mode & ~0o777) | 0o600
                return type(metadata)(values)
            return metadata

        with mock.patch.object(Path, "lstat", autospec=True, side_effect=lstat):
            self.assertEqual(reuse.product_digest(app), baseline)

    def test_product_digest_ignores_symlink_permission_bits(self):
        app = self.producer / Path(reuse.APP_REL)
        expected = reuse.product_digest(app)
        original_lstat = Path.lstat

        def lstat_with_different_link_mode(path):
            metadata = original_lstat(path)
            if stat.S_ISLNK(metadata.st_mode):
                metadata = mock.Mock(st_mode=(metadata.st_mode & ~0o777) | 0o700)
            return metadata

        with mock.patch.object(Path, "lstat", new=lstat_with_different_link_mode):
            self.assertEqual(reuse.product_digest(app), expected)

    def test_source_mismatch_forces_rebuild(self):
        self.assert_rebuild_for_contract_change(
            lambda value: value.__setitem__("source_revision", "9" * 40)
        )

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

    def test_same_run_artifact_survives_busy_repository_window(self):
        calls = []
        original_get = self.api.get

        def get(path):
            calls.append(path)
            if path.startswith("actions/artifacts?"):
                return {"artifacts": [
                    {"id": 1000 + index, "name": "unrelated-artifact"}
                    for index in range(100)
                ]}
            return original_get(path)

        with mock.patch.object(self.api, "get", side_effect=get):
            result = self.restore()

        self.assertTrue(result["hit"])
        artifact_lookups = [path for path in calls if "artifacts?" in path]
        self.assertTrue(artifact_lookups[0].startswith("actions/runs/12/artifacts?"))
        self.assertLessEqual(
            sum(path.startswith("actions/artifacts?") for path in artifact_lookups),
            3,
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

    def test_post_move_failure_cleans_restored_product_and_metadata(self):
        with mock.patch.object(reuse.shutil, "copy2", side_effect=OSError("copy failed")):
            result = self.restore()

        self.assertFalse(result["hit"])
        self.assertEqual(result["outcome"], "fallback_rebuild")
        products = self.consumer / "Build/Products"
        self.assertFalse((self.consumer / Path(reuse.APP_REL)).exists())
        self.assertFalse((products / reuse.RECEIPT).exists())
        self.assertFalse((products / reuse.PROVENANCE).exists())

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


class ContractCoverageTests(unittest.TestCase):
    """Bind the production contract to every key the restore path indexes.

    The fixtures above hand-build a contract dict, so a key that `restore`
    reads but `contract` never produces stays green here while every real CI
    candidate dies on KeyError and silently falls back to a full rebuild.
    """

    BRANCH_REVISION = "a" * 40
    GHOSTTY_REVISION = "b" * 40
    CHECKOUT_TREE = "c" * 40

    COMMANDS = {
        ("xcodebuild", "-version"): "Xcode 26.3\nBuild version 26C123",
        ("xcrun", "--sdk", "macosx", "--show-sdk-build-version"): "26C123",
        ("sw_vers", "-buildVersion"): "26C123",
        ("git", "-C", "ghostty", "rev-parse", "HEAD"): GHOSTTY_REVISION,
        ("git", "rev-parse", "HEAD^{tree}"): CHECKOUT_TREE,
    }

    ENVIRONMENT = {
        "CMUX_RELEASE_ARCHS": "arm64 x86_64",
        "CMUX_RELEASE_SOURCE_REVISION": BRANCH_REVISION,
        "CMUX_RELEASE_GHOSTTY_HELPER_SHA256": "e" * 64,
        "CMUX_RELEASE_GHOSTTY_HELPER_TOOLCHAIN_SHA256": "f" * 64,
        "CMUX_RELEASE_GHOSTTY_HELPER_SDK": "15.5",
        "CMUX_RELEASE_TUI_COMMIT": "1" * 40,
        "CMUX_RELEASE_TUI_MANIFEST_SHA256": "2" * 64,
    }

    def read(self, *args):
        """Stand in for the host toolchain while the real contract code runs."""
        if args in self.COMMANDS:
            return self.COMMANDS[args]
        if len(args) == 2 and args[1] in {"--version", "version"}:
            return f"{Path(args[0]).name} 1.0.0"
        raise AssertionError(f"unexpected command: {args}")

    def production_contract(self):
        """Evaluate the real contract() with only host commands stubbed out."""
        cwd = os.getcwd()
        self.addCleanup(os.chdir, cwd)
        os.chdir(ROOT)
        with mock.patch.object(reuse.app_host_reuse, "read", side_effect=self.read), \
                mock.patch.dict(os.environ, self.ENVIRONMENT):
            return reuse.contract()

    def indexed_keys(self):
        """Collect every value["..."] the module reads off a contract dict."""
        module = ast.parse((ROOT / "scripts/ci/reuse_release_product.py").read_text())
        keys = set()
        for function in ast.walk(module):
            if not isinstance(function, ast.FunctionDef) or function.name == "contract":
                continue
            arguments = function.args
            names = {argument.arg for argument in
                     [*arguments.posonlyargs, *arguments.args, *arguments.kwonlyargs]}
            if "value" not in names:
                continue
            for node in ast.walk(function):
                if (isinstance(node, ast.Subscript)
                        and isinstance(node.value, ast.Name)
                        and node.value.id == "value"
                        and isinstance(node.slice, ast.Constant)
                        and isinstance(node.slice.value, str)):
                    keys.add(node.slice.value)
        return keys

    def test_contract_carries_every_key_the_restore_path_indexes(self):
        keys = self.indexed_keys()
        # Guard the scan itself: an AST refactor that finds nothing must fail.
        self.assertLessEqual({"source_revision", "tree"}, keys)
        self.assertEqual(keys - set(self.production_contract()), set())

    def test_contract_binds_the_checked_out_tree_not_the_branch_revision(self):
        value = self.production_contract()
        # The producer receipt records `git rev-parse HEAD`; restore re-derives
        # that commit's tree from GitHub and compares it against this key, so
        # both sides must describe the compiled checkout, not the branch head.
        self.assertEqual(value["tree"], self.CHECKOUT_TREE)
        self.assertEqual(value["source_revision"], self.BRANCH_REVISION)
        self.assertNotEqual(value["tree"], value["source_revision"])

    def test_contract_key_changes_when_the_checkout_tree_changes(self):
        baseline = reuse.app_host_reuse.key(self.production_contract())
        self.COMMANDS = {**self.COMMANDS, ("git", "rev-parse", "HEAD^{tree}"): "9" * 40}
        self.assertNotEqual(reuse.app_host_reuse.key(self.production_contract()), baseline)

    def test_contract_rejects_an_unusable_checkout_tree(self):
        self.COMMANDS = {**self.COMMANDS, ("git", "rev-parse", "HEAD^{tree}"): "HEAD^{tree}"}
        with self.assertRaises(ValueError):
            self.production_contract()


if __name__ == "__main__":
    unittest.main()
