#!/usr/bin/env python3
"""Mutations of the native signing workflow must still fail custody checks."""
import copy
from pathlib import Path
import unittest
import yaml
import test_ci_signing_keychain_is_deleted_before_bundle_code as guard

ROOT = Path(__file__).resolve().parents[1]
JOBS = yaml.safe_load((ROOT / '.github/workflows/nightly.yml').read_text())['jobs']


class NativeCustodyTests(unittest.TestCase):
    def errors(self, job):
        errors = []
        guard.check_job('nightly.yml signer-app', job, errors)
        return errors

    def test_both_native_signers_preserve_custody(self):
        for name in ('signer-app', 'signer-dmg'):
            errors = []
            guard.check_job(f'nightly.yml {name}', JOBS[name], errors)
            self.assertEqual(errors, [])

    def test_import_requires_macos_condition(self):
        job = copy.deepcopy(JOBS['signer-app'])
        step = next(s for s in job['steps'] if 'signing-keychain.sh create' in s.get('run', ''))
        step.pop('if')
        self.assertTrue(any('macOS-conditional' in e for e in self.errors(job)))

    def test_cleanup_is_unconditional(self):
        job = copy.deepcopy(JOBS['signer-app'])
        step = next(s for s in job['steps'] if 'signing-keychain.sh delete' in s.get('run', ''))
        step['if'] = "runner.os == 'macOS'"
        self.assertTrue(any('always()' in e for e in self.errors(job)))

    def test_stale_capability_is_rejected(self):
        job = copy.deepcopy(JOBS['signer-app'])
        job['runs-on'] = job['runs-on'].replace(
            'needs.pick-nightly-sign-runner.outputs.attempt == github.run_attempt && ', '')
        self.assertTrue(any('current-attempt' in e for e in self.errors(job)))

    def test_unrelated_step_cannot_receive_certificate(self):
        job = copy.deepcopy(JOBS['signer-app'])
        job['steps'].append({'run': 'echo unexpected', 'env': {
            'P12': '${{ secrets.APPLE_CERTIFICATE_BASE64 }}'}})
        self.assertTrue(any('only the managed native import' in e for e in self.errors(job)))

    def test_removing_native_route_does_not_allow_linux_keychain(self):
        job = copy.deepcopy(JOBS['signer-app'])
        job['runs-on'] = 'blacksmith-4vcpu-ubuntu-2404'
        self.assertTrue(any('makes no keychain' in e for e in self.errors(job)))

    def test_linux_fallback_cannot_disappear(self):
        job = copy.deepcopy(JOBS['signer-app'])
        for step in job['steps']:
            if 'run' in step:
                step['run'] = step['run'].replace('scripts/ci/release-signer/sign-app.sh', 'missing.sh')
        self.assertTrue(any('Linux signer fallback' in e for e in self.errors(job)))


if __name__ == '__main__':
    unittest.main()
