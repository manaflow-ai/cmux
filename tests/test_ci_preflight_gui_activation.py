#!/usr/bin/env python3
"""Regressions for scripts/ci/preflight-e2e-gui-activation.py's reading of lsappinfo.

macOS 27 prints `bundleID="..."` where earlier releases printed
`"CFBundleIdentifier"="..."`. The probe read neither, so it compared raw
lsappinfo text with Finder's bundle ID and failed UI jobs on runners whose
Finder was in front. A runner session that LaunchServices cannot see (Finder
runs, but lsappinfo lists none) must fail in seconds instead of letting
xcodebuild die on "Assertion failed: childPID > 0".
"""
import importlib.util
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "ci" / "preflight-e2e-gui-activation.py"
spec = importlib.util.spec_from_file_location("preflight_gui_activation", SCRIPT)
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)

MACOS_27_INFO = (
    '[ NULL ]  ASN:0x0-0x2a02a: (in front) \n'
    '    bundleID="com.apple.finder"\n'
    '    bundle path=[ NULL ] \n'
    '    executable path=[ NULL ] \n'
    ' !cgsConnection !signalled type=[ NULL ]  flavor=[ NULL ]  Version=[ NULL ]  Arch=!!none \n'
)
MACOS_26_INFO = '"CFBundleIdentifier"="com.apple.finder"\n'


def fake_run(table):
    """A run() that answers each command by its first words, else fails."""
    def run(command, timeout=10):
        for prefix, answer in table.items():
            if tuple(command[:len(prefix)]) == prefix:
                return answer
        return 1, '', 'unexpected command'
    return run


class BundleIdTests(unittest.TestCase):
    def test_reads_macos_27_bundle_id(self):
        self.assertEqual(preflight.bundle_id(MACOS_27_INFO), 'com.apple.finder')

    def test_reads_pre_27_bundle_id(self):
        self.assertEqual(preflight.bundle_id(MACOS_26_INFO), 'com.apple.finder')

    def test_unparsed_text_is_no_bundle_id(self):
        self.assertIsNone(preflight.bundle_id('[ NULL ]  ASN:0x0-0x2a02a: (in front) \n'))
        self.assertIsNone(preflight.bundle_id(''))
        self.assertIsNone(preflight.bundle_id(None))
        self.assertIsNone(preflight.bundle_id('bundleID=[ NULL ] \n'))

    def test_front_bundle_on_macos_27_is_finder(self):
        run = fake_run({
            ('lsappinfo', 'front'): (0, 'ASN:0x0-0x2a02a:\n', ''),
            ('lsappinfo', 'info'): (0, MACOS_27_INFO, ''),
        })
        with mock.patch.object(preflight, 'run', run):
            self.assertEqual(preflight.front_bundle([]), preflight.FINDER)

    def test_null_front_is_unreadable(self):
        run = fake_run({('lsappinfo', 'front'): (0, '[ NULL ] \n', '')})
        with mock.patch.object(preflight, 'run', run):
            self.assertIsNone(preflight.front_bundle([]))


class ConsoleFinderHiddenTests(unittest.TestCase):
    def test_finder_running_but_not_listed_is_hidden(self):
        run = fake_run({
            ('pgrep',): (0, '1232\n', ''),
            ('lsappinfo', 'find'): (0, '\n', ''),
        })
        with mock.patch.object(preflight, 'run', run):
            self.assertTrue(preflight.console_finder_hidden([], 'cmux'))

    def test_finder_listed_is_not_hidden(self):
        run = fake_run({
            ('pgrep',): (0, '930\n', ''),
            ('lsappinfo', 'find'): (0, 'ASN:0x0-0x2a02a-"Finder":\n', ''),
        })
        with mock.patch.object(preflight, 'run', run):
            self.assertFalse(preflight.console_finder_hidden([], 'cmux'))

    def test_no_finder_process_proves_nothing(self):
        run = fake_run({('pgrep',): (1, '', ''), ('lsappinfo', 'find'): (0, '', '')})
        with mock.patch.object(preflight, 'run', run):
            self.assertFalse(preflight.console_finder_hidden([], 'cmux'))

    def test_failed_lsappinfo_proves_nothing(self):
        run = fake_run({('pgrep',): (0, '930\n', ''), ('lsappinfo', 'find'): (1, '', 'boom')})
        with mock.patch.object(preflight, 'run', run):
            self.assertFalse(preflight.console_finder_hidden([], 'cmux'))


class MainTests(unittest.TestCase):
    def main_with(self, table):
        base = {
            ('stat',): (0, 'cmux\n', ''),
            ('id', '-u'): (0, '501\n', ''),
            ('sudo', '-n', 'true'): (1, '', 'a password is required'),
            ('automationmodetool',): (0, 'Automation Mode is disabled. This device DOES NOT REQUIRE user '
                                         'authentication to enable Automation Mode.\n', ''),
            ('ioreg',): (1, '', ''),
            ('pmset',): (1, '', ''),
            ('open',): (0, '', ''),
            ('caffeinate',): (0, '', ''),
        }
        base.update(table)
        with mock.patch.object(preflight, 'run', fake_run(base)), \
                mock.patch.object(preflight, 'annotate') as annotate, \
                mock.patch.object(preflight.time, 'sleep'), \
                mock.patch('sys.argv', ['preflight']):
            code = preflight.main()
        return code, [call.args for call in annotate.call_args_list]

    def test_macos_27_runner_with_finder_in_front_passes(self):
        code, notes = self.main_with({
            ('lsappinfo', 'front'): (0, 'ASN:0x0-0x2a02a:\n', ''),
            ('lsappinfo', 'info'): (0, MACOS_27_INFO, ''),
        })
        self.assertEqual(code, 0)
        self.assertEqual(notes, [])

    def test_session_cut_off_from_launchservices_fails_fast(self):
        code, notes = self.main_with({
            ('lsappinfo', 'front'): (0, '[ NULL ] \n', ''),
            ('pgrep',): (0, '1232\n', ''),
            ('lsappinfo', 'find'): (0, '', ''),
        })
        self.assertEqual(code, 1)
        self.assertEqual(notes[0][0], 'error')
        self.assertIn('childPID > 0', notes[0][1])

    def test_unreadable_front_with_finder_listed_only_warns(self):
        code, notes = self.main_with({
            ('lsappinfo', 'front'): (1, '', 'no access'),
            ('pgrep',): (0, '930\n', ''),
            ('lsappinfo', 'find'): (0, 'ASN:0x0-0x2a02a-"Finder":\n', ''),
        })
        self.assertEqual(code, 0)
        self.assertEqual(notes[0][0], 'warning')


if __name__ == '__main__':
    unittest.main()
