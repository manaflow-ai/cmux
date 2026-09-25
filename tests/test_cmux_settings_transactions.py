#!/usr/bin/env python3
"""Production helper transaction tests on owned temporary JSONC files.

ConfigTransactionTests inject the validation seam for deterministic
interleavings. The later classes run the real validation path against a fake
`cmux config validate`; canonical schema rejection is exercised by
JSONConfigTransactionTests and CLI doctor tests.
"""
import argparse
import contextlib
import fcntl
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'skills/cmux-settings/scripts'
sys.path.insert(0, str(SCRIPTS))
loader = importlib.machinery.SourceFileLoader('transaction_helper', str(SCRIPTS / 'cmux-settings'))
spec = importlib.util.spec_from_loader(loader.name, loader)
helper = importlib.util.module_from_spec(spec)
loader.exec_module(helper)


class ConfigTransactionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / 'cmux.json'
        self.config.write_text('{\n // keep\n "computerUse": {"showInMenuBar": true}\n}\n')
        self.receipt = self.root / 'undo.json'
        self.validation = patch.object(helper, 'candidate_issues', return_value=[])
        self.validation.start()
        self.addCleanup(self.validation.stop)

    def args(self, **kwargs):
        return argparse.Namespace(file=str(self.config), key='computerUse.showInMenuBar',
                                  value='false', scope='global', receipt=None, **kwargs)

    def set_value(self, value='false', key='computerUse.showInMenuBar', receipt=None):
        args = self.args()
        args.value, args.key, args.receipt = value, key, receipt
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(helper.cmd_set(args), 0)

    def undo(self):
        with contextlib.redirect_stdout(io.StringIO()):
            return helper.cmd_undo(self.args(receipt_file=str(self.receipt)))

    def test_stale_undo_preserves_newer_choice_byte_for_byte(self):
        self.set_value(receipt=str(self.receipt))
        self.set_value('true')
        before = self.config.read_bytes()
        with self.assertRaises(SystemExit):
            self.undo()
        self.assertEqual(self.config.read_bytes(), before)
        self.assertEqual(self.receipt.stat().st_mode & 0o777, 0o600)

    def test_undo_preserves_unrelated_edits_and_jsonc(self):
        self.set_value(receipt=str(self.receipt))
        self.set_value('false', key='computerUse.enabled')
        self.assertEqual(self.undo(), 0)
        root = helper.load_settings(self.config)
        self.assertTrue(root['computerUse']['showInMenuBar'])
        self.assertFalse(root['computerUse']['enabled'])
        self.assertIn('// keep', self.config.read_text())

    def test_reset_receipt_restores_explicit_pin(self):
        args = self.args()
        args.receipt = str(self.receipt)
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(helper.cmd_unset(args), 0)
        self.assertFalse(helper.owned_value(helper.load_settings(self.config), ['computerUse', 'showInMenuBar'])['present'])
        self.assertEqual(self.undo(), 0)
        self.assertTrue(helper.load_settings(self.config)['computerUse']['showInMenuBar'])

    def test_external_edit_during_validation_is_preserved(self):
        external = b'{"computerUse":{"showInMenuBar":true,"enabled":false}}'
        def validate(*_):
            self.config.write_bytes(external)
            return []
        with patch.object(helper, 'candidate_issues', side_effect=validate):
            with self.assertRaises(SystemExit):
                self.set_value()
        self.assertEqual(self.config.read_bytes(), external)

    def test_identical_byte_replacement_during_validation_conflicts(self):
        before = self.config.read_bytes()
        def validate(*_):
            replacement = self.root / 'replacement'
            replacement.write_bytes(before)
            os.replace(replacement, self.config)
            return []
        with patch.object(helper, 'candidate_issues', side_effect=validate):
            with self.assertRaises(SystemExit):
                self.set_value()
        self.assertEqual(self.config.read_bytes(), before)

    def test_retarget_during_validation_preserves_both_files(self):
        target = self.root / 'target.json'
        self.config.rename(target)
        self.config.symlink_to(target)
        other = self.root / 'other.json'
        other.write_text('{}')
        before = target.read_bytes()
        def validate(*_):
            self.config.unlink()
            self.config.symlink_to(other)
            return []
        with patch.object(helper, 'candidate_issues', side_effect=validate):
            with self.assertRaises(SystemExit):
                self.set_value()
        self.assertEqual(target.read_bytes(), before)
        self.assertEqual(other.read_text(), '{}')
        self.assertTrue(self.config.is_symlink())

    def test_busy_writer_refuses_without_touching_config(self):
        before = self.config.read_bytes()
        with helper.mutation_lock(self.config):
            with self.assertRaises(SystemExit):
                self.set_value()
        self.assertEqual(self.config.read_bytes(), before)
        self.set_value()  # release permits an explicit retry

    def test_malformed_and_rejected_candidate_preserve_bytes(self):
        before = self.config.read_bytes()
        rejected = [{'path': '$.computerUse.showInMenuBar', 'message': 'fixture rejection'}]
        with patch.object(helper, 'introduced_issues', return_value=rejected):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                helper.cmd_set(self.args())
        self.assertEqual(self.config.read_bytes(), before)
        self.config.write_text('{broken')
        with self.assertRaises(SystemExit):
            self.set_value()
        self.assertEqual(self.config.read_text(), '{broken')

    def test_failed_publication_never_leaves_usable_receipt(self):
        before = self.config.read_bytes()
        with patch.object(helper, 'atomic_write_text', side_effect=OSError('fixture failure')):
            with self.assertRaises(OSError):
                self.set_value(receipt=str(self.receipt))
        self.assertEqual(self.config.read_bytes(), before)
        self.assertEqual(self.receipt.read_bytes(), b'')
        with self.assertRaises(SystemExit):
            self.undo()

    def test_committed_publication_reports_receipt_failure_without_retry_error(self):
        output = io.StringIO()
        args = self.args()
        args.receipt = str(self.receipt)
        with patch.object(helper.json, 'dump', side_effect=OSError('receipt failure')):
            with contextlib.redirect_stdout(output):
                self.assertEqual(
                    helper.cmd_set(args),
                    0,
                )
        self.assertEqual(
            json.loads(output.getvalue()),
            {'status': 'persisted', 'receipt': 'failed', 'runtime': 'unobserved'},
        )
        self.assertFalse(helper.load_settings(self.config)['computerUse']['showInMenuBar'])
        self.assertEqual(self.receipt.read_bytes(), b'')

    def test_undo_refuses_retarget_even_with_same_installed_value(self):
        self.set_value(receipt=str(self.receipt))
        target = self.root / 'other.json'
        self.config.rename(target)
        self.config.symlink_to(target)
        before = target.read_bytes()
        with self.assertRaises(SystemExit):
            self.undo()
        self.assertEqual(target.read_bytes(), before)

    def test_noop_receipt_is_private_and_undo_is_byte_stable(self):
        before = self.config.read_bytes()
        self.set_value('true', receipt=str(self.receipt))
        self.assertEqual(self.undo(), 0)
        self.assertEqual(self.config.read_bytes(), before)
        self.assertEqual(self.receipt.stat().st_mode & 0o777, 0o600)

    def test_parent_symlink_uses_same_writer_lock(self):
        alias = self.root / 'alias'
        alias.symlink_to(self.root, target_is_directory=True)
        with helper.mutation_lock(self.config):
            with self.assertRaises(SystemExit):
                with helper.mutation_lock(alias / 'cmux.json'):
                    self.fail('aliased writer entered')

    def test_preview_is_read_only_and_stale_revision_conflicts(self):
        args = self.args()
        args.preview = True
        before = self.config.read_bytes()
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(helper.cmd_set(args), 0)
        preview = json.loads(output.getvalue())
        self.assertFalse(preview['persisted'])
        self.assertEqual(self.config.read_bytes(), before)
        self.set_value('false', key='computerUse.enabled')
        newer = self.config.read_bytes()
        args.preview = False
        args.expect_revision = preview['revision']
        with self.assertRaises(SystemExit):
            helper.cmd_set(args)
        self.assertEqual(self.config.read_bytes(), newer)

    def test_conflict_diagnostic_is_localized_without_private_values(self):
        with patch.dict(os.environ, {'LC_ALL': 'ja_JP.UTF-8'}):
            output = io.StringIO()
            with contextlib.redirect_stderr(output):
                error = helper.mutation_conflict('undo_conflict', 'computerUse.showInMenuBar')
            payload = json.loads(output.getvalue())
            self.assertEqual(error.code, 1)
            self.assertEqual(payload['code'], 'undo_conflict')
            self.assertIn('取り消し', payload['message'])
            self.assertNotIn('value', payload)

    def test_json_types_are_not_conflated_for_undo(self):
        self.assertFalse(helper.same_owned_value({'present': True, 'value': True}, {'present': True, 'value': 1}))
        self.assertFalse(helper.same_owned_value({'present': False}, {'present': True, 'value': None}))



