#!/usr/bin/env python3
"""Exercise cross-run artifact reuse through real archives and product relocation."""
import hashlib
import io
import json
import os
from unittest import mock
import shutil
import sys
import tarfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/ci"))
import reuse_app_host_products as reuse
from test_app_host_test_products import TestProductHandoff


class ReuseProducts(TestProductHandoff):
    def setUp(self):
        super().setUp()
        self.contract = {
            "tree": "same-tree",
            "xcode": "same-xcode",
            "sdk": "same-sdk",
            "os": "same-os",
            "architecture": "arm64",
            "tools": {"rustc": "rustc 1.0", "cargo": "cargo 1.0"},
            "environment": {"RUSTFLAGS": "", "SDKROOT": ""},
            "runner": "macos-arm64",
        }
        self.api = FakeGitHub(self.contract)
        self.api.archive = self.producer.parent / "artifact.zip"
        self.seal()

    def package(self, derived, archive_path):
        root = derived / "Build/Products"
        archive = derived.parent / "app-host-products.tar.gz"
        with tarfile.open(archive, "w:gz", dereference=True) as tar:
            tar.add(root, arcname="Build/Products")
        with zipfile.ZipFile(archive_path, "w") as z:
            z.write(archive, "app-host-products.tar.gz")
        return "sha256:" + hashlib.sha256(archive_path.read_bytes()).hexdigest()

    def seal(self):
        reuse.products.stamp(self.producer, self.identity)
        root = self.producer / "Build/Products"
        (root / reuse.RECEIPT).write_text(json.dumps({
            "contract": self.contract,
            "revision": self.identity["revision"],
            "run_id": str(self.api.run["id"]),
            "run_attempt": str(self.api.run["run_attempt"]),
        }))
        self.api.artifact["digest"] = self.package(self.producer, self.api.archive)

    def restore_reuse(self, *, current_run="13", current_attempt="1",
                      revision="def456", destination=None, report=None):
        current = {**self.identity, "revision": revision, "checkout": "/queue/work/cmux"}
        return reuse.restore(
            self.api,
            self.contract,
            destination or self.consumer,
            current_run,
            current,
            current_attempt,
            report,
        )

    def test_other_commit_same_tree_reuses_and_relocates_without_test_result(self):
        # The full run failed tests, while compilation itself succeeded.
        self.api.run["conclusion"] = "failure"
        self.assertTrue(self.restore_reuse())
        receipt = json.loads((self.consumer / "Build/Products" / reuse.products.RECEIPT).read_text())
        self.assertEqual(receipt["revision"], "def456")
        provenance = json.loads((self.consumer / "Build/Products/cmux-original-producer.json").read_text())
        self.assertEqual(provenance["revision"], "abc123")
        value = __import__('plistlib').loads(next((self.consumer / "Build/Products").glob('cmux-unit_*.xctestrun')).read_bytes())
        target = list(reuse.products.targets(value))[0]
        self.assertEqual(target['EnvironmentVariables']['SOURCE'], '/queue/work/cmux/fixtures')
        self.assertTrue(Path(target['DependentProductPaths'][0]).exists())

    def test_fork_wrong_workflow_and_failed_compile_are_misses(self):
        for field, value in [('event', 'workflow_dispatch'), ('path', '.github/workflows/untrusted.yml'),
                             ('head_repository', {'full_name': 'fork/cmux'})]:
            with self.subTest(field=field):
                old = self.api.run[field]
                self.api.run[field] = value
                self.assertFalse(self.restore_reuse())
                self.api.run[field] = old
        self.api.job['conclusion'] = 'failure'
        self.assertFalse(self.restore_reuse())

    def test_expired_missing_digest_current_run_are_misses(self):
        self.api.artifact['expired'] = True
        self.assertFalse(self.restore_reuse())
        self.api.artifact['expired'] = False
        self.api.artifact['workflow_run']['id'] = 13
        self.assertFalse(self.restore_reuse())
        self.api.artifact['workflow_run']['id'] = 12
        self.api.artifact.pop('digest')
        self.assertFalse(self.restore_reuse())

    def test_build_contract_changes_do_not_reuse(self):
        cases = {
            "xcode": {**self.contract, "xcode": "different-xcode"},
            "sdk": {**self.contract, "sdk": "different-sdk"},
            "tooling": {**self.contract, "tools": {**self.contract["tools"], "rustc": "rustc 2.0"}},
            "environment": {**self.contract, "environment": {**self.contract["environment"], "RUSTFLAGS": "-Dwarnings"}},
        }
        for name, changed in cases.items():
            with self.subTest(name=name):
                original = self.contract
                self.contract = changed
                self.assertFalse(self.restore_reuse())
                self.contract = original

    def test_changed_source_tree_is_a_miss(self):
        original = self.contract
        self.contract = {**self.contract, "tree": "changed-tree"}
        self.assertFalse(self.restore_reuse())
        self.contract = original

    def test_actual_source_and_run_provenance_must_match(self):
        self.api.trees["abc123"] = "different-tree"
        self.assertFalse(self.restore_reuse())
        self.assertFalse(self.consumer.exists())
        self.api.trees["abc123"] = "same-tree"
        root = self.producer / "Build/Products"
        receipt = json.loads((root / reuse.RECEIPT).read_text())
        receipt["run_id"] = "999"
        (root / reuse.RECEIPT).write_text(json.dumps(receipt))
        self.api.artifact["digest"] = self.package(self.producer, self.api.archive)
        self.assertFalse(self.restore_reuse())
        self.assertFalse(self.consumer.exists())

    def test_malformed_api_fields_are_normal_misses(self):
        cases = (
            ("consumer_head", "consumer_revision_invalid"),
            ("producer_head", "producer_revision_invalid"),
            ("digest", "artifact_digest_missing"),
            ("size", "artifact_size_invalid"),
        )
        for name, expected in cases:
            with self.subTest(name=name):
                report = {}
                if name == "consumer_head":
                    old = self.api.consumer_run["head_sha"]
                    self.api.consumer_run["head_sha"] = None
                elif name == "producer_head":
                    old = self.api.run["head_sha"]
                    self.api.run["head_sha"] = None
                elif name == "digest":
                    old = self.api.artifact["digest"]
                    self.api.artifact["digest"] = None
                else:
                    old = self.api.artifact["size_in_bytes"]
                    self.api.artifact["size_in_bytes"] = None
                try:
                    self.assertFalse(self.restore_reuse(report=report))
                    self.assertIn(expected, report["miss_reasons"])
                    self.assertFalse(self.consumer.exists())
                finally:
                    if name == "consumer_head":
                        self.api.consumer_run["head_sha"] = old
                    elif name == "producer_head":
                        self.api.run["head_sha"] = old
                    elif name == "digest":
                        self.api.artifact["digest"] = old
                    else:
                        self.api.artifact["size_in_bytes"] = old

    def valid_schema2_upstream(self):
        """Build a complete prior-hop provenance record for validation tests."""
        producer = {
            "run_id": "10",
            "run_attempt": "1",
            "run_url": "https://github.com/manaflow-ai/cmux/actions/runs/10",
            "revision": "abc123",
            "artifact_id": 40,
            "artifact_digest": "sha256:" + "a" * 64,
        }
        return {
            "schema": 2,
            "original_producer": dict(producer),
            "immediate_producer": dict(producer),
            "consumer": {"run_id": "11", "run_attempt": "1", "revision": "abc123"},
            "restore_route": "github_artifact",
            "metrics": {
                "compile_seconds_avoided": 600.0,
                "lookup_seconds": 1.0,
                "transfer_seconds": 2.0,
                "restore_seconds": 3.0,
                "total_reuse_seconds": 6.0,
                "macos_runner_minutes_saved": 9.9,
            },
            "candidate_misses": [],
            "run_url": producer["run_url"],
            "revision": producer["revision"],
            "artifact_id": producer["artifact_id"],
            "artifact_digest": producer["artifact_digest"],
            "consumer_revision": "abc123",
            "upstream": None,
        }

    def install_upstream(self, provenance):
        """Embed provenance in the producer archive and refresh its outer digest."""
        root = self.producer / "Build/Products"
        (root / "cmux-original-producer.json").write_text(json.dumps(provenance))
        self.api.artifact["digest"] = self.package(self.producer, self.api.archive)

    def test_malformed_receipt_revision_is_a_normal_miss(self):
        root = self.producer / "Build/Products"
        receipt = json.loads((root / reuse.RECEIPT).read_text())
        receipt["revision"] = None
        (root / reuse.RECEIPT).write_text(json.dumps(receipt))
        self.api.artifact["digest"] = self.package(self.producer, self.api.archive)
        report = {}
        self.assertFalse(self.restore_reuse(report=report))
        self.assertIn("product_provenance_invalid", report["miss_reasons"])
        self.assertFalse(self.consumer.exists())

    def test_malformed_schema2_upstream_provenance_is_a_miss(self):
        cases = {
            "empty_original_producer": lambda value: value.__setitem__("original_producer", {}),
            "nan_compile_metric": lambda value: value["metrics"].__setitem__(
                "compile_seconds_avoided", float("nan")),
            "negative_restore_metric": lambda value: value["metrics"].__setitem__(
                "restore_seconds", -1),
        }
        for name, mutate in cases.items():
            with self.subTest(name=name):
                provenance = self.valid_schema2_upstream()
                mutate(provenance)
                self.install_upstream(provenance)
                report = {}
                self.assertFalse(self.restore_reuse(report=report))
                self.assertIn("product_provenance_invalid", report["miss_reasons"])
                self.assertFalse(self.consumer.exists())
                (self.producer / "Build/Products/cmux-original-producer.json").unlink()
                self.seal()

    def test_valid_legacy_upstream_provenance_remains_eligible(self):
        legacy = {
            "run_url": "https://github.com/manaflow-ai/cmux/actions/runs/9",
            "revision": "abc123",
            "artifact_id": 39,
            "consumer_revision": "abc123",
            "upstream": None,
        }
        self.install_upstream(legacy)
        self.assertTrue(self.restore_reuse())
        provenance = json.loads(
            (self.consumer / "Build/Products/cmux-original-producer.json").read_text())
        self.assertEqual(provenance["upstream"], legacy)
        self.assertEqual(provenance["original_producer"]["run_id"], "12")

    def test_corrupt_archive_never_populates_consumer(self):
        self.api.archive.write_bytes(b'corrupt')
        self.assertFalse(self.restore_reuse())
        self.assertFalse(self.consumer.exists())

    def test_invalid_candidate_does_not_hide_later_valid_archive(self):
        original_download = self.api.download
        for failure in ('download', 'archive', 'receipt'):
            with self.subTest(failure=failure):
                bad = {**self.api.artifact, 'id': 41}
                if failure == 'archive':
                    bad['digest'] = 'sha256:' + hashlib.sha256(b'corrupt').hexdigest()
                bad_run = {**self.api.run, 'id': 99} if failure == 'receipt' else self.api.run
                def download(artifact_id, target):
                    if artifact_id == 41 and failure == 'download':
                        raise OSError('candidate unavailable')
                    if artifact_id == 41 and failure == 'archive':
                        target.write_bytes(b'corrupt')
                    else:
                        original_download(42, target)
                with mock.patch.object(reuse, 'select', return_value=[
                        (bad, bad_run), (self.api.artifact, self.api.run)]), \
                        mock.patch.object(self.api, 'download', side_effect=download) as calls:
                    self.assertTrue(self.restore_reuse())
                    self.assertEqual([call.args[0] for call in calls.call_args_list], [41, 42])
                provenance = json.loads((self.consumer / 'Build/Products/cmux-original-producer.json').read_text())
                self.assertEqual(provenance['artifact_id'], 42)
                shutil.rmtree(self.consumer)

    def test_failure_after_relocation_aborts_without_trying_another_candidate(self):
        original_restore = reuse.products.restore
        def restore(derived, identity):
            if derived == self.consumer:
                raise ValueError('consumer relocation failed')
            return original_restore(derived, identity)
        with mock.patch.object(reuse, 'select', return_value=[
                (self.api.artifact, self.api.run), (self.api.artifact, self.api.run)]), \
                mock.patch.object(reuse.products, 'restore', side_effect=restore), \
                mock.patch.object(self.api, 'download', wraps=self.api.download) as download:
            with self.assertRaisesRegex(ValueError, 'consumer relocation failed'):
                self.restore_reuse()
            self.assertEqual(download.call_count, 1)

    def test_attempt_suffixed_artifact_remains_discoverable(self):
        self.assertTrue(self.api.artifact['name'].endswith('-1'))
        self.assertTrue(self.restore_reuse())

    def test_successful_exact_rerun_reuses_prior_attempt(self):
        self.api.run.update({"id": 13, "run_attempt": 1, "head_sha": "abc123"})
        self.api.consumer_run.update({"id": 13, "run_attempt": 2, "head_sha": "abc123"})
        self.api.artifact["workflow_run"]["id"] = 13
        self.api.artifact["name"] = reuse.PREFIX + reuse.key(self.contract) + "-1"
        self.seal()
        report = {}
        with mock.patch.object(
                reuse.time, "monotonic",
                side_effect=[100.0, 101.0, 102.0, 104.0, 105.0, 108.0, 109.0]):
            self.assertTrue(self.restore_reuse(
                current_run="13", current_attempt="2", revision="abc123", report=report))
        self.assertEqual(report["reason"], "hit")
        self.assertEqual(report["compile_seconds_avoided"], 600.0)
        self.assertEqual(report["lookup_seconds"], 1.0)
        self.assertEqual(report["transfer_seconds"], 2.0)
        self.assertEqual(report["restore_seconds"], 3.0)
        self.assertEqual(report["total_reuse_seconds"], 9.0)
        self.assertEqual(report["macos_runner_minutes_saved"], 9.85)

    def test_oversize_compressed_artifact_is_rejected_without_download(self):
        with mock.patch.object(reuse, 'MAX_ARCHIVE_BYTES', 1), \
                mock.patch.object(self.api, 'download') as download:
            self.assertFalse(self.restore_reuse())
            download.assert_not_called()

    def test_valid_digest_with_corrupt_tar_is_rejected(self):
        with zipfile.ZipFile(self.api.archive, 'w') as z:
            z.writestr('app-host-products.tar.gz', b'corrupt')
        self.api.artifact['digest'] = 'sha256:' + hashlib.sha256(self.api.archive.read_bytes()).hexdigest()
        self.assertFalse(self.restore_reuse())
        self.assertFalse(self.consumer.exists())

    def test_archive_expansion_is_bounded(self):
        for limit in ('MAX_MEMBER_BYTES', 'MAX_EXPANDED_BYTES', 'MAX_MEMBERS', 'MAX_TAR_BYTES'):
            with self.subTest(limit=limit), mock.patch.object(reuse, limit, 1, create=True):
                self.assertFalse(self.restore_reuse())
                self.assertFalse(self.consumer.exists())

    def test_unrelated_producer_tree_rejected_before_download(self):
        self.api.trees["abc123"] = "different-tree"
        with mock.patch.object(self.api, "download", wraps=self.api.download) as download:
            self.assertFalse(self.restore_reuse())
            download.assert_not_called()

    def test_completed_compile_can_be_used_while_other_tests_run(self):
        self.api.run['status'] = 'in_progress'
        self.assertTrue(self.restore_reuse())

    def test_api_failure_cli_falls_back_to_compile(self):
        output = self.producer.parent / "github-output"
        env = {
            "GITHUB_OUTPUT": str(output),
            "GITHUB_EVENT_NAME": "merge_group",
            "GITHUB_REPOSITORY": self.api.repository,
            "GITHUB_RUN_ID": "13",
            "GITHUB_RUN_ATTEMPT": "1",
        }
        with mock.patch.dict(os.environ, env), mock.patch.object(
                sys, "argv", ["reuse", "restore", str(self.consumer)]), \
                mock.patch.object(reuse, "contract", return_value=self.contract), \
                mock.patch.object(reuse.products, "identity", return_value=self.identity), \
                mock.patch.object(reuse.GitHub, "get", side_effect=OSError("API unavailable")):
            reuse.main()
        outputs = dict(line.split("=", 1) for line in output.read_text().splitlines())
        self.assertEqual(outputs["hit"], "false")
        self.assertEqual(outputs["reason"], "miss")
        self.assertEqual(outputs["miss_reasons"], "consumer_provenance_unavailable")
        self.assertFalse(self.consumer.exists())


    def test_permitted_producer_consumer_matrix(self):
        base = {
            "path": ".github/workflows/ci.yml",
            "head_repository": {"full_name": self.api.repository},
            "pull_requests": [{"number": 7}],
        }
        cases = [
            ("pr_same_pr", {**base, "event": "pull_request"},
             {**base, "event": "pull_request"}, True),
            ("pr_other_pr", {**base, "event": "pull_request", "pull_requests": [{"number": 8}]},
             {**base, "event": "pull_request"}, False),
            ("merge_group_to_pr", {**base, "event": "merge_group"},
             {**base, "event": "pull_request"}, False),
            ("pr_to_merge_group", {**base, "event": "pull_request"},
             {**base, "event": "merge_group"}, True),
            ("merge_group_to_merge_group", {**base, "event": "merge_group"},
             {**base, "event": "merge_group"}, True),
        ]
        for name, producer, consumer, expected in cases:
            with self.subTest(name=name):
                self.assertEqual(
                    reuse.permitted_pair(producer, consumer, self.api.repository),
                    expected,
                )
        fork = {**base, "event": "pull_request",
                "head_repository": {"full_name": "fork/cmux"}}
        self.assertFalse(reuse.permitted_pair(fork, {**base, "event": "pull_request"},
                                              self.api.repository))
        self.assertFalse(reuse.permitted_pair({**base, "event": "pull_request"}, fork,
                                              self.api.repository))

    def test_failed_producer_compile_is_a_miss(self):
        self.api.job["conclusion"] = "failure"
        self.assertFalse(self.restore_reuse())
        self.assertFalse(self.consumer.exists())

    def test_wrong_repository_provenance_is_a_miss(self):
        self.api.run["head_repository"] = {"full_name": "other/cmux"}
        self.assertFalse(self.restore_reuse())
        self.assertFalse(self.consumer.exists())

    def test_expired_and_missing_artifacts_are_misses(self):
        self.api.artifact["expired"] = True
        self.assertFalse(self.restore_reuse())
        self.api.artifact["expired"] = False
        self.api.artifacts = []
        self.assertFalse(self.restore_reuse())

    def test_candidate_lookup_is_bounded(self):
        original_get = self.api.get
        artifact_pages = []
        def no_matches(path):
            if path.startswith("actions/artifacts?"):
                artifact_pages.append(path)
                return {"artifacts": [{"name": "unrelated"} for _ in range(100)]}
            return original_get(path)
        with mock.patch.object(self.api, "get", side_effect=no_matches):
            self.assertFalse(self.restore_reuse())
        self.assertEqual(len(artifact_pages), 3)

        prefix = reuse.PREFIX + reuse.key(self.contract) + "-1"
        candidates = [
            {"id": 100 + index, "name": prefix, "size_in_bytes": 100,
             "expired": False, "digest": self.api.artifact["digest"],
             "workflow_run": {"id": 20 + index}}
            for index in range(7)
        ]
        attempts = []
        def six_candidates(path):
            if path.startswith("actions/artifacts?"):
                return {"artifacts": candidates}
            if path.startswith("actions/runs/") and "/attempts/" in path and "/jobs?" not in path:
                attempts.append(path)
                return {
                    **self.api.run,
                    "id": int(path.split("/")[2]),
                    "run_attempt": 1,
                    "head_repository": {"full_name": "other/cmux"},
                }
            return original_get(path)
        with mock.patch.object(self.api, "get", side_effect=six_candidates):
            self.assertFalse(self.restore_reuse())
        self.assertEqual(len(attempts), 6)

    def test_multi_hop_reuse_preserves_original_producer(self):
        first_report = {}
        self.assertTrue(self.restore_reuse(report=first_report))
        first_provenance = json.loads(
            (self.consumer / "Build/Products/cmux-original-producer.json").read_text())
        self.assertEqual(first_provenance["original_producer"]["run_id"], "12")
        self.assertEqual(first_provenance["immediate_producer"]["run_id"], "12")

        root = self.consumer / "Build/Products"
        (root / reuse.RECEIPT).write_text(json.dumps({
            "contract": self.contract,
            "revision": "def456",
            "run_id": "13",
            "run_attempt": "1",
        }))
        second_archive = self.consumer.parent / "second-artifact.zip"
        self.api.archive = second_archive
        self.api.artifact.update({
            "id": 43,
            "name": reuse.PREFIX + reuse.key(self.contract) + "-1",
            "workflow_run": {"id": 13},
            "expired": False,
        })
        self.api.artifact["digest"] = self.package(self.consumer, second_archive)
        self.api.run.update({
            "id": 13,
            "run_attempt": 1,
            "head_sha": "def456",
            "event": "pull_request",
            "pull_requests": [{"number": 7}],
        })
        # This producer reused the original product, so its compile step was skipped
        # even though the compile-admission job itself completed successfully.
        self.api.job["steps"] = []
        self.api.consumer_run.update({
            "id": 15,
            "run_attempt": 1,
            "head_sha": "fed789",
            "event": "merge_group",
            "pull_requests": [],
        })
        self.api.trees["fed789"] = "same-tree"
        second = self.consumer.parent / "second-consumer" / "derived"
        second_report = {}
        self.assertTrue(self.restore_reuse(
            current_run="15",
            revision="fed789",
            destination=second,
            report=second_report,
        ))
        provenance = json.loads(
            (second / "Build/Products/cmux-original-producer.json").read_text())
        self.assertEqual(provenance["original_producer"]["run_id"], "12")
        self.assertEqual(provenance["original_producer"]["revision"], "abc123")
        self.assertEqual(provenance["immediate_producer"]["run_id"], "13")
        self.assertEqual(provenance["immediate_producer"]["revision"], "def456")
        self.assertEqual(provenance["consumer"]["run_id"], "15")
        self.assertEqual(provenance["consumer"]["revision"], "fed789")
        self.assertEqual(provenance["restore_route"], "github_artifact")
        self.assertEqual(provenance["metrics"]["compile_seconds_avoided"], 600.0)
        self.assertEqual(second_report["compile_seconds_avoided"], 600.0)


    def test_tar_cannot_escape_staging(self):
        tarbytes = io.BytesIO()
        with tarfile.open(fileobj=tarbytes, mode='w:gz') as tar:
            member = tarfile.TarInfo('../escape')
            member.size = 1
            tar.addfile(member, io.BytesIO(b'x'))
        with zipfile.ZipFile(self.api.archive, 'w') as z:
            z.writestr('app-host-products.tar.gz', tarbytes.getvalue())
        self.api.artifact['digest'] = 'sha256:' + hashlib.sha256(self.api.archive.read_bytes()).hexdigest()
        self.assertFalse(self.restore_reuse())
        self.assertFalse((self.producer.parent / 'escape').exists())


