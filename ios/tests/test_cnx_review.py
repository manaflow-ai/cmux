"""cmux-next-ios/scripts/review.sh, the cmux-next iPhone app's end-of-task hand-off; never invokes Apple tools.

Stand-in xcrun / cmux-ci binaries and shell functions replace the fleet, the phone and the Mac, so it
runs on Linux. Covers: the report and its exit code for every state (all phones pass, no phone, a
phone that fails its gate, a fleet failure, a Mac that does not come back), the launch environment
(credentials only in the signed-in launch, never on a command line, nothing in the credential-free
relaunch), the readiness receipt checker, the local signer's profile and entitlement choices, and
the fleet step's handoff arguments.
Run: python3 ios/tests/test_cnx_review.py
"""
import datetime
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
REVIEW = ROOT / 'cmux-next-ios/scripts/review.sh'
RECEIPT = ROOT / 'cmux-next-ios/scripts/handoff_receipt.py'
SIGNER = ROOT / 'cmux-next-ios/scripts/sign_device_app.py'
SIM = ROOT / 'scripts/ci/cmux-next-ios-sim.sh'
PHONE = '00008140-001E3C840E8B001C'
TAG = 'cnx-test-v1'
SHA = 'a' * 40


def bash(script, env=None, timeout=60):
    return subprocess.run(['bash', '-c', script], capture_output=True, text=True, timeout=timeout,
                          env=dict(os.environ, **(env or {})))


def devices_json(*phones):
    return json.dumps({'result': {'devices': [
        {'identifier': u.lower(), 'hardwareProperties': {'platform': 'iOS', 'reality': 'physical', 'udid': u,
                                                          'productType': 'iPhone17,4', 'marketingName': 'iPhone 16 Plus'},
         'connectionProperties': {'pairingState': 'paired', 'transportType': 'wired', 'tunnelState': 'connected'},
         'deviceProperties': {'bootState': 'booted', 'name': n}} for u, n in phones]}})