FAKE_CLI = r"""#!/usr/bin/env python3
import json, sys
candidate = json.load(open(sys.argv[sys.argv.index('--path') + 1]))
issues = [{'path': '$.' + key, 'message': 'is not a recognized setting'}
          for key in candidate if key not in ('computerUse', 'notifications')]
menu_bar = candidate.get('computerUse', {}).get('showInMenuBar', False)
if not isinstance(menu_bar, bool):
    issues.append({'path': '$.computerUse.showInMenuBar', 'message': 'expected boolean, got string'})
status = 'error' if issues else 'ok'
print(json.dumps({'ok': not issues, 'findings': [{'status': status, 'issues': issues}]}))
sys.exit(1 if issues else 0)
"""


class FakeValidatorTestCase(unittest.TestCase):
    """Runs the helper's real validation path against a fake `cmux config validate`."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        cli = self.root / 'fake-cmux'
        cli.write_text(FAKE_CLI)
        cli.chmod(0o755)
        environment = patch.dict(os.environ, {'CMUX_CLI_BIN': str(cli), 'LC_ALL': 'en_US.UTF-8'})
        environment.start()
        self.addCleanup(environment.stop)
        self.config = self.root / 'cmux.json'
        # A key from a newer build: an issue that predates any write here.
        self.config.write_text('{\n "futureSetting": true,\n "computerUse": {"showInMenuBar": true}\n}\n')


class CandidateValidationTests(FakeValidatorTestCase):

    def set_value(self, value):
        args = argparse.Namespace(file=str(self.config), key='computerUse.showInMenuBar',
                                  value=value, scope='global', receipt=None)
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            try:
                code = helper.cmd_set(args)
            except SystemExit as error:
                code = error.code
        return code, stdout.getvalue(), stderr.getvalue()

    def test_unrelated_pre_existing_issue_does_not_block_a_valid_change(self):
        code, stdout, stderr = self.set_value('false')
        self.assertEqual((code, stderr), (0, ''))
        self.assertEqual(json.loads(stdout)['status'], 'persisted')
        root = helper.load_settings(self.config)
        self.assertFalse(root['computerUse']['showInMenuBar'])
        self.assertTrue(root['futureSetting'])

    def test_issue_introduced_by_the_change_is_refused_as_structured_json(self):
        before = self.config.read_bytes()
        code, stdout, stderr = self.set_value('"yes"')
        self.assertEqual((code, stdout), (1, ''))
        payload = json.loads(stderr)
        self.assertEqual(payload['status'], 'conflict')
        self.assertEqual(payload['code'], 'invalid_config')
        self.assertEqual(payload['key'], 'computerUse.showInMenuBar')
        self.assertEqual(payload['message'], helper.mutation_message('invalidCandidate'))
        self.assertEqual(payload['issues'], [
            {'path': '$.computerUse.showInMenuBar', 'message': 'expected boolean, got string'},
        ])
        self.assertEqual(self.config.read_bytes(), before)


    def test_validator_failure_without_issues_refuses_even_when_baseline_fails_too(self):
        # An older CLI rejecting a flag, or a crash, fails both runs the same way.
        (self.root / 'fake-cmux').write_text('#!/bin/sh\necho "error: unknown option --scope" >&2\nexit 2\n')
        before = self.config.read_bytes()
        code, stdout, stderr = self.set_value('false')
        self.assertEqual((code, stdout), (1, ''))
        payload = json.loads(stderr)
        self.assertEqual(payload['code'], 'invalid_config')
        self.assertEqual(payload['issues'], [{'path': '$', 'message': 'error: unknown option --scope'}])
        self.assertEqual(self.config.read_bytes(), before)


class ReceiptAndMessageTests(FakeValidatorTestCase):

    def test_existing_receipt_is_a_structured_conflict_and_config_is_unchanged(self):
        receipt = self.root / 'undo.json'
        receipt.write_text('keep')
        before = self.config.read_bytes()
        args = argparse.Namespace(file=str(self.config), key='computerUse.showInMenuBar',
                                  value='false', scope='global', receipt=str(receipt))
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            with self.assertRaises(SystemExit) as raised:
                helper.cmd_set(args)
        self.assertEqual(raised.exception.code, 1)
        payload = json.loads(stderr.getvalue())
        self.assertEqual(payload['code'], 'receipt_exists')
        self.assertEqual(payload['message'], helper.mutation_message('receiptExists'))
        self.assertEqual(self.config.read_bytes(), before)
        self.assertEqual(receipt.read_text(), 'keep')

    def test_unwritable_receipt_is_a_structured_conflict_and_config_is_unchanged(self):
        before = self.config.read_bytes()
        args = argparse.Namespace(file=str(self.config), key='computerUse.showInMenuBar',
                                  value='false', scope='global',
                                  receipt=str(self.root / 'missing' / 'undo.json'))
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit):
            helper.cmd_set(args)
        payload = json.loads(stderr.getvalue())
        self.assertEqual(payload['code'], 'receipt_unwritable')
        self.assertEqual(payload['message'], helper.mutation_message('receiptInvalid'))
        self.assertEqual(self.config.read_bytes(), before)

    def test_every_locale_has_every_message_as_a_complete_sentence(self):
        catalog = json.loads((SCRIPTS / 'config_mutation_messages.json').read_text(encoding='utf-8'))
        self.assertEqual(set(catalog), {'en', 'de', 'fr', 'ar', 'es', 'zh-Hant', 'zh-Hans', 'ko', 'ja'})
        for locale, messages in catalog.items():
            self.assertEqual(set(messages), set(catalog['en']), locale)
            for key, message in messages.items():
                self.assertFalse(message.rstrip().endswith((':', '：')), f'{locale}.{key}')


if __name__ == '__main__':
    unittest.main()
