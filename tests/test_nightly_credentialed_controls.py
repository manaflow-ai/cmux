#!/usr/bin/env python3
"""Credentialed controls accept only their trusted runner set in production."""
import json
import unittest

from test_nightly_trusted_routing import DOC, evaluate, parse_expression

JOBS = ('attest-nightly-remote-daemon', 'route-visual-gate-nightly', 'published-in')
MEMBERS = ('blacksmith-16vcpu-ubuntu-2404', 'blacksmith-32vcpu-ubuntu-2404')


class CredentialedControls(unittest.TestCase):
    def select(self, job, pool='', attempt=1, owner='manaflow-ai'):
        # The shared parser intentionally discards properties of call results.
        # Resolve this JSON property lazily so the fork branch still tests
        # short-circuit behavior without pretending the entire object is a label.
        class Context(dict):
            def get(self, key, default=''):
                if key == 'pool_linux':
                    return json.loads(pool or '{}').get('linux', '')
                return super().get(key, default)
        source = DOC['jobs'][job]['runs-on'][3:-2]
        self.assertIn("fromJSON(vars.RUNNER_POOLS || '{}').linux", source)
        source = source.replace("fromJSON(vars.RUNNER_POOLS || '{}').linux", 'pool_linux')
        return evaluate(parse_expression(source), Context({
            'github.repository_owner': owner,
            'github.run_attempt': attempt,
            'vars.RUNNER_POOLS': pool,
        }))

    def test_live_trusted_member_is_used(self):
        for job in JOBS:
            for member in MEMBERS:
                with self.subTest(job=job, member=member):
                    self.assertEqual(self.select(job, json.dumps({'linux': member})), member)

    def test_unset_and_untrusted_routes_stay_ephemeral_on_every_attempt(self):
        for job in JOBS:
            for pool in ('', '{}', '{"linux":"ubuntu-24.04"}',
                         '{"linux":"cmux-fleet-linux-x64"}',
                         '{"linux":"glaeda-side-std-xcode-26.6"}'):
                with self.subTest(job=job, pool=pool):
                    self.assertEqual(self.select(job, pool), MEMBERS[1])
                    self.assertEqual(self.select(job, pool, attempt=2), MEMBERS[0])

    def test_forks_short_circuit_pool_parsing(self):
        for job in JOBS:
            self.assertEqual(self.select(job, 'not json', owner='someone'), 'ubuntu-24.04')

    def test_credential_permissions_remain_scoped_to_each_control(self):
        self.assertEqual(DOC['jobs'][JOBS[0]]['permissions'], {
            'contents': 'read', 'attestations': 'write', 'id-token': 'write'})
        self.assertEqual(DOC['jobs'][JOBS[1]]['environment'], 'ci-routing-agent')
        self.assertEqual(DOC['jobs'][JOBS[2]]['permissions'], {
            'contents': 'read', 'pull-requests': 'write'})


if __name__ == '__main__':
    unittest.main()
