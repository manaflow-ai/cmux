#!/usr/bin/env python3
"""The SSH daemon attestation runs outside the build slot and waits out a used-up token quota.

Nightly-next run 39368582348 lost a 17-minute build in build-nightly-app's
"Attest immutable SSH daemon assets" step ("API rate limit exceeded for
installation"). The attestation now runs in its own Linux job that retries
after waiting for the quota to reset, and publication still requires it.
"""
from pathlib import Path
import sys
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts/ci'))
import wait_for_token_quota as quota

DOC = yaml.safe_load((ROOT / '.github/workflows/nightly.yml').read_text())
JOBS = DOC['jobs']
ATTEST = 'actions/attest-build-provenance@'


def uses(step, action):
    return str(step.get('uses', '')).startswith(action)


class SshDaemonAttestation(unittest.TestCase):
    def test_the_build_slot_attests_nothing(self):
        steps = JOBS['build-nightly-app']['steps']
        self.assertFalse([step.get('name') for step in steps if uses(step, ATTEST)])
        names = [step.get('name') for step in steps]
        self.assertIn('Upload SSH daemon assets', names)

    def test_a_linux_job_attests_the_uploaded_assets_with_retries(self):
        job = JOBS['attest-nightly-ssh-daemon']
        self.assertEqual(job['runs-on'], 'ubuntu-24.04')
        self.assertIn('build-nightly-app', job['needs'])
        self.assertIn("needs.build-nightly-app.result == 'success'", job['if'])
        # An unsigned resume re-uploads the source run's assets under the same
        # name and publishes them, so it attests them too (publish requires it).
        self.assertNotIn('nightly_next_unsigned_run', job['if'])
        retain = [step for step in JOBS['build-nightly-app']['steps']
                  if step.get('name') == 'Retain resumed cmux-nightly-remote-daemon']
        self.assertEqual([step['with']['name'] for step in retain], ['cmux-nightly-remote-daemon'])
        self.assertEqual(job['permissions'].get('attestations'), 'write')
        self.assertEqual(job['permissions'].get('id-token'), 'write')
        steps = job['steps']
        download = [step for step in steps if uses(step, 'actions/download-artifact@')]
        self.assertEqual([step['with']['name'] for step in download], ['cmux-nightly-remote-daemon'])
        attests = [step for step in steps if uses(step, ATTEST)]
        self.assertEqual(len(attests), 3)
        for step in attests:
            self.assertEqual(step['with']['subject-path'], 'remote-daemon-assets/cmuxd-remote-*')
        # Every attempt but the last may fail; the last one fails the job.
        self.assertTrue(attests[0].get('continue-on-error'))
        self.assertTrue(attests[1].get('continue-on-error'))
        self.assertFalse(attests[2].get('continue-on-error', False))
        self.assertEqual(attests[1]['if'], "steps.attest-1.outcome == 'failure'")
        self.assertEqual(attests[2]['if'], "steps.attest-2.outcome == 'failure'")
        waits = [step for step in steps if 'wait_for_token_quota.py' in str(step.get('run', ''))]
        self.assertEqual([step['if'] for step in waits],
                         ["steps.attest-1.outcome == 'failure'", "steps.attest-2.outcome == 'failure'"])
        # Two waits of up to an hour fit the job's budget.
        self.assertGreaterEqual(job['timeout-minutes'], 2 * 61 + 10)

    def test_publication_requires_the_attestation_of_a_fresh_build(self):
        publish = JOBS['publish-nightly']
        self.assertIn('attest-nightly-ssh-daemon', publish['needs'])
        fresh = ("needs.verify-signed-nightly.result == 'success' && "
                 "needs.attest-nightly-ssh-daemon.result == 'success')")
        self.assertIn(fresh, publish['if'])
        self.assertIn('attest-nightly-ssh-daemon', JOBS['report-nightly-failure']['needs'])


class QuotaWait(unittest.TestCase):
    def test_waits_until_the_core_quota_resets(self):
        rate = {'resources': {'core': {'remaining': 0, 'reset': 1_000 + 1_500}}}
        self.assertEqual(quota.wait_seconds(rate, 1_000, 60, 3660), 1_500 + quota.MARGIN)

    def test_never_shorter_than_the_floor_or_longer_than_the_cap(self):
        soon = {'resources': {'core': {'remaining': 0, 'reset': 1_005}}}
        self.assertEqual(quota.wait_seconds(soon, 1_000, 60, 3660), 60)
        late = {'resources': {'core': {'remaining': 0, 'reset': 1_000 + 99_999}}}
        self.assertEqual(quota.wait_seconds(late, 1_000, 60, 3660), 3660)

    def test_quota_left_or_unreadable_waits_briefly(self):
        left = {'resources': {'core': {'remaining': 12, 'reset': 1_000 + 3_000}}}
        self.assertEqual(quota.wait_seconds(left, 1_000, 60, 3660), 60)
        self.assertEqual(quota.wait_seconds(None, 1_000, 60, 3660), 120)
        self.assertEqual(quota.wait_seconds({'resources': {}}, 1_000, 60, 3660), 120)


if __name__ == '__main__':
    unittest.main()
