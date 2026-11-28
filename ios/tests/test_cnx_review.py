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
import shlex
import signal
from pathlib import Path
import plistlib
import subprocess
import tempfile
import textwrap
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
    # Its own process group, so a timeout ends the script and every child it started (a fake recorder too).
    with subprocess.Popen([BASH, '-c', script], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                          env=dict(os.environ, **(env or {})), start_new_session=True) as p:
        try:
            out, err = p.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            p.communicate()
            raise
    return subprocess.CompletedProcess(p.args, p.returncode, out, err)


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

    def test_a_rerun_reuses_this_heads_iphone_build_that_passed(self):
        # 2026-11-24: the hand-off of 0e728c2b25 passed its iPhone step (3808c362) while the Mac build failed; the
        # rerun sent the iPhone step again, the controller refused its key ("409: step_key already names a different
        # step": a new sign-in key), and the run had nothing for the phone. A head's passed iPhone build is reused.
        reuse = """mkdir -p "$STATE"; printf '%s\\n' step-passed > "$STATE/ios-passed"; echo zip > "$STATE/ios.zip"
fleet_start_sim() { echo SIM_STARTED; }
fleet_finish_sim() { echo SIM_FINISHED; }
read_ios_artifact() { echo "READ_STEP=$SIM_STEP"; REPORT_SIM="fleet simulator (aws-m4pro-3, iPhone-17 on iOS-26-5), signed in: /e"; }"""
        r = self.run_review([(PHONE, 'iPhone')], reuse)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn('SIM_STARTED', r.stdout)
        self.assertNotIn('SIM_FINISHED', r.stdout)
        self.assertIn("==> iPhone app: reusing this head's build from step step-passed (its simulator check passed)", r.stdout)
        self.assertIn('READ_STEP=step-passed', r.stdout)
        # No marker, or a marker with no artifact beside it: a step as before.
        for setup in ('', 'mkdir -p "$STATE"; echo step-passed > "$STATE/ios-passed"'):
            with self.subTest(setup=setup):
                r = self.run_review([(PHONE, 'iPhone')], setup + "\nfleet_start_sim() { echo SIM_STARTED; }")
                self.assertIn('SIM_STARTED', r.stdout, r.stderr)
                self.assertNotIn('reusing this head', r.stdout)

    def test_a_rerun_downloads_a_passed_steps_artifact_again_instead_of_a_new_step(self):
        # 2026-11-25: vcorp1125d's iPhone step 9fd70d54 passed but its artifact did not download; the rerun sent a new
        # step, the controller refused its key ("409: step_key already names a different step"), and the run had
        # nothing for the phone. The passed step is saved before the download, and a rerun fetches it again.
        step = '9fd70d548f30e9577207cfc4'
        again = f"""mkdir -p "$STATE"; printf '%s\\n' {step} > "$STATE/sim-passed"
fleet_start_sim() {{ echo SIM_STARTED; }}
fleet_finish_sim() {{ echo SIM_FINISHED; }}
cmux_ci() {{ [ "$1" = artifact ] && echo "$2" > "$STATE/artifact-call" && echo zip > "$3"; }}
read_ios_artifact() {{ echo "READ_STEP=$SIM_STEP ARTIFACT=$(cat "$STATE/artifact-call") ZIP=$(cat "$STATE/ios.zip")"; REPORT_SIM="fleet simulator (aws-m4pro-3, iPhone-17 on iOS-26-5), signed in: /e"; }}"""
        r = self.run_review([(PHONE, 'iPhone')], again)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn('SIM_STARTED', r.stdout)
        self.assertIn(f'==> iPhone app: step {step} passed before; downloading its artifact again', r.stdout)
        self.assertIn(f'ARTIFACT={step} ZIP=zip', r.stdout)
        self.assertIn(f'READ_STEP={step}', r.stdout)
        # A download that fails again forgets the step and sends a new one; a malformed id is never fetched.
        for setup in (f"""mkdir -p "$STATE"; printf '%s\\n' {step} > "$STATE/sim-passed"
cmux_ci() {{ [ "$1" = artifact ] && return 1; return 0; }}""",
                      'mkdir -p "$STATE"; echo not-a-step > "$STATE/sim-passed"'):
            with self.subTest(setup=setup):
                r = self.run_review([(PHONE, 'iPhone')], setup + '\nfleet_start_sim() { echo "SIM_STARTED KEY=$(sim_key)"; }')
                self.assertIn('SIM_STARTED', r.stdout, r.stderr)
        # The passed step given up after a second failed download: the new step goes out under a new key, which the
        # controller accepts (the old key names the old step: "409: step_key already names a different step").
        r = self.run_review([(PHONE, 'iPhone')], f"""mkdir -p "$STATE"; printf '%s\\n' {step} > "$STATE/sim-passed"
cmux_ci() {{ [ "$1" = artifact ] && return 1; return 0; }}
fleet_start_sim() {{ echo "SIM_STARTED KEY=$(sim_key)"; }}""")
        self.assertIn(f'SIM_STARTED KEY=cnx-ios-handoff-{TAG}-{SHA[:12]}-r1', r.stdout, r.stderr)

    def test_a_failed_simulator_check_is_never_fetched_again(self):
        # A step that ran to its end but whose check failed (or whose artifact was rejected) is forgotten: the
        # retry the report names sends a new step under a new key instead of downloading the same failure.
        with tempfile.TemporaryDirectory() as temp:
            state = Path(temp)
            (state / 'sim-passed').write_text('0123456789abcdef01234567\n')
            r = bash(f'''source "{REVIEW}"; SLUG={TAG} SHA={SHA} STATE="{state}" SIM_STEP=0123456789abcdef01234567
echo not-a-zip > "$STATE/ios.zip"
rc=0; read_ios_artifact || rc=$?; echo "RC=$rc"; echo "KEY=$(sim_key)"''', {})
            self.assertIn('RC=1', r.stdout, r.stderr)
            self.assertFalse((state / 'sim-passed').exists())
            self.assertIn(f'KEY=cnx-ios-handoff-{TAG}-{SHA[:12]}-r1', r.stdout)

    def test_a_passed_step_is_saved_before_its_artifact_downloads(self):
        with tempfile.TemporaryDirectory() as temp:
            state = Path(temp)
            r = bash(f'''source "{REVIEW}"; SLUG={TAG} SHA={SHA} STATE="{state}"
SIM_PID=$$; wait() {{ return 0; }}
printf 'cmux-ci: step 0123456789abcdef01234567 (simulator)\\n' > "$STATE/sim-step.err"; : > "$STATE/sim-step.log"
cmux_ci() {{ return 1; }}
rc=0; fleet_finish_sim || rc=$?; echo "RC=$rc"; echo "REPORT=$REPORT_SIM"''', {})
            self.assertIn('RC=1', r.stdout, r.stderr)
            self.assertIn('passed but its artifact did not download', r.stdout)
            self.assertEqual((state / 'sim-passed').read_text().strip(), '0123456789abcdef01234567')

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

    def launch(self, session, receipt_fields, focus_mac='', backend='', mobile='', phone='', phone_mobile='', extra='',
               settled=None, settle='0'):
        """settled: receipt fields of every copy after the first (the path the link settled on); settle:
        CNX_REVIEW_PATH_SETTLE."""
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'bin').mkdir()
            fields = json.dumps(receipt_fields)
            settled_json = json.dumps(settled)
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
    if {settled_json!r} != "null":
        receipt.update(json.loads({settled_json!r}))
        open(os.path.join(root, "receipt-settled.json"), "w").write(json.dumps(receipt))
elif args[:3] == ["devicectl", "device", "copy"]:
    dest = args[args.index("--destination") + 1]
    copies = os.path.join(root, "copies")
    first = not os.path.exists(copies)
    open(copies, "a").write("1")
    settled = os.path.join(root, "receipt-settled.json")
    open(dest, "w").write(open(settled if not first and os.path.exists(settled) else os.path.join(root, "receipt.json")).read())
else:
    sys.exit(1)
''')
            xcrun.chmod(0o755)
            script = f'''
