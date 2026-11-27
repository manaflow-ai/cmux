#!/usr/bin/env python3
"""Shared Swift product routing, identity and cross-checkout runtime contract."""
from __future__ import annotations

import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('products', ROOT / 'scripts/ci/swift-test-products.py')
products = importlib.util.module_from_spec(spec)
spec.loader.exec_module(products)
WORKFLOW = ROOT / '.github/workflows/cmux-next.yml'


def evaluate(expression, context):
    def field(match):
        value = context
        for part in match.group().split('.'):
            value = value.get(part, '') if isinstance(value, dict) else ''
        return repr(value)
    source = re.sub(r'\b(?:needs|github|inputs)(?:\.[A-Za-z0-9_-]+)+', field, expression[3:-2])
    source = source.replace('&&', ' and ').replace('||', ' or ')
    source = re.sub(r'!(?!=)', ' not ', source)
    return bool(eval(source, {'__builtins__': {}}, {
        'cancelled': lambda: context.get('cancelled', False),
        'startsWith': lambda a, b: a.startswith(b), 'contains': lambda a, b: b in a,
        'fromJSON': json.loads, 'true': True, 'false': False,
    }))


class Routing(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.jobs = yaml.safe_load(WORKFLOW.read_text())['jobs']

    def context(self, **outputs):
        return {'github': {'event_name': 'pull_request', 'repository': 'manaflow-ai/cmux', 'event': {
            'action': 'synchronize', 'pull_request': {'base': {'ref': 'main'}, 'head': {'repo': {'full_name': 'manaflow-ai/cmux'}}}}},
            'inputs': {'same_tree_sha': '', 'same_tree_origin': ''},
            'needs': {'path_route': {'outputs': {'swift': 'false', 'swift_targets': '', 'daemon': 'false', 'tree_state': 'ready', 'generated_host': '', 'labels': '', **outputs}},
                      'web-bundles': {'result': 'success'}, 'push-head-preflight': {'outputs': {'current': 'true'}},
                      'generated-files-base-red': {'outputs': {'base_red': 'false'}}, 'generated-files-linux': {'outputs': {'verdict': ''}}}}

    def selected(self, context):
        return evaluate(self.jobs['swift-test-products']['if'], context)

    def test_union_each_consumer_can_be_only_build(self):
        for outputs in ({'swift': 'true', 'swift_targets': 'CmuxNextAppTests'}, {'daemon': 'true'}, {'generated_host': 'generated-files'}):
            with self.subTest(outputs=outputs):
                self.assertTrue(self.selected(self.context(**outputs)))
        self.assertFalse(self.selected(self.context()))
        self.assertFalse(self.selected(self.context(swift='true')))

    def test_web_skipped_and_generated_linux_fallback(self):
        context = self.context(generated_host='generated-files')
        context['needs']['web-bundles']['result'] = 'skipped'
        context['github']['event']['pull_request']['base']['ref'] = 'feat-cmux-next'
        self.assertTrue(self.selected(context))
        context['needs']['generated-files-linux']['outputs']['verdict'] = 'fresh'
        self.assertFalse(self.selected(context))
        context['needs']['path_route']['outputs'].update(swift='true', swift_targets='all')
        context['github']['event']['pull_request']['base']['ref'] = 'main'
        self.assertTrue(self.selected(context))

    def test_full_ci_fork_generated_route_and_unrelated_labels(self):
        context = self.context(generated_host='generated-files', labels=',full-ci,')
        event = context['github']['event']
        event['pull_request']['head']['repo']['full_name'] = 'fork/cmux'
        event['pull_request']['base']['ref'] = 'feat-cmux-next'
        event.update(action='labeled', label={'name': 'full-ci'})
        self.assertTrue(self.selected(context))
        event['label']['name'] = 'documentation'
        self.assertFalse(self.selected(context))

    def test_failed_web_cancel_nonpr_and_different_source_do_not_produce(self):
        for edit in ('web', 'cancelled', 'push', 'same-tree'):
            context = self.context(daemon='true')
            if edit == 'web': context['needs']['web-bundles']['result'] = 'failure'
            if edit == 'cancelled': context['cancelled'] = True
            if edit == 'push': context['github']['event_name'] = 'push'
            if edit == 'same-tree': context['inputs']['same_tree_sha'] = 'other'
            with self.subTest(edit=edit): self.assertFalse(self.selected(context))

    def test_consumers_fail_closed_preserving_build_step_receipts(self):
        for name in ('swift-test', 'daemon-test', 'generated-files'):
            job = self.jobs[name]
            self.assertIn('swift-test-products', job['needs'])
            self.assertIn("needs.swift-test-products.result == 'skipped'", job['if'])
            self.assertEqual(job['permissions']['id-token'], 'write')
            download = next(s for s in job['steps'] if s['name'] == 'Download the shared Swift test products')
            self.assertNotIn('continue-on-error', download)
            self.assertEqual(download['with']['name'], '${{ needs.swift-test-products.outputs.artifact_name }}')
            build = next(s for s in job['steps'] if s['name'] == 'Build package and tests')
            self.assertIn('restore --archive', build['run'].split('\nelse\n')[0])
            self.assertNotIn('swift build', build['run'].split('\nelse\n')[0])
            if name != 'generated-files': self.assertEqual(build['id'], 'build-tests')

    def test_no_dependency_cycle_added(self):
        visiting, visited = set(), set()
        def visit(name):
            self.assertNotIn(name, visiting)
            if name in visited: return
            visiting.add(name)
            needs = self.jobs[name].get('needs', [])
            for dependency in ([needs] if isinstance(needs, str) else needs): visit(dependency)
            visiting.remove(name)
            visited.add(name)
        for name in self.jobs: visit(name)


class Products(unittest.TestCase):
    def current(self):
        return {'version': 1, 'profile': products.PROFILE, 'package': products.PACKAGE, 'sha': 'a' * 40,
                'tree': 'b' * 40, 'run': '123', 'repository': 'manaflow-ai/cmux', 'xcode': 'Xcode 27.2\nBuild 27A1',
                'swift': 'Swift 6.4', 'sdk': '27A1', 'developer': '/Applications/Xcode.app/Contents/Developer',
                'architecture': 'arm64', 'flags': {'CMUX_LIVE_CODE_BUILD': '', 'CMUX_SWIFTPM_TARGET_LINUX': ''}}

    def test_rejects_each_identity_mismatch(self):
        current = self.current()
        for key in current:
            receipt = {**current, 'source_root': '/original/checkout', key: 'different'}
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, key): products.validate(receipt, current)

    def test_real_archive_relocates_runtime_resources_on_failed_job_rerun(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            producer = root / ('producer-' + 'x' * 60)
            consumer = root / 'consumer'
            producer.mkdir(); consumer.mkdir()
            build = producer / products.PACKAGE / '.build/arm64-apple-macosx/debug'
            bundle = build / 'CmuxNextPackageTests.xctest'
            bundle.mkdir(parents=True)
            binary = bundle / 'test'
            resource = build / 'CmuxNextApp.bundle'
            resource.mkdir()
            (resource / 'fixture.txt').write_text('runtime resource')
            binary.write_bytes(b'\xcf\xfa\xed\xfe' + str(producer).encode() + b'/Packages/macOS/CmuxNext/.build/debug/CmuxNextApp.bundle/fixture.txt')
            (build / 'description.json').write_text(json.dumps({'path': str(producer) + '/Packages/macOS/CmuxNext'}))
            (build / 'some-module.build').mkdir()
            (build / 'some-module.build/object.o').write_bytes(b'not transported')
            archive = root / 'products.tar.gz'
            current = self.current()
            with patch.dict(os.environ, GITHUB_OUTPUT=str(root / 'outputs'), GITHUB_RUN_ATTEMPT='1'):
                products.pack(producer, archive, current)
            self.assertIn('artifact_name=cmux-swift-products-123-1', (root / 'outputs').read_text())
            alias = str(root / 'alias') + 'x' * (len(str(producer)) - len(str(root / 'alias')))
            os.symlink(consumer, alias)
            with patch.dict(os.environ, GITHUB_RUN_ATTEMPT='2'), patch.object(products.fleet, 'alias_for', return_value=alias), patch.object(products.subprocess, 'run') as signed:
                products.restore(consumer, archive, products.digest(archive), current)
            copied = consumer / products.PACKAGE / '.build/debug'
            self.assertEqual((copied / 'CmuxNextPackageTests.xctest/test').read_bytes(), binary.read_bytes().replace(str(producer).encode(), alias.encode()))
            self.assertTrue((Path(alias) / products.PACKAGE / '.build/debug/CmuxNextApp.bundle/fixture.txt').is_file())
            self.assertFalse((copied / 'some-module.build').exists())
            signed.assert_called_once()
            with self.assertRaisesRegex(ValueError, 'digest mismatch'):
                products.restore(consumer, archive, '0' * 64, current)

    def test_archive_rejects_escape_and_symlink_parent(self):
        for names in [('product/../../escape',), ('product', 'product/file')]:
            with tempfile.TemporaryFile() as stream:
                with tarfile.open(fileobj=stream, mode='w') as tar:
                    for name in names:
                        member = tarfile.TarInfo(name)
                        if name == 'product': member.type, member.linkname = tarfile.SYMTYPE, 'other'
                        tar.addfile(member, io.BytesIO(b''))
                stream.seek(0)
                with tarfile.open(fileobj=stream) as tar, self.assertRaises(ValueError):
                    products.checked_members(tar, ['product', 'other'])


if __name__ == '__main__': unittest.main()
