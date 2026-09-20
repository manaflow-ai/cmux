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
        self.contract = {"tree": "same-tree", "xcode": "same-xcode"}
        self.api = FakeGitHub(self.contract)
        self.api.archive = self.producer.parent / "artifact.zip"
        self.seal()

    def seal(self):
        reuse.products.stamp(self.producer, self.identity)
        root = self.producer / "Build/Products"
        (root / reuse.RECEIPT).write_text(json.dumps({"contract": self.contract,
            "revision": self.identity["revision"], "run_id": "12", "run_attempt": "1"}))
        archive = self.producer.parent / "app-host-products.tar.gz"
        with tarfile.open(archive, "w:gz", dereference=True) as tar:
            tar.add(root, arcname="Build/Products")
        with zipfile.ZipFile(self.api.archive, "w") as z:
            z.write(archive, "app-host-products.tar.gz")
        self.api.artifact["digest"] = "sha256:" + hashlib.sha256(self.api.archive.read_bytes()).hexdigest()

    def restore_reuse(self):
        current = {**self.identity, "revision": "def456", "checkout": "/queue/work/cmux"}
        return reuse.restore(self.api, self.contract, self.consumer, "13", current)

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

    def test_environment_changes_do_not_reuse(self):
        self.contract = {**self.contract, 'xcode': 'different-xcode'}
        self.assertFalse(self.restore_reuse())

    def test_actual_source_and_attempt_must_match(self):
        self.api.tree = 'different-tree'
        with self.assertRaisesRegex(ValueError, 'source tree'):
            self.restore_reuse()
        self.assertFalse(self.consumer.exists())
        self.api.tree = 'same-tree'
        self.api.run['run_attempt'] = 2
        with self.assertRaisesRegex(ValueError, 'producer contract'):
            self.restore_reuse()

    def test_corrupt_archive_never_populates_consumer(self):
        self.api.archive.write_bytes(b'corrupt')
        with self.assertRaisesRegex(ValueError, 'digest'):
            self.restore_reuse()
        self.assertFalse(self.consumer.exists())

    def test_attempt_suffixed_artifact_remains_discoverable(self):
        self.api.artifact['name'] += '-1'
        self.assertTrue(self.restore_reuse())

    def test_valid_digest_with_corrupt_tar_is_rejected(self):
        with zipfile.ZipFile(self.api.archive, 'w') as z:
            z.writestr('app-host-products.tar.gz', b'corrupt')
        self.api.artifact['digest'] = 'sha256:' + hashlib.sha256(self.api.archive.read_bytes()).hexdigest()
        with self.assertRaises(tarfile.TarError):
            self.restore_reuse()
        self.assertFalse(self.consumer.exists())

    def test_archive_expansion_is_bounded(self):
        for limit in ('MAX_ARCHIVE_BYTES', 'MAX_MEMBER_BYTES', 'MAX_EXPANDED_BYTES', 'MAX_MEMBERS'):
            with self.subTest(limit=limit), mock.patch.object(reuse, limit, 1, create=True):
                with self.assertRaises((ValueError, tarfile.TarError)):
                    self.restore_reuse()
                self.assertFalse(self.consumer.exists())

    def test_unrelated_producer_tree_rejected_before_download(self):
        self.api.tree = 'different-tree'
        with mock.patch.object(self.api, 'download', wraps=self.api.download) as download:
            try:
                self.restore_reuse()
            except ValueError:
                pass
            download.assert_not_called()

    def test_completed_compile_can_be_used_while_other_tests_run(self):
        self.api.run['status'] = 'in_progress'
        self.assertTrue(self.restore_reuse())

    def test_api_failure_cli_falls_back_to_compile(self):
        output = self.producer.parent / 'github-output'
        env = {'GITHUB_OUTPUT': str(output), 'GITHUB_EVENT_NAME': 'merge_group',
               'GITHUB_REPOSITORY': self.api.repository, 'GITHUB_RUN_ID': '13'}
        with mock.patch.dict(os.environ, env), mock.patch.object(sys, 'argv',
                ['reuse', 'restore', str(self.consumer)]), \
                mock.patch.object(reuse, 'contract', return_value=self.contract), \
                mock.patch.object(reuse.products, 'identity', return_value=self.identity), \
                mock.patch.object(reuse.GitHub, 'get', side_effect=OSError('API unavailable')):
            reuse.main()
        self.assertEqual(output.read_text(), 'hit=false\n')
        self.assertFalse(self.consumer.exists())


    def test_tar_cannot_escape_staging(self):
        tarbytes = io.BytesIO()
        with tarfile.open(fileobj=tarbytes, mode='w:gz') as tar:
            member = tarfile.TarInfo('../escape')
            member.size = 1
            tar.addfile(member, io.BytesIO(b'x'))
        with zipfile.ZipFile(self.api.archive, 'w') as z:
            z.writestr('app-host-products.tar.gz', tarbytes.getvalue())
        self.api.artifact['digest'] = 'sha256:' + hashlib.sha256(self.api.archive.read_bytes()).hexdigest()
        with self.assertRaises(tarfile.TarError):
            self.restore_reuse()
        self.assertFalse((self.producer.parent / 'escape').exists())


class FakeGitHub:
    repository = 'manaflow-ai/cmux'
    def __init__(self, contract):
        self.tree = contract['tree']
        self.artifact = {'id': 42, 'name': reuse.PREFIX + reuse.key(contract),
                         'expired': False, 'workflow_run': {'id': 12}}
        self.run = {'id': 12, 'path': '.github/workflows/ci.yml', 'event': 'pull_request',
                    'head_repository': {'full_name': self.repository}, 'run_attempt': 1,
                    'head_sha': 'abc123', 'html_url': 'https://github.com/manaflow-ai/cmux/actions/runs/12'}
        self.job = {'name': 'macOS compile admission', 'conclusion': 'success'}
    def get(self, path):
        if path.startswith('actions/artifacts?'):
            return {'artifacts': [self.artifact]}
        if '/jobs?' in path:
            return {'jobs': [self.job]}
        if path.startswith('actions/runs/'):
            return self.run
        if path.startswith('git/commits/'):
            return {'tree': {'sha': self.tree}}
        raise AssertionError(path)
    def download(self, artifact_id, target):
        assert artifact_id == 42
        shutil.copyfile(self.archive, target)


if __name__ == '__main__':
    unittest.main()