set -euo pipefail
source "{REVIEW}"
BUNDLE_ID=dev.cmux.mobile.{TAG} MAC_DEVICE_ID=mac-tagged CNX_REVIEW_RECEIPT_TIMEOUT=2 SHA={SHA} SLUG={TAG} STATE="{root}/state"
BACKEND_URL="{backend}" BACKEND_MOBILE_URL="{mobile}" BACKEND_PHONE_URL="{phone}" BACKEND_PHONE_MOBILE_URL="{phone_mobile}"
export DEVICECTL_CHILD_CMUX_NEXT_CLOUD_BACKEND=https://ambient.example
PERSONAL_EMAIL=me@example.com PERSONAL_PASSWORD=pw-secret PERSONAL_ACCOUNT=me@example.com
export DEVICECTL_CHILD_CMUX_MOBILE_STACK_PASSWORD=ambient-leak
export DEVICECTL_CHILD_CMUX_MOBILE_DEV_RELAY_ONLY=ambient-relay
{extra}
if phone_launch_and_check {PHONE} client-1 {session} "{focus_mac}"; then echo "PASS: $PHONE_VERDICT"; else echo "FAIL: $PHONE_REASON"; fi
'''
            r = bash(script, {'PATH': f"{root / 'bin'}:{os.environ['PATH']}", 'CNX_REVIEW_PATH_SETTLE': settle})
            argv = json.loads((root / 'argv').read_text()) if (root / 'argv').exists() else []
            env = json.loads((root / 'env').read_text()) if (root / 'env').exists() else {}
            return r, argv, env

    DEFAULT = 'https://cmux-api-development.debussy.workers.dev'
    # Every receipt of this build names its Cloud backend (DogfoodReadiness.cloud_backend).
    linked = {'cloud_backend': DEFAULT, 'paired_macs': [{'id': 'mac-tagged', 'name': 'cmux DEV cnx', 'linked': True}]}

    def test_signed_in_launch_carries_the_account_and_mac_in_its_environment_only(self):
        r, argv, env = self.launch('auto_login', self.linked, focus_mac='mac-tagged')
        self.assertIn('PASS: signed in (auto_login), paired and linked with cmux DEV cnx', r.stdout, r.stderr)
        self.assertEqual(env['DEVICECTL_CHILD_CMUX_MOBILE_STACK_PASSWORD'], 'pw-secret')
        self.assertEqual(env['DEVICECTL_CHILD_CMUX_MOBILE_FOCUS_MAC'], 'mac-tagged')
        self.assertNotIn('DEVICECTL_CHILD_CMUX_MOBILE_PAIR_URL', env)
        self.assertNotIn('pw-secret', ' '.join(argv))
        self.assertIn('--terminate-existing', argv)

    def test_credential_free_relaunch_carries_nothing_and_must_restore(self):
        r, argv, env = self.launch('restored', self.linked)
        self.assertIn('PASS: signed in (restored)', r.stdout, r.stderr)
        for key in ('DEVICECTL_CHILD_CMUX_MOBILE_STACK_EMAIL', 'DEVICECTL_CHILD_CMUX_MOBILE_STACK_PASSWORD',
                    'DEVICECTL_CHILD_CMUX_MOBILE_FOCUS_MAC'):
            self.assertNotIn(key, env)
        self.assertIn('DEVICECTL_CHILD_CMUX_DOGFOOD_READINESS_NONCE', env)

    def test_a_signed_out_install_fails(self):
        r, _, _ = self.launch('restored', {'session_source': 'auto_login', **self.linked})
        self.assertIn('FAIL: restored launch: the session is auto_login, expected restored', r.stdout)

    def test_an_unpaired_install_fails_at_the_deadline(self):
        r, _, _ = self.launch('restored', {'paired_macs': [{'id': 'other-mac', 'name': 'x', 'linked': True}]})
        self.assertIn("FAIL: restored launch: linked with another Mac, not this tag's: x (other-mac), not the tagged Mac mac-tagged",
                      r.stdout)
        r, _, _ = self.launch('restored', {'paired_macs': []})
        self.assertIn('FAIL: restored launch: not on the tagged Mac yet (the phone has picked no Mac so far)', r.stdout)

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

    STACK_MOBILE = 'https://cmux-dev-backend-1.tail137216.ts.net:3851'

    def test_a_tag_stack_launch_must_use_the_stacks_own_mobile_worker(self):
        # The tag's Mac registers with the stack's mobile Worker: a phone on the shared one never finds it.
        on_stack = {**self.linked, 'cloud_backend': self.STACK, 'api_base_url': self.STACK_MOBILE}
        r, _, _ = self.launch('restored', on_stack, backend=self.STACK, mobile=self.STACK_MOBILE)
        self.assertIn('PASS: signed in (restored)', r.stdout, r.stderr)
        shared = {**on_stack, 'api_base_url': 'https://cmux-mobile-api-dev.debussy.workers.dev'}
        r, _, _ = self.launch('restored', shared, backend=self.STACK, mobile=self.STACK_MOBILE)
        self.assertIn('FAIL: restored launch: the app uses the mobile service https://cmux-mobile-api-dev.debussy.workers.dev, '
                      f'not the tag stack\'s {self.STACK_MOBILE}', r.stdout)

    PUBLIC = 'https://api.s7.wdev.cmux.dev'
    PUBLIC_MOBILE = 'https://mobile.s7.wdev.cmux.dev'

    def test_a_stack_with_a_public_origin_gives_the_phone_that_origin(self):
        # The Mac keeps the tailnet origin; the phone gets the same stack's public one, which works off the tailnet.
        on_public = {**self.linked, 'cloud_backend': self.PUBLIC, 'api_base_url': self.PUBLIC_MOBILE}
        r, _, env = self.launch('auto_login', on_public, backend=self.STACK, mobile=self.STACK_MOBILE,
                                phone=self.PUBLIC, phone_mobile=self.PUBLIC_MOBILE)
        self.assertIn('PASS: signed in (auto_login)', r.stdout, r.stderr)
        self.assertEqual(env['DEVICECTL_CHILD_CMUX_NEXT_CLOUD_BACKEND'], self.PUBLIC)
        tailnet = {**on_public, 'cloud_backend': self.STACK, 'api_base_url': self.STACK_MOBILE}
        r, _, _ = self.launch('restored', tailnet, backend=self.STACK, mobile=self.STACK_MOBILE,
                              phone=self.PUBLIC, phone_mobile=self.PUBLIC_MOBILE)
        self.assertIn(f'FAIL: restored launch: the app uses the Cloud backend {self.STACK}, not {self.PUBLIC}', r.stdout)

    def test_the_default_clears_a_kept_backend_and_proves_it(self):
        # `default` (not an empty value a launcher may drop) clears the kept override...
        r, _, env = self.launch('auto_login', self.linked)
        self.assertIn('PASS: signed in (auto_login)', r.stdout, r.stderr)
        self.assertEqual(env['DEVICECTL_CHILD_CMUX_NEXT_CLOUD_BACKEND'], 'default', 'the first launch clears the kept override')
        _, _, env = self.launch('restored', self.linked)
        self.assertNotIn('DEVICECTL_CHILD_CMUX_NEXT_CLOUD_BACKEND', env, 'no ambient value leaks into a launch')

    def test_the_default_fails_when_the_phone_kept_an_earlier_override(self):
        # ...and the receipt must show it took: a phone still on a kept stack or preview fails.
        for kept in (self.STACK, 'https://cmux-api-preview-7.debussy.workers.dev', 'https://api.s7.wdev.cmux.dev'):
            r, _, _ = self.launch('restored', {**self.linked, 'cloud_backend': kept})
            self.assertIn(f'FAIL: restored launch: the app still uses the kept Cloud backend {kept}', r.stdout)
        r, _, _ = self.launch('restored', {**self.linked, 'cloud_backend': ''})
        self.assertIn('FAIL: restored launch: the receipt names no cloud_backend', r.stdout)

    def test_a_receipt_from_another_launch_never_passes(self):
        r, _, _ = self.launch('restored', {'nonce': 'old', **self.linked})
        self.assertIn('FAIL: restored launch: the receipt is from another launch', r.stdout)

    def routed(self, **route):
        return {**self.linked, 'paired_macs': [{**self.linked['paired_macs'][0], **route}]}

    def test_every_check_names_the_links_path(self):
        r, _, env = self.launch('restored', self.routed(transport='wireguard', path='direct-lan', tailnet=False))
        self.assertIn('PASS: signed in (restored), paired and linked with cmux DEV cnx over WireGuard, direct LAN', r.stdout, r.stderr)
        self.assertNotIn('DEVICECTL_CHILD_CMUX_MOBILE_DEV_RELAY_ONLY', env, 'an ambient relay switch never leaks into a launch')

    def test_the_relay_only_relaunch_carries_only_the_relay_switch_and_must_link_via_turn(self):
        turn = self.routed(transport='wireguard', path='turn', tailnet=False)
        r, argv, env = self.launch('relay-only', turn)
        self.assertIn('PASS: signed in (restored), paired and linked with cmux DEV cnx over WireGuard, via TURN', r.stdout, r.stderr)
        self.assertEqual(env['DEVICECTL_CHILD_CMUX_MOBILE_DEV_RELAY_ONLY'], '1')
        for key in ('DEVICECTL_CHILD_CMUX_MOBILE_STACK_EMAIL', 'DEVICECTL_CHILD_CMUX_MOBILE_STACK_PASSWORD',
                    'DEVICECTL_CHILD_CMUX_MOBILE_PAIR_URL', 'DEVICECTL_CHILD_CMUX_NEXT_CLOUD_BACKEND'):
            self.assertNotIn(key, env, 'the relay-only relaunch is the person\'s cold launch plus the relay switch')
        self.assertNotIn('RELAY_ONLY', ' '.join(argv))
        # A phone that still linked direct (the switch not honored) fails at once, naming the path.
        r, _, _ = self.launch('relay-only', self.routed(transport='wireguard', path='direct-lan', tailnet=False))
        self.assertIn('FAIL: relay-only launch: the relay-only launch linked direct LAN with cmux DEV cnx, not via TURN', r.stdout)

    def test_forbid_tailnet_fails_a_phone_linked_over_the_tailnet(self):
        tailnet = self.routed(transport='wireguard', path='direct-wan', tailnet=True)
        r, _, _ = self.launch('restored', tailnet)
        self.assertIn('PASS: signed in (restored), paired and linked with cmux DEV cnx over WireGuard, direct over the tailnet',
                      r.stdout, r.stderr)
        r, _, _ = self.launch('restored', tailnet, extra='FORBID_TAILNET=1')
        self.assertIn('FAIL: restored launch: linked with cmux DEV cnx over the tailnet (--forbid-tailnet)', r.stdout, r.stderr)

    def test_the_path_the_link_settles_on_decides(self):
        # WireGuard may answer through TURN first and move to the direct route it confirms a moment later: the
        # verdict is the settled path's, so a link that settles on the tailnet never passes as TURN.
        turn = self.routed(transport='wireguard', path='turn', tailnet=False)
        tailnet = self.routed(transport='wireguard', path='direct-wan', tailnet=True)
        r, _, _ = self.launch('restored', turn, settled=tailnet, settle='1')
        self.assertIn('PASS: signed in (restored), paired and linked with cmux DEV cnx over WireGuard, direct over the tailnet',
                      r.stdout, r.stderr)
        r, _, _ = self.launch('restored', turn, settled=tailnet, settle='1', extra='FORBID_TAILNET=1')
        self.assertIn('FAIL: restored launch: linked with cmux DEV cnx over the tailnet (--forbid-tailnet)', r.stdout, r.stderr)
        # A second read that is not ready (a receipt between writes) keeps the first verdict.
        r, _, _ = self.launch('restored', turn, settled={'nonce': 'old'}, settle='1')
        self.assertIn('PASS: signed in (restored), paired and linked with cmux DEV cnx over WireGuard, via TURN', r.stdout, r.stderr)


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
                            ('https://cmux-dev-backend-1.tail137216.ts.net', 'https://cmux-dev-backend-1.tail137216.ts.net'),
                            ('https://API.s7.wdev.cmux.dev/', 'https://api.s7.wdev.cmux.dev')]:
            self.assertEqual(m.backend_origin(value), want, value)
        for value in ['https://attacker.example', 'https://cloud-api.cmux.dev', 'prod', 'staging',
                      'http://cmux-dev-backend-1.tail137216.ts.net:3850', 'https://ts.net', 'https://tail137216.ts.net',
                      'https://cmux-dev-backend-1.tail137216.ts.net.attacker.example', self.STACK + '/v1',
                      self.STACK + '?x=1', 'https://user@cmux-dev-backend-1.tail137216.ts.net', 'https://a_b.tail.ts.net',
                      'https://100.70.231.80', 'preview-0', 'http://localhost:8787', '',
                      'https://mobile.s7.wdev.cmux.dev', 'https://api.s7.wdev.cmux.dev:8443', 'http://api.s7.wdev.cmux.dev',
                      'https://api.s7777.wdev.cmux.dev', 'https://api.s7.wdev.cmux.dev.attacker.example', 'https://wdev.cmux.dev',
                      # another tailnet's machine (a Funnel name is public), or a name under ours that is no machine
                      'https://cmux-dev-backend-1.tail9999.ts.net:3850', 'https://evil.ts.net', 'https://a.b.tail137216.ts.net',
                      'https://api.s7.other.cmux.dev', 'https://cmux.dev']:
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
        self.assertIn('URL=\n', r.stdout, r.stderr)  # the default reads the stack only once its up ran
        self.assertIn("REPORT=this tag's stack (not up yet)", r.stdout)
        self.assertNotIn('--backend', r.stdout)
        r = self.resolve('dev')
        self.assertIn('URL=\n', r.stdout, r.stderr)
        self.assertIn('REPORT=shared dev Workers (--backend dev, no override)', r.stdout)
        self.assertIn('--backend dev', r.stdout)
        r = self.resolve(self.STACK + '/')
        self.assertIn(f'URL={self.STACK}\n', r.stdout, r.stderr)
        self.assertIn(f'--backend {self.STACK}/', r.stdout)
        public = self.resolve('tag-stack', '#!/bin/sh\ncase "$*" in *--public*--service*) echo https://mobile.s7.wdev.cmux.dev ;; '
                              '*--public*) echo https://api.s7.wdev.cmux.dev ;; *--service*) echo https://cmux-dev-backend-1.tail137216.ts.net:3851 ;; '
                              f'*) echo {self.STACK} ;; esac\n')
        self.assertIn(f'URL={self.STACK}\n', public.stdout, public.stderr)
        self.assertIn("the phone: https://api.s7.wdev.cmux.dev (its public origin)", public.stdout)
        r = self.resolve('tag-stack')
        self.assertIn(f"REPORT={self.STACK} (this tag's stack: API, mobile Worker and device hub)", r.stdout, r.stderr)
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

    def default(self, stack_body, arg=''):
        """review_start_stack then review_await_backend (the default), against a fake cloud-dev-stack.sh that logs
        each call."""
        with tempfile.TemporaryDirectory() as temp:
            calls = Path(temp) / 'calls'
            stack = Path(temp) / 'cloud-dev-stack.sh'
            stack.write_text(f'#!/bin/sh\necho "$*" >> "{calls}"\n' + stack_body)
            stack.chmod(0o755)
            script = '\n'.join([
                'set -euo pipefail',
                f'source "{REVIEW}"',
                f'SLUG={TAG} BACKEND_ARG="{arg}" TAG_STATE="{temp}/state"',
                'review_resolve_backend',
                'review_start_stack',
                'review_await_backend',
                'echo "URL=$BACKEND_URL"; echo "PHONE=$BACKEND_PHONE_URL"; echo "MOBILE=$BACKEND_MOBILE_URL"; echo "REPORT=$BACKEND_REPORT"',
                'echo "LAUNCH=${BACKEND_PHONE_URL:-${BACKEND_URL:-default}}"',
            ])
            r = bash(script, {'CNX_CLOUD_DEV_STACK': str(stack)})
            return r, (calls.read_text() if calls.exists() else '')

    def test_the_default_brings_the_tags_stack_up_and_points_both_apps_at_it(self):
        body = ('case "$*" in up*) echo "== up in 31 s" ;; *--public*--service*) echo https://mobile.s7.wdev.cmux.dev ;; '
                '*--public*) echo https://api.s7.wdev.cmux.dev ;; *--service*) echo https://cmux-dev-backend-1.tail137216.ts.net:3851 ;; '
                f'*) echo {self.STACK} ;; esac\n')
        r, calls = self.default(body)
        self.assertEqual(calls.splitlines()[0], f'up --tag {TAG}', calls)
        self.assertIn(f'URL={self.STACK}\n', r.stdout, r.stderr)  # the Mac: the tailnet origin
        self.assertIn('PHONE=https://api.s7.wdev.cmux.dev\n', r.stdout)  # the phone: the public one
        self.assertIn('LAUNCH=https://api.s7.wdev.cmux.dev\n', r.stdout)
        self.assertIn('MOBILE=https://cmux-dev-backend-1.tail137216.ts.net:3851\n', r.stdout)
        self.assertIn("this tag's stack: API, mobile Worker and device hub, default)", r.stdout)

    def test_a_stack_that_does_not_come_up_falls_back_to_the_shared_workers_and_says_why(self):
        r, calls = self.default('case "$*" in up*) echo "cloud-dev-stack: ssh: connect to host cmux-dev-backend-1: timed out" >&2; exit 1 ;; '
                                f'*) echo {self.STACK} ;; esac\n')
        self.assertEqual(r.returncode, 0, r.stderr)  # the hand-off still finishes
        self.assertEqual(calls.splitlines(), [f'up --tag {TAG}'], 'no url read after a failed up')
        self.assertIn('URL=\n', r.stdout)
        self.assertIn('LAUNCH=default\n', r.stdout)  # the phone's kept override is cleared
        self.assertIn('REPORT=shared dev Workers (FALLBACK: this tag\'s stack did not come up: cloud-dev-stack: ssh: connect to host '
                      'cmux-dev-backend-1: timed out', r.stdout)
        # An up that passed but names an origin outside the allowlist falls back too.
        r, _ = self.default('case "$*" in up*) exit 0 ;; *) echo https://attacker.example ;; esac\n')
        self.assertIn('URL=\n', r.stdout, r.stderr)
        self.assertIn('is not a tailnet origin', r.stdout)

    def test_an_up_that_fails_silently_still_falls_back(self):
        r, _ = self.default('case "$*" in up*) exit 1 ;; *) exit 0 ;; esac\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("did not come up: up exited 1", r.stdout)

    def test_a_stack_with_no_public_slot_says_the_phone_is_tailnet_only(self):
        r, _ = self.default(f'case "$*" in up*) exit 0 ;; *--public*) echo "stack has no public origin" >&2; exit 3 ;; *) echo {self.STACK} ;; esac\n')
        self.assertIn('PHONE=\n', r.stdout, r.stderr)
        self.assertIn(f'LAUNCH={self.STACK}\n', r.stdout)
        self.assertIn('the phone: tailnet only (no free public slot', r.stdout)

    def test_backend_dev_touches_no_stack(self):
        r, calls = self.default(f'echo {self.STACK}\n', arg='dev')
        self.assertEqual(calls, '', 'no up, no url')
        self.assertIn('URL=\n', r.stdout, r.stderr)
        self.assertIn('LAUNCH=default\n', r.stdout)

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

    def test_a_phone_on_the_tagged_mac_that_was_not_let_in_is_not_called_paired(self):
        # pv1121e-ap (2026-11-21): the receipt names the Mac the phone picked from the account's Mac list
        # (`paired_macs` is its focused Mac), not a Mac that let it in; nobody had pressed Allow.
        mac = {'id': 'm1', 'name': 'Aziz’s MacBook Pro', 'linked': False}
        receipt = {**self.base, 'session_source': 'auto_login', 'paired_macs': [mac]}
        r = self.check(receipt, '--session', 'auto_login', '--mac-id', 'm1')
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertNotIn('paired', r.stdout)
        self.assertIn('on the tagged Mac Aziz’s MacBook Pro, not linked yet', r.stdout)

    def test_want_asking_passes_once_the_phone_is_on_the_tagged_mac(self):
        # --approve-first: the first launch only has to reach the tagged Mac; the Mac's own answer (allow-state)
        # says whether it waits for Allow.
        mac = {'id': 'm1', 'name': 'Aziz’s MacBook Pro', 'linked': False}
        receipt = {**self.base, 'session_source': 'auto_login', 'paired_macs': [mac]}
        r = self.check(receipt, '--session', 'auto_login', '--mac-id', 'm1', '--want', 'asking')
        self.assertEqual((r.returncode, r.stdout.strip()),
                         (0, 'signed in (auto_login), on the tagged Mac Aziz’s MacBook Pro, not linked yet'))
        r = self.check({**receipt, 'paired_macs': [{**mac, 'linked': True}]}, '--session', 'auto_login', '--mac-id', 'm1',
                       '--want', 'asking')
        self.assertEqual((r.returncode, r.stdout.strip()),
                         (0, 'signed in (auto_login), paired and linked with Aziz’s MacBook Pro'))
        # Another Mac, or none yet: still not this tag's Mac.
        r = self.check({**receipt, 'paired_macs': [{**mac, 'id': 'other'}]}, '--session', 'auto_login', '--mac-id', 'm1',
                       '--want', 'asking')
        self.assertEqual(r.returncode, 1)
        self.assertEqual(self.check({**receipt, 'paired_macs': []}, '--session', 'auto_login', '--mac-id', 'm1',
                                    '--want', 'asking').returncode, 1)

    def test_a_phone_on_another_tags_mac_says_which(self):
        # Aziz's 2026-11-18 ios-infinite-scroll-v3 and ios-onboard receipts: the phone linked the cu-all
        # dev build, not its tag's Mac. Never accepted; the reason names the other Mac and the tagged one.
        cu_all, v3 = '0ae8a0d4-d8d9-4872-b541-a48f3dc6cc50', 'e7673bc3-6fc4-4184-ba29-d80ad6743844'
        for linked, state in ((True, 'linked with another Mac'), (False, 'on another Mac')):
            with self.subTest(linked=linked):
                receipt = {**self.base, 'paired_macs': [{'id': cu_all, 'name': 'Aziz’s MacBook Pro', 'linked': linked}]}
                r = self.check({**receipt, 'session_source': 'auto_login'}, '--session', 'auto_login', '--mac-id', v3)
                self.assertEqual(r.returncode, 1, r.stdout)
                self.assertIn(f"{state}, not this tag's: Aziz’s MacBook Pro ({cu_all}), not the tagged Mac {v3}",
                              r.stdout)
        # The Mac it is linked with is named, not the first one it lists.
        receipt = {**self.base, 'session_source': 'auto_login', 'paired_macs': [
            {'id': 'old', 'name': 'Old', 'linked': False}, {'id': cu_all, 'name': 'cu-all', 'linked': True}]}
        r = self.check(receipt, '--session', 'auto_login', '--mac-id', v3)
        self.assertIn(f"linked with another Mac, not this tag's: cu-all ({cu_all})", r.stdout)

    def test_build_space_must_be_the_tagged_macs(self):
        space = 'dev:cnx-test-v1'
        self.assertEqual(self.check({**self.base, 'build_space': space}, '--session', 'restored', '--build-space', space).returncode, 0)
        for have, why in ((None, 'names no build_space'), ('', "'the default space', not the tagged Mac's 'dev:cnx-test-v1'"),
                          ('dev:other', "'dev:other', not the tagged Mac's 'dev:cnx-test-v1'"), ('unusable', "'unusable'")):
            with self.subTest(have=have):
                receipt = dict(self.base) if have is None else {**self.base, 'build_space': have}
                r = self.check(receipt, '--session', 'restored', '--build-space', space)
                self.assertEqual(r.returncode, 3, r.stdout)
                self.assertIn(why, r.stdout)
        # Checked before sign-in: a signed-out (--no-auth) receipt in another space is refused too.
        out = {**self.base, 'session_source': 'signed_out', 'signed_in': False, 'account_email': '', 'user_id': '', 'build_space': ''}
        self.assertEqual(self.check(out, '--session', 'signed_out', '--build-space', space).returncode, 3)
        # Without --build-space (an older review.sh) the field is not required.
        self.assertEqual(self.check(self.base, '--session', 'restored').returncode, 0)

    def linked(self, linked=True, **route):
        """A receipt whose focused Mac m1 is linked, with the link's transport, path and tailnet flag."""
        return {**self.base, 'paired_macs': [{'id': 'm1', 'name': 'Mac', 'linked': linked, **route}]}

    LAN = dict(transport='wireguard', path='direct-lan', tailnet=False)
    TAILNET = dict(transport='wireguard', path='direct-wan', tailnet=True)
    TURN = dict(transport='wireguard', path='turn', tailnet=False)

    def test_the_verdict_names_the_links_transport_and_path(self):
        # Aziz's iPhone and Mac are both on Tailscale: a hand-off at home may link over the tailnet, which no
        # user without Tailscale gets. The verdict says which path the link took.
        for route, words in ((self.LAN, 'over WireGuard, direct LAN'),
                             (self.TAILNET, 'over WireGuard, direct over the tailnet'),
                             ({**self.TAILNET, 'tailnet': False}, 'over WireGuard, direct over the internet'),
                             (self.TURN, 'over WireGuard, via TURN'),
                             ({**self.TURN, 'path': 'turn-tls'}, 'over WireGuard, via TURN over TLS'),
                             (dict(transport='webrtc', path='turn', tailnet=False), 'over WebRTC, via TURN'),
                             (dict(transport='webrtc', path='direct', tailnet=False), 'over WebRTC, direct (peer address unknown)')):
            with self.subTest(route=route):
                r = self.check(self.linked(**route), '--session', 'restored', '--mac-id', 'm1')
                self.assertEqual((r.returncode, r.stdout.strip()), (0, f'signed in (restored), paired and linked with Mac {words}'))
        # An app from before the path fields: the verdict as before, with no path.
        r = self.check(self.linked(), '--session', 'restored', '--mac-id', 'm1')
        self.assertEqual((r.returncode, r.stdout.strip()), (0, 'signed in (restored), paired and linked with Mac'))
        # Up, but no route at the moment (WireGuard before the peer's first datagram authenticated): not yet.
        r = self.check(self.linked(**{**self.LAN, 'path': 'none'}), '--session', 'restored', '--mac-id', 'm1')
        self.assertEqual((r.returncode, r.stdout.strip()), (1, 'linked with Mac, no route at the moment'))

    def test_forbid_tailnet_fails_a_link_over_the_tailnet(self):
        r = self.check(self.linked(**self.TAILNET), '--session', 'restored', '--mac-id', 'm1', '--forbid-tailnet')
        self.assertEqual(r.returncode, 3, r.stdout)
        self.assertIn('linked with Mac over the tailnet (--forbid-tailnet)', r.stdout)
        for route in (self.LAN, {**self.TAILNET, 'tailnet': False}, self.TURN):
            with self.subTest(route=route):
                r = self.check(self.linked(**route), '--session', 'restored', '--mac-id', 'm1', '--forbid-tailnet')
                self.assertEqual(r.returncode, 0, r.stdout)
        # No path to judge (an app from before the path fields) is refused, never passed.
        r = self.check(self.linked(), '--session', 'restored', '--mac-id', 'm1', '--forbid-tailnet')
        self.assertEqual(r.returncode, 3, r.stdout)
        self.assertIn('names no link path', r.stdout)
        # Not linked yet: keep waiting; the path counts once the link is up.
        r = self.check(self.linked(False, **self.TAILNET), '--session', 'restored', '--mac-id', 'm1', '--forbid-tailnet')
        self.assertEqual(r.returncode, 1, r.stdout)

    def test_require_turn_takes_only_a_link_through_turn(self):
        # The relay-only relaunch (CMUX_MOBILE_DEV_RELAY_ONLY=1): the path a phone away from home takes.
        for route in (self.TURN, {**self.TURN, 'path': 'turn-tls'}):
            with self.subTest(route=route):
                r = self.check(self.linked(**route), '--session', 'restored', '--mac-id', 'm1', '--require-turn')
                self.assertEqual(r.returncode, 0, r.stdout)
        for route in (self.LAN, self.TAILNET):
            with self.subTest(route=route):
                r = self.check(self.linked(**route), '--session', 'restored', '--mac-id', 'm1', '--require-turn')
                self.assertEqual(r.returncode, 3, r.stdout)
                self.assertIn('the relay-only launch linked direct', r.stdout)
                self.assertIn('not via TURN', r.stdout)
        # No route at the moment: keep waiting for TURN.
        r = self.check(self.linked(**{**self.TURN, 'path': 'none'}), '--session', 'restored', '--mac-id', 'm1', '--require-turn')
        self.assertEqual(r.returncode, 1, r.stdout)
        r = self.check(self.linked(), '--session', 'restored', '--mac-id', 'm1', '--require-turn')
        self.assertEqual(r.returncode, 3, r.stdout)

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
    def test_a_stale_ffi_pin_keeps_the_default_builder(self):
        # review.sh sent every head whose FFI sources were ahead of app-ffi-pin.json to `--builder mac`
        # (#47722, after pool job 9fa436759cd7bb0f72e3e928 failed "stale FFI" at 0e6e7019af, 2026-11-19).
        # The pool has built such heads since hq#16145/#16334/#16431 (2026-11-21): it links the newest
        # published release with the head's FFI inputs, or cross-builds the library, or the whole
        # xcframework when the headers changed. With FFI commits landing every half hour the pin is behind
        # nearly always (f85c0754cb on 2026-11-23, 198 files behind), so every hand-off queued for the few
        # Macs, for hours, and a Mac fails a head whose headers changed ("the FFI headers at 9edfda1061
        # drop or change declarations of the pinned f85c0754", job cb3e5fa3159ea9806ae980fe). A stale pin
        # and a fresh one submit the same build, and the pin check is not run at all.
        for pin_ok in (False, True):
            with self.subTest(pin_ok=pin_ok), tempfile.TemporaryDirectory() as temp:
                ci = Path(temp) / 'cmux-ci'
                ci.write_text('#!/bin/sh\nfor a in "$@"; do echo "$a"; done > "%s/args"\necho \'{"id": "job123"}\'\n' % temp)
                ci.chmod(0o755)
                pin = Path(temp) / 'pin'
                pin.write_text('#!/bin/sh\ntouch "%s/pin-checked"\nexit %d\n' % (temp, 0 if pin_ok else 1))
                pin.chmod(0o755)
                r = bash(f'''source "{REVIEW}"; SLUG={TAG} SHA={SHA} STATE="{temp}" WORKSPACE=w CMUX_CI="{ci}"
