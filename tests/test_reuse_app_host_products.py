#!/usr/bin/env python3
"""Exercise cross-run artifact reuse through real archives and product relocation."""
import hashlib
import json
import os
from unittest import mock
import shutil
import subprocess
import sys
import tarfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/ci"))
import reuse_app_host_products as reuse
from test_app_host_test_products import TestProductHandoff


# Real archives need /usr/bin/aa. The Linux guard job still runs ArchiveListingRules
# below, and the macOS compile admission job runs this whole file.
@unittest.skipUnless(shutil.which("aa"), "Apple Archive (aa) ships only with macOS")
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
            "revision": self.identity["revision"], "run_id": "12", "run_attempt": str(self.api.run["run_attempt"])}))
        archive = self.producer.parent / reuse.ARCHIVE
        subprocess.run([str(reuse.ARCHIVER), "pack", str(self.producer), str(archive)], check=True)
        self.publish(archive)

    def publish(self, archive, name=reuse.ARCHIVE):
        with zipfile.ZipFile(self.api.archive, "w") as z:
            z.write(archive, name)
        self.api.artifact["digest"] = "sha256:" + hashlib.sha256(self.api.archive.read_bytes()).hexdigest()

    def archive_directly(self, subdir="Build/Products"):
        """Archive without the packing script, as a producer that skips its rules would."""
        archive = self.producer.parent / "direct.aar"
        subprocess.run(["aa", "archive", "-d", str(self.producer), "-subdir", subdir,
                        "-o", str(archive), "-a", "lzfse"], check=True)
        self.publish(archive)

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
        self.assertFalse(self.restore_reuse())
        self.assertFalse(self.consumer.exists())
        self.api.tree = 'same-tree'
        self.api.run['run_attempt'] = 2
        self.assertFalse(self.restore_reuse())

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

    def test_later_attempt_gets_its_own_artifact_and_receipt(self):
        self.api.run['run_attempt'] = 2
        self.assertFalse(self.restore_reuse())
        self.api.artifact['name'] = reuse.PREFIX + reuse.key(self.contract) + '-2'
        self.seal()
        self.assertTrue(self.restore_reuse())

    def test_oversize_compressed_artifact_is_rejected_without_download(self):
        with mock.patch.object(reuse, 'MAX_ARCHIVE_BYTES', 1), \
                mock.patch.object(self.api, 'download') as download:
            self.assertFalse(self.restore_reuse())
            download.assert_not_called()

    def test_valid_digest_with_corrupt_archive_is_rejected(self):
        with zipfile.ZipFile(self.api.archive, 'w') as z:
            z.writestr(reuse.ARCHIVE, b'corrupt')
        self.api.artifact['digest'] = 'sha256:' + hashlib.sha256(self.api.archive.read_bytes()).hexdigest()
        self.assertFalse(self.restore_reuse())
        self.assertFalse(self.consumer.exists())

    def test_archive_expansion_is_bounded(self):
        for limit in ('MAX_MEMBER_BYTES', 'MAX_EXPANDED_BYTES', 'MAX_MEMBERS', 'MAX_LISTING_BYTES'):
            with self.subTest(limit=limit), mock.patch.object(reuse, limit, 1):
                self.assertFalse(self.restore_reuse())
                self.assertFalse(self.consumer.exists())

    def test_stalled_archive_tool_is_a_miss(self):
        stalled = self.producer.parent / 'stalled.sh'
        stalled.write_text('#!/bin/sh\nexec sleep 30\n')
        stalled.chmod(0o755)
        class ImmediateTimer:
            def __init__(self, _delay, callback):
                self.callback = callback

            def start(self):
                self.callback()

            def cancel(self):
                pass

        with mock.patch.object(reuse, 'ARCHIVER', stalled), \
             mock.patch.object(reuse, 'ARCHIVE_TOOL_TIMEOUT', 0.2), \
             mock.patch.object(reuse.threading, 'Timer', ImmediateTimer):
            self.assertFalse(self.restore_reuse())
        self.assertFalse(self.consumer.exists())

    def test_framework_links_survive_reuse(self):
        framework = self.producer / 'Build/Products/Debug/Sample.framework'
        (framework / 'Versions/A').mkdir(parents=True)
        (framework / 'Versions/A/Sample').write_text('binary')
        (framework / 'Versions/A/Sample').chmod(0o755)
        (framework / 'Versions/Current').symlink_to('A')
        (framework / 'Sample').symlink_to('Versions/Current/Sample')
        (framework / 'Headers').symlink_to('Versions/Current/Headers')
        self.seal()
        self.assertTrue(self.restore_reuse())
        restored = self.consumer / 'Build/Products/Debug/Sample.framework'
        self.assertEqual(os.readlink(restored / 'Versions/Current'), 'A')
        self.assertEqual(os.readlink(restored / 'Sample'), 'Versions/Current/Sample')
        self.assertEqual(os.readlink(restored / 'Headers'), 'Versions/Current/Headers')
        self.assertEqual((restored / 'Sample').read_text(), 'binary')
        self.assertEqual((restored / 'Versions/A/Sample').stat().st_mode & 0o777, 0o755)

    def test_earlier_tar_format_is_a_miss(self):
        legacy = self.producer.parent / 'app-host-products.tar.gz'
        with tarfile.open(legacy, 'w:gz', dereference=True) as tar:
            tar.add(self.producer / 'Build/Products', arcname='Build/Products')
        for name in ('app-host-products.tar.gz', reuse.ARCHIVE):
            with self.subTest(name=name):
                self.publish(legacy, name)
                self.assertFalse(self.restore_reuse())
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


    def test_archive_cannot_escape_staging(self):
        secret = self.producer.parent / 'secret'
        secret.write_text('outside')
        for target in (str(secret), '../../../../secret'):
            with self.subTest(target=target):
                link = self.producer / 'Build/Products/Debug/escape'
                link.symlink_to(target)
                self.archive_directly()
                link.unlink()
                self.assertFalse(self.restore_reuse())
                self.assertFalse(self.consumer.exists())
        (self.producer / 'Elsewhere').mkdir()
        (self.producer / 'Elsewhere/file').write_text('unscoped')
        self.archive_directly('Elsewhere')
        self.assertFalse(self.restore_reuse())
        self.assertFalse(self.consumer.exists())