class ReviewRunTests(unittest.TestCase):
    """review_run's states, with the fleet, the Mac and each phone's checks replaced by stand-ins."""

    def run_review(self, phones, overrides):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'bin').mkdir()
            (root / 'devices.json').write_text(devices_json(*phones))
            xcrun = root / 'bin/xcrun'
            xcrun.write_text('#!/bin/sh\n[ "$1" = devicectl ] && [ "$2" = list ] || exit 1\ncp "%s" "$5"\n'
                             % (root / 'devices.json'))
            xcrun.chmod(0o755)
            (root / 'config').mkdir()
            script = f'''
set -euo pipefail
source "{REVIEW}"
SLUG={TAG} SHA={SHA} BUNDLE_ID=dev.cmux.mobile.{TAG} STATE="{root}/state"
PERSONAL_EMAIL=me@example.com PERSONAL_PASSWORD=pw-secret PERSONAL_ACCOUNT=me@example.com
REVIEW_PHONES_FILE="{root}/config/iphone-device-ids"
fleet_start_sim() {{ :; }}
fleet_submit_mac() {{ MAC_JOB=job123; }}
fleet_finish_mac() {{ REPORT_MAC="fleet job $MAC_JOB, published to HQ"; }}
fleet_finish_sim() {{ :; }}
read_ios_artifact() {{ REPORT_SIM="fleet simulator (aws-m4pro-3, iPhone-17 on iOS-26-5), signed in: /e"; }}
mac_install() {{ :; }}
mac_start() {{ :; }}
mac_restart() {{ :; }}
phone_review() {{ PHONE_LINE="$2: installed, signed in (auto_login), paired and linked with cmux DEV {TAG}"; }}
phone_after_mac_restart() {{ PHONE_VERDICT="signed in (restored), paired and linked with cmux DEV {TAG}"; }}
{overrides}
review_run
'''
            env = {'PATH': f"{root / 'bin'}:{os.environ['PATH']}", 'HOME': str(root), 'CMUX_CONFIG_DIR': str(root / 'config')}
            return bash(script, env)

    def test_every_phone_passes(self):
        r = self.run_review([(PHONE, 'iPhone')], '')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(f'Dev build:  http://127.0.0.1:17320/{TAG}   (fleet job job123, published to HQ, head {SHA})', r.stdout)
        self.assertIn('Simulator:  fleet simulator (aws-m4pro-3', r.stdout)
        self.assertIn(f'iPhone:     iPhone (iPhone 16 Plus, {PHONE}): installed, signed in (auto_login), paired', r.stdout)
        self.assertIn('after the Mac app relaunched: signed in (restored), paired and linked', r.stdout)

    def test_two_phones_get_one_line_each(self):
        other = '00008110-000000000000001E'
        r = self.run_review([(PHONE, 'iPhone'), (other, 'Spare')], '')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(f'iPhone:     iPhone (iPhone 16 Plus, {PHONE}):', r.stdout)
        self.assertIn(f'            Spare (iPhone 16 Plus, {other}):', r.stdout)

    def test_no_connected_phone_fails_before_building(self):
        r = self.run_review([], 'fleet_start_sim() { echo SUBMITTED; }')
        self.assertEqual(r.returncode, 1)
        self.assertNotIn('SUBMITTED', r.stdout)
        self.assertIn('found no connected iPhone', r.stderr)
        self.assertIn(f'iPhone:     BLOCKED: no connected iPhone; connect and unlock one, then rerun: '
                      f'cmux-next-ios/scripts/review.sh --tag {TAG}', r.stdout)

    def test_a_phone_that_fails_its_gate_is_blocked_with_a_retry(self):
        other = '00008110-000000000000001E'
        r = self.run_review([(PHONE, 'iPhone'), (other, 'Spare')], f'''
phone_review() {{
  if [[ "$1" == {other} ]]; then PHONE_REASON="restored launch: not paired with the tagged Mac yet (after 180 s)"; return 1; fi
  PHONE_LINE="$2: installed, signed in (auto_login)"
}}''')
        self.assertEqual(r.returncode, 1)
        self.assertIn(f'iPhone (iPhone 16 Plus, {PHONE}): installed, signed in (auto_login); after the Mac app relaunched', r.stdout)
        self.assertIn(f'Spare (iPhone 16 Plus, {other}): BLOCKED: restored launch: not paired with the tagged Mac yet '
                      f'(after 180 s); retry: cmux-next-ios/scripts/review.sh --tag {TAG}', r.stdout)

    def test_a_fleet_failure_blocks_every_phone_and_the_build_line(self):
        r = self.run_review([(PHONE, 'iPhone')], f'''
fleet_finish_mac() {{ REPORT_MAC="BLOCKED: fleet job $MAC_JOB failed (cmux-ci log $MAC_JOB); retry: $(retry_command)"; return 1; }}
phone_review() {{ echo PHONE_TOUCHED; }}''')
        self.assertEqual(r.returncode, 1)
        self.assertNotIn('PHONE_TOUCHED', r.stdout)
        self.assertIn('Dev build:  http://127.0.0.1:17320/cnx-test-v1   (BLOCKED: fleet job job123 failed', r.stdout)
        self.assertIn(f'iPhone:     iPhone (iPhone 16 Plus, {PHONE}): BLOCKED: nothing installed, the tagged Mac is not ready', r.stdout)

    def test_a_failed_simulator_build_blocks_too(self):
        r = self.run_review([(PHONE, 'iPhone')], '''
fleet_finish_sim() { REPORT_SIM="BLOCKED: the fleet iPhone build failed (step abc, exit 1; /x); retry: $(retry_command)"; return 1; }''')
        self.assertEqual(r.returncode, 1)
        self.assertIn('Simulator:  BLOCKED: the fleet iPhone build failed', r.stdout)
        self.assertIn('nothing installed, the iPhone build is not ready', r.stdout)

    def test_a_mac_that_does_not_come_back_is_a_blocker(self):
        r = self.run_review([(PHONE, 'iPhone')], 'mac_restart() { return 1; }')
        self.assertEqual(r.returncode, 1)
        self.assertIn('BLOCKED: the tagged Mac app did not quit and start again', r.stdout)

    def test_a_phone_that_loses_the_mac_after_its_relaunch_is_a_blocker(self):
        r = self.run_review([(PHONE, 'iPhone')], '''
phone_after_mac_restart() { PHONE_REASON="restored launch: paired with the tagged Mac, not linked yet (after 180 s)"; return 1; }''')
        self.assertEqual(r.returncode, 1)
        self.assertIn('BLOCKED after the Mac app relaunched: restored launch: paired with the tagged Mac, not linked yet', r.stdout)

    def test_target_worker_is_in_the_retry(self):
        r = self.run_review([], 'TARGET_WORKER=aws-m4pro-3')
        self.assertIn(f'review.sh --tag {TAG} --target-worker aws-m4pro-3', r.stdout)


