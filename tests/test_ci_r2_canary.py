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

    def test_worker_cleanup_requires_ownership_and_removes_bound_durable_objects(self):
        self.run_mode('delete-worker')
        self.assertEqual(self.calls, [])
        self.created.write_text(json.dumps({'worker': 'someone-elses-worker'}))
        self.run_mode('delete-worker')
        self.assertEqual(self.calls, [])
        self.created.write_text(json.dumps({'worker': self.resource}))
        self.run_mode('delete-worker')
        self.assertEqual(self.calls, [(f'workers/scripts/{self.resource}?force=true', 'DELETE', None)])

    def test_secret_cleanup_ignores_absent_secrets(self):
        def missing_secret(path, method='GET', value=None):
            self.calls.append((path, method, value))
            if '/secrets/' in path:
                raise cf.CloudflareError(method, path, 404)
            return {}
        with patch.object(cf, 'api', missing_secret), patch.object(cf, 'CREATED', self.created), \
             patch('sys.argv', ['canary', 'delete-secret']), \
             patch.dict(os.environ, {'GITHUB_RUN_ID': '123', 'GITHUB_RUN_ATTEMPT': '1'}):
            cf.main()
        self.assertEqual(len(self.calls), 2)
        self.assertTrue(all(call[1] == 'DELETE' for call in self.calls))

    def test_secret_cleanup_preserves_non_not_found_errors(self):
        def forbidden_secret(path, method='GET', value=None):
            self.calls.append((path, method, value))
            if '/secrets/' in path:
                raise cf.CloudflareError(method, path, 403)
            return {}
        with patch.object(cf, 'api', forbidden_secret), patch.object(cf, 'CREATED', self.created), \
             patch('sys.argv', ['canary', 'delete-secret']), \
             patch.dict(os.environ, {'GITHUB_RUN_ID': '123', 'GITHUB_RUN_ATTEMPT': '1'}):
            with self.assertRaises(RuntimeError):
                cf.main()

    def test_workflow_covers_transport_pushes_and_canary_measurement_budget(self):
        canary = (ROOT / '.github/workflows/ci-artifact-canary.yml').read_text()
        self.assertIn('timeout-minutes: 20', canary)
        transport = (ROOT / '.github/workflows/ci-artifact-transport.yml').read_text()
        push = transport.split('  push:', 1)[1].split('\n\npermissions:', 1)[0]
        self.assertIn('- .github/workflows/ci.yml', push)

    def test_workflow_retries_remote_artifact_delete_before_bucket_cleanup(self):
        workflow = (ROOT / '.github/workflows/ci-artifact-canary.yml').read_text()
        delete_step = workflow.split("name: Remove only the canary's artifact copy", 1)[1]
        delete_step = delete_step.split('name: Remove an empty bucket created by this run', 1)[0]
        self.assertIn('for attempt in 1 2 3 4; do', delete_step)
        self.assertIn('wrangler r2 object delete "$key" --remote', delete_step)
        self.assertIn('sleep "$((attempt * 5))"', delete_step)
        self.assertIn('exit 1', delete_step)


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