fleet_submit_mac; echo "JOB=$MAC_JOB"''', {'CMUX_CI': str(ci), 'CNX_REVIEW_FFI_PIN_CHECK': str(pin)})
                self.assertIn('JOB=job123', r.stdout, r.stderr)
                args = (Path(temp) / 'args').read_text().splitlines()
                self.assertEqual(args[:2], ['build', 'cmux'])
                self.assertNotIn('--builder', args)
                self.assertNotIn('--reason', args)
                self.assertFalse((Path(temp) / 'pin-checked').exists())
                self.assertNotIn('builds on a Mac', r.stdout)

    def test_a_head_that_changes_nothing_in_the_mac_app_builds_its_base(self):
        # Leo, 2026-11-24: "examine if his recent prs have actually needed dev builds". #53007 changed 7
        # CmuxMobileKit files and queued a full Mac build of its head for 3+ hours. build_select.py says when the
        # Mac app is the base's: the tag gets the base's build, which --any-tag answers from one the fleet made.
        for mac, want_base in (('none', True), ('build', False)):
            with self.subTest(mac=mac), tempfile.TemporaryDirectory() as temp:
                repo = Path(temp) / 'repo'
                repo.mkdir()
                git = lambda *a: subprocess.run(['git', '-C', str(repo), *a], check=True, capture_output=True,
                                                text=True).stdout.strip()
                git('init', '-q')
                git('-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-q', '--allow-empty', '-m', 'base')
                base = git('rev-parse', 'HEAD')
                git('update-ref', 'refs/remotes/origin/feat-cmux-next', base)
                git('-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-q', '--allow-empty', '-m', 'head')
                head = git('rev-parse', 'HEAD')
                select = Path(temp) / 'select.py'
                select.write_text('import json,sys\nprint(json.dumps({"mac": "%s", "ios": "build"}))\n' % mac)
                ci = Path(temp) / 'cmux-ci'
                ci.write_text('#!/bin/sh\nfor a in "$@"; do echo "$a"; done > "%s/args"\necho \'{"id": "job123"}\'\n' % temp)
                ci.chmod(0o755)
                state = Path(temp) / 'state'
                state.mkdir()
                r = bash(f'''source "{REVIEW}"; SLUG={TAG} SHA={head} STATE="{state}" WORKSPACE=w CMUX_CI="{ci}" REPO_ROOT="{repo}"
fleet_submit_mac; echo "JOB=$MAC_JOB"''', {'CMUX_CI': str(ci), 'CNX_REVIEW_BUILD_SELECT': str(select)})
                self.assertIn('JOB=job123', r.stdout, r.stderr)
                args = (Path(temp) / 'args').read_text().splitlines()
                ref = args[args.index('--ref') + 1]
                self.assertEqual(ref, base if want_base else head)
                self.assertEqual('--any-tag' in args, want_base)
                # The fleet client's swap-first default queues nothing for a change it can swap; the hand-off
                # needs the tagged Mac app itself, for its head as for its base (vfix1125, 2026-11-25).
                self.assertIn('--build', args)
                self.assertEqual((state / 'mac-ref').read_text().strip(), ref)

    def test_a_build_the_fleet_does_not_queue_says_what_the_client_said(self):
        # Before: `KeyError: 'id'` on stderr and "printed no job id"; the client's reason was lost.
        with tempfile.TemporaryDirectory() as temp:
            ci = Path(temp) / 'cmux-ci'
            ci.write_text('#!/bin/sh\necho "Nothing queued (swap first): pass --build to build anyway."\n')
            ci.chmod(0o755)
            state = Path(temp) / 'state'
            state.mkdir()
            (state / 'mac-ref').write_text(SHA + '\n')
            r = bash(f'''source "{REVIEW}"; SLUG={TAG} SHA={SHA} STATE="{state}" WORKSPACE=w CMUX_CI="{ci}"