class PhoneLaunchTests(unittest.TestCase):
    """phone_launch_and_check: the credentials reach only the signed-in launch, never argv; the
    credential-free relaunch carries none; the receipt of that very launch decides."""

    def launch(self, session, receipt_fields, pair_url=''):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'bin').mkdir()
            fields = json.dumps(receipt_fields)
            # The stand-in phone: `process launch` records its argv and environment and writes the receipt
            # the app would (with the launch's own nonce); `copy from` hands it back.
            xcrun = root / 'bin/xcrun'
            xcrun.write_text(f'''#!/usr/bin/env python3
import json, os, sys
root = {str(root)!r}
args = sys.argv[1:]
if args[:3] == ["devicectl", "device", "process"]:
    open(os.path.join(root, "argv"), "w").write(json.dumps(args))
    env = {{k: v for k, v in os.environ.items() if k.startswith("DEVICECTL_CHILD_")}}
    open(os.path.join(root, "env"), "w").write(json.dumps(env))
    receipt = dict(schema=1, nonce=env.get("DEVICECTL_CHILD_CMUX_DOGFOOD_READINESS_NONCE"),
                   client_id=env.get("DEVICECTL_CHILD_CMUX_DOGFOOD_CLIENT_ID"), bundle_id="dev.cmux.mobile.{TAG}",
                   account_email="me@example.com", user_id="u1", written_at="now",
                   session_source="auto_login" if env.get("DEVICECTL_CHILD_CMUX_MOBILE_STACK_EMAIL") else "restored")
    receipt.update(json.loads({fields!r}))
    open(os.path.join(root, "receipt.json"), "w").write(json.dumps(receipt))
elif args[:3] == ["devicectl", "device", "copy"]:
    dest = args[args.index("--destination") + 1]
    open(dest, "w").write(open(os.path.join(root, "receipt.json")).read())
else:
    sys.exit(1)
''')
            xcrun.chmod(0o755)
            script = f'''
set -euo pipefail
source "{REVIEW}"
BUNDLE_ID=dev.cmux.mobile.{TAG} MAC_DEVICE_ID=mac-tagged CNX_REVIEW_RECEIPT_TIMEOUT=2
PERSONAL_EMAIL=me@example.com PERSONAL_PASSWORD=pw-secret PERSONAL_ACCOUNT=me@example.com
export DEVICECTL_CHILD_CMUX_MOBILE_STACK_PASSWORD=ambient-leak
if phone_launch_and_check {PHONE} client-1 {session} "{pair_url}"; then echo "PASS: $PHONE_VERDICT"; else echo "FAIL: $PHONE_REASON"; fi
'''
            r = bash(script, {'PATH': f"{root / 'bin'}:{os.environ['PATH']}"})
            argv = json.loads((root / 'argv').read_text()) if (root / 'argv').exists() else []
            env = json.loads((root / 'env').read_text()) if (root / 'env').exists() else {}
            return r, argv, env

    linked = {'paired_macs': [{'id': 'mac-tagged', 'name': 'cmux DEV cnx', 'linked': True}]}

    def test_signed_in_launch_carries_the_account_and_code_in_its_environment_only(self):
        r, argv, env = self.launch('auto_login', self.linked, pair_url='cmux-next://pair?t=tok123')
        self.assertIn('PASS: signed in (auto_login), paired and linked with cmux DEV cnx', r.stdout, r.stderr)
        self.assertEqual(env['DEVICECTL_CHILD_CMUX_MOBILE_STACK_PASSWORD'], 'pw-secret')
        self.assertEqual(env['DEVICECTL_CHILD_CMUX_MOBILE_PAIR_URL'], 'cmux-next://pair?t=tok123')
        self.assertNotIn('pw-secret', ' '.join(argv))
        self.assertNotIn('tok123', ' '.join(argv) + r.stdout + r.stderr)
        self.assertIn('--terminate-existing', argv)

    def test_credential_free_relaunch_carries_nothing_and_must_restore(self):
        r, argv, env = self.launch('restored', self.linked)
        self.assertIn('PASS: signed in (restored)', r.stdout, r.stderr)
        for key in ('DEVICECTL_CHILD_CMUX_MOBILE_STACK_EMAIL', 'DEVICECTL_CHILD_CMUX_MOBILE_STACK_PASSWORD',
                    'DEVICECTL_CHILD_CMUX_MOBILE_PAIR_URL'):
            self.assertNotIn(key, env)
        self.assertIn('DEVICECTL_CHILD_CMUX_DOGFOOD_READINESS_NONCE', env)

    def test_a_signed_out_install_fails(self):
        r, _, _ = self.launch('restored', {'session_source': 'auto_login', **self.linked})
        self.assertIn('FAIL: restored launch: the session is auto_login, expected restored', r.stdout)

    def test_an_unpaired_install_fails_at_the_deadline(self):
        r, _, _ = self.launch('restored', {'paired_macs': [{'id': 'other-mac', 'name': 'x', 'linked': True}]})
        self.assertIn('FAIL: restored launch: not paired with the tagged Mac yet', r.stdout)

    def test_a_receipt_from_another_launch_never_passes(self):
        r, _, _ = self.launch('restored', {'nonce': 'old', **self.linked})
        self.assertIn('FAIL: restored launch: the receipt is from another launch', r.stdout)


