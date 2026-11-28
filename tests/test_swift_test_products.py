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
    source = re.sub(r'\b(?:needs|github|inputs|steps|env)(?:\.[A-Za-z0-9_-]+)+', field, expression[3:-2])
    source = source.replace('&&', ' and ').replace('||', ' or ')
    source = re.sub(r'!(?!=)', ' not ', source)
    return eval(source, {'__builtins__': {}}, {
        'cancelled': lambda: context.get('cancelled', False),
        'startsWith': lambda a, b: a.startswith(b), 'contains': lambda a, b: b in a,
        'fromJSON': json.loads, 'true': True, 'false': False,
    })


class Routing(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.jobs = yaml.safe_load(WORKFLOW.read_text())['jobs']

    def test_no_eager_producer_and_existing_reuse_controls_every_compile(self):
        self.assertNotIn('swift-test-products', self.jobs)
        for name in ('swift-test', 'daemon-test', 'generated-files'):
            job = self.jobs[name]
            build = next(s for s in job['steps'] if s['name'] == 'Build package and tests')
            self.assertIn("steps.reuse.outputs.hit != 'true'", build['if'])
            self.assertEqual(build['id'], 'build-tests')
            context = {'steps': {'reuse': {'outputs': {'hit': 'true'}}}, 'env': {'SWIFT_TARGETS': 'all'}}
            # No separate compile job exists when all reuse receipts hit.
            self.assertFalse(evaluate(build['if'], context))

    def test_relay_edges_and_failed_tests_do_not_gate_later_suites(self):
        self.assertIn('swift-test', self.jobs['daemon-test']['needs'])
        self.assertIn('daemon-test', self.jobs['generated-files']['needs'])
        self.assertIn('swift-test', self.jobs['generated-files']['needs'])
        for name in ('daemon-test', 'generated-files'):
            job = self.jobs[name]
            self.assertIn('!cancelled()', job['if'])
            self.assertNotIn("needs.swift-test.result", job['if'])
            self.assertNotIn("needs.daemon-test.result", job['if'])
        for name in ('swift-test', 'daemon-test'):
            output = self.jobs[name]['outputs']['swift_products_state']
            self.assertNotIn('job.status', output)
            self.assertNotIn('success()', output)

    def test_product_state_needs_upload_or_successful_restore_not_test_success(self):
        base = {'github': {'event_name': 'pull_request'}, 'inputs': {'same_tree_sha': ''}}
        for name in ('swift-test', 'daemon-test'):
            output = self.jobs[name]['outputs']['swift_products_state']
            cases = [('success', 'success', '', 'ready'), ('success', 'failure', '', 'failed'),
                     ('success', 'skipped', '', 'failed'), ('failure', 'skipped', '', 'failed'),
                     ('skipped', 'skipped', '', '')]
            if name == 'daemon-test':
                cases.append(('success', 'skipped', 'true', 'ready'))
            for build, upload, restored, expected in cases:
                with self.subTest(job=name, build=build, upload=upload, restored=restored):
                    context = {**base, 'steps': {'build-tests': {'outcome': build, 'outputs': {'restored': restored}},
                                                'products-upload': {'outcome': upload}}, 'job': {'status': 'failure'}}
                    self.assertEqual(evaluate(output, context), expected)

    def test_job_outputs_only_reference_real_step_ids(self):
        for name in ('swift-test', 'daemon-test', 'generated-files'):
            job = self.jobs[name]
            steps = {step.get('id') for step in job['steps']}
            for expression in job['outputs'].values():
                self.assertTrue(set(re.findall(r'steps\.([\w-]+)\.', expression)) <= steps)

    def test_original_routing_keeps_web_skips_and_linux_fallback(self):
        base = {
            'github': {'event_name': 'pull_request', 'repository': 'manaflow-ai/cmux',
                       'event': {'pull_request': {'base': {'ref': 'main'},
                                                  'head': {'repo': {'full_name': 'manaflow-ai/cmux'}}}}},
            'needs': {'web-bundles': {'result': 'skipped'},
                      'path_route': {'outputs': {'swift': 'true', 'daemon': 'true', 'tree_state': 'ready',
                                                'generated_host': 'generated-files'}},
                      'push-head-preflight': {'outputs': {'current': 'true'}},
                      'swift-test': {'result': 'failure'}, 'daemon-test': {'result': 'failure'}}}
        for name in ('swift-test', 'daemon-test', 'generated-files'):
            self.assertTrue(evaluate(self.jobs[name]['if'], base), name)
        linux_success = copy.deepcopy(base)
        linux_success['needs']['generated-files-linux'] = {'outputs': {'verdict': 'fresh'}}
        self.assertFalse(evaluate(self.jobs['generated-files']['if'], linux_success))
        normal_next = copy.deepcopy(base)
        normal_next['github']['event']['pull_request']['base']['ref'] = 'feat-cmux-next'
        for name in ('swift-test', 'daemon-test'):
            self.assertFalse(evaluate(self.jobs[name]['if'], normal_next), name)
        for result in ('failure', 'cancelled'):
            failed_web = copy.deepcopy(base)
            failed_web['needs']['web-bundles']['result'] = result
            for name in ('swift-test', 'daemon-test', 'generated-files'):
                self.assertFalse(evaluate(self.jobs[name]['if'], failed_web), name)
        cancelled = {**base, 'cancelled': True}
        for name in ('swift-test', 'daemon-test', 'generated-files'):
            self.assertFalse(evaluate(self.jobs[name]['if'], cancelled), name)

    def test_missing_or_failed_artifacts_fail_closed(self):
        import subprocess
        for name in ('daemon-test', 'generated-files'):
            job = self.jobs[name]
            select = next(s for s in job['steps'] if s.get('id') == 'shared-products')
            download = next(s for s in job['steps'] if s['name'] == 'Download shared Swift test products')
            self.assertNotIn('continue-on-error', download)
            self.assertNotIn('github.run_attempt', download['with']['name'])
            for state, artifact, digest, code in [('ready', 'original-attempt-1', 'a' * 64, 0), ('ready', '', '', 1), ('failed', '', '', 1), ('', '', '', 0)]:
                with self.subTest(job=name,state=state,artifact=artifact), tempfile.TemporaryDirectory() as tmp:
                    result = subprocess.run(['bash', '-e', '-c', select['run']], env={**os.environ, 'GITHUB_OUTPUT': str(Path(tmp) / 'output'), 'PRODUCT_STATE': state, 'PRODUCT_NAME': artifact, 'PRODUCT_SHA256': digest}, capture_output=True)
                    self.assertEqual(result.returncode, code, result.stderr)
            build = next(s for s in job['steps'] if s['name'] == 'Build package and tests')
            self.assertNotIn('swift build', build['run'].split('\nelse\n')[0])

    def test_publish_only_actual_local_builds_not_reused_or_restored_products(self):
        for name in ('swift-test', 'daemon-test'):
            steps = self.jobs[name]['steps']
            for step in [s for s in steps if s['name'] in ('Pack shared Swift test products', 'Upload shared Swift test products')]:
                self.assertIn("steps.build-tests.outcome == 'success'", step['if'])
                self.assertIn("steps.build-tests.outputs.restored != 'true'", step['if'])
                self.assertIn("github.event_name == 'pull_request'", step['if'])
                self.assertNotIn('continue-on-error', step)

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
            with patch.dict(os.environ, GITHUB_RUN_ATTEMPT='2', GITHUB_OUTPUT=str(root / 'restore-output')), patch.object(products.fleet, 'alias_for', return_value=alias), patch.object(products.subprocess, 'run') as signed:
                products.restore(consumer, archive, products.digest(archive), current)
            copied = consumer / products.PACKAGE / '.build/debug'
            self.assertEqual((copied / 'CmuxNextPackageTests.xctest/test').read_bytes(), binary.read_bytes().replace(str(producer).encode(), alias.encode()))
            self.assertTrue((Path(alias) / products.PACKAGE / '.build/debug/CmuxNextApp.bundle/fixture.txt').is_file())
            self.assertFalse((copied / 'some-module.build').exists())
            signed.assert_called_once()
            with self.assertRaisesRegex(ValueError, 'digest mismatch'):
                products.restore(consumer, archive, '0' * 64, current)
            copied.unlink()
            copied.mkdir()
            (copied / 'stale-product').write_text('must not consume this tree')
            with self.assertRaisesRegex(ValueError, 'expected product symlink'):
                products.restore(consumer, archive, products.digest(archive), current)
            self.assertEqual((copied / 'stale-product').read_text(), 'must not consume this tree')

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
