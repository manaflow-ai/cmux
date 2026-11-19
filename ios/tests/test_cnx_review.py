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
import re
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


# macOS's own bash (3.2) where it exists: review.sh runs under it, and 3.2 aborts on an empty
# array expanded under set -u, which a newer bash allows.
BASH = '/bin/bash' if os.path.exists('/bin/bash') else 'bash'


def bash(script, env=None, timeout=60):
    return subprocess.run([BASH, '-c', script], capture_output=True, text=True, timeout=timeout,
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
SLUG={TAG} SHA={SHA} BUNDLE_ID=dev.cmux.mobile.{TAG} STATE="{root}/state/{SHA}" TAG_STATE="{root}/state"
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

    def test_no_connected_phone_still_builds_publishes_and_checks_the_simulator(self):
        r = self.run_review([], '''fleet_start_sim() { echo SIM_STARTED; }
fleet_finish_mac() { echo MAC_PUBLISHED; REPORT_MAC="fleet job $MAC_JOB, published to HQ"; }
mac_install() { echo MAC_INSTALLED; }''')
        self.assertEqual(r.returncode, 1)
        self.assertIn('SIM_STARTED', r.stdout)
        self.assertIn('MAC_PUBLISHED', r.stdout)
        self.assertNotIn('MAC_INSTALLED', r.stdout)  # no phone to pair: the Mac app is not started
        self.assertIn('found no connected iPhone', r.stderr)
        self.assertIn('Dev build:  http://127.0.0.1:17320/cnx-test-v1   (fleet job job123, published to HQ', r.stdout)
        self.assertIn('Simulator:  fleet simulator (aws-m4pro-3', r.stdout)
        self.assertIn(f'iPhone:     BLOCKED: no connected iPhone; connect and unlock one, then rerun: '
                      f'cmux-next-ios/scripts/review.sh --tag {TAG}', r.stdout)

    def test_the_sole_phone_failing_still_prints_the_report(self):
        # PASSED_PHONES empty: on macOS's bash 3.2 an unguarded "${arr[*]}" under set -u aborted here.
        r = self.run_review([(PHONE, 'iPhone')], '''
phone_review() { PHONE_REASON="install failed (locked)"; return 1; }
mac_restart() { echo MAC_RESTARTED; }''')
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertNotIn('unbound variable', r.stderr)
        self.assertNotIn('MAC_RESTARTED', r.stdout)
        self.assertIn('==> Review ready (tag: cnx-test-v1)', r.stdout)
        self.assertIn(f'iPhone:     iPhone (iPhone 16 Plus, {PHONE}): BLOCKED: install failed (locked); retry:', r.stdout)

    def test_a_requested_phone_that_is_missing_is_a_blocker_and_a_missing_default_a_notice(self):
        other = '00008150-0005154E0E84401C'
        r = self.run_review([(PHONE, 'iPhone')], f'REQUESTED_DEVICE_ID={other}')
        self.assertEqual(r.returncode, 1)
        self.assertIn(f'{other}: BLOCKED, requested with --device-id but not connected', r.stdout)
        r = self.run_review([(PHONE, 'iPhone')], f'echo {other} > "$(dirname "$REVIEW_PHONES_FILE")/iphone-device-id"')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn(f'{other} (default): not connected, nothing installed', r.stdout)

    def test_a_new_phone_gets_no_classic_tailnet_note(self):
        r = self.run_review([(PHONE, 'iPhone')], '')
        self.assertIn('new iPhone registered: iPhone', r.stdout)
        self.assertNotIn('tailnet', r.stdout)

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

    def launch(self, session, receipt_fields, pair_url='', backend=''):
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
                   account_email="me@example.com", user_id="u1", written_at="now", git_sha="{SHA}", dev_tag="{TAG}",
                   phone_device_ids=["link-1", "presence-1"],
                   cloud_backend=env.get("DEVICECTL_CHILD_CMUX_NEXT_CLOUD_BACKEND", "").strip() not in ("", "default")
                   and env["DEVICECTL_CHILD_CMUX_NEXT_CLOUD_BACKEND"] or "https://cmux-api-development.debussy.workers.dev",
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
BUNDLE_ID=dev.cmux.mobile.{TAG} MAC_DEVICE_ID=mac-tagged CNX_REVIEW_RECEIPT_TIMEOUT=2 SHA={SHA} SLUG={TAG} STATE="{root}/state"
BACKEND_URL="{backend}"
export DEVICECTL_CHILD_CMUX_NEXT_CLOUD_BACKEND=https://ambient.example
PERSONAL_EMAIL=me@example.com PERSONAL_PASSWORD=pw-secret PERSONAL_ACCOUNT=me@example.com
export DEVICECTL_CHILD_CMUX_MOBILE_STACK_PASSWORD=ambient-leak
if phone_launch_and_check {PHONE} client-1 {session} "{pair_url}"; then echo "PASS: $PHONE_VERDICT"; else echo "FAIL: $PHONE_REASON"; fi
'''
            r = bash(script, {'PATH': f"{root / 'bin'}:{os.environ['PATH']}"})
            argv = json.loads((root / 'argv').read_text()) if (root / 'argv').exists() else []
            env = json.loads((root / 'env').read_text()) if (root / 'env').exists() else {}
            return r, argv, env

    DEFAULT = 'https://cmux-api-development.debussy.workers.dev'
    # Every receipt of this build names its Cloud backend (DogfoodReadiness.cloud_backend).
    linked = {'cloud_backend': DEFAULT, 'paired_macs': [{'id': 'mac-tagged', 'name': 'cmux DEV cnx', 'linked': True}]}

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

    STACK = 'https://cmux-dev-backend-1.tail137216.ts.net:3850'

    def test_the_first_launch_names_the_tags_backend_and_the_relaunch_must_keep_it(self):
        r, _, env = self.launch('auto_login', {**self.linked, 'cloud_backend': self.STACK}, backend=self.STACK)
        self.assertIn('PASS: signed in (auto_login)', r.stdout, r.stderr)
        self.assertEqual(env['DEVICECTL_CHILD_CMUX_NEXT_CLOUD_BACKEND'], self.STACK)
        r, _, env = self.launch('restored', {**self.linked, 'cloud_backend': self.STACK}, backend=self.STACK)
        self.assertIn('PASS: signed in (restored)', r.stdout, r.stderr)
        self.assertNotIn('DEVICECTL_CHILD_CMUX_NEXT_CLOUD_BACKEND', env, 'the relaunch carries nothing; the app kept it')

    def test_an_app_on_another_backend_fails(self):
        r, _, _ = self.launch('restored', {**self.linked, 'cloud_backend': 'https://cloud-api-staging.cmux.dev'},
                              backend=self.STACK)
        self.assertIn(f'FAIL: restored launch: the app uses the Cloud backend https://cloud-api-staging.cmux.dev, not {self.STACK}',
                      r.stdout)
        r, _, _ = self.launch('restored', {**self.linked, 'cloud_backend': ''}, backend=self.STACK)
        self.assertIn('FAIL: restored launch: the receipt names no cloud_backend', r.stdout)

    def test_the_default_clears_a_kept_backend_and_proves_it(self):
        # `default` (not an empty value a launcher may drop) clears the kept override...
        r, _, env = self.launch('auto_login', self.linked)
        self.assertIn('PASS: signed in (auto_login)', r.stdout, r.stderr)
        self.assertEqual(env['DEVICECTL_CHILD_CMUX_NEXT_CLOUD_BACKEND'], 'default', 'the first launch clears the kept override')
        _, _, env = self.launch('restored', self.linked)
        self.assertNotIn('DEVICECTL_CHILD_CMUX_NEXT_CLOUD_BACKEND', env, 'no ambient value leaks into a launch')

    def test_the_default_fails_when_the_phone_kept_an_earlier_override(self):
        # ...and the receipt must show it took: a phone still on a kept stack or preview fails.
        for kept in (self.STACK, 'https://cmux-api-preview-7.debussy.workers.dev'):
            r, _, _ = self.launch('restored', {**self.linked, 'cloud_backend': kept})
            self.assertIn(f'FAIL: restored launch: the app still uses the kept Cloud backend {kept}', r.stdout)
        r, _, _ = self.launch('restored', {**self.linked, 'cloud_backend': ''})
        self.assertIn('FAIL: restored launch: the receipt names no cloud_backend', r.stdout)

    def test_a_receipt_from_another_launch_never_passes(self):
        r, _, _ = self.launch('restored', {'nonce': 'old', **self.linked})
        self.assertIn('FAIL: restored launch: the receipt is from another launch', r.stdout)


def load_review_mac():
    spec = importlib.util.spec_from_file_location('review_mac', ROOT / 'cmux-next-ios/scripts/review_mac.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class BackendTests(unittest.TestCase):
    """--backend: the allowlist, the Mac's backend.json, the report and retry, and the Mac's own answer."""
    STACK = 'https://cmux-dev-backend-1.tail137216.ts.net:3850'

    def test_only_the_shared_dev_deployment_and_tailnet_origins_are_allowed(self):
        m = load_review_mac()
        for value, want in [('dev', m.DEVELOPMENT_API), ('development', m.DEVELOPMENT_API),
                            (m.DEVELOPMENT_API + '/', m.DEVELOPMENT_API),
                            ('preview-7', 'https://cmux-api-preview-7.debussy.workers.dev'),
                            (self.STACK + '/', self.STACK),
                            ('https://cmux-dev-backend-1.tail137216.ts.net', 'https://cmux-dev-backend-1.tail137216.ts.net')]:
            self.assertEqual(m.backend_origin(value), want, value)
        for value in ['https://attacker.example', 'https://cloud-api.cmux.dev', 'prod', 'staging',
                      'http://cmux-dev-backend-1.tail137216.ts.net:3850', 'https://ts.net', 'https://tail137216.ts.net',
                      'https://cmux-dev-backend-1.tail137216.ts.net.attacker.example', self.STACK + '/v1',
                      self.STACK + '?x=1', 'https://user@cmux-dev-backend-1.tail137216.ts.net', 'https://a_b.tail.ts.net',
                      'https://100.70.231.80', 'preview-0', 'http://localhost:8787', '']:
            with self.assertRaises(ValueError, msg=value):
                m.backend_origin(value)

    def test_backend_json_is_written_privately_replaced_and_removed(self):
        m = load_review_mac()
        with tempfile.TemporaryDirectory() as temp:
            folder = os.path.join(temp, 'cmux-next', 'com.cmuxterm.app.debug.cnx-test-v1')
            self.assertEqual(m.write_backend(folder, self.STACK), 'changed')
            path = os.path.join(folder, 'backend.json')
            self.assertEqual(json.load(open(path))['backend'], self.STACK)
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
            self.assertEqual(m.write_backend(folder, self.STACK), 'same')
            self.assertEqual(m.write_backend(folder, m.DEVELOPMENT_API), 'changed')
            self.assertEqual(m.write_backend(folder, ''), 'changed')
            self.assertFalse(os.path.exists(path))
            self.assertEqual(m.write_backend(folder, ''), 'same')
            self.assertEqual(sorted(os.listdir(folder)), [], 'no temporary file is left')

    def resolve(self, arg, stack_body=None):
        with tempfile.TemporaryDirectory() as temp:
            stack = Path(temp) / 'cloud-dev-stack.sh'
            stack.write_text(stack_body or '#!/bin/sh\necho "starting"\necho "%s"\n' % self.STACK)
            stack.chmod(0o755)
            script = '\n'.join([
                'set -euo pipefail',
                f'source "{REVIEW}"',
                f'SLUG={TAG} BACKEND_ARG="{arg}"',
                'review_resolve_backend',
                'echo "URL=$BACKEND_URL"; echo "REPORT=$BACKEND_REPORT"; retry_command',
            ])
            return bash(script, {'CNX_CLOUD_DEV_STACK': str(stack)})

    def test_resolve_backend(self):
        r = self.resolve('')
        self.assertIn('URL=\n', r.stdout, r.stderr)
        self.assertIn('REPORT=shared dev Workers (default, no override)', r.stdout)
        self.assertNotIn('--backend', r.stdout)
        r = self.resolve(self.STACK + '/')
        self.assertIn(f'URL={self.STACK}\n', r.stdout, r.stderr)
        self.assertIn(f'--backend {self.STACK}/', r.stdout)
        r = self.resolve('tag-stack')
        self.assertIn(f"REPORT={self.STACK} (this tag's stack)", r.stdout, r.stderr)
        self.assertIn('--backend tag-stack', r.stdout)

    def test_a_refused_backend_stops_before_any_build(self):
        r = self.resolve('https://attacker.example')
        self.assertEqual(r.returncode, 2)
        self.assertIn('--backend refused', r.stderr)
        r = self.resolve('tag-stack', '#!/bin/sh\necho https://attacker.example\n')
        self.assertEqual(r.returncode, 2)
        self.assertIn('is not a tailnet origin', r.stderr)
        r = self.resolve('tag-stack', '#!/bin/sh\necho "no stack for this tag" >&2; exit 3\n')
        self.assertEqual(r.returncode, 2)
        self.assertIn('no stack for this tag', r.stderr)

    def check_mac(self, backend_url, answer):
        with tempfile.TemporaryDirectory() as temp:
            reply = Path(temp) / 'auth-status.json'
            reply.write_text(json.dumps(answer))
            script = '\n'.join([
                'set -euo pipefail',
                f'source "{REVIEW}"',
                f'BACKEND_URL="{backend_url}" MAC_SOCKET=/nonexistent',
                f'mac_py() {{ [ "$1" = backend ] && cat "{reply}"; }}',
                'if mac_check_backend; then echo "OK: $REPORT_BACKEND_MAC"; else echo "NO: $REPORT_BACKEND_MAC"; fi',
            ])
            return bash(script).stdout

    def test_the_mac_app_must_report_the_asked_for_backend(self):
        label = f"{self.STACK} (this tag's backend.json)"
        self.assertIn(f'OK: {label}', self.check_mac(self.STACK, {'backend': self.STACK, 'backend_label': label}))
        self.assertIn(f'NO: BLOCKED: it uses https://cmux-api-development.debussy.workers.dev, not {self.STACK}',
                      self.check_mac(self.STACK, {'backend': 'https://cmux-api-development.debussy.workers.dev'}))
        dev = 'https://cmux-api-development.debussy.workers.dev'
        self.assertIn(f'OK: {dev} (dev)', self.check_mac('', {'backend': dev, 'backend_label': f'{dev} (dev)'}))

    def test_the_mac_gets_backend_json_before_it_starts_and_a_running_app_restarts_on_a_change(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            script = '\n'.join([
                'set -euo pipefail',
                f'source "{REVIEW}"',
                f'HOME="{root}" BACKEND_URL="{self.STACK}" MAC_APP="{root}/cmux DEV t.app" REPORT_MAC=""',
                'mac_py() { case "$1" in bundle) echo com.cmuxterm.app.debug.cnx-test-v1 ;;'
                ' *) /usr/bin/python3 -I "$SCRIPT_DIR/review_mac.py" "$@" ;; esac; }',
                'pgrep() { return 0; }',
                'mac_quit_installed() { echo QUIT; }',
                'mac_apply_backend; mac_apply_backend',
            ])
            r = bash(script)
            self.assertEqual(r.stdout.count('QUIT'), 1, r.stdout + r.stderr)
            folder = root / 'Library/Application Support/cmux-next/com.cmuxterm.app.debug.cnx-test-v1'
            self.assertEqual(json.loads((folder / 'backend.json').read_text())['backend'], self.STACK)

    def test_the_report_has_a_backend_line(self):
        script = '\n'.join([
            f'source "{REVIEW}"',
            f'SLUG={TAG} REPORT_MAC=x BACKEND_REPORT="{self.STACK} (this tag\'s stack)"',
            f'REPORT_BACKEND_MAC="{self.STACK} (this tag\'s backend.json)"',
            'review_report',
        ])
        r = bash(script)
        self.assertIn(f"Backend:    {self.STACK} (this tag's stack); Mac app: {self.STACK} (this tag's backend.json)",
                      r.stdout, r.stderr)


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

    def test_another_builds_receipt_is_refused(self):
        receipt = {**self.base, 'git_sha': 'a' * 40, 'dev_tag': 'my-tag'}
        self.assertEqual(self.check(receipt, '--session', 'restored', '--git-sha', 'a' * 40, '--dev-tag', 'my-tag').returncode, 0)
        r = self.check(receipt, '--session', 'restored', '--git-sha', 'b' * 40)
        self.assertEqual(r.returncode, 3)
        self.assertIn('another build', r.stdout)
        self.assertEqual(self.check(receipt, '--session', 'restored', '--dev-tag', 'other').returncode, 3)

    def test_signed_out_session(self):
        out = {**self.base, 'session_source': 'signed_out', 'signed_in': False, 'account_email': '', 'user_id': ''}
        r = self.check(out, '--session', 'signed_out')
        self.assertEqual((r.returncode, r.stdout.strip()), (0, 'signed out (at the welcome screen)'))
        # Signed in when --no-auth expects signed out: refused at once.
        self.assertEqual(self.check(self.base, '--session', 'signed_out').returncode, 3)
        # A signed-out receipt while sign-in is expected: not yet (the launch may still sign in).
        self.assertEqual(self.check(out, '--session', 'restored').returncode, 1)
        # A signed-out receipt that still names an account is refused.
        self.assertEqual(self.check({**out, 'account_email': 'me@example.com'}, '--session', 'signed_out').returncode, 3)

    def test_phone_ids(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'r.json'
            path.write_text(json.dumps({'phone_device_ids': ['a', 'b']}))
            r = subprocess.run(['python3', str(RECEIPT), 'phone-ids', str(path)], capture_output=True, text=True)
            self.assertEqual(r.stdout.split(), ['a', 'b'])
            path.write_text(json.dumps({}))
            r = subprocess.run(['python3', str(RECEIPT), 'phone-ids', str(path)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 1)

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

    def test_each_bundle_gets_its_own_profile(self):
        with tempfile.TemporaryDirectory() as temp:
            app = Path(temp) / 'CmuxMobileApp.app'
            for path, bundle_id in ((app, 'dev.cmux.mobile.t'),
                                    (app / 'PlugIns/CmuxMobileNotificationService.appex', 'dev.cmux.mobile.t.notification-service'),
                                    (app / 'PlugIns/CmuxMobileNotificationContent.appex', 'dev.cmux.mobile.t.notification-content')):
                path.mkdir(parents=True)
                with open(path / 'Info.plist', 'wb') as f:
                    plistlib.dump({'CFBundleIdentifier': bundle_id}, f)
            profiles = [('exact.mobileprovision', self.profile(app_id='7WLXT3NR37.dev.cmux.mobile.t', name='exact')),
                        ('wild.mobileprovision', self.profile(name='wild'))]
            plan = self.s.plan_bundles(str(app), 'dev.cmux.mobile.t', str(ROOT), '7WLXT3NR37', [PHONE], profiles, self.ids, self.now)
            chosen = {Path(step['path']).name: step['profile']['Name'] for step in plan}
            self.assertEqual(chosen, {'CmuxMobileNotificationContent.appex': 'wild',
                                      'CmuxMobileNotificationService.appex': 'wild', 'CmuxMobileApp.app': 'exact'})
            self.assertEqual(Path(plan[-1]['path']).name, 'CmuxMobileApp.app')  # extensions are signed first
            with self.assertRaises(self.s.SignError) as e:
                self.s.plan_bundles(str(app), 'dev.cmux.mobile.t', str(ROOT), '7WLXT3NR37', [PHONE],
                                    profiles[:1], self.ids, self.now)
            self.assertIn('CmuxMobileNotificationContent.appex', str(e.exception))

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
                                    '--arg', 'shots'])
        self.assertIn(f'handoff={TAG}', args)
        self.assertIn(f'cnx-ios-handoff-{TAG}-{SHA[:12]}', args)
        self.assertEqual(args[-2:], ['--target-worker', 'aws-m4pro-3'])
        # The session is sealed from this Mac (hq build-fleet sign_in) and delivered while cmux-ci run
        # follows the step: no worker label, and never detached.
        self.assertIn('--sign-in agent', ' '.join(args))
        self.assertNotIn('--label', args)
        self.assertNotIn('--detach', args)

    def test_an_unreviewed_step_script_is_named_as_the_blocker(self):
        with tempfile.TemporaryDirectory() as temp:
            ci = Path(temp) / 'cmux-ci'
            ci.write_text('#!/bin/sh\necho "cmux-ci: step 0123456789abcdef01234567 (simulator, key k)" >&2\n'
                          'echo "cmux-ci: step 0123456789abcdef01234567 failed on m: ci-step refused: scripts/ci/cmux-next-ios-sim.sh '
                          'at x (blob y) is not the reviewed version on main or feat-cmux-next" >&2\nexit 1\n')
            ci.chmod(0o755)
            r = bash(f'''source "{REVIEW}"; SLUG={TAG} SHA={SHA} STATE="{temp}" CMUX_CI="{ci}"
fleet_start_sim; fleet_finish_sim || echo "SIM=$REPORT_SIM"''', {'CMUX_CI': str(ci)})
        self.assertIn('SIM=BLOCKED: the fleet refused scripts/ci/cmux-next-ios-sim.sh', r.stdout)
        self.assertIn('not on feat-cmux-next yet', r.stdout)

    def test_handoff_mode_takes_one_tag(self):
        for args, want in ((['handoff'], 'handoff takes one argument, tag=TAG'),
                           (['handoff', 'tag=Bad_Tag'], 'handoff tag= wants lowercase'),
                           (['handoff', 'tag=default'], 'handoff tag= wants lowercase'),
                           # The fleet controller's form of the same step.
                           (['shots', 'handoff=Bad_Tag'], 'handoff tag= wants lowercase')):
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

    def test_handoff_check_uses_the_submitters_session(self):
        text = SIM.read_text()
        start = text.index('  handoff_check() {')
        body = text[start:text.index('\n  }\n', start)]
        self.assertIn('source scripts/lib/fleet-signin-session.sh', text)
        self.assertIn('cmux_fleet_signin_load || { handoff_sim_reason="$CMUX_FLEET_SIGNIN_ERROR"; return 1; }', body)
        self.assertIn('account="$CMUX_FLEET_SIGNIN_EMAIL"', body)
        self.assertIn('cmux_fleet_signin_simctl --set "$sims" launch "$udid" "$bundle_id"', body)
        self.assertIn('cmux_fleet_signin_forget', body)
        for gone in ('ios-agent-stack.env', 'ios-agent-signin', 'stat -f', 'CMUX_MOBILE_STACK_PASSWORD',
                     'CMUX_MOBILE_STACK_EMAIL', 'env-value'):
            self.assertNotIn(gone, body)

    def test_the_session_reaches_only_the_auto_login_launch(self):
        with tempfile.TemporaryDirectory() as temp:
            f = Path(temp) / 'session.json'
            f.write_text(json.dumps({'profile': 'agent', 'email': 'agent@example.com', 'project': 'p',
                                     'refresh_token': 'rt-secret'}))
            f.chmod(0o600)
            bin_dir = Path(temp) / 'bin'
            bin_dir.mkdir()
            (bin_dir / 'xcrun').write_text('#!/bin/sh\necho "TOKEN=$SIMCTL_CHILD_CMUX_MOBILE_STACK_REFRESH_TOKEN ARGS=$*"\n')
            (bin_dir / 'xcrun').chmod(0o755)
            r = bash(f'''PATH="{bin_dir}:$PATH"; source "{ROOT}/scripts/lib/fleet-signin-session.sh"
cmux_fleet_signin_load || {{ echo "ERR $CMUX_FLEET_SIGNIN_ERROR"; exit 1; }}
echo "EMAIL=$CMUX_FLEET_SIGNIN_EMAIL"; cmux_fleet_signin_simctl --set S launch U B
env | grep -c rt-secret || true; cmux_fleet_signin_forget; cmux_fleet_signin_simctl launch U B || echo FORGOTTEN''',
                     {'CMUX_CI_SIGNIN_FILE': str(f)})
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn('EMAIL=agent@example.com', r.stdout)
            self.assertIn('TOKEN=rt-secret ARGS=simctl --set S launch U B', r.stdout)
            self.assertIn('\n0\n', r.stdout)
            self.assertIn('FORGOTTEN', r.stdout)
            r = bash(f'source "{ROOT}/scripts/lib/fleet-signin-session.sh"; cmux_fleet_signin_load || echo "ERR $CMUX_FLEET_SIGNIN_ERROR"', {})
            self.assertIn('ERR no CMUX_CI_SIGNIN_FILE: send the step with cmux-ci run --sign-in agent', r.stdout)

    def test_the_tagged_mac_starts_without_this_shells_environment(self):
        with tempfile.TemporaryDirectory() as temp:
            bin_dir = Path(temp) / 'bin'
            bin_dir.mkdir()
            (bin_dir / 'open').write_text('#!/bin/sh\nenv > "%s/env"; echo "$@" > "%s/args"\n' % (temp, temp))
            (bin_dir / 'open').chmod(0o755)
            r = bash(f'''source "{REVIEW}"; MAC_APP="/x/cmux DEV t.app"; MAC_OPEN="{bin_dir}/open"
mac_open''', {'CMUX_NEXT_CLOUD_ENV': 'prod', 'CMUX_NEXT_CLOUD_BACKEND': 'https://cloud-api.cmux.dev'})
            self.assertEqual(r.returncode, 0, r.stderr)
            seen = (Path(temp) / 'env').read_text()
            args = (Path(temp) / 'args').read_text()
        self.assertNotIn('CMUX_NEXT_CLOUD', seen)
        self.assertIn('-g --env CMUX_NEXT_NO_ACTIVATE=1 /x/cmux DEV t.app', args)

    def test_review_never_builds_or_boots_a_simulator_here(self):
        text = REVIEW.read_text()
        self.assertIn('--sign-in agent', text)
        self.assertNotIn('ios-agent-signin', text)
        for word in ('xcodebuild', 'simctl', 'swift build', 'cargo '):
            self.assertNotIn(word, text)
        self.assertIn('CMUX_SANCTIONED_IPHONE_INSTALL=1 xcrun devicectl device install app', text)
        self.assertIn('open -g', text)


MAC_PY = ROOT / 'cmux-next-ios/scripts/review_mac.py'


class PairingCodeTests(unittest.TestCase):
    """A pairing code is recorded as used only after a phone paired with it."""

    def run_phone_review(self, launch_ok):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'device/CmuxMobileApp.app').mkdir(parents=True)
            (root / 'bin').mkdir()
            xcrun = root / 'bin/xcrun'
            xcrun.write_text('#!/bin/sh\nexit 0\n')
            xcrun.chmod(0o755)
            script = f"""
set -euo pipefail
source "{REVIEW}"
BUNDLE_ID=dev.cmux.mobile.{TAG} STATE="{root}" TAG_STATE="{root}" MAC_SOCKET=/nonexistent SLUG={TAG} SHA={SHA}
REPO_ROOT="{root}"; mkdir -p "$REPO_ROOT/scripts"; printf '#!/bin/sh\\nexit 0\\n' > "$REPO_ROOT/scripts/ios-device-process.sh"; chmod +x "$REPO_ROOT/scripts/ios-device-process.sh"
mac_py() {{
  case "$1" in
    pair-url) echo "cmux-next://pair?mac=m1&t=tok-secret"; ;;
    mark-used) echo "MARK_USED $(cat)" >> "{root}/calls" ;;
    *) command /usr/bin/python3 -I "{MAC_PY}" "$@" ;;
  esac
}}
sign_app() {{ echo '{{}}'; }}
phone_launch_and_check() {{ echo "LAUNCH $3" >> "{root}/calls"; [[ {1 if launch_ok else 0} -eq 1 ]] || {{ PHONE_REASON=x; return 1; }}; PHONE_VERDICT=ok; }}
mac_sees_phone() {{ return 0; }}
if phone_review {PHONE} iPhone; then echo PASS; else echo "FAIL $PHONE_REASON"; fi
"""
            r = bash(script, {'PATH': f"{root / 'bin'}:{os.environ['PATH']}"})
            calls = (root / 'calls').read_text() if (root / 'calls').exists() else ''
            return r, calls

    def test_a_failed_launch_leaves_the_code_unused(self):
        r, calls = self.run_phone_review(False)
        self.assertIn('FAIL', r.stdout, r.stderr)
        self.assertIn('LAUNCH auto_login', calls)
        self.assertNotIn('MARK_USED', calls)

    def test_a_paired_phone_marks_its_code_used(self):
        r, calls = self.run_phone_review(True)
        self.assertIn('PASS', r.stdout, r.stderr)
        self.assertIn('MARK_USED cmux-next://pair?mac=m1&t=tok-secret', calls)
        self.assertNotIn('tok-secret', r.stdout + r.stderr)

    def test_pair_url_only_reads_the_used_file_and_mark_used_writes_it(self):
        with tempfile.TemporaryDirectory() as temp:
            used = Path(temp) / 'used'
            r = subprocess.run(['python3', str(MAC_PY), 'mark-used', str(used)], input='cmux-next://pair?t=a',
                               capture_output=True, text=True)
            self.assertEqual(r.returncode, 0)
            import hashlib
            self.assertEqual(used.read_text().strip(), hashlib.sha256(b'cmux-next://pair?t=a').hexdigest())
        text = MAC_PY.read_text()
        pair_block = text[text.index('if a.op == "pair-url":'):text.index('if a.op == "mark-used":')]
        self.assertNotIn('open(a.used, "a"', pair_block)


class FakeMacSocket:
    """A tagged Mac's control socket answering cmux.mobilePairing.status with VALUE."""

    def __init__(self, path, value):
        import socket, threading
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(path)
        self.server.listen(8)
        self.value = value
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            with conn:
                conn.recv(1 << 16)
                conn.sendall((json.dumps({'ok': True, 'result': {'value': self.value}}) + '\n').encode())

    def close(self):
        self.server.close()


class MacIdTests(unittest.TestCase):
    def test_mac_id_comes_from_the_pairing_link(self):
        with tempfile.TemporaryDirectory(dir='/tmp') as temp:
            sock = os.path.join(temp, 's')
            fake = FakeMacSocket(sock, {'state': 'ready', 'qr': {'url': 'cmux-next://pair?mac=mac-abc&team=t&t=secret-token'}})
            try:
                r = subprocess.run(['python3', str(MAC_PY), 'mac-id', sock, '--timeout', '3'], capture_output=True, text=True)
            finally:
                fake.close()
        self.assertEqual(r.stdout.strip(), 'mac-abc')
        self.assertNotIn('secret-token', r.stdout + r.stderr)

    def test_no_code_says_why(self):
        with tempfile.TemporaryDirectory(dir='/tmp') as temp:
            sock = os.path.join(temp, 's')
            fake = FakeMacSocket(sock, {'state': 'off', 'allowed': False})
            try:
                r = subprocess.run(['python3', str(MAC_PY), 'pair-url', sock, '--timeout', '2'], capture_output=True, text=True)
            finally:
                fake.close()
        self.assertEqual(r.returncode, 3)
        self.assertIn('iPhone connections are off', r.stderr)


class MacSeesPhoneTests(unittest.TestCase):
    def sees(self, rows):
        with tempfile.TemporaryDirectory() as temp:
            phone = Path(temp) / f'phone-{PHONE}'
            phone.mkdir()
            (phone / 'receipt.json').write_text(json.dumps({'phone_device_ids': ['LINK-1', 'presence-1']}))
            script = f"""source "{REVIEW}"; set +e; STATE="{temp}"; MAC_SOCKET=x
mac_py() {{ echo '{json.dumps({"phones": rows})}'; }}
seq() {{ echo 1; }}; sleep() {{ :; }}
mac_sees_phone {PHONE} && echo SEES || echo NOT"""
            return bash(script).stdout.strip()

    def test_matches_this_phones_id_only(self):
        self.assertEqual(self.sees([{'id': 'link-1', 'paired': True, 'connected': True}]), 'SEES')
        self.assertEqual(self.sees([{'id': 'other-phone', 'paired': True, 'connected': True}]), 'NOT')
        self.assertEqual(self.sees([{'id': 'link-1', 'paired': True, 'connected': False}]), 'NOT')


class MacInstallTests(unittest.TestCase):
    """The tag's Mac app: reused for the same head, replaced for this tool's earlier head, never
    touched when this tool did not install it."""

    def install(self, record, app_exists=True):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            home = root / 'home'
            app = home / f'Library/Developer/Xcode/DerivedData/cmux-{TAG}/Build/Products/Debug/cmux DEV {TAG}.app'
            if app_exists:
                (app / 'Contents').mkdir(parents=True)
                (app / 'Contents/old').write_text('old')
            state = root / 'state' / SHA
            (state / f'mac/cmux DEV {TAG}.app/Contents').mkdir(parents=True)
            (state / f'mac/cmux DEV {TAG}.app/Contents/new').write_text('new')
            if record is not None:
                (root / 'state/mac-installed').write_text(record)
            script = f"""set -uo pipefail
source "{REVIEW}"
HOME="{home}" SLUG={TAG} SHA={SHA} MAC_JOB=job2 STATE="{state}" TAG_STATE="{root / 'state'}"
safe_unzip() {{ :; }}
mac_py() {{ case "$1" in socket) echo /tmp/s ;; *) return 0 ;; esac; }}
mac_quit_installed() {{ echo QUIT_CALLED; }}
if mac_install; then echo OK; else echo "BLOCKED $REPORT_MAC"; fi
ls "$MAC_APP/Contents"; cat "{root / 'state/mac-installed'}" 2>/dev/null"""
            return bash(script).stdout

    def test_this_tools_earlier_head_is_quit_and_replaced(self):
        out = self.install('b' * 40 + ' job1\n')
        self.assertIn('QUIT_CALLED', out)
        self.assertIn('OK', out)
        self.assertIn('new', out)
        self.assertNotIn('old', out)
        self.assertIn(f'{SHA} job2', out)

    def test_the_same_head_is_reused(self):
        out = self.install(f'{SHA} job2\n')
        self.assertNotIn('QUIT_CALLED', out)
        self.assertIn('old', out)

    def test_an_install_this_tool_did_not_make_is_refused(self):
        out = self.install(None)
        self.assertIn('BLOCKED', out)
        self.assertIn('did not install', out)
        self.assertNotIn('QUIT_CALLED', out)
        self.assertIn('old', out)

    def test_a_fresh_tag_installs(self):
        out = self.install(None, app_exists=False)
        self.assertIn('OK', out)
        self.assertIn('new', out)


class ManifestAndZipTests(unittest.TestCase):
    def manifest(self, body):
        with tempfile.TemporaryDirectory() as temp:
            f = Path(temp) / 'handoff.json'
            f.write_text(json.dumps(body))
            return subprocess.run(['python3', str(RECEIPT), 'read-manifest', str(f), '--tag', TAG, '--sha', SHA,
                                   '--bundle-id', f'dev.cmux.mobile.{TAG}'], capture_output=True, text=True)

    good = {'kind': 'cmux-next-ios-handoff', 'tag': TAG, 'source_sha': SHA, 'bundle_id': f'dev.cmux.mobile.{TAG}',
            'host': 'aws-m4pro-2', 'simulator': {'status': 'pass', 'device': 'iPhone-17', 'reason': ''}}

    def test_empty_fields_keep_their_lines(self):
        r = self.manifest({**self.good, 'host': ''})
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.split('\n')[:4], ['pass', '', 'iPhone-17', ''])

    def test_a_mismatch_names_the_field(self):
        r = self.manifest({**self.good, 'source_sha': 'c' * 40})
        self.assertEqual(r.returncode, 1)
        self.assertIn("source_sha is 'cccc", r.stderr)

    def test_the_report_carries_the_manifest_reason(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'ios').mkdir()
            (root / 'ios/handoff.json').write_text(json.dumps({**self.good, 'tag': 'other'}))
            r = bash(f"""source "{REVIEW}"; set +e; SLUG={TAG} SHA={SHA} STATE="{root}" SIM_STEP=step1
safe_unzip() {{ :; }}
read_ios_artifact; echo "SIM=$REPORT_SIM\"""")
        self.assertIn("SIM=BLOCKED: step step1: handoff.json does not match this run: tag is 'other'", r.stdout)

    def zip_with(self, links):
        import zipfile
        temp = tempfile.mkdtemp()
        path = Path(temp) / 'a.zip'
        with zipfile.ZipFile(path, 'w') as z:
            z.writestr('App.app/Info.plist', 'x')
            for name, target in links:
                info = zipfile.ZipInfo(name)
                info.external_attr = (0o120777 << 16)
                z.writestr(info, target)
        return subprocess.run(['python3', str(RECEIPT), 'check-zip', str(path)], capture_output=True, text=True)

    def test_symlinks_out_of_the_archive_are_refused(self):
        self.assertEqual(self.zip_with([('App.app/Versions/Current', 'A')]).returncode, 0)
        self.assertEqual(self.zip_with([('App.app/x', '/etc/passwd')]).returncode, 1)
        r = self.zip_with([('App.app/x', '../../outside')])
        self.assertEqual(r.returncode, 1)
        self.assertIn('symlink out of the archive', r.stderr)


class HeadPushedTests(unittest.TestCase):
    """head_pushed tells "origin did not answer" (2) from "not pushed" (1) (origin-net guard)."""

    def run_head_pushed(self, git_body, sha='a' * 40):
        text = REVIEW.read_text()
        func = re.search(r'\n(head_pushed\(\) \{\n.*?\n\})\n', text, re.S).group(1)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'bin').mkdir()
            git = root / 'bin/git'
            git.write_text('#!/bin/sh\n' + git_body)
            git.chmod(0o755)
            lib = (ROOT / 'scripts/cmux-next/lib/origin-net.sh').read_text()
            script = (f'set -u\nREPO_ROOT="{root}"\nSHA={sha}\nORIGIN_NET_TRIES=1\nORIGIN_NET_SLEEP_S=0\n'
                      + lib + '\n' + func + '\nhead_pushed; echo "rc=$?"\n')
            env = dict(os.environ, PATH=f"{root / 'bin'}:/usr/bin:/bin")
            return subprocess.run(['/bin/bash', '-c', script], env=env, capture_output=True, text=True, timeout=30)

    def test_unreachable_origin_is_no_answer_not_unpushed(self):
        body = ('case "$*" in *"branch --show-current"*) echo feat;; *ls-remote*) exit 128;; '
                '*"branch -r --contains"*) ;; esac\n')
        result = self.run_head_pushed(body)
        self.assertIn('rc=2', result.stdout, result.stderr)

    def test_pushed_head_passes(self):
        body = ('case "$*" in *"branch --show-current"*) echo feat;; *ls-remote*) printf "%s\\trefs/heads/feat\\n" '
                + 'a' * 40 + ';; *"branch -r --contains"*) echo origin/feat;; esac\n')
        self.assertIn('rc=0', self.run_head_pushed(body).stdout)

    def test_unpushed_head_is_refused(self):
        body = ('case "$*" in *"branch --show-current"*) echo feat;; *ls-remote*) printf "%s\\trefs/heads/feat\\n" '
                + 'b' * 40 + ';; *"branch -r --contains"*) ;; esac\n')
        self.assertIn('rc=1', self.run_head_pushed(body).stdout)


class PhoneModeTests(unittest.TestCase):
    """phone_review in each mode against a stand-in phone that keeps a stored session across launches,
    as the app's Keychain does: auto-login stores one, CMUX_MOBILE_CLEAR_AUTH drops it, a plain
    launch restores it or stays signed out. Every launch's environment is recorded."""

    PHONE_PY = r"""#!/usr/bin/env python3
import json, os, sys
root = sys.argv[0].rsplit('/bin/', 1)[0]
args = sys.argv[1:]
store = os.path.join(root, 'stored-session')
if args[:3] == ['devicectl', 'device', 'install']:
    sys.exit(0)
if args[:3] == ['devicectl', 'device', 'process']:
    env = {k: v for k, v in os.environ.items() if k.startswith('DEVICECTL_CHILD_')}
    with open(os.path.join(root, 'launches'), 'a') as f:
        f.write(json.dumps({'argv': args, 'env': env}) + '\n')
    if env.get('DEVICECTL_CHILD_CMUX_MOBILE_CLEAR_AUTH') == '1' and os.path.exists(store):
        os.remove(store)
    if env.get('DEVICECTL_CHILD_CMUX_MOBILE_STACK_EMAIL') and env.get('DEVICECTL_CHILD_CMUX_MOBILE_CLEAR_AUTH') != '1':
        open(store, 'w').write('session')
        source = 'auto_login'
    elif os.path.exists(store):
        source = 'restored'
    else:
        source = 'signed_out'
    signed_in = source != 'signed_out'
    paired = signed_in and (bool(env.get('DEVICECTL_CHILD_CMUX_MOBILE_PAIR_URL')) or os.path.exists(os.path.join(root, 'paired')))
    if paired:
        open(os.path.join(root, 'paired'), 'w').write('1')
    receipt = dict(schema=1, nonce=env.get('DEVICECTL_CHILD_CMUX_DOGFOOD_READINESS_NONCE'),
                   client_id=env.get('DEVICECTL_CHILD_CMUX_DOGFOOD_CLIENT_ID'), bundle_id='dev.cmux.mobile.TAGX',
                   written_at='now', git_sha='SHAX', dev_tag='TAGX', signed_in=signed_in, session_source=source,
                   account_email='me@example.com' if signed_in else '', user_id='u1' if signed_in else '',
                   phone_device_ids=['link-1', 'presence-1'] if signed_in else [],
                   cloud_backend='https://cmux-api-development.debussy.workers.dev',
                   paired_macs=[{'id': 'mac-tagged', 'name': 'cmux DEV x', 'linked': True}] if paired else [])
    open(os.path.join(root, 'receipt.json'), 'w').write(json.dumps(receipt))
    sys.exit(0)
if args[:3] == ['devicectl', 'device', 'copy']:
    dest = args[args.index('--destination') + 1]
    open(dest, 'w').write(open(os.path.join(root, 'receipt.json')).read())
    sys.exit(0)
sys.exit(1)
"""

    def review(self, mode, stored=False):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'bin').mkdir()
            (root / 'bin/xcrun').write_text(self.PHONE_PY.replace('TAGX', TAG).replace('SHAX', SHA))
            (root / 'bin/xcrun').chmod(0o755)
            (root / 'device/CmuxMobileApp.app').mkdir(parents=True)
            (root / 'scripts').mkdir()
            (root / 'scripts/ios-device-process.sh').write_text('#!/bin/sh\nexit 0\n')
            (root / 'scripts/ios-device-process.sh').chmod(0o755)
            if stored:
                (root / 'stored-session').write_text('session')
            script = f"""
set -euo pipefail
source "{REVIEW}"
PHONE_MODE={mode} BUNDLE_ID=dev.cmux.mobile.{TAG} SHA={SHA} SLUG={TAG} STATE="{root}" TAG_STATE="{root}"
REPO_ROOT="{root}" MAC_SOCKET=/x MAC_DEVICE_ID=mac-tagged CNX_REVIEW_RECEIPT_TIMEOUT=2
PERSONAL_EMAIL=me@example.com PERSONAL_PASSWORD=pw-secret PERSONAL_ACCOUNT=me@example.com
sign_app() {{ echo '{{}}'; }}
mac_py() {{
  case "$1" in
    pair-url) echo "PAIR_URL_FETCHED" >> "{root}/calls"; echo "cmux-next://pair?mac=mac-tagged&t=tok" ;;
    mark-used) echo "MARK_USED" >> "{root}/calls"; cat >/dev/null ;;
    phones) echo '{{"phones": [{{"id": "link-1", "paired": true, "connected": true}}]}}' ;;
  esac
}}
if phone_review {PHONE} "iPhone (iPhone 16 Plus, {PHONE})"; then echo "LINE: $PHONE_LINE"; else echo "FAIL: $PHONE_REASON"; fi
"""
            r = bash(script, {'PATH': f"{root / 'bin'}:{os.environ['PATH']}"})
            launches = [json.loads(l) for l in (root / 'launches').read_text().splitlines()] if (root / 'launches').exists() else []
            calls = (root / 'calls').read_text() if (root / 'calls').exists() else ''
            still_stored = (root / 'stored-session').exists()
            return r, launches, calls, still_stored

    def test_default_signs_in_pairs_and_restores(self):
        r, launches, calls, stored = self.review('paired')
        self.assertIn('LINE: iPhone (iPhone 16 Plus, ', r.stdout, r.stderr)
        self.assertIn('signed in (auto_login), paired and linked with cmux DEV x', r.stdout)
        self.assertIn('credential-free relaunch: signed in (restored), paired and linked', r.stdout)
        self.assertIn('PAIR_URL_FETCHED', calls)
        self.assertIn('MARK_USED', calls)
        self.assertTrue(stored)
        self.assertEqual(len(launches), 2)
        self.assertNotIn('DEVICECTL_CHILD_CMUX_MOBILE_STACK_EMAIL', launches[1]['env'])

    def test_manual_pairing_signs_in_and_never_hands_over_the_code(self):
        r, launches, calls, stored = self.review('manual')
        self.assertIn('LINE: ', r.stdout, r.stderr)
        self.assertIn('installed, signed in (auto_login); credential-free relaunch: signed in (restored); '
                      'pairing left to you (--manual-pairing)', r.stdout)
        self.assertNotIn('paired and linked', r.stdout)
        self.assertNotIn('PAIR_URL_FETCHED', calls)
        self.assertNotIn('MARK_USED', calls)
        self.assertTrue(stored)
        for launch in launches:
            self.assertNotIn('DEVICECTL_CHILD_CMUX_MOBILE_PAIR_URL', launch['env'])
        self.assertEqual(launches[0]['env']['DEVICECTL_CHILD_CMUX_MOBILE_STACK_PASSWORD'], 'pw-secret')
        self.assertNotIn('DEVICECTL_CHILD_CMUX_MOBILE_STACK_PASSWORD', launches[1]['env'])

    def test_no_auth_clears_a_stored_session_and_stays_signed_out(self):
        r, launches, calls, stored = self.review('none', stored=True)
        self.assertIn('LINE: iPhone (iPhone 16 Plus, ', r.stdout, r.stderr)
        self.assertIn('installed, not signed in (--no-auth)', r.stdout)
        self.assertIn('relaunch: still signed out', r.stdout)
        self.assertFalse(stored)  # the tag's stored session is gone
        self.assertEqual(launches[0]['env'].get('DEVICECTL_CHILD_CMUX_MOBILE_CLEAR_AUTH'), '1')
        self.assertNotIn('DEVICECTL_CHILD_CMUX_MOBILE_CLEAR_AUTH', launches[1]['env'])
        for launch in launches:
            for key in ('DEVICECTL_CHILD_CMUX_MOBILE_STACK_EMAIL', 'DEVICECTL_CHILD_CMUX_MOBILE_STACK_PASSWORD',
                        'DEVICECTL_CHILD_CMUX_MOBILE_PAIR_URL'):
                self.assertNotIn(key, launch['env'])
        self.assertNotIn('PAIR_URL_FETCHED', calls)

    def test_no_auth_fails_when_the_app_is_still_signed_in(self):
        # A build without the clear hook keeps the stored session: --no-auth must not pass.
        r, launches, _, _ = self.review_without_clear()
        self.assertIn('FAIL: clear launch: the app is signed in (restored), expected signed out', r.stdout, r.stderr)

    def test_manual_pairing_fails_when_sign_in_does_not_persist(self):
        saved = self.PHONE_PY
        self.PHONE_PY = saved.replace("open(store, 'w').write('session')", "pass")
        try:
            r, *_ = self.review('manual')
        finally:
            self.PHONE_PY = saved
        self.assertIn('FAIL: restored launch: the app is signed out (so far)', r.stdout, r.stderr)

    def review_without_clear(self):
        saved = self.PHONE_PY
        self.PHONE_PY = saved.replace("if env.get('DEVICECTL_CHILD_CMUX_MOBILE_CLEAR_AUTH') == '1' and os.path.exists(store):\n        os.remove(store)",
                                      "pass")
        try:
            return self.review('none', stored=True)
        finally:
            self.PHONE_PY = saved


class ModeFlagTests(unittest.TestCase):
    def mode(self, *flags):
        r = bash(f"""source "{REVIEW}"; set +e
die() {{ echo "DIE $*"; exit 0; }}
cmux_attach_validate_dev_tag() {{ echo "MODE=$PHONE_MODE RETRY=$(SLUG=t; retry_command)"; exit 0; }}
main --tag t {' '.join(flags)}""")
        return r.stdout.strip()

    def test_flags_set_the_mode_and_the_retry_keeps_it(self):
        self.assertIn('MODE=paired RETRY=cmux-next-ios/scripts/review.sh --tag t', self.mode())
        self.assertIn('MODE=manual RETRY=cmux-next-ios/scripts/review.sh --tag t --manual-pairing', self.mode('--manual-pairing'))
        self.assertIn('MODE=none RETRY=cmux-next-ios/scripts/review.sh --tag t --no-auth', self.mode('--no-auth'))
        # --no-auth implies no pairing, in either order.
        self.assertIn('MODE=none', self.mode('--no-auth', '--manual-pairing'))
        self.assertIn('MODE=none', self.mode('--manual-pairing', '--no-auth'))

    def test_only_the_paired_mode_relaunches_the_mac(self):
        text = REVIEW.read_text()
        self.assertIn('if [[ "$PASSED_PHONES" != " " && "$PHONE_MODE" == paired ]]; then', text)

    def test_the_clear_hook_is_debug_only(self):
        auth = (ROOT / 'cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileAuth/CmuxMobileAuthModel.swift').read_text()
        self.assertIn('clearAuthRequested: isDebug && environment["CMUX_MOBILE_CLEAR_AUTH"] == "1"', auth)
        self.assertIn('let isDebug = false', auth[auth.index('#else'):])
        root_view = (ROOT / 'cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileShell/RootView.swift').read_text()
        at = root_view.index('DogfoodReadiness().writeSignedOut(')
        self.assertGreater(at, root_view.rindex('#if DEBUG', 0, at))
        self.assertGreater(root_view.index('#endif', at), at)
        receipt = (ROOT / 'cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileShell/DogfoodReadiness.swift').read_text()
        self.assertTrue(receipt.startswith('#if DEBUG'))


if __name__ == '__main__':
    unittest.main()