rc=0; fleet_submit_mac || rc=$?; echo "RC=$rc"; echo "REPORT=$REPORT_MAC"''', {'CMUX_CI': str(ci)})
            self.assertIn('RC=1', r.stdout, r.stderr)
            self.assertIn('REPORT=BLOCKED: cmux-ci build cmux queued no job: Nothing queued (swap first)', r.stdout)
            self.assertNotIn('KeyError', r.stderr)
            self.assertFalse((state / 'cmux-job').exists())

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

    def test_urgent_puts_the_simulator_step_first_and_promotes_the_mac_build(self):
        # A hand-off with the person waiting on the phone (2026-11-23): the simulator step sat 2 h in a
        # queue of 126 (step 1e1c4a5c2700774f73411917) and the Mac build 45 min at agent priority (job
        # dc0dd1e42a065339b8191fb2), until both were raised by hand. --urgent does it, with a reason.
        for urgent in (0, 1):
            with self.subTest(urgent=urgent), tempfile.TemporaryDirectory() as temp:
                ci = Path(temp) / 'cmux-ci'
                ci.write_text('#!/bin/sh\necho "$@" >> "%s/calls"\n'
                              '[ "$1" = build ] && echo \'{"id": "job123"}\'\n'
                              '[ "$1" = run ] && echo "cmux-ci: step 0123456789abcdef01234567 (simulator, key k)" >&2\n'
                              'exit 0\n' % temp)
                ci.chmod(0o755)
                r = bash(f'''source "{REVIEW}"; SLUG={TAG} SHA={SHA} STATE="{temp}" WORKSPACE=w URGENT={urgent} CMUX_CI="{ci}"
fleet_start_sim; fleet_finish_sim; fleet_submit_mac; echo "JOB=$MAC_JOB"; echo "RETRY=$(retry_command)"''', {'CMUX_CI': str(ci)})
                self.assertIn('JOB=job123', r.stdout, r.stderr)
                calls = (Path(temp) / 'calls').read_text().splitlines()
                run = next(c for c in calls if c.startswith('run '))
                promote = [c for c in calls if c.startswith('promote ')]
                if urgent:
                    self.assertIn(' --urgent ', run + ' ')
                    self.assertIn('--reason', run)
                    self.assertEqual(len(promote), 1)
                    self.assertTrue(promote[0].startswith('promote job123 --reason '), promote)
                    self.assertIn(' --urgent', r.stdout.split('RETRY=')[1])
                else:
                    self.assertNotIn('--urgent', run)
                    self.assertEqual(promote, [])
                    self.assertNotIn('--urgent', r.stdout.split('RETRY=')[1])

    def test_a_step_that_got_no_sign_in_session_is_sent_once_more(self):
        # Step 1e1c4a5c2700774f73411917 (2026-11-24) ran after 2 h in the queue and failed: "sign-in: no session
        # was delivered within 10m0s" while the controller timed out. Nothing about the build was wrong, so the
        # hand-off sends one new step (a new key) by itself; a second miss is reported as the sign-in delivery.
        # A status read that fails too (the controller timing out) still sends the new step under a new key.
        # Step df827ca8f4eb26596c17942e (2026-11-24) restarted with the controller and then read "sign-in: the
        # controller no longer lists this run as the step's (409 Conflict)": the same lost delivery, other words.
        timeout_line = "sign-in: no session was delivered within 10m0s; the submitter\\'s cmux-ci must follow the step to deliver it"
        conflict_line = "sign-in: the controller no longer lists this run as the step\\'s (409 Conflict)"
        # Step c50f2a91d132270d466e64d8 (2026-11-24): its worker stopped mid-step ("lease lost"), another loss
        # that says nothing about the build.
        lease_line = "cmux-ci: step x failed on cmux23: lease lost: cmux23 stopped renewing the step\\'s lease (worker unreachable or down)"
        for second_ok, status_ok, line in ((True, True, timeout_line), (False, True, timeout_line), (True, False, timeout_line),
                                           (True, True, conflict_line), (False, False, conflict_line),
                                           (True, True, lease_line), (False, True, lease_line)):
            with self.subTest(second_ok=second_ok, status_ok=status_ok, line=line[:30]), tempfile.TemporaryDirectory() as temp:
                ci = Path(temp) / 'cmux-ci'
                status = 'echo \'{"id": "x", "state": "failed"}\'; exit 0' if status_ok else 'echo "cmux-ci: cannot reach the build controller" >&2; exit 69'
                ci.write_text('#!/bin/sh\n'
                              f'if [ "$1" = status ]; then {status}; fi\n'
                              f'[ "$1" = run ] || exit 0\necho "$@" >> "{temp}/args"\n'
                              f'n=$(wc -l < "{temp}/args" | tr -d " ")\n'
                              'echo "cmux-ci: step 00000000000000000000000$n (simulator, key k)" >&2\n'
                              f'if [ "$n" = 1 ] || [ "{0 if second_ok else 1}" = 1 ]; then\n'
                              f'  echo "{line}"\n'
                              '  echo "ci-step k exited 1"; exit 1\nfi\nexit 0\n')
                ci.chmod(0o755)
                r = bash(f'''source "{REVIEW}"; SLUG={TAG} TAG={TAG} SHA={SHA} STATE="{temp}" CMUX_CI="{ci}"
fleet_start_sim; if fleet_finish_sim; then echo "OK STEP=$SIM_STEP"; else echo "SIM=$REPORT_SIM"; fi''', {'CMUX_CI': str(ci)})
                keys = [line.split('--key ')[1].split()[0] for line in (Path(temp) / 'args').read_text().splitlines()]
                base = f'cnx-ios-handoff-{TAG}-{SHA[:12]}'
                self.assertEqual(keys, [base, base + '-r1'], r.stdout + r.stderr)
                lease = line is lease_line
                self.assertIn('its fleet worker stopped mid-step' if lease else 'no sign-in session reached it', r.stdout)
                if second_ok:
                    self.assertIn('OK STEP=000000000000000000000002', r.stdout)
                elif lease:
                    self.assertIn('SIM=BLOCKED: the fleet iPhone build lost its worker mid-step twice', r.stdout)
                else:
                    self.assertIn('SIM=BLOCKED: the fleet iPhone build got no sign-in session from this Mac twice', r.stdout)

    def test_a_superseded_simulator_step_is_not_reported_as_a_failed_build(self):
        # A newer head of the same tag cancels this head's step; the report said "the fleet iPhone build
        # failed (exit 76)" for step f06392e4d16521e2f9762f4b (2026-11-19), though nothing failed.
        with tempfile.TemporaryDirectory() as temp:
            ci = Path(temp) / 'cmux-ci'
            ci.write_text('#!/bin/sh\n'
                          'if [ "$1" = status ]; then echo \'{"id": "f06392e4d16521e2f9762f4b", "state": "cancelled"}\'; exit 0; fi\n'
                          'echo "cmux-ci: step f06392e4d16521e2f9762f4b (simulator, key k)" >&2\n'
                          'echo "cmux-ci: step f06392e4d16521e2f9762f4b superseded by cda830322e8883a86b11d74f (a newer head of this lane)" >&2\n'
                          'exit 76\n')
            ci.chmod(0o755)
            r = bash(f'''source "{REVIEW}"; SLUG={TAG} TAG={TAG} SHA={SHA} STATE="{temp}" CMUX_CI="{ci}"
fleet_start_sim; fleet_finish_sim || echo "SIM=$REPORT_SIM"''', {'CMUX_CI': str(ci)})
            self.assertIn('SIM=BLOCKED: not a failure', r.stdout, r.stderr)
            self.assertIn('superseded by cda830322e8883a86b11d74f', r.stdout)
            self.assertNotIn('build failed', r.stdout)
            self.assertEqual((Path(temp) / 'sim-attempt').read_text().strip(), '1')

    def test_a_rerun_after_a_failed_simulator_step_sends_a_new_step(self):
        # The controller answers a --key with the step it already names, finished or not (hq
        # controller main.go archivedStep), so a rerun at the same head re-attached to the cancelled
        # step 10714bf70abba176377ca4de and reported its failure again (2026-11-18).
        for state, want_new in (('cancelled', True), ('failed', True), ('running', False)):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as temp:
                ci = Path(temp) / 'cmux-ci'
                ci.write_text('#!/bin/sh\n'
                              f'if [ "$1" = status ]; then echo \'{{"id": "0123456789abcdef01234567", "state": "{state}"}}\'; exit 0; fi\n'
                              f'[ "$1" = run ] && echo "$@" >> "{temp}/args"\n'
                              'echo "cmux-ci: step 0123456789abcdef01234567 (simulator, key k)" >&2\nexit 1\n')
                ci.chmod(0o755)
                r = bash(f'''source "{REVIEW}"; SLUG={TAG} SHA={SHA} STATE="{temp}" CMUX_CI="{ci}"
fleet_start_sim; fleet_finish_sim || echo "SIM=$REPORT_SIM"; fleet_start_sim; fleet_finish_sim || true''', {'CMUX_CI': str(ci)})
                keys = [line.split('--key ')[1].split()[0] for line in (Path(temp) / 'args').read_text().splitlines()]
                base = f'cnx-ios-handoff-{TAG}-{SHA[:12]}'
                self.assertEqual(keys[0], base, r.stderr)
                if want_new:
                    self.assertEqual(keys[1], base + '-r1')
                    self.assertIn('(a rerun sends a new step)', r.stdout)
                else:
                    # Only this client stopped following; the step runs on, so the rerun re-attaches.
                    self.assertEqual(keys[1], base)
                    self.assertNotIn('a rerun sends a new step', r.stdout)

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
                           # The shared tag rule (scripts/lib/mobile-attach.sh cmux_attach_validate_dev_tag).
                           (['handoff', 'tag=Bad_Tag'], "'Bad_Tag' is not a canonical tag"),
                           (['handoff', 'tag=bad--tag'], "'bad--tag' is not a canonical tag"),
                           (['handoff', 'tag=default'], 'reserved for the stable app instance'),
                           # The fleet controller's form of the same step.
                           (['shots', 'handoff=Bad_Tag'], 'handoff tag=Bad_Tag refused')):
            with self.subTest(args=args):
                r = subprocess.run(['bash', str(SIM), *args], capture_output=True, text=True,
                                   env=dict(os.environ, CMUX_CI_STEP_KEY='test'), timeout=30)
                self.assertEqual(r.returncode, 2)
                self.assertIn(want, r.stderr)

    def test_handoff_mode_builds_the_tagged_device_app_unsigned(self):
        text = SIM.read_text()
        self.assertIn('"CMUX_MOBILE_TAG=.$handoff_tag" "CMUX_MOBILE_DEV_TAG=.$handoff_tag" "CMUX_MOBILE_DISPLAY_NAME=cmux $handoff_tag"', text)
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

    def test_the_handoff_recording_stops_when_the_check_ends(self):
        # The step hung after its last leg (2026-11-18, step 10714bf70abba176377ca4de): the recorder
        # was started through the simctl() wrapper in the background, a subshell that ignores the
        # SIGINT meant to finish the recording, so `wait` never returned. This runs the handoff
        # check's own start and stop lines against a recorder that only exits on SIGINT.
        text = SIM.read_text()
        start = text.index('  handoff_check() {')
        body = text[start:text.index('\n  }\n', start)].splitlines()
        rec = next(i for i, line in enumerate(body) if 'recordVideo' in line)
        stop = next(line for line in body if 'kill -INT "$rec_pid"' in line)
        self.assertEqual(body[rec + 1].strip(), 'rec_pid=$!')
        with tempfile.TemporaryDirectory() as temp:
            bin_dir = Path(temp) / 'bin'
            bin_dir.mkdir()
            (bin_dir / 'xcrun').write_text(
                '#!/usr/bin/env python3\nimport signal, sys, time\n'
                f'def done(*_):\n    open("{temp}/stopped", "w").write(" ".join(sys.argv[1:])); sys.exit(0)\n'
                'signal.signal(signal.SIGINT, done)\nwhile True: time.sleep(0.1)\n')
            (bin_dir / 'xcrun').chmod(0o755)
            script = (f'PATH="{bin_dir}:$PATH"; sims=S udid=U out="{temp}" work="{temp}"\n'
                      'simctl() { xcrun simctl --set "$sims" "$@"; }\n'
                      f'{body[rec]}\n{body[rec + 1]}\nsleep 1\n{stop}\necho STOPPED')
            try:
                r = bash(script, timeout=45)
            except subprocess.TimeoutExpired:
                self.fail('the handoff check never stopped its recording (wait hung)')
            self.assertIn('STOPPED', r.stdout, r.stderr)
            self.assertTrue((Path(temp) / 'stopped').exists(), 'the recorder never got SIGINT, so recording.mp4 is unfinished')
            self.assertIn('simctl --set S io U recordVideo', (Path(temp) / 'stopped').read_text())

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

    def test_approve_first_starts_the_mac_with_its_auto_approve_off(self):
        with tempfile.TemporaryDirectory() as temp:
            bin_dir = Path(temp) / 'bin'
            bin_dir.mkdir()
            (bin_dir / 'open').write_text('#!/bin/sh\necho "$@" >> "%s/args"\ntouch "%s/running"\n' % (temp, temp))
            (bin_dir / 'open').chmod(0o755)
            (Path(temp) / 'running').write_text('')  # a copy of the tag already runs (auto-approve on)
            r = bash(f'''source "{REVIEW}"; MAC_APP="{temp}/cmux DEV t.app"; MAC_OPEN="{bin_dir}/open"; MAC_SOCKET=/x
