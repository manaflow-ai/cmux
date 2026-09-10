#!/usr/bin/env python3
"""Exercise helper submission, artifact identity, and release gates with fake Apple tools."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts/ci/notarize-computer-use-helper.sh'
TOOL = r'''#!/usr/bin/env python3
import hashlib, json, os, pathlib, shutil, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
root = pathlib.Path(os.environ['FIXTURE_ROOT'])
with (root / 'calls').open('a') as f:
    f.write(json.dumps([name, *args]) + '\n')
helper = root / 'cmux.app/Contents/Library/cmux Computer Use.app'
def arches():
    return os.environ.get('FIXTURE_ARCHS', 'arm64 x86_64').split()
def cdhash(bundle, arch):
    override = os.environ.get('FIXTURE_HASH_' + arch)
    if override is not None:
        return override
    data = (pathlib.Path(bundle) / 'Contents/Info.plist').read_bytes()
    return hashlib.sha256(data + arch.encode()).hexdigest()[:40]
if name == 'codesign':
    if '-d' in args:
        arch = args[args.index('-a') + 1] if '-a' in args else 'arm64'
        if os.environ.get('FIXTURE_CODESIGN_FAIL'):
            sys.exit(1)
        print('CDHash=' + cdhash(args[-1], arch), file=sys.stderr)
    elif '--verify' in args and os.environ.get('FIXTURE_VERIFY_FAIL'):
        sys.exit(1)
elif name == 'lipo':
    if os.environ.get('FIXTURE_LIPO_FAIL'):
        sys.exit(1)
    print(' '.join(arches()))
elif name == 'ditto':
    if args[0] == '-c':
        pathlib.Path(args[-1]).write_bytes(b'zip')
    else:
        shutil.copytree(args[0], args[1])
elif name == 'xcrun':
    if args[:2] == ['notarytool', 'submit']:
        (root / 'submitted.json').write_text(json.dumps([
            {'arch': a, 'cdhash': cdhash(helper, a)} for a in arches()
        ]))
        print(json.dumps({'id': 'fixture-submission', 'status': 'In Progress'}))
    elif args[:2] == ['notarytool', 'wait']:
        print(json.dumps({'id': 'fixture-submission', 'status': os.environ.get('FIXTURE_NOTARY_STATUS', 'Accepted')}))
    elif args[:2] == ['notarytool', 'log']:
        entries = json.loads((root / 'submitted.json').read_text())
        entries = [e for e in entries if e['arch'] != os.environ.get('FIXTURE_LOG_OMIT')]
        print(json.dumps({'status': 'Accepted', 'ticketContents': entries}))
    elif args[:2] == ['stapler', 'staple']:
        entries = json.loads((root / 'submitted.json').read_text())
        data = b'fixture-ticket' + b''.join(bytes.fromhex(e['cdhash']) for e in entries if e['arch'] != os.environ.get('FIXTURE_TICKET_OMIT'))
        (pathlib.Path(args[-1]) / 'Contents/CodeResources').write_bytes(data)
    elif args[:2] == ['stapler', 'validate'] and os.environ.get('FIXTURE_VALIDATE_FAIL'):
        sys.exit(1)
elif name == 'spctl':
    if '--ignore-cache' not in args or '--no-cache' not in args:
        print('assessment cache was reused', file=sys.stderr)
        sys.exit(2)
    count_file = root / 'assessments'
    count = int(count_file.read_text()) + 1 if count_file.exists() else 1
    count_file.write_text(str(count))
    if count <= int(os.environ.get('FIXTURE_REJECTS', '0')):
        print('source=Unnotarized Developer ID', file=sys.stderr)
        sys.exit(3)
elif name == 'sign-bundle':
    if os.environ.get('CMUX_SIGN_MODE') != 'main-only':
        sys.exit('helper must not be re-signed after stapling')
'''


class HelperNotarizationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='cmux-notary-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.app = self.root / 'cmux.app'
        self.helper = self.app / 'Contents/Library/cmux Computer Use.app'
        (self.helper / 'Contents/MacOS').mkdir(parents=True)
        (self.helper / 'Contents/MacOS/cmux-cua').write_bytes(b'fixture-executable')
        (self.helper / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleExecutable': 'cmux-cua', 'CFBundleIdentifier': 'com.cmuxterm.cua',
        }))
        self.entitlements = self.root / 'entitlements.plist'
        self.entitlements.write_bytes(plistlib.dumps({}))
        self.state = self.root / 'submission.state'
        # Authentication is stubbed; this credential has no account or network access.
        self.env = dict(os.environ, FIXTURE_ROOT=str(self.root),
                        APPLE_ID='fixture@example.com', APPLE_TEAM_ID='FIXTURETEAM',
                        APPLE_APP_SPECIFIC_PASSWORD='fixture-password',  # noqa: S106  # gitleaks:allow
                        CMUX_HELPER_ENTITLEMENTS=str(self.entitlements),
                        CMUX_GATEKEEPER_ASSESS_DELAY_SECONDS='0',
                        CMUX_GATEKEEPER_ASSESS_ATTEMPTS='3')
        for tool in ('codesign', 'lipo', 'ditto', 'xcrun', 'spctl', 'sign-bundle'):
            path = self.root / tool
            path.write_text(TOOL)
            path.chmod(0o755)
            self.env['CMUX_' + tool.upper().replace('-', '_') + '_TOOL'] = str(path)

    def run_helper(self, *args, success=True, **env):
        # Only the repository script and fixture arguments are executed, without a shell.
        result = subprocess.run([str(SCRIPT), *map(str, args), str(self.app),  # noqa: S603
                                 str(self.entitlements), 'Developer ID Application: Fixture'],
                                env=dict(self.env, **env), text=True,
                                capture_output=True, check=False)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def calls(self, tool, *prefix):
        calls = [json.loads(line) for line in (self.root / 'calls').read_text().splitlines()]
        return [c for c in calls if c[0] == tool and c[1:1 + len(prefix)] == list(prefix)]

    def test_submit_and_finish_preserve_ticket_and_reseal_outer_app(self):
        self.run_helper('--start', self.state)
        self.assertTrue(self.state.exists())
        self.assertFalse(self.calls('xcrun', 'notarytool', 'wait'))
        self.assertFalse(self.calls('xcrun', 'stapler'))
        self.assertNotIn('--wait', self.calls('xcrun', 'notarytool', 'submit')[0])
        submitted = (self.helper / 'Contents/Info.plist').read_bytes()
        self.run_helper('--finish', self.state)
        self.assertFalse(self.state.exists())
        self.assertEqual((self.helper / 'Contents/Info.plist').read_bytes(), submitted)
        self.assertEqual(len(self.calls('xcrun', 'notarytool', 'submit')), 1)
        self.assertEqual(len(self.calls('sign-bundle')), 1)
        self.assertIn('/standalone/cmux Computer Use.app', self.calls('spctl')[0][-1])
        self.assertTrue((self.helper / 'Contents/CodeResources').exists())

    def test_each_submission_has_distinct_signed_hashes(self):
        self.run_helper('--start', self.state)
        first = json.loads((self.root / 'submitted.json').read_text())
        self.run_helper('--start', self.root / 'another.state')
        second = json.loads((self.root / 'submitted.json').read_text())
        self.assertTrue({e['cdhash'] for e in first}.isdisjoint(e['cdhash'] for e in second),
                        'separate notarization submissions must not share any slice CDHash')

    def test_changed_non_native_slice_stops_before_wait(self):
        self.run_helper('--start', self.state)
        self.run_helper('--finish', self.state, success=False, FIXTURE_HASH_x86_64='a' * 40)
        self.assertFalse(self.calls('xcrun', 'notarytool', 'wait'))

    def test_missing_or_broken_slice_discovery_stops_before_upload(self):
        for env in ({'FIXTURE_ARCHS': ''}, {'FIXTURE_LIPO_FAIL': '1'},
                    {'FIXTURE_CODESIGN_FAIL': '1'}, {'FIXTURE_HASH_arm64': 'invalid'}):
            with self.subTest(env=env):
                self.run_helper(success=False, **env)
        self.assertFalse(self.calls('xcrun', 'notarytool', 'submit'))

    def test_incomplete_accepted_ticket_stops_before_staple(self):
        self.run_helper(success=False, FIXTURE_LOG_OMIT='x86_64')
        self.assertFalse(self.calls('xcrun', 'stapler', 'staple'))
        self.assertFalse(self.calls('sign-bundle'))

    def test_incomplete_stapled_ticket_stops_before_gatekeeper(self):
        self.run_helper(success=False, FIXTURE_TICKET_OMIT='x86_64')
        self.assertFalse(self.calls('spctl'))
        self.assertFalse(self.calls('sign-bundle'))

    def test_all_supported_architecture_sets(self):
        for archs in ('arm64', 'x86_64', 'arm64 x86_64'):
            with self.subTest(archs=archs):
                self.run_helper(FIXTURE_ARCHS=archs)

    def test_rejected_notarization_stops_before_staple(self):
        self.run_helper(success=False, FIXTURE_NOTARY_STATUS='Invalid')
        self.assertFalse(self.calls('xcrun', 'stapler'))
        self.assertTrue(self.calls('xcrun', 'notarytool', 'log'))

    def test_invalid_signature_or_ticket_cannot_reseal_host(self):
        for env in ({'FIXTURE_VERIFY_FAIL': '1'}, {'FIXTURE_VALIDATE_FAIL': '1'}):
            with self.subTest(env=env):
                self.run_helper(success=False, **env)
        self.assertFalse(self.calls('sign-bundle'))

    def test_gatekeeper_eventually_accepts(self):
        self.run_helper(FIXTURE_REJECTS='2')
        self.assertEqual(len(self.calls('spctl')), 3)
        self.assertTrue(self.calls('sign-bundle'))

    def test_gatekeeper_rejection_still_blocks_release(self):
        self.run_helper(success=False, FIXTURE_REJECTS='5')
        self.assertEqual(len(self.calls('spctl')), 3)
        self.assertFalse(self.calls('sign-bundle'))

    def test_existing_submission_cannot_be_overwritten(self):
        self.run_helper('--start', self.state)
        state = self.state.read_bytes()
        self.run_helper('--start', self.state, success=False)
        self.assertEqual(self.state.read_bytes(), state)
        self.assertEqual(len(self.calls('xcrun', 'notarytool', 'submit')), 1)


if __name__ == '__main__':
    unittest.main()