class FakeGitHub:
    repository = "manaflow-ai/cmux"

    def __init__(self, contract):
        self.tree = contract["tree"]
        self.trees = {"abc123": self.tree, "def456": self.tree}
        self.artifact = {
            "id": 42,
            "name": reuse.PREFIX + reuse.key(contract) + "-1",
            "size_in_bytes": 100,
            "expired": False,
            "workflow_run": {"id": 12},
        }
        self.artifacts = [self.artifact]
        self.run = {
            "id": 12,
            "path": ".github/workflows/ci.yml",
            "event": "pull_request",
            "head_repository": {"full_name": self.repository},
            "pull_requests": [{"number": 7}],
            "run_attempt": 1,
            "head_sha": "abc123",
            "html_url": "https://github.com/manaflow-ai/cmux/actions/runs/12",
        }
        self.consumer_run = {
            "id": 13,
            "path": ".github/workflows/ci.yml",
            "event": "pull_request",
            "head_repository": {"full_name": self.repository},
            "pull_requests": [{"number": 7}],
            "run_attempt": 1,
            "head_sha": "def456",
            "html_url": "https://github.com/manaflow-ai/cmux/actions/runs/13",
        }
        self.job = {
            "name": "macOS compile admission",
            "conclusion": "success",
            "status": "completed",
            "steps": [{
                "name": "Compile app-host test product",
                "conclusion": "success",
                "status": "completed",
                "started_at": "2026-09-21T08:00:00Z",
                "completed_at": "2026-09-21T08:10:00Z",
            }],
        }

    def get(self, path):
        if path.startswith("actions/artifacts?"):
            return {"artifacts": self.artifacts}
        if path == f"actions/runs/{self.consumer_run['id']}":
            return self.consumer_run
        match = __import__("re").fullmatch(r"actions/runs/(\d+)/attempts/(\d+)", path)
        if match:
            run_id, attempt = map(int, match.groups())
            if run_id == int(self.run["id"]) and attempt == int(self.run["run_attempt"]):
                return self.run
            raise OSError("attempt unavailable")
        match = __import__("re").fullmatch(
            r"actions/runs/(\d+)/attempts/(\d+)/jobs\?per_page=100&page=(\d+)", path)
        if match:
            run_id, attempt, _ = map(int, match.groups())
            if run_id == int(self.run["id"]) and attempt == int(self.run["run_attempt"]):
                return {"jobs": [self.job]}
            raise OSError("jobs unavailable")
        if path.startswith("git/commits/"):
            revision = path.rsplit("/", 1)[-1]
            return {"tree": {"sha": self.trees.get(revision, self.tree)}}
        raise AssertionError(path)

    def download(self, artifact_id, target):
        assert artifact_id == self.artifact["id"]
        shutil.copyfile(self.archive, target)


if __name__ == '__main__':
    unittest.main()
