"""ios/scripts/reload.sh --review argument contract; never invokes Apple tools.

--review is the end-of-task hand-off (AGENTS.md "Finishing a task"): always the
tag's isolated simulator plus the authenticated iPhone install. Flags that would
drop a leg or skip the auth gate must be refused before anything is built.
Run: python3 ios/tests/test_reload_review_flag.py
"""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
RELOAD = ROOT / 'ios/scripts/reload.sh'


def reload(*args):
    return subprocess.run(['bash', str(RELOAD), *args], cwd=ROOT, capture_output=True, text=True, timeout=30)


class ReviewFlagTests(unittest.TestCase):
    def test_help_documents_review(self):
        result = reload('--help')
        self.assertEqual(result.returncode, 0)
        self.assertIn('--review', result.stdout)
        self.assertIn('verify-iphone-auth.sh', result.stdout)

    def test_review_refuses_flags_that_drop_a_leg_or_the_auth_gate(self):
        for extra in (['--simulator-only'], ['--device-only'], ['--no-launch'], ['--no-sign-in'],
                      ['--no-attach'], ['--no-setup'], ['--prod-auth'], ['--simulator', 'iPhone 17'],
                      ['--device-name', 'Phone']):
            with self.subTest(extra=extra):
                result = reload('--tag', 'review-test', '--review', *extra)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('--review always installs', result.stderr)

    def test_workspace_needs_review(self):
        result = reload('--tag', 'review-test', '--workspace', 'https://github.com/manaflow-ai/cmux/pull/1')
        self.assertEqual(result.returncode, 2)
        self.assertIn('--workspace applies only to --review', result.stderr)


def device(udid, name, product, boot='booted', paired='paired', reality='physical'):
    return {'identifier': udid.lower(), 'hardwareProperties': {'platform': 'iOS', 'reality': reality, 'udid': udid,
            'productType': product}, 'connectionProperties': {'pairingState': paired, 'transportType': 'wired',
            'tunnelState': 'connected'}, 'deviceProperties': {'bootState': boot, 'name': name}}