class ReadinessTests(unittest.TestCase):
    def scenario(self, responses):
        body = b'canary bytes'
        calls = []
        clock = [0.0]
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            (work / verify.TOKEN_FILE).write_text('a' * 64)
            output = work / 'receipt.json'
            sequence = iter(responses)
            def advance_fake_clock(seconds):
                self.assertGreaterEqual(seconds, 10)
                clock[0] += seconds
            def curl(args, **kwargs):
                self.assertNotIn('a' * 64, ' '.join(args))
                calls.append((args[-1], clock[0]))
                status, marker, code = next(sequence, (404, '', 22))
                clock[0] += 1
                if code == -1:
                    raise subprocess.TimeoutExpired(args, kwargs['timeout'], output='a' * 64)
                headers = Path(args[args.index('--dump-header') + 1])
                headers.write_text('Server: cloudflare\nCF-Ray: 0123456789abcdef-SJC\n'
                    + f'X-Cmux-Canary-Stage: {marker}\n'
                    + ('X-Cmux-Artifact-Cache: fill\n' if len([c for c in calls if c[0].endswith('.zip')]) == 1 else 'X-Cmux-Artifact-Cache: hit\n')
                    + 'Set-Cookie: secret\nAuthorization: aaaaa\nX-Cmux-Canary-Token: ' + 'a' * 64 + '\n')
                Path(args[args.index('--output') + 1]).write_bytes(body if status == 200 else b'')
                return subprocess.CompletedProcess(args, code, stdout=f'{status:03d} 0.1 0.2 {len(body) if status == 200 else 0}', stderr='a' * 64)
            with patch.object(verify, 'metadata', lambda: {'id': verify.ARTIFACT}), \
                 patch.object(verify, 'SIZE', len(body)), patch.object(verify, 'DIGEST', hashlib.sha256(body).hexdigest()), \
                 patch.object(verify.subprocess, 'run', curl), patch.object(verify.time, 'monotonic', lambda: clock[0]), \
                 patch.object(verify.time, 'sleep', advance_fake_clock), patch.dict(os.environ, {'RUNNER_TEMP': directory}), \
                 patch('sys.argv', ['verify', '--origin', 'https://cmux-ci-artifacts-canary-123-1.test.workers.dev', '--receipt', str(output)]):
                with self.assertRaises(SystemExit) as exited:
                    verify.main()
            receipt = json.loads(output.read_text())
            self.assertNotIn('a' * 64, output.read_text())
            self.assertNotIn('Set-Cookie', output.read_text())
            return exited.exception.code, receipt, calls, clock[0]

    def test_routing_retry_precedes_exactly_one_cold_and_warm_request(self):
        code, receipt, calls, virtual_seconds = self.scenario([(404, '', 22), (204, 'ready-v1', 0), (200, 'artifact-v1', 0), (200, 'artifact-v1', 0)])
        self.assertEqual(code, 0)
        self.assertEqual([r['phase'] for r in receipt['requests']], ['readiness', 'readiness', 'cold', 'warm'])
        self.assertTrue(all('__cmux_artifact_canary_ready' in url for url, _ in calls[:2]))
        self.assertEqual(sum(url.endswith('.zip') for url, _ in calls), 2)
        self.assertGreaterEqual(calls[1][1] - calls[0][1], 10)

    def test_marked_gate_rejection_stops_without_import_or_sleep(self):
        code, receipt, calls, virtual_seconds = self.scenario([(404, 'gate-rejected', 22)])
        self.assertEqual(code, 1)
        self.assertEqual(len(calls), 1)
        self.assertEqual(receipt['requests'][0]['http_status'], 404)
        self.assertEqual(receipt['requests'][0]['canary_stage'], 'gate-rejected')
        self.assertFalse(any(url.endswith('.zip') for url, _ in calls))
        self.assertEqual(virtual_seconds, 1)

    def test_unready_routes_are_bounded_and_never_import(self):
        code, receipt, calls, virtual_seconds = self.scenario([])
        self.assertEqual(code, 1)
        self.assertLessEqual(len(calls), 6)
        self.assertEqual(virtual_seconds, 56)  # Six simulated 1s probes and five 10s advances.
        self.assertTrue(all(b[1] - a[1] >= 10 for a, b in zip(calls, calls[1:])))
        self.assertFalse(any(url.endswith('.zip') for url, _ in calls))

    def test_204_without_protocol_marker_never_passes_readiness(self):
        code, receipt, calls, virtual_seconds = self.scenario([(204, '', 0)] * 6)
        self.assertEqual(code, 1)
        self.assertFalse(any(url.endswith('.zip') for url, _ in calls))

    def test_process_timeout_cannot_inherit_readiness_headers_or_leak_exception_output(self):
        code, receipt, calls, virtual_seconds = self.scenario([(204, 'ready-v1', 0), (0, '', -1)])
        self.assertEqual(code, 1)
        self.assertEqual(len(calls), 2)
        row = receipt['requests'][-1]
        self.assertEqual(row['phase'], 'cold')
        self.assertEqual(row['request_error'], 'process-timeout')
        self.assertNotIn('canary_stage', row)
        self.assertEqual(receipt['error_stage'], 'cold')

    def test_artifact_http_errors_and_timeouts_are_recorded_without_retry(self):
        for status, exit_code in [(404, 22), (502, 22), (0, 28)]:
            with self.subTest(status=status):
                code, receipt, calls, virtual_seconds = self.scenario([(204, 'ready-v1', 0), (status, 'artifact-v1', exit_code)])
                self.assertEqual(code, 1)
                self.assertEqual([r['phase'] for r in receipt['requests']], ['readiness', 'cold'])
                self.assertEqual(sum(url.endswith('.zip') for url, _ in calls), 1)
                self.assertEqual(receipt['requests'][-1]['http_status'], status)
                self.assertEqual(receipt['requests'][-1]['canary_stage'], 'artifact-v1')
                self.assertEqual(receipt['error_stage'], 'cold')


if __name__ == '__main__':
    unittest.main()