class ReceiptCheckTests(unittest.TestCase):
    def check(self, receipt, *extra):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'r.json'
            path.write_text(json.dumps(receipt))
            return subprocess.run(['python3', str(RECEIPT), 'check', str(path), '--nonce', 'n', '--client-id', 'c',
                                   '--bundle-id', 'dev.cmux.mobile.t', '--account', 'Me@Example.com', *extra],
                                  capture_output=True, text=True)

    base = dict(schema=1, nonce='n', client_id='c', bundle_id='dev.cmux.mobile.t', account_email='me@example.com',
                user_id='u', session_source='restored', written_at='w')

    def test_valid(self):
        r = self.check(self.base, '--session', 'restored')
        self.assertEqual((r.returncode, r.stdout.strip()), (0, 'signed in (restored)'))

    def test_wrong_account_or_bundle_or_client_stop_waiting(self):
        for key, value in (('account_email', 'x@y.z'), ('bundle_id', 'dev.cmux.mobile.other'), ('client_id', 'd')):
            with self.subTest(key=key):
                self.assertEqual(self.check({**self.base, key: value}, '--session', 'restored').returncode, 3)

    def test_secret_like_field_is_refused(self):
        self.assertEqual(self.check({**self.base, 'refresh_token': 'x'}, '--session', 'restored').returncode, 3)

    def test_paired_mac(self):
        mac = [{'id': 'm1', 'name': 'Mac', 'linked': True}]
        self.assertEqual(self.check({**self.base, 'paired_macs': mac}, '--session', 'restored', '--mac-id', 'm1').returncode, 0)
        self.assertEqual(self.check({**self.base, 'paired_macs': [{**mac[0], 'linked': False}]},
                                    '--session', 'restored', '--mac-id', 'm1').returncode, 1)
        self.assertEqual(self.check({**self.base, 'paired_macs': []}, '--session', 'restored', '--mac-id', 'm1').returncode, 1)
        self.assertEqual(self.check(self.base, '--session', 'restored', '--mac-id', 'm1').returncode, 3)

    def test_env_value_reads_without_sourcing(self):
        with tempfile.TemporaryDirectory() as temp:
            f = Path(temp) / 'a.env'
            f.write_text('# c\nexport CMUX_UITEST_STACK_EMAIL="a@b.c"\nCMUX_UITEST_STACK_PASSWORD=$(touch /tmp/x)\n')
            r = subprocess.run(['python3', str(RECEIPT), 'env-value', str(f), 'CMUX_UITEST_STACK_EMAIL'], capture_output=True, text=True)
            self.assertEqual(r.stdout, 'a@b.c\n')
            r = subprocess.run(['python3', str(RECEIPT), 'env-value', str(f), 'MISSING'], capture_output=True, text=True)
            self.assertEqual(r.returncode, 1)