class ConnectedPhonesTests(unittest.TestCase):
    """--review installs on every connected phone and registers new ones."""

    def run_helpers(self, devices, body, known=''):
        text = RELOAD.read_text()
        funcs = ''.join(re.search(r'\n(%s\(\) \{\n.*?\n\})\n' % name, text, re.S).group(1) + '\n'
                        for name in ('review_phone_result', 'review_connected_phones', 'review_register_phone',
                                     'review_resolve_phones'))
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'bin').mkdir()
            (root / 'devices.json').write_text(json.dumps({'result': {'devices': devices}}))
            xcrun = root / 'bin/xcrun'
            xcrun.write_text('#!/bin/sh\n[ "$1" = devicectl ] || exit 1\nout=$5\ncp "%s" "$out"\n' % (root / 'devices.json'))
            xcrun.chmod(0o755)
            config = root / 'config'
            config.mkdir()
            if known:
                (config / 'iphone-device-ids').write_text(known)
            script = ('set -u\nREVIEW_PHONES_FILE="$CMUX_CONFIG_DIR/iphone-device-ids"\nREVIEW_TARGETS=()\n'
                      'REVIEW_FAILED=0\nREVIEW_PHONE_STATUS=""\n' + funcs + body)
            env = dict(os.environ, PATH=f"{root / 'bin'}:{os.environ['PATH']}", CMUX_CONFIG_DIR=str(config))
            result = subprocess.run(['bash', '-c', script], env=env, capture_output=True, text=True, timeout=30)
            files = {f.name: f.read_text() for f in config.iterdir()}
            return result, files

    def test_every_connected_phone_is_a_target_and_new_ones_register(self):
        devices = [device('00008140-001E3C840E8B001C', 'iPhone', 'iPhone17,4'),
                   device('00008150-0005154E0E84401C', 'Aziz', 'iPhone18,2', boot='unavailable'),
                   device('AAAA', 'Sim', 'iPhone18,3', reality='simulated'),
                   device('00008110-000000000000001E', 'Spare', 'iPhone14,2')]
        result, files = self.run_helpers(devices, 'DEVICE_ID=""; DEFAULT_DEVICE_ID=00008150-0005154E0E84401C\n'
                                         'review_resolve_phones; printf "%s\\n" "${REVIEW_TARGETS[@]}"; '
                                         'echo "FAILED=$REVIEW_FAILED"; echo "$REVIEW_PHONE_STATUS"',
                                         known='00008140-001E3C840E8B001C\tiPhone\tiPhone17,4\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('00008140-001E3C840E8B001C\tiPhone (iPhone17,4', result.stdout)
        self.assertIn('00008110-000000000000001E\tSpare (iPhone14,2', result.stdout)
        self.assertNotIn('AAAA', result.stdout)
        self.assertIn('new iPhone registered: Spare', result.stdout)
        self.assertNotIn('new iPhone registered: iPhone ', result.stdout)
        self.assertIn('FAILED=0', result.stdout)
        self.assertIn('00008150-0005154E0E84401C (default): not connected', result.stdout)
        self.assertIn('00008110-000000000000001E', files['iphone-device-ids'])
        self.assertEqual(files['iphone-device-id'].strip(), '00008140-001E3C840E8B001C')

    def test_no_connected_phone_is_a_blocker(self):
        result, _ = self.run_helpers([], 'DEVICE_ID=""; DEFAULT_DEVICE_ID=""\nreview_resolve_phones')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('found no connected iPhone', result.stderr)

    def test_requested_phone_not_connected_fails(self):
        devices = [device('00008140-001E3C840E8B001C', 'iPhone', 'iPhone17,4')]
        result, _ = self.run_helpers(devices, 'DEVICE_ID=00008150-0005154E0E84401C; DEFAULT_DEVICE_ID=""\n'
                                     'review_resolve_phones; echo "FAILED=$REVIEW_FAILED"')
        self.assertIn('FAILED=1', result.stdout)


class FleetSimulatorTests(unittest.TestCase):
    """--review never opens a simulator on the person's Mac: the simulator check runs on the fleet.

    review_fleet_simulator calls hq's scripts/verify-remote.sh (agent sign-in, a recording) and
    reports the evidence directory it prints; a failure is a blocker with the retry command.
    """

    def run_check(self, verify_body):
        func = re.search(r'\n(review_fleet_simulator\(\) \{\n.*?\n\})\n', RELOAD.read_text(), re.S).group(1)
        with tempfile.TemporaryDirectory() as temp:
            hq = Path(temp) / 'hq'
            (hq / 'scripts').mkdir(parents=True)
            evidence = Path(temp) / 'evidence'
            evidence.mkdir()
            verify = hq / 'scripts/verify-remote.sh'
            verify.write_text('#!/bin/sh\necho "$*" > "%s/args"\n' % temp + verify_body.replace('EVIDENCE', str(evidence)))
            verify.chmod(0o755)
            script = (f'set -u\nTAG=review-test\nREVIEW_HQ_ROOT="{hq}"\nREVIEW_SIM_STATUS=""\n{func}\n'
                      'review_fleet_simulator; rc=$?; echo "STATUS=$REVIEW_SIM_STATUS"; exit $rc')
            result = subprocess.run(['bash', '-c', script], capture_output=True, text=True, timeout=30)
            args = (Path(temp) / 'args').read_text() if (Path(temp) / 'args').exists() else ''
            return result, args, evidence

    def test_reports_the_fleet_evidence_directory(self):
        result, args, evidence = self.run_check('echo "verify-remote: progress" >&2\necho EVIDENCE\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(args.split(), ['ios', '--tag', 'review-test', '--sign-in', 'agent', '--record-secs', '15'])
        self.assertIn(f'STATUS=fleet simulator, signed in (agent account): {evidence}', result.stdout)

    def test_a_failed_fleet_check_is_a_blocker_with_its_retry(self):
        result, _, _ = self.run_check('exit 1\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('STATUS=BLOCKED: the fleet simulator check failed', result.stdout)
        self.assertIn('verify-remote.sh ios --tag review-test --sign-in agent', result.stdout)

    def test_review_never_boots_a_local_simulator(self):
        text = RELOAD.read_text()
        review = text[text.index('if [[ "$REVIEW" -eq 1 ]]; then\n  review_resolve_phones'):]
        self.assertIn('--device-only)', review.split('\n\n')[0] + review[:4000])
        self.assertNotIn('simctl boot', text[text.index('# --- --review'):text.index('# Keep the linked xcframework')])
        self.assertIn('RELOAD_SIMULATOR=0', text)

if __name__ == '__main__':
    unittest.main()
