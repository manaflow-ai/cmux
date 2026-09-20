#!/usr/bin/env python3
"""Offline canary provisioning and measurement failure contracts."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts/ci' / f'{name}.py')
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


cf = load('r2-canary-cloudflare')
verify = load('verify-r2-canary')


class PreflightTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.created = Path(self.directory.name) / 'created.json'
        self.previous = Path.cwd()
        os.chdir(self.directory.name)
        self.addCleanup(os.chdir, self.previous)
        self.calls = []
        self.missing = True
        self.resource = "cmux-ci-artifacts-canary-123-1"
        self.denied = False
        self.public = False

    def api(self, path, method='GET', value=None):
        self.calls.append((path, method, value))
        if path == 'workers/subdomain': return {'subdomain': 'cmux-test'}
        if path.endswith('/settings'): raise cf.CloudflareError(method, path, 404)
        if path.endswith('/domains/managed'): return {'enabled': self.public}
        if path.endswith('/domains/custom'): return {'domains': []}
        if path.endswith('/lifecycle'): return {'rules': [{'id': 'keep-other-rule'}]}
        if path == f'r2/buckets/{self.resource}' and method == 'GET':
            if self.denied: raise cf.CloudflareError(method, path, 403)
            if self.missing:
                self.missing = False
                raise cf.CloudflareError(method, path, 404)
        return {}

    def run_mode(self, mode):
        with patch.object(cf, 'api', self.api), patch.object(cf, 'CREATED', self.created), \
             patch('sys.argv', ['canary', mode]), patch.dict(os.environ, {'GITHUB_OUTPUT': str(self.created.parent / 'outputs'), 'GITHUB_RUN_ID': '123', 'GITHUB_RUN_ATTEMPT': '1'}):
            cf.main()

    def test_absent_bucket_creates_only_named_bucket_and_preserves_other_lifecycle_rules(self):
        self.missing = True
        self.run_mode('preflight')
        creates = [c for c in self.calls if c[1] == 'POST']
        self.assertEqual(creates, [('r2/buckets', 'POST', {'name': self.resource})])
        rules = [c[2]['rules'] for c in self.calls if c[1] == 'PUT'][0]
        self.assertEqual(rules[0], {'id': 'keep-other-rule'})
        self.assertEqual(rules[1]['conditions']['prefix'], 'github/manaflow-ai/cmux/10610975375/')
        self.assertEqual(json.loads(self.created.read_text())['bucket'], self.resource)

    def test_permission_error_never_creates_or_changes_resources(self):
        self.denied = True
        with self.assertRaises(cf.CloudflareError): self.run_mode('preflight')
        self.assertTrue(all(c[1] == 'GET' for c in self.calls))
        self.assertFalse(self.created.exists())

    def test_public_bucket_never_receives_a_lifecycle_or_deployment(self):
        self.public = True
        with self.assertRaises(RuntimeError): self.run_mode('preflight')
        self.assertFalse(any(c[1] == 'PUT' for c in self.calls))

    def test_unknown_existing_bucket_is_not_reused(self):
        self.missing = False
        with self.assertRaises(RuntimeError): self.run_mode('preflight')
        self.assertTrue(all(c[1] == 'GET' for c in self.calls))

    def test_invalid_run_identity_cannot_select_another_resource(self):
        with patch.dict(os.environ, {'GITHUB_RUN_ID': '123/other', 'GITHUB_RUN_ATTEMPT': '1'}):
            with self.assertRaises(RuntimeError): cf.resource_name()

    def test_cleanup_never_deletes_a_preexisting_bucket(self):
        self.run_mode('cleanup-bucket')
        self.assertEqual(self.calls, [])
        self.created.write_text(json.dumps({'bucket': self.resource}))
        self.run_mode('cleanup-bucket')
        self.assertEqual(self.calls, [(f'r2/buckets/{self.resource}', 'DELETE', None)])


class MeasurementTests(unittest.TestCase):
    def test_hashes_real_bytes_and_distinguishes_fill_from_hit(self):
        for phase in ('cold', 'warm'):
            with self.subTest(phase=phase): self.run_download(phase)

    def test_bad_bytes_and_mislabeled_cold_request_fail(self):
        with self.assertRaises(ValueError): self.run_download('cold', bad_digest=True)
        with self.assertRaises(ValueError): self.run_download('cold', cache='hit')

    def test_cold_timeout_is_a_recorded_failure(self):
        with self.assertRaises(RuntimeError): self.run_download('cold', exit_code=28)

    def run_download(self, phase, bad_digest=False, cache=None, exit_code=0):
        body = b'actual downloaded bytes'
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            (work / verify.TOKEN_FILE).write_text('a' * 64)
            receipt = {'requests': []}
            def curl(args, **kwargs):
                self.assertNotIn('a' * 64, ' '.join(args))
                self.assertEqual((work / 'curl-secret-config').stat().st_mode & 0o777, 0o600)
                (work / 'artifact.zip').write_bytes(body)
                (work / 'headers').write_text('X-Cmux-Artifact-Cache: ' + (cache or ('fill' if phase == 'cold' else 'hit')))
                return subprocess.CompletedProcess(args, exit_code, stdout='200 0.1 0.2 23', stderr='')
            with patch.object(verify, 'SIZE', len(body)), patch.object(verify, 'DIGEST', '0' * 64 if bad_digest else hashlib.sha256(body).hexdigest()), \
                 patch.object(verify.subprocess, 'run', curl), patch.dict(os.environ, {'RUNNER_TEMP': directory}):
                try:
                    verify.verify('https://cmux-ci-artifacts-canary.test.workers.dev', phase, receipt, work)
                finally:
                    self.assertEqual(receipt['requests'][0]['phase'], phase)
                    self.assertNotIn('a' * 64, json.dumps(receipt))


if __name__ == '__main__':
    unittest.main()