PHONE_MODE=approve PERSONAL_ACCOUNT=me@example.com REPORT_MAC=built
mac_py() {{
  echo "$1" >> "{temp}/calls"
  case "$1" in
    wait-socket) [ -e "{temp}/running" ] ;;
    quit) rm -f "{temp}/running" ;;
    account) echo me@example.com ;;
    mac-id) echo mac-tagged ;;
    space) echo dev:t ;;
  esac
}}
mac_apply_backend() {{ :; }}
mac_check_backend() {{ :; }}
mac_start; echo "MAC=$MAC_DEVICE_ID REPORT=$REPORT_MAC"''')
            self.assertEqual(r.returncode, 0, r.stderr)
            args = (Path(temp) / 'args').read_text()
            calls = (Path(temp) / 'calls').read_text().split()
        self.assertIn('MAC=mac-tagged REPORT=built', r.stdout)
        self.assertIn('-g --env CMUX_NEXT_NO_ACTIVATE=1 --env CMUX_NEXT_IPHONE_APPROVE_FIRST=1 ', args)
        self.assertLess(calls.index('quit'), calls.index('account'))

    def test_the_default_mac_launch_keeps_its_auto_approve(self):
        with tempfile.TemporaryDirectory() as temp:
            bin_dir = Path(temp) / 'bin'
            bin_dir.mkdir()
            (bin_dir / 'open').write_text('#!/bin/sh\necho "$@" > "%s/args"\n' % temp)
            (bin_dir / 'open').chmod(0o755)
            for mode in ('paired', 'manual', 'none'):
                r = bash(f'''source "{REVIEW}"; MAC_APP="/x/cmux DEV t.app"; MAC_OPEN="{bin_dir}/open"; PHONE_MODE={mode}