class ArchiveListingRules(unittest.TestCase):
    """The listing checks are plain data rules, so they run on every platform."""

    def entries(self, *extra):
        return [{'TYP': 'D', 'PAT': 'Build/Products', 'MOD': 0o755},
                {'TYP': 'D', 'PAT': 'Build/Products/Debug', 'MOD': 0o755},
                {'TYP': 'F', 'PAT': 'Build/Products/Debug/cmux DEV', 'MOD': 0o755, 'DAT': 10, 'XAT': 36},
                {'TYP': 'L', 'PAT': 'Build/Products/Debug/Current', 'LNK': 'Versions/A', 'MOD': 0o755},
                *extra]

    def test_scoped_files_directories_and_portable_links_pass(self):
        reuse.validate_entries(self.entries())

    def test_unsafe_entries_are_rejected(self):
        unsafe = {
            'absolute path': {'TYP': 'F', 'PAT': '/etc/passwd', 'DAT': 1},
            'parent path': {'TYP': 'F', 'PAT': 'Build/Products/../../escape', 'DAT': 1},
            'other root': {'TYP': 'F', 'PAT': 'Build/Intermediates/file', 'DAT': 1},
            'empty component': {'TYP': 'F', 'PAT': 'Build/Products//file', 'DAT': 1},
            'duplicate': {'TYP': 'D', 'PAT': 'Build/Products/Debug'},
            'absolute link': {'TYP': 'L', 'PAT': 'Build/Products/link', 'LNK': '/etc'},
            'climbing link': {'TYP': 'L', 'PAT': 'Build/Products/link', 'LNK': 'Debug/../../..'},
            'empty link': {'TYP': 'L', 'PAT': 'Build/Products/link', 'LNK': ''},
            'missing link target': {'TYP': 'L', 'PAT': 'Build/Products/link'},
            'entry below a link': {'TYP': 'F', 'PAT': 'Build/Products/Debug/Current/file', 'DAT': 1},
            'device': {'TYP': 'C', 'PAT': 'Build/Products/device'},
            'fifo': {'TYP': 'P', 'PAT': 'Build/Products/fifo'},
            'setuid': {'TYP': 'F', 'PAT': 'Build/Products/tool', 'MOD': 0o4755, 'DAT': 1},
            'link target on a file': {'TYP': 'F', 'PAT': 'Build/Products/file', 'LNK': 'x', 'DAT': 1},
            'contents on a directory': {'TYP': 'D', 'PAT': 'Build/Products/dir', 'DAT': 1},
            'oversized metadata': {'TYP': 'F', 'PAT': 'Build/Products/file', 'XAT': reuse.MAX_METADATA_BYTES + 1},
            'oversized file': {'TYP': 'F', 'PAT': 'Build/Products/file', 'DAT': reuse.MAX_MEMBER_BYTES + 1},
            'missing path': {'TYP': 'F'},
            'not an entry': 'Build/Products/file',
        }
        for label, entry in unsafe.items():
            with self.subTest(label=label), self.assertRaises((ValueError, KeyError, TypeError)):
                reuse.validate_entries(self.entries(entry))
        with self.assertRaises(ValueError):
            reuse.validate_entries({'PAT': 'Build/Products'})

    def test_total_size_and_member_count_are_bounded(self):
        with mock.patch.object(reuse, 'MAX_EXPANDED_BYTES', 40), self.assertRaises(ValueError):
            reuse.validate_entries(self.entries({'TYP': 'F', 'PAT': 'Build/Products/more', 'DAT': 10}))
        with mock.patch.object(reuse, 'MAX_MEMBERS', 3), self.assertRaises(ValueError):
            reuse.validate_entries(self.entries())


class FakeGitHub:
    repository = 'manaflow-ai/cmux'
    def __init__(self, contract):
        self.tree = contract['tree']
        self.artifact = {'id': 42, 'name': reuse.PREFIX + reuse.key(contract) + '-1', 'size_in_bytes': 100,
                         'expired': False, 'workflow_run': {'id': 12}}
        self.run = {'id': 12, 'path': '.github/workflows/ci.yml', 'event': 'pull_request',
                    'head_repository': {'full_name': self.repository}, 'run_attempt': 1,
                    'head_sha': 'abc123', 'html_url': 'https://github.com/manaflow-ai/cmux/actions/runs/12'}
        self.job = {'name': 'macOS compile admission', 'conclusion': 'success', 'status': 'completed'}
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