def load_signer():
    spec = importlib.util.spec_from_file_location('sign_device_app', SIGNER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class SignerTests(unittest.TestCase):
    """sign_device_app.py: which profile signs, and with which entitlements (no Apple tool runs)."""

    now = datetime.datetime(2026, 11, 14, tzinfo=datetime.timezone.utc)
    cert = b'certificate-bytes'

    def profile(self, app_id='7WLXT3NR37.*', devices=(PHONE,), dev=True, expires=2027, name='p'):
        return {'Name': name, 'Entitlements': {'application-identifier': app_id, 'get-task-allow': dev,
                                                'keychain-access-groups': ['7WLXT3NR37.*', 'com.apple.token']},
                'ExpirationDate': datetime.datetime(expires, 1, 1), 'ProvisionedDevices': list(devices),
                'DeveloperCertificates': [self.cert]}

    def setUp(self):
        self.s = load_signer()
        import hashlib
        self.ids = {hashlib.sha1(self.cert).hexdigest().upper()}

    def test_profile_fits(self):
        fits = lambda p: self.s.profile_fits(p, '7WLXT3NR37', 'dev.cmux.mobile.t', [PHONE], self.ids, self.now)
        self.assertIsNone(fits(self.profile()))
        self.assertIsNone(fits(self.profile(app_id='7WLXT3NR37.dev.cmux.mobile.t')))
        self.assertIn('names 7WLXT3NR37.dev.cmux.ios.x', fits(self.profile(app_id='7WLXT3NR37.dev.cmux.ios.x')))
        self.assertIn('does not name', fits(self.profile(devices=['OTHER'])))
        self.assertEqual(fits(self.profile(expires=2025)), 'expired')
        self.assertEqual(fits(self.profile(dev=False)), 'is not a development profile')
        self.assertEqual(self.s.profile_fits(self.profile(), '7WLXT3NR37', 'dev.cmux.mobile.t', [PHONE], set(), self.now),
                         'has no certificate in this keychain')

    def test_exact_profile_wins_and_no_fit_names_every_reason(self):
        _, chosen = self.s.choose_profile([('a', self.profile(name='wild')),
                                           ('b', self.profile(app_id='7WLXT3NR37.dev.cmux.mobile.t', name='exact'))],
                                          '7WLXT3NR37', 'dev.cmux.mobile.t', [PHONE], self.ids, self.now)
        self.assertEqual(chosen['Name'], 'exact')
        with self.assertRaises(self.s.SignError) as e:
            self.s.choose_profile([('a', self.profile(devices=['X'], name='wild'))], '7WLXT3NR37', 'dev.cmux.mobile.t',
                                  [PHONE], self.ids, self.now)
        self.assertIn('wild: does not name ' + PHONE, str(e.exception))

    def test_entitlements_from_the_target_file(self):
        source = (ROOT / 'cmux-next-ios/App/CmuxMobileApp-Keychain.entitlements').read_text()
        ents = self.s.entitlements(source, '7WLXT3NR37', 'dev.cmux.mobile.t', 'dev.cmux.mobile.t')
        self.assertEqual(ents['keychain-access-groups'], ['7WLXT3NR37.dev.cmux.mobile.t', '7WLXT3NR37.dev.cmux.mobile.t.push'])
        self.assertEqual(ents['application-identifier'], '7WLXT3NR37.dev.cmux.mobile.t')
        self.assertIs(ents['get-task-allow'], True)
        self.assertIsNone(self.s.allowed(ents, self.profile()))
        group = (ROOT / 'cmux-next-ios/App/CmuxMobileApp-Group.entitlements').read_text()
        self.assertNotIn('com.apple.security.application-groups',
                         self.s.entitlements(group, '7WLXT3NR37', 'dev.cmux.mobile.t', 'dev.cmux.mobile.t'))
        ext = (ROOT / 'cmux-next-ios/NotificationService/NotificationService.entitlements').read_text()
        ents = self.s.entitlements(ext, '7WLXT3NR37', 'dev.cmux.mobile.t.notification-service', 'dev.cmux.mobile.t')
        self.assertEqual(ents['keychain-access-groups'], ['7WLXT3NR37.dev.cmux.mobile.t.push'])

    def test_a_group_the_profile_does_not_grant_is_refused(self):
        p = self.profile()
        p['Entitlements']['keychain-access-groups'] = ['7WLXT3NR37.dev.cmux.mobile.t']
        ents = {'keychain-access-groups': ['7WLXT3NR37.dev.cmux.mobile.t.push']}
        self.assertIn('is not in the profile', self.s.allowed(ents, p))

    def test_every_extension_of_the_app_has_its_entitlements(self):
        import re
        text = (ROOT / 'cmux-next-ios/project.yml').read_text()
        extensions = re.findall(r'^  (\w+):\n    type: app-extension', text, re.M)
        self.assertTrue(extensions)
        for name in extensions:
            self.assertIn(name + '.appex', self.s.ENTITLEMENTS)
            self.assertTrue((ROOT / self.s.ENTITLEMENTS[name + '.appex']).exists())


class FleetStepTests(unittest.TestCase):
    def test_sim_step_arguments(self):
        with tempfile.TemporaryDirectory() as temp:
            ci = Path(temp) / 'cmux-ci'
            ci.write_text('#!/bin/sh\n[ "$1" = run ] && echo "$@" > "%s/args"\necho "cmux-ci: step 0123456789abcdef01234567 (simulator, key k)" >&2\n' % temp)
            ci.chmod(0o755)
            r = bash(f'''source "{REVIEW}"; SLUG={TAG} SHA={SHA} STATE="{temp}" TARGET_WORKER=aws-m4pro-3 CMUX_CI="{ci}"
fleet_start_sim; fleet_finish_sim; echo "STEP=$SIM_STEP"''', {'CMUX_CI': str(ci)})
            args = (Path(temp) / 'args').read_text().split()
            self.assertIn('STEP=0123456789abcdef01234567', r.stdout)
        self.assertEqual(args[:9], ['run', '--class', 'simulator', '--script', 'scripts/ci/cmux-next-ios-sim.sh', '--ref', SHA,
                                    '--arg', 'handoff'])
        self.assertIn(f'tag={TAG}', args)
        self.assertIn(f'cnx-ios-handoff-{TAG}-{SHA[:12]}', args)
        self.assertEqual(args[-2:], ['--target-worker', 'aws-m4pro-3'])

    def test_handoff_mode_takes_one_tag(self):
        for args, want in ((['handoff'], 'handoff takes one argument, tag=TAG'),
                           (['handoff', 'tag=Bad_Tag'], 'handoff tag= wants lowercase'),
                           (['handoff', 'tag=default'], 'handoff tag= wants lowercase')):
            with self.subTest(args=args):
                r = subprocess.run(['bash', str(SIM), *args], capture_output=True, text=True,
                                   env=dict(os.environ, CMUX_CI_STEP_KEY='test'), timeout=30)
                self.assertEqual(r.returncode, 2)
                self.assertIn(want, r.stderr)

    def test_handoff_mode_builds_the_tagged_device_app_unsigned(self):
        text = SIM.read_text()
        self.assertIn('"CMUX_MOBILE_TAG=.$handoff_tag" "CMUX_MOBILE_DISPLAY_NAME=cmux $handoff_tag"', text)
        self.assertIn("-destination 'generic/platform=iOS'", text)
        self.assertIn('CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM=7WLXT3NR37', text)

    def test_review_never_builds_or_boots_a_simulator_here(self):
        text = REVIEW.read_text()
        for word in ('xcodebuild', 'simctl', 'swift build', 'cargo '):
            self.assertNotIn(word, text)
        self.assertIn('CMUX_SANCTIONED_IPHONE_INSTALL=1 xcrun devicectl device install app', text)
        self.assertIn('open -g', text)


if __name__ == '__main__':
    unittest.main()