mac_open''')
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertNotIn('APPROVE_FIRST', (Path(temp) / 'args').read_text(), mode)

    def test_review_never_builds_or_boots_a_simulator_here(self):
        text = REVIEW.read_text()
        self.assertIn('--sign-in agent', text)
        self.assertNotIn('ios-agent-signin', text)
        for word in ('xcodebuild', 'simctl', 'swift build', 'cargo '):
            self.assertNotIn(word, text)
        self.assertIn('CMUX_SANCTIONED_IPHONE_INSTALL=1 xcrun devicectl device install app', text)
        self.assertIn('open -g', text)


MAC_PY = ROOT / 'cmux-next-ios/scripts/review_mac.py'


class PhoneReviewFocusTests(unittest.TestCase):
    """The default hand-off names the tagged Mac to the phone (its device id, no secret) and asks the Mac
    for no pairing code: the phone pairs on its own, approved by the tagged Mac's dev auto-approve."""

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
BUNDLE_ID=dev.cmux.mobile.{TAG} STATE="{root}" TAG_STATE="{root}" MAC_SOCKET=/nonexistent SLUG={TAG} SHA={SHA} MAC_DEVICE_ID=mac-tagged
REPO_ROOT="{root}"; mkdir -p "$REPO_ROOT/scripts"; printf '#!/bin/sh\\nexit 0\\n' > "$REPO_ROOT/scripts/ios-device-process.sh"; chmod +x "$REPO_ROOT/scripts/ios-device-process.sh"
mac_py() {{ echo "MAC_PY $1" >> "{root}/calls"; command /usr/bin/python3 -I "{MAC_PY}" "$@"; }}
sign_app() {{ echo '{{}}'; }}
phone_launch_and_check() {{ echo "LAUNCH $3 ${{4:-}}" >> "{root}/calls"; [[ {1 if launch_ok else 0} -eq 1 ]] || {{ PHONE_REASON=x; return 1; }}; PHONE_VERDICT=ok; }}
mac_sees_phone() {{ return 0; }}
if phone_review {PHONE} iPhone; then echo PASS; else echo "FAIL $PHONE_REASON"; fi
"""
            r = bash(script, {'PATH': f"{root / 'bin'}:{os.environ['PATH']}"})
            calls = (root / 'calls').read_text() if (root / 'calls').exists() else ''
            return r, calls

    def test_the_first_launch_names_the_tagged_mac(self):
        r, calls = self.run_phone_review(True)
        self.assertIn('PASS', r.stdout, r.stderr)
        self.assertIn('LAUNCH auto_login mac-tagged', calls)
        self.assertNotIn('MAC_PY pair-url', calls)

    def test_a_failed_launch_fails_the_phone(self):
        r, calls = self.run_phone_review(False)
        self.assertIn('FAIL', r.stdout, r.stderr)
        self.assertIn('LAUNCH auto_login mac-tagged', calls)

    def test_review_mac_offers_no_pairing_code_ops(self):
        text = MAC_PY.read_text()
        self.assertNotIn('pair-url', text)
        self.assertNotIn('mark-used', text)


class FakeMacSocket:
    """A tagged Mac's control socket answering every call (the Settings page's `cmux.settings.host.lists`) with VALUE."""

    def __init__(self, path, value, dialogs=()):
        import socket, threading
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(path)
        self.server.listen(8)
        self.value = value
        self.dialogs = list(dialogs)
        self.methods = []
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            with conn:
                request = json.loads(conn.recv(1 << 16) or b'{}')
                self.methods.append((request.get('method'), request.get('params')))
                if request.get('method') == 'debug.dialog':
                    result = {'dialogs': self.dialogs}
                else:
                    result = {'value': self.value() if callable(self.value) else self.value}
                conn.sendall((json.dumps({'ok': True, 'result': result}) + '\n').encode())

    def close(self):
        self.server.close()


class MacIdTests(unittest.TestCase):
    def test_mac_id_comes_from_the_settings_iphone_card(self):
        with tempfile.TemporaryDirectory(dir='/tmp') as temp:
            sock = os.path.join(temp, 's')
            fake = FakeMacSocket(sock, {'iphone': {'allowed': True, 'phase': 'online', 'device_id': 'mac-abc'}})
            try:
                r = subprocess.run(['python3', str(MAC_PY), 'mac-id', sock, '--timeout', '3'], capture_output=True, text=True)
            finally:
                fake.close()
        self.assertEqual(r.stdout.strip(), 'mac-abc')

    def test_connections_off_says_why(self):
        with tempfile.TemporaryDirectory(dir='/tmp') as temp:
            sock = os.path.join(temp, 's')
            fake = FakeMacSocket(sock, {'iphone': {'allowed': False, 'phase': 'off', 'device_id': None}})
            try:
                r = subprocess.run(['python3', str(MAC_PY), 'mac-id', sock, '--timeout', '2'], capture_output=True, text=True)
            finally:
                fake.close()
        self.assertEqual(r.returncode, 3)
        self.assertIn('iPhone connections are off', r.stderr)


class MacAllowStateTests(unittest.TestCase):
    """review_mac.py allow-state: what the tagged Mac shows for a phone of `--approve-first`, read from its
    Mobile Pairing status (the request waiting, the phone paired) and its open dialogs (the prompt). It
    only reads: it never presses Allow."""

    PROMPT = {'id': 7, 'identifier': 'cmux.dialog.iphonePair', 'title': 'Allow “iPhone” (f0982d96) to connect to this Mac?',
              'visible': True}
    # The Settings page's iPhone card (`iphone` in `cmux.settings.host.lists`, IPhoneHostService+Page.swift) since the
    # Mobile Pairing page went (#48532). It names no Mac: allow-state takes this computer's name (scutil).
    WAITING = {'iphone': {'allowed': True, 'phase': 'online', 'device_id': 'mac-tagged',
        'pending': [{'id': 'link-1', 'title': '“iPhone” wants to connect to this Mac', 'subtitle': 'Signed in as me'}],
        'phones': [{'id': 'presence-1', 'title': 'iPhone · cmux (iOS)', 'paired': False, 'connected': False}]}}
    PAIRED = {'iphone': {'allowed': True, 'phase': 'online', 'device_id': 'mac-tagged',
        'pending': [], 'phones': [{'id': 'presence-1', 'title': 'iPhone · cmux (iOS)', 'paired': True, 'connected': True}]}}

    def state(self, value, dialogs=(), *extra):
        with tempfile.TemporaryDirectory(dir='/tmp') as temp:
            sock = os.path.join(temp, 's')
            fake = FakeMacSocket(sock, value, dialogs)
            # This computer's name, as scutil --get ComputerName says it.
            scutil = Path(temp) / 'scutil'
            scutil.write_text('#!/bin/sh\n[ "$*" = "--get ComputerName" ] && echo "Aziz’s MacBook Pro"\n')
            scutil.chmod(0o755)
            try:
                r = subprocess.run(['python3', str(MAC_PY), 'allow-state', sock, '--phone-id', 'link-1',
                                    '--phone-id', 'presence-1', *extra], capture_output=True, text=True, timeout=30,
                                   env={**os.environ, 'PATH': f"{temp}:{os.environ['PATH']}"})
            finally:
                fake.close()
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads(r.stdout), fake.methods

    def test_a_waiting_request_and_its_open_prompt(self):
        got, methods = self.state(self.WAITING, [self.PROMPT], '--timeout', '2')
        self.assertEqual(got['state'], 'waiting')
        self.assertEqual(got['mac_name'], 'Aziz’s MacBook Pro')
        self.assertEqual(got['prompt'], 'Allow “iPhone” (f0982d96) to connect to this Mac?')
        self.assertEqual(got['request'], '“iPhone” wants to connect to this Mac')
        # Only reads: the dialog list asks for no press, key or dismissal.
        for method, params in methods:
            if method == 'debug.dialog':
                self.assertEqual(params, {})

    def test_a_waiting_request_with_no_prompt_on_screen(self):
        other = {**self.PROMPT, 'identifier': 'cmux.dialog.other', 'title': 'Something else'}
        got, _ = self.state(self.WAITING, [other, {**self.PROMPT, 'visible': False}], '--timeout', '2')
        self.assertEqual((got['state'], got['prompt']), ('waiting', None))

    def test_paired_after_the_allow_and_no_request_at_all(self):
        got, _ = self.state(self.PAIRED, [], '--timeout', '2')
        self.assertEqual((got['state'], got['connected']), ('paired', True))
        empty = {'iphone': {**self.PAIRED['iphone'], 'pending': [], 'phones': []}}
        got, _ = self.state(empty, [], '--timeout', '1')
        self.assertEqual(got['state'], 'none')
        got, _ = self.state({'iphone': {**empty['iphone'], 'allowed': False}}, [], '--timeout', '1')
        self.assertEqual(got['state'], 'off')

    def test_until_answered_waits_for_the_allow(self):
        answers = iter([self.WAITING] * 2 + [self.PAIRED] * 50)
        got, _ = self.state(lambda: next(answers), [self.PROMPT], '--until', 'answered', '--timeout', '20')
        self.assertEqual(got['state'], 'paired')

    def test_until_answered_reports_a_request_that_went_without_an_allow(self):
        # Don't Allow (or the phone signed out): the request is gone and the phone is not paired.
        gone = {'iphone': {**self.WAITING['iphone'], 'pending': []}}
        answers = iter([self.WAITING] + [gone] * 50)
        got, _ = self.state(lambda: next(answers), [], '--until', 'answered', '--timeout', '20')
        self.assertEqual(got['state'], 'gone')

    def test_until_answered_times_out_still_waiting(self):
        got, _ = self.state(self.WAITING, [self.PROMPT], '--until', 'answered', '--timeout', '2')
        self.assertEqual((got['state'], got['prompt']), ('waiting', self.PROMPT['title']))


class MacBuildSpaceTests(unittest.TestCase):
    # review_mac.py space: the space the tagged Mac's requests and hostd carry (BuildIdentity.devTag, then
    # CMUXBuildSpace), read from the installed app; the phone's receipt must name the same one.
    def space(self, plist, name='cmux DEV x'):
        with tempfile.TemporaryDirectory() as temp:
            app = Path(temp) / f'{name}.app'
            (app / 'Contents').mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(plist))
            return subprocess.run(['python3', str(MAC_PY), 'space', str(app)], capture_output=True, text=True)

    def test_a_tagged_dev_build_is_in_its_tags_space(self):
        debug = 'com.cmuxterm.app.debug'
        cases = [
            ({'CFBundleIdentifier': f'{debug}.cu.all', 'LSEnvironment': {'CMUX_TAG': 'cu-all'}}, 'dev:cu-all'),
            ({'CFBundleIdentifier': f'{debug}.x', 'LSEnvironment': {'CMUX_TAG': 'Ios_Scroll V3'}}, 'dev:ios-scroll-v3'),
            ({'CFBundleIdentifier': debug, 'LSEnvironment': {}}, 'dev:x'),  # the `cmux DEV x` name
            ({'CFBundleIdentifier': f'{debug}.x', 'LSEnvironment': {'CMUX_TAG': 'a' * 65}}, 'unusable'),
            ({'CFBundleIdentifier': 'com.cmuxterm.app.nightly.cmux-next'}, ''),
            ({'CFBundleIdentifier': 'com.cmuxterm.app'}, ''),
            ({'CFBundleIdentifier': 'com.cmuxterm.app.rc'}, ''),
        ]
        for plist, want in cases:
            with self.subTest(plist=plist):
                r = self.space(plist)
                self.assertEqual((r.returncode, r.stdout.strip()), (0, want), r.stderr)
        # With no CMUX_TAG and no `cmux DEV <tag>` name, the bundle suffix, sanitized; with neither, none.
        self.assertEqual(self.space({'CFBundleIdentifier': f'{debug}.my.tag'}, name='cmux').stdout.strip(), 'dev:my-tag')
        self.assertEqual(self.space({'CFBundleIdentifier': debug}, name='cmux').stdout.strip(), 'unusable')

    def test_no_app_says_why(self):
        r = subprocess.run(['python3', str(MAC_PY), 'space', '/nonexistent.app'], capture_output=True, text=True)
        self.assertEqual(r.returncode, 1)
        self.assertIn('no readable Info.plist', r.stderr)


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

    def install(self, record, app_exists=True, sealed=False):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            home = root / 'home'
            app = home / f'Library/Developer/Xcode/DerivedData/cmux-{TAG}/Build/Products/Debug/cmux DEV {TAG}.app'
            if app_exists:
                (app / 'Contents').mkdir(parents=True)
                (app / 'Contents/old').write_text('old')
                if sealed:
                    # macOS App Management: nothing inside another app's bundle may be changed or removed,
                    # while the bundle itself can still be renamed (seen 2026-11-18 replacing the tag's app).
                    (app / 'Contents').chmod(0o555)
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
ls "$MAC_APP/Contents"; cat "{root / 'state/mac-installed'}" 2>/dev/null
find "{root}" -type d -exec chmod u+w {{}} + 2>/dev/null"""
            return bash(script).stdout

    def test_this_tools_earlier_head_is_quit_and_replaced(self):
        out = self.install('b' * 40 + ' job1\n')
        self.assertIn('QUIT_CALLED', out)
        self.assertIn('OK', out)
        self.assertIn('new', out)
        self.assertNotIn('old', out)
        self.assertIn(f'{SHA} job2', out)

    def test_an_app_whose_contents_may_not_change_is_still_replaced(self):
        # The tag's earlier app could not be emptied in place (App Management: "Operation not permitted"),
        # so `rm -rf` left half of it and `ditto` into it failed silently: an app with no Info.plist,
        # recorded as installed. The new app goes in beside it and replaces it by renames.
        out = self.install('b' * 40 + ' job1\n', sealed=True)
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

    def test_a_passed_artifact_marks_the_head_reusable_and_a_failed_one_does_not(self):
        for status, marked in (('pass', True), ('fail', False)):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                (root / 'ios').mkdir()
                (root / 'ios/handoff.json').write_text(json.dumps({**self.good, 'simulator': {
                    'status': status, 'device': 'iPhone-17', 'reason': '' if status == 'pass' else 'no receipt'}}))
                (root / 'ios-passed').write_text('older-step\n')
                r = bash(f"""source "{REVIEW}"; set +e; SLUG={TAG} SHA={SHA} STATE="{root}" SIM_STEP=step1
safe_unzip() {{ [ "$2" = "{root}/device" ] && mkdir -p "$2/CmuxMobileApp.app"; :; }}
read_ios_artifact; echo RC=$?""")
                self.assertIn('RC=0', r.stdout, r.stderr)
                marker = root / 'ios-passed'
                self.assertEqual(marker.exists(), marked)
                if marked:
                    self.assertEqual(marker.read_text().strip(), 'step1')

    def test_an_unsafe_zip_or_another_heads_manifest_clears_the_reuse_mark(self):
        # Review of #53313: the mark was cleared only after these early returns, so a stale one survived them and
        # every rerun reused the bad artifact.
        for case in ('unsafe-zip', 'other-head'):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                (root / 'ios').mkdir()
                (root / 'ios/handoff.json').write_text(json.dumps({**self.good, 'source_sha': 'c' * 40}))
                (root / 'ios-passed').write_text('older-step\n')
                unzip = 'return 1' if case == 'unsafe-zip' else ':'
                r = bash(f"""source "{REVIEW}"; set +e; SLUG={TAG} SHA={SHA} STATE="{root}" SIM_STEP=step1
safe_unzip() {{ {unzip}; }}
read_ios_artifact; echo RC=$?""")
                self.assertIn('RC=1', r.stdout, r.stderr)
                self.assertFalse((root / 'ios-passed').exists())

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
    # 'auto-approve': the tagged Mac's dev auto-approve is on (the default hand-off) and the phone
    # dials it; 'allowed': the person pressed Allow on the Mac (--approve-first).
    dials = bool(env.get('DEVICECTL_CHILD_CMUX_MOBILE_FOCUS_MAC'))
    paired = signed_in and ((dials and os.path.exists(os.path.join(root, 'auto-approve')))
                            or os.path.exists(os.path.join(root, 'paired'))
                            or os.path.exists(os.path.join(root, 'allowed')))
    if paired:
        open(os.path.join(root, 'paired'), 'w').write('1')
    receipt = dict(schema=1, nonce=env.get('DEVICECTL_CHILD_CMUX_DOGFOOD_READINESS_NONCE'),
                   client_id=env.get('DEVICECTL_CHILD_CMUX_DOGFOOD_CLIENT_ID'), bundle_id='dev.cmux.mobile.TAGX',
                   written_at='now', git_sha='SHAX', dev_tag='TAGX', signed_in=signed_in, session_source=source,
                   account_email='me@example.com' if signed_in else '', user_id='u1' if signed_in else '',
                   phone_device_ids=['link-1', 'presence-1'] if signed_in else [],
                   cloud_backend='https://cmux-api-development.debussy.workers.dev',
                   # Signed in, the app picks the tagged Mac from the account's Mac list (its focused Mac), linked
                   # only once that Mac let it in; the receipt is written at launch and never again (as the app's
                   # stops after DogfoodReadiness.window).
                   paired_macs=[{'id': 'mac-tagged', 'name': 'cmux DEV x', 'linked': paired}] if signed_in else [])
    if os.path.exists(os.path.join(root, 'phone-space')):
        receipt['build_space'] = open(os.path.join(root, 'phone-space')).read()
    # A relay-only launch links through TURN, and its receipt says so (DogfoodReadiness.Route).
    if env.get('DEVICECTL_CHILD_CMUX_MOBILE_DEV_RELAY_ONLY') == '1':
        for mac in receipt['paired_macs']:
            mac.update(transport='wireguard', path='turn', tailnet=False)
    open(os.path.join(root, 'receipt.json'), 'w').write(json.dumps(receipt))
    sys.exit(0)
if args[:3] == ['devicectl', 'device', 'copy']:
    dest = args[args.index('--destination') + 1]
    open(dest, 'w').write(open(os.path.join(root, 'receipt.json')).read())
    sys.exit(0)
sys.exit(1)
"""

    # What the tagged Mac's allow-state says (review_mac.py allow-state) for --approve-first.
    PROMPT = 'Allow “iPhone” (f0982d96) to connect to this Mac?'
    WAITING = {'state': 'waiting', 'mac_name': 'Aziz’s MacBook Pro', 'request': '“iPhone” wants to connect to this Mac',
               'prompt': PROMPT, 'connected': False}
    ALLOWED = {'state': 'paired', 'mac_name': 'Aziz’s MacBook Pro', 'request': None, 'prompt': None, 'connected': True}

    def review(self, mode, stored=False, allowed=False, mac_space='', phone_space=None, asked=None, answered=None,
               paired_before=False):
        """asked / answered: the tagged Mac's allow-state before and after the wait for the person's Allow
        (`paired` in `answered` is the Allow: the phone is paired from then on). paired_before: the Mac had
        paired this phone before the run."""
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            if allowed:
                (root / 'allowed').write_text('1')
            if mode == 'paired':
                (root / 'auto-approve').write_text('1')
            if paired_before:
                (root / 'paired').write_text('1')
            (root / 'mac-asked').write_text(json.dumps(asked or {'state': 'none', 'mac_name': 'Aziz’s MacBook Pro'}))
            (root / 'mac-answered').write_text(json.dumps(answered or asked or {'state': 'none'}))
            if phone_space is not None:
                (root / 'phone-space').write_text(phone_space)
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
REPO_ROOT="{root}" MAC_SOCKET=/x MAC_DEVICE_ID=mac-tagged CNX_REVIEW_RECEIPT_TIMEOUT=2 CNX_REVIEW_ALLOW_TIMEOUT=2 MAC_BUILD_SPACE="{mac_space}"
PERSONAL_EMAIL=me@example.com PERSONAL_PASSWORD=pw-secret PERSONAL_ACCOUNT=me@example.com
sign_app() {{ echo '{{}}'; }}
mac_py() {{
  case "$1" in
    pair-url|mark-used) echo "PAIR_URL_FETCHED" >> "{root}/calls" ;;
    # The Mac's paired phones: only once this phone paired (or was paired before the run).
    phones)
      if [[ -f "{root}/paired" ]]; then echo '{{"phones": [{{"id": "link-1", "paired": true, "connected": true}}]}}'
      else echo '{{"phones": [{{"id": "presence-1", "paired": false, "connected": false}}]}}'; fi ;;
    # --approve-first: what the Mac shows before the wait (mac-asked) and after it (mac-answered); a paired answer is the Allow.
    allow-state)
      echo "ALLOW_STATE $*" >> "{root}/calls"
      case "$*" in *"--until answered"*) f="{root}/mac-answered" ;; *) f="{root}/mac-asked" ;; esac
      cat "$f" 2>/dev/null || true
      ! grep -q '"state": "paired"' "$f" 2>/dev/null || echo 1 >"{root}/paired" ;;
  esac
}}
if phone_review {PHONE} "iPhone (iPhone 16 Plus, {PHONE})"; then echo "LINE: $PHONE_LINE"; else echo "FAIL: $PHONE_REASON"; fi
"""
            r = bash(script, {'PATH': f"{root / 'bin'}:{os.environ['PATH']}", 'CNX_REVIEW_PATH_SETTLE': '0'})
            launches = [json.loads(l) for l in (root / 'launches').read_text().splitlines()] if (root / 'launches').exists() else []
            calls = (root / 'calls').read_text() if (root / 'calls').exists() else ''
            still_stored = (root / 'stored-session').exists()
            return r, launches, calls, still_stored

    def test_default_signs_in_pairs_and_restores(self):
        r, launches, calls, stored = self.review('paired')
        self.assertIn('LINE: iPhone (iPhone 16 Plus, ', r.stdout, r.stderr)
        self.assertIn('signed in (auto_login), paired and linked with cmux DEV x', r.stdout)
        self.assertIn('credential-free relaunch: signed in (restored), paired and linked', r.stdout)
        self.assertNotIn('PAIR_URL_FETCHED', calls)
        self.assertEqual(launches[0]['env']['DEVICECTL_CHILD_CMUX_MOBILE_FOCUS_MAC'], 'mac-tagged')
        self.assertTrue(stored)
        self.assertEqual(len(launches), 3)
        self.assertNotIn('DEVICECTL_CHILD_CMUX_MOBILE_STACK_EMAIL', launches[1]['env'])
        for launch in launches[:2]:
            self.assertNotIn('DEVICECTL_CHILD_CMUX_MOBILE_DEV_RELAY_ONLY', launch['env'])

    def test_default_ends_with_a_relay_only_relaunch_that_links_via_turn(self):
        # At home the phone links over the LAN (or, with Tailscale on both, the tailnet); a person away from home
        # links through TURN. The hand-off proves that path too, with the relay switch alone.
        r, launches, calls, stored = self.review('paired')
        self.assertIn('; relay-only relaunch (TURN only, as a phone away from home): signed in (restored), paired and '
                      'linked with cmux DEV x over WireGuard, via TURN', r.stdout, r.stderr)
        relay = launches[2]['env']
        self.assertEqual(relay.get('DEVICECTL_CHILD_CMUX_MOBILE_DEV_RELAY_ONLY'), '1')
        for key in ('DEVICECTL_CHILD_CMUX_MOBILE_STACK_EMAIL', 'DEVICECTL_CHILD_CMUX_MOBILE_STACK_PASSWORD',
                    'DEVICECTL_CHILD_CMUX_MOBILE_PAIR_URL'):
            self.assertNotIn(key, relay)

    def test_a_relay_only_relaunch_that_links_direct_is_a_blocker(self):
        # A build that ignores the relay switch still links over the LAN.
        saved = self.PHONE_PY
        self.PHONE_PY = saved.replace("mac.update(transport='wireguard', path='turn', tailnet=False)",
                                      "mac.update(transport='wireguard', path='direct-lan', tailnet=False)")
        try:
            r, *_ = self.review('paired')
        finally:
            self.PHONE_PY = saved
        self.assertIn('FAIL: relay-only launch: the relay-only launch linked direct LAN with cmux DEV x, not via TURN',
                      r.stdout, r.stderr)

    def test_only_the_default_hand_off_relaunches_relay_only(self):
        for mode, kwargs in (('manual', {}), ('approve', {'allowed': True}), ('none', {'stored': True})):
            with self.subTest(mode=mode):
                _, launches, *_ = self.review(mode, **kwargs)
                self.assertTrue(launches)
                for launch in launches:
                    self.assertNotIn('DEVICECTL_CHILD_CMUX_MOBILE_DEV_RELAY_ONLY', launch['env'])

    def test_the_phone_must_be_in_the_tagged_macs_build_space(self):
        # A Demo hand-off build without CMUX_MOBILE_DEV_TAG sat in the default space while its Mac was in
        # dev:<tag>: once the backend lists Macs by space, that phone lists none of its Mac's devices.
        r, *_ = self.review('paired', mac_space=f'dev:{TAG}', phone_space=f'dev:{TAG}')
        self.assertIn('paired and linked with cmux DEV x', r.stdout, r.stderr)
        r, launches, *_ = self.review('paired', mac_space=f'dev:{TAG}', phone_space='')
        self.assertIn(f"FAIL: auto_login launch: the app's build space is 'the default space', not the tagged Mac's 'dev:{TAG}'",
                      r.stdout, r.stderr)
        self.assertEqual(len(launches), 1)  # refused at once, not after the receipt deadline

    def test_manual_pairing_signs_in_and_names_no_mac(self):
        r, launches, calls, stored = self.review('manual')
        self.assertIn('LINE: ', r.stdout, r.stderr)
        self.assertIn('installed, signed in (auto_login); credential-free relaunch: signed in (restored); '
                      'pairing left to you (--manual-pairing)', r.stdout)
        self.assertNotIn('paired and linked', r.stdout)
        self.assertNotIn('PAIR_URL_FETCHED', calls)
        self.assertTrue(stored)
        for launch in launches:
            self.assertNotIn('DEVICECTL_CHILD_CMUX_MOBILE_FOCUS_MAC', launch['env'])
        self.assertEqual(launches[0]['env']['DEVICECTL_CHILD_CMUX_MOBILE_STACK_PASSWORD'], 'pw-secret')
        self.assertNotIn('DEVICECTL_CHILD_CMUX_MOBILE_STACK_PASSWORD', launches[1]['env'])

    def test_approve_first_waits_for_the_macs_allow(self):
        # #52876's flow (restored after #48532 merged an older copy over it): the Mac shows the request and its
        # prompt (asked), then the person's Allow pairs the phone (answered).
        r, launches, calls, stored = self.review('approve', asked=self.WAITING, answered=self.ALLOWED)
        self.assertIn('waiting for Allow on the Mac', r.stdout, r.stderr)
        self.assertIn('LINE: iPhone (iPhone 16 Plus, ', r.stdout, r.stderr)
        self.assertIn('installed, signed in (auto_login), asked the tagged Mac “Aziz’s MacBook Pro” '
                      f'(cmux DEV {TAG}), which showed “{self.PROMPT}”; allowed on the Mac (--approve-first); '
                      'credential-free relaunch: signed in (restored), paired and linked with cmux DEV x; '
                      'Mac sees it paired and connected', r.stdout)
        self.assertNotIn('PAIR_URL_FETCHED', calls)
        self.assertEqual(len(launches), 2)
        self.assertEqual(launches[0]['env']['DEVICECTL_CHILD_CMUX_MOBILE_FOCUS_MAC'], 'mac-tagged')
        self.assertEqual(launches[0]['env']['DEVICECTL_CHILD_CMUX_MOBILE_STACK_PASSWORD'], 'pw-secret')
        self.assertNotIn('DEVICECTL_CHILD_CMUX_MOBILE_STACK_PASSWORD', launches[1]['env'])
        # The Mac is asked with this phone's own device ids, from its receipt.
        self.assertIn('allow-state /x --phone-id link-1 --phone-id presence-1 --until asked', calls)
        self.assertIn('--until answered --timeout 2', calls)

    def test_approve_first_an_allow_after_the_first_receipt_still_links(self):
        # The first launch's receipt says "on the tagged Mac, not linked" and never changes: the app stops
        # writing it 180 s after launch (DogfoodReadiness.window), and the person pressed Allow later. The
        # old flow waited 600 s on that receipt, so an Allow after the third minute could never pass.
        r, launches, *_ = self.review('approve', asked=self.WAITING, answered=self.ALLOWED)
        self.assertIn('LINE: ', r.stdout, r.stderr)
        self.assertIn('credential-free relaunch: signed in (restored), paired and linked with cmux DEV x', r.stdout)
        self.assertEqual([l['env'].get('DEVICECTL_CHILD_CMUX_MOBILE_STACK_EMAIL') for l in launches],
                         ['me@example.com', None])

    def test_approve_first_unattended_says_where_the_prompt_waits_and_what_to_do(self):
        # pv1121e-ap (2026-11-21): nobody at the Mac. The report says the prompt shows on the tagged Mac, by name
        # and app, that the phone waits for it, and what the person does next; never "paired ... not linked".
        r, launches, calls, _ = self.review('approve', asked=self.WAITING)
        self.assertIn('FAIL: waiting for Allow on the Mac: nobody pressed Allow in 2 s. The tagged Mac '
                      f'“Aziz’s MacBook Pro” (cmux DEV {TAG}) shows “{self.PROMPT}” (also under Connection Requests '
                      'in its Settings > Mobile), and the phone is signed in and waiting for it, not linked yet. '
                      'Next: at that Mac, rerun this command and press Allow when the prompt shows',
                      r.stdout, r.stderr)
        self.assertNotIn('paired with the tagged Mac', r.stdout)
        self.assertNotIn('PAIR_URL_FETCHED', calls)
        self.assertEqual(len(launches), 1)
        # Said before the wait, so the person at the Mac knows what to press.
        self.assertIn(f'==> iPhone (iPhone 16 Plus, {PHONE}): waiting for Allow on the Mac: “{self.PROMPT}” is showing '
                      f'on the tagged Mac “Aziz’s MacBook Pro” (cmux DEV {TAG}); press Allow there (up to 2 s)', r.stdout)

    def test_approve_first_a_request_with_no_prompt_on_screen_says_so(self):
        r, *_ = self.review('approve', asked={**self.WAITING, 'prompt': None})
        self.assertIn('FAIL: waiting for Allow on the Mac: nobody pressed Allow in 2 s. The tagged Mac '
                      f'“Aziz’s MacBook Pro” (cmux DEV {TAG}) lists the request under Connection Requests in its '
                      'Settings > Mobile, but shows no Allow prompt (it shows on a window of that app on screen)',
                      r.stdout, r.stderr)

    def test_approve_first_with_no_request_on_the_mac_says_so(self):
        r, launches, *_ = self.review('approve')
        self.assertIn('FAIL: the phone is signed in and on the tagged Mac “Aziz’s MacBook Pro” '
                      f'(cmux DEV {TAG}), but that Mac shows no request from it', r.stdout, r.stderr)
        self.assertEqual(len(launches), 1)

    def test_approve_first_dont_allow_is_reported(self):
        r, *_ = self.review('approve', asked=self.WAITING, answered={**self.WAITING, 'state': 'gone', 'prompt': None})
        self.assertIn('FAIL: the request is gone from the tagged Mac “Aziz’s MacBook Pro” '
                      f"(cmux DEV {TAG}) without an Allow (Don't Allow, or the phone signed out)", r.stdout, r.stderr)

    def test_approve_first_a_phone_paired_before_the_run_is_not_asked(self):
        # The Mac's paired list outlives its relaunch, so a phone it paired earlier links at once: no prompt.
        r, *_ = self.review('approve', paired_before=True, asked=self.ALLOWED)
        self.assertIn('FAIL: not asked: the tagged Mac “Aziz’s MacBook Pro” '
                      f'(cmux DEV {TAG}) had paired this phone before this run, so it linked with no Allow prompt; '
                      'to see the prompt, remove the phone in that Mac\'s Settings > Mobile and rerun', r.stdout, r.stderr)

    def test_approve_first_an_allow_before_the_first_receipt_passes(self):
        # The person was at the Mac and pressed Allow at once: the first receipt is already linked.
        r, launches, *_ = self.review('approve', allowed=True, asked=self.ALLOWED)
        self.assertIn('installed, signed in (auto_login), paired and linked with cmux DEV x (allowed on the Mac '
                      '“Aziz’s MacBook Pro”, --approve-first); credential-free relaunch: signed in (restored), '
                      'paired and linked with cmux DEV x; Mac sees it paired and connected', r.stdout, r.stderr)
        self.assertEqual(len(launches), 2)

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
                        'DEVICECTL_CHILD_CMUX_MOBILE_FOCUS_MAC'):
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
        self.assertIn('MODE=approve RETRY=cmux-next-ios/scripts/review.sh --tag t --approve-first', self.mode('--approve-first'))
        self.assertIn('MODE=none', self.mode('--approve-first', '--no-auth'))
        self.assertIn('MODE=none', self.mode('--no-auth', '--approve-first'))
        # --no-auth implies no pairing, in either order.
        self.assertIn('MODE=none', self.mode('--no-auth', '--manual-pairing'))
        self.assertIn('MODE=none', self.mode('--manual-pairing', '--no-auth'))

    def test_forbid_tailnet_is_kept_in_the_retry(self):
        self.assertIn('RETRY=cmux-next-ios/scripts/review.sh --tag t --forbid-tailnet', self.mode('--forbid-tailnet'))
        self.assertIn('RETRY=cmux-next-ios/scripts/review.sh --tag t --approve-first --forbid-tailnet',
                      self.mode('--forbid-tailnet', '--approve-first'))

    def test_only_the_paired_mode_relaunches_the_mac(self):
        text = REVIEW.read_text()
        self.assertIn('if [[ "$PASSED_PHONES" != " " && "$PHONE_MODE" == paired ]]; then', text)

    def test_the_clear_hook_is_debug_only(self):
        auth = (ROOT / 'cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileAuth/CmuxMobileAuthModel.swift').read_text()
        self.assertIn('clearAuthRequested: isDebug && environment["CMUX_MOBILE_CLEAR_AUTH"] == "1"', auth)
        self.assertIn('let isDebug = false', auth[auth.index('#else'):])
        root_view = (ROOT / 'cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileShell/RootView.swift').read_text()
        at = root_view.index('DogfoodReadiness(auth: auth).writeSignedOut(')
        self.assertGreater(at, root_view.rindex('#if DEBUG', 0, at))
        self.assertGreater(root_view.index('#endif', at), at)
        receipt = (ROOT / 'cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileShell/DogfoodReadiness.swift').read_text()
        self.assertTrue(receipt.startswith('#if DEBUG'))



TRY = ROOT / 'cmux-next-ios/scripts/try.sh'


class TryScriptTests(unittest.TestCase):
    """cmux-next-ios/scripts/try.sh: any PR, branch or commit on the phone as cmux Dev (dev.cmux.mobile.dev)."""

    def test_try_mode_takes_no_arguments_and_tag_dev_is_reserved(self):
        for args, want in ((['try', 'x'], 'try takes no further arguments'),
                           (['handoff', 'tag=dev'], 'tag dev is the cmux Dev app'),
                           (['shots', 'handoff=dev'], 'tag dev is the cmux Dev app')):
            with self.subTest(args=args):
                r = subprocess.run(['bash', str(SIM), *args], capture_output=True, text=True,
                                   env=dict(os.environ, CMUX_CI_STEP_KEY='test'), timeout=30)
                self.assertEqual(r.returncode, 2, r.stderr)
                self.assertIn(want, r.stderr)

    def test_try_mode_builds_the_dev_app_with_no_build_space(self):
        text = SIM.read_text()
        # The controller's shots form reaches it until the controller lists try.
        self.assertIn('"${2:-}" == try=dev', text)
        block = text[text.index('if [[ "$mode" == try ]]; then\n  # The cmux Dev app'):]
        block = block[:block.index('\nfi\n')]
        self.assertIn('"CMUX_MOBILE_TAG=.dev" "CMUX_MOBILE_DISPLAY_NAME=cmux Dev"', block)
        # No dev tag: the person's real data, as the shared Demo build.
        settings = [l for l in block.splitlines() if 'build_settings+=' in l]
        self.assertEqual(len(settings), 1)
        self.assertNotIn('CMUX_MOBILE_DEV_TAG', settings[0])
        self.assertIn("-destination 'generic/platform=iOS'", block)
        self.assertIn('CODE_SIGNING_ALLOWED=NO', block)
        self.assertIn('CmuxMobileApp-Dev-device-unsigned.app.zip', block)

    def test_resolves_a_commit_and_a_branch(self):
        r = bash(f'CNX_TRY_HOME=/tmp/x "{TRY}" {SHA} --dry-run')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(f'commit {SHA[:12]} on every connected iPhone as cmux Dev (dev.cmux.mobile.dev)', r.stdout)
        r = bash(f'"{TRY}" --dry-run')
        self.assertEqual(r.returncode, 2)
        self.assertIn('name a PR, branch or commit', r.stderr)
        r = bash(f'"{TRY}" {SHA} {SHA}')
        self.assertEqual(r.returncode, 2)
        self.assertIn('one target at a time', r.stderr)

    def test_fleet_step_arguments(self):
        for mode, scene in (('try', 'try=dev'), ('handoff', 'handoff=dev')):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temp:
                ci = Path(temp) / 'cmux-ci'
                ci.write_text('#!/bin/sh\n[ "$1" = run ] && echo "$@" > "%s/args"\n'
                              'echo "cmux-ci: step 0123456789abcdef01234567 (simulator, key k)" >&2\n' % temp)
                ci.chmod(0o755)
                r = bash(f'''source "{TRY}"; SHA={SHA} STATE="{temp}" TRY_LABEL=x CMUX_CI="{ci}"; try_fleet {mode}; echo rc=$?''',
                         {'CMUX_CI': str(ci)})
                self.assertIn('rc=0', r.stdout, r.stderr)
                args = (Path(temp) / 'args').read_text().split()
                self.assertEqual(args[:7], ['run', '--class', 'simulator', '--script', 'scripts/ci/cmux-next-ios-sim.sh',
                                            '--ref', SHA])
                self.assertEqual(args[args.index('shots') + 2], scene)
                self.assertIn(f'cnx-ios-try-{mode}-{SHA[:12]}', args)
                self.assertIn('--no-supersede', args)
                # No session: cmux Dev keeps the person's own sign-in; nothing is sealed to the worker.
                self.assertNotIn('--sign-in', args)
                self.assertNotIn('--urgent', args)

    def test_a_key_that_names_an_earlier_step_is_sent_again_under_the_next_key(self):
        # 2026-11-26, a0a4b2d1: the ahead build's step was cancelled, and the controller refuses its key from then on
        # ("409: step_key already names a different step"). The tap sends the step again under the next key.
        with tempfile.TemporaryDirectory() as temp:
            ci = Path(temp) / 'cmux-ci'
            ci.write_text(f"""#!/bin/bash
[ "$1" = run ] || exit 1
for a in "$@"; do case "$a" in cnx-ios-try-*) echo "$a" >> "{temp}/keys";; esac; done
case "$*" in *-r1*) echo "cmux-ci: step 0123456789abcdef01234567 (simulator)" >&2; exit 0;; esac
echo "cmux-ci: controller HTTP 409: step_key already names a different step" >&2; exit 1
""")
            ci.chmod(0o755)
            r = bash(f'''source "{TRY}"; SHA={SHA} STATE="{temp}" TRY_LABEL="PR #1" CMUX_CI="{ci}"
try_script_mode() {{ echo try; }}; try_get_app || echo "fail=$TRY_FAIL"''', {'CMUX_CI': str(ci)})
            keys = (Path(temp) / 'keys').read_text().split()
            self.assertEqual(keys, [f'cnx-ios-try-try-{SHA[:12]}', f'cnx-ios-try-try-{SHA[:12]}-r1'], r.stdout + r.stderr)
            self.assertIn('names an earlier step; sending it again under the next key', r.stdout)
            # Past the submit: the artifact download is next (this fake has none).
            self.assertIn('passed but its artifact did not download', r.stdout)

    def test_urgent_puts_the_step_first_with_a_reason(self):
        with tempfile.TemporaryDirectory() as temp:
            ci = Path(temp) / 'cmux-ci'
            ci.write_text('#!/bin/sh\n[ "$1" = run ] && for a in "$@"; do echo "$a"; done > "%s/args"\n' % temp)
            ci.chmod(0o755)
            bash(f'source "{TRY}"; SHA={SHA} STATE="{temp}" TRY_LABEL="PR #1" TRY_URGENT=1 CMUX_CI="{ci}"; try_fleet try',
                 {'CMUX_CI': str(ci)})
            args = (Path(temp) / 'args').read_text().splitlines()
            self.assertIn('--urgent', args)
            self.assertIn('PR #1', args[args.index('--reason') + 1])

    def test_a_script_without_the_try_mode_builds_through_handoff(self):
        with tempfile.TemporaryDirectory() as temp:
            gh = Path(temp) / 'gh'
            gh.write_text('#!/bin/sh\necho "case \\"$mode\\" in build|handoff) ;; esac"\n')
            gh.chmod(0o755)
            r = bash(f'source "{TRY}"; SHA={"b" * 40} REPO_ROOT="{temp}"; try_script_mode',
                     {'PATH': f'{temp}:{os.environ["PATH"]}'})
            self.assertEqual(r.stdout.strip(), 'handoff', r.stderr)
            gh.write_text('#!/bin/sh\necho "try=dev"\n')
            r = bash(f'source "{TRY}"; SHA={"b" * 40} REPO_ROOT="{temp}"; try_script_mode',
                     {'PATH': f'{temp}:{os.environ["PATH"]}'})
            self.assertEqual(r.stdout.strip(), 'try', r.stderr)

    def test_status_reads_the_history(self):
        with tempfile.TemporaryDirectory() as temp:
            rows = [{'at': '2026-11-21T12:00:00Z', 'result': 'ok', 'sha': SHA, 'target': 'PR #1', 'how': h,
                     'total_s': t, 'build_s': b, 'phones': 1}
                    for h, t, b in (('cached on this Mac (fleet)', 40, 1), ('fleet step s (try mode)', 600, 560))]
            Path(temp, 'history.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in rows))
            r = bash(f'CNX_TRY_HOME="{temp}" "{TRY}" status')
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn('built ahead or cached: n=1 p50=40 s', r.stdout)
            self.assertIn('cold (fleet build): n=1 p50=600 s', r.stdout)

    def test_list_shows_the_iphone_prs_and_their_build_state(self):
        check, fleet = 'cmux Dev try build (ahead)', 'cmux Dev try build (fleet)'
        prs = [
            {'number': 1, 'title': 'ios ahead', 'author': {'login': 'a'}, 'headRefOid': '1' * 40, 'updatedAt': '2026-11-22T01:00:00Z',
             'isDraft': False, 'files': [{'path': 'cmux-next-ios/x.swift'}],
             'statusCheckRollup': [{'name': check, 'status': 'COMPLETED', 'conclusion': 'SUCCESS'}]},
            {'number': 2, 'title': 'web only', 'author': {'login': 'b'}, 'headRefOid': '2' * 40, 'updatedAt': '2026-11-22T02:00:00Z',
             'isDraft': False, 'files': [{'path': 'webviews/x.ts'}], 'statusCheckRollup': []},
            {'number': 3, 'title': 'ios building', 'author': {'login': 'c'}, 'headRefOid': '3' * 40, 'updatedAt': '2026-11-22T03:00:00Z',
             'isDraft': True, 'files': [{'path': 'Packages/iOS/y.swift'}],
             'statusCheckRollup': [{'name': fleet, 'status': 'IN_PROGRESS', 'conclusion': ''}]},
            {'number': 4, 'title': 'ios cached', 'author': {'login': 'd'}, 'headRefOid': '4' * 40, 'updatedAt': '2026-11-22T00:00:00Z',
             'isDraft': False, 'files': [{'path': 'cmux-next-ios/z.swift'}], 'statusCheckRollup': []},
            {'number': 5, 'title': 'ios failed', 'author': {'login': 'e'}, 'headRefOid': '5' * 40, 'updatedAt': '2026-11-21T00:00:00Z',
             'isDraft': False, 'files': [], 'statusCheckRollup': [{'name': check, 'status': 'COMPLETED', 'conclusion': 'FAILURE'}]},
            # The fleet gave no verdict (a host that could not set up): the fleet job is green, no verdict check.
            {'number': 6, 'title': 'ios no verdict', 'author': {'login': 'f'}, 'headRefOid': '6' * 40, 'updatedAt': '2026-11-20T00:00:00Z',
             'isDraft': False, 'files': [{'path': 'cmux-next-ios/w.swift'}],
             'statusCheckRollup': [{'name': fleet, 'status': 'COMPLETED', 'conclusion': 'SUCCESS'},
                                   {'name': check, 'status': 'COMPLETED', 'conclusion': 'SKIPPED'}]},
        ]
        with tempfile.TemporaryDirectory() as temp:
            Path(temp, 'prs.json').write_text(json.dumps(prs))
            gh = Path(temp, 'gh')
            gh.write_text(f'#!/bin/sh\necho "$@" > "{temp}/gh-args"\ncat "{temp}/prs.json"\n')
            gh.chmod(0o755)
            Path(temp, 'cache', '4' * 40, 'device', 'CmuxMobileApp.app').mkdir(parents=True)
            r = bash(f'CNX_TRY_HOME="{temp}/cache" "{TRY}" list', {'PATH': f'{temp}:{os.environ["PATH"]}'})
            self.assertEqual(r.returncode, 0, r.stderr)
            out = json.loads(r.stdout)
            self.assertEqual(out['schema'], 'cmux.ios-try.list.v1')
            self.assertEqual([(p['number'], p['build']) for p in out['prs']],
                             [(3, 'building'), (1, 'ahead'), (4, 'cached'), (5, 'failed'), (6, 'none')])
            self.assertTrue(out['prs'][0]['draft'])
            self.assertIn('--base feat-cmux-next', Path(temp, 'gh-args').read_text())
            gh.write_text('#!/bin/sh\nexit 1\n')
            r = bash(f'CNX_TRY_HOME="{temp}/cache" "{TRY}" list', {'PATH': f'{temp}:{os.environ["PATH"]}'})
            self.assertEqual(r.returncode, 1)
            self.assertIn('could not list pull requests', json.loads(r.stdout)['error'])

    def test_the_ahead_workflow_submits_the_step_try_sh_attaches_to(self):
        # Same script, scene, artifact and key as try_fleet: the controller answers try.sh's submit with that step.
        flow = (ROOT / '.github/workflows/cmux-next-ios-try-ahead.yml').read_text()
        text = TRY.read_text()
        for needle in ('--script scripts/ci/cmux-next-ios-sim.sh', '--artifact artifacts/ios-sim/evidence.zip',
                       '--no-supersede', '--arg shots --arg try=dev'):
            self.assertIn(needle, flow)
        self.assertIn('--key "cnx-ios-try-try-${HEAD_SHA:0:12}"', flow)
        self.assertIn('--key "cnx-ios-try-$mode-${SHA:0:12}', text)
        self.assertIn('--background', flow)
        self.assertIn('name: cmux Dev try build (ahead)', flow)
        self.assertIn('name: cmux Dev try build (fleet)', flow)
        self.assertIn('TRY_AHEAD_CHECK="cmux Dev try build (ahead)"', text)
        self.assertIn('TRY_FLEET_CHECK="cmux Dev try build (fleet)"', text)

    def test_the_ahead_verdict_is_success_only_when_the_fleet_built_it(self):
        # 2026-11-26: the step failed at setup (exit 3) and the one check said success, so the picker said "ahead".
        flow = (ROOT / '.github/workflows/cmux-next-ios-try-ahead.yml').read_text()
        verdict = flow[flow.index('  verdict:'):]
        self.assertIn("needs.build-ahead.outputs.outcome == 'built'", verdict)
        self.assertIn('[[ "$OUTCOME" == built ]]', verdict)
        # The gateway's hook admits only build-ahead; the verdict job there was refused red at 7df749d8.
        self.assertNotIn('CI_EVAL_STEP_GATEWAY', verdict)
        self.assertIn("'cmux-linux'", verdict)
        fleet = flow[:flow.index('  verdict:')]
        self.assertEqual(fleet.count('outcome=built'), 1)
        self.assertIn('if [[ "$state" == done ]]; then echo "outcome=built"', fleet)
        # Only events that bring a new head: a second run at one head cancelled the first one's step (a0a4b2d1).
        self.assertIn('types: [opened, synchronize]\n', flow)

    def test_the_fleet_job_reads_its_verdict_from_the_steps_own_state(self):
        # 2026-11-26, a0a4b2d1: the controller refused the submit (HTTP 409, client exit 1, no step) and the job
        # said the device app did not build. The outcome comes from the step's state and exit code alone.
        flow = (ROOT / '.github/workflows/cmux-next-ios-try-ahead.yml').read_text()
        start = flow.index('        run: |\n', flow.index('id: fleet')) + len('        run: |\n')
        body = textwrap.dedent(flow[start:flow.index('\n\n  verdict:')])
        step = '0123456789abcdef01234567'
        cases = [  # client run output, run exit, status JSON -> outcome, job exit
            ('cmux-ci: controller HTTP 409: step_key already names a different step', 1, '', '', 0),
            # a121379b: the controller was unreachable; the log names no step.
            ('cmux-ci: controller unavailable, no verdict (infra): 9 tries over 600 s', 69, '', '', 0),
            (f'cmux-ci: step {step} queued', 0, '{"state": "done", "exit_code": 0}', 'built', 0),
            (f'cmux-ci: step {step} queued', 1, '{"state": "failed", "exit_code": 1}', 'failed', 1),
            (f'cmux-ci: step {step} queued', 1, '{"state": "failed", "exit_code": 3}', '', 0),
            (f'cmux-ci: step {step} queued', 1, '{"state": "cancelled"}', '', 0),
            (f'cmux-ci: step {step} queued', 1, '', '', 0),  # status unreadable
        ]
        for out, rc, status, outcome, code in cases:
            with self.subTest(out=out, status=status), tempfile.TemporaryDirectory() as temp:
                t = Path(temp)
                client = t / 'cmux-ci'
                (t / 'status.json').write_text(status)
                client.write_text(f"""#!/bin/bash
if [ "$1" = status ]; then [ "$2" = {step} ] && cat "{t}/status.json"; exit 0; fi
echo {shlex.quote(out)} >&2; exit {rc}
""")
                client.chmod(0o755)
                (t / 'out').write_text('')
                env = dict(os.environ, CMUX_CI_CLIENT=str(client), HEAD_SHA='a0a4b2d1fcdb7450ec0bc2078a3e27fb0d70434c',
                           PR='51721', RUNNER_TEMP=temp, RUNNER_NAME='r', GITHUB_OUTPUT=str(t / 'out'),
                           GITHUB_STEP_SUMMARY=str(t / 'summary'))
                # The runner's shell: `bash -e {0}` (the step's own line adds -uo pipefail).
                r = subprocess.run(['bash', '-e', '-c', body], env=env, capture_output=True, text=True, timeout=30)
                self.assertEqual(r.returncode, code, r.stdout + r.stderr)
                self.assertEqual((t / 'out').read_text(), f'outcome={outcome}\n' if outcome else '')
                self.assertEqual('Built ahead' in (t / 'summary').read_text(), outcome == 'built')

    def test_the_fleet_job_detaches_and_the_controller_posts_the_verdict(self):
        # 2026-11-27: the waiting job billed ~26k runner-min/day (1662 min, 38 jobs in 1.5 h), a gateway runner
        # waiting at the lowest class. With --detach the controller posts "cmux Dev try build (ahead)" itself.
        flow = (ROOT / '.github/workflows/cmux-next-ios-try-ahead.yml').read_text()
        self.assertIn("DETACH: ${{ vars.CI_IOS_TRY_AHEAD_DETACH || '1' }}", flow)
        self.assertIn('REPORT_CHECK: cmux Dev try build (ahead)', flow)
        start = flow.index('        run: |\n', flow.index('id: fleet')) + len('        run: |\n')
        body = textwrap.dedent(flow[start:flow.index('\n\n  verdict:')])
        step = '0123456789abcdef01234567'
        for detach, outcome in (('1', 'detached'), ('0', 'built')):
            with self.subTest(detach=detach), tempfile.TemporaryDirectory() as temp:
                t = Path(temp)
                client = t / 'cmux-ci'
                client.write_text(f"""#!/bin/bash
if [ "$1" = run ] && [ "$2" = --help ]; then echo 'usage: run [--report-check NAME] [--detach]'; exit 0; fi
if [ "$1" = status ]; then echo '{{"state": "done", "exit_code": 0}}'; exit 0; fi
echo "$@" > "{t}/args"
case " $* " in *" --detach "*) echo "cmux-ci: step {step} (simulator, key k) detached; check run 'cmux Dev try build (ahead)'";;
  *) echo 'cmux-ci: step {step} queued';; esac
""")
                client.chmod(0o755)
                (t / 'out').write_text('')
                env = dict(os.environ, CMUX_CI_CLIENT=str(client), HEAD_SHA='a0a4b2d1fcdb7450ec0bc2078a3e27fb0d70434c',
                           PR='51721', RUNNER_TEMP=temp, RUNNER_NAME='r', GITHUB_OUTPUT=str(t / 'out'),
                           GITHUB_STEP_SUMMARY=str(t / 'summary'), DETACH=detach, REPORT_CHECK='cmux Dev try build (ahead)')
                r = subprocess.run(['bash', '-e', '-c', body], env=env, capture_output=True, text=True, timeout=30)
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                self.assertEqual((t / 'out').read_text(), f'outcome={outcome}\n')
                args = (t / 'args').read_text()
                self.assertEqual('--report-check cmux Dev try build (ahead) --detach' in args, detach == '1')
        # The verdict job runs only on the waiting path; detached, the controller's check run is the verdict.
        verdict = flow[flow.index('  verdict:'):]
        self.assertNotIn("'detached'", verdict)

    def test_a_try_setup_failure_is_no_verdict(self):
        # The controller posts exit 3 as failure; in try mode the script exits 69 (neutral) for a setup failure.
        sim = (ROOT / 'scripts/ci/cmux-next-ios-sim.sh').read_text()
        self.assertIn('if [[ "$mode" == try && "$result" == 3 ]]; then result=69; fi', sim)

if __name__ == '__main__':
    unittest.main()
