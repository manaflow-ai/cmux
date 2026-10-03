#!/usr/bin/env python3
"""`cmux hooks setup` and `uninstall` reject options they don't understand.

An unknown or valueless option used to be skipped, so the command fell back
to every agent and rewrote their configs. Each case runs the real CLI against
a temporary home with no agent binaries on PATH. Pi hooks install without a
binary, so an unfiltered setup always writes Pi's extension there; a rejected
command must exit non-zero and write nothing.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from claude_teams_test_utils import resolve_cmux_cli


class HooksSetupArgumentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='cmux-hooks-args-')
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name) / 'home'
        self.home.mkdir()
        self.cli = str(resolve_cmux_cli())

    def run_cli(self, *args):
        # A minimal environment so no agent config override points outside
        # the temporary home.
        env = {
            'HOME': str(self.home),
            'CFFIXED_USER_HOME': str(self.home),
            'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
            'TMPDIR': os.environ.get('TMPDIR', '/tmp'),
            'CMUX_CLI_SENTRY_DISABLED': '1',
            'CMUX_SOCKET_PATH': str(Path(self.temp.name) / 'no-socket.sock'),
        }
        # No stdin, so a confirmation prompt can't wait on the test runner.
        return subprocess.run([self.cli, *args], env=env, stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=30, check=False)

    def written_files(self):
        return sorted(str(p.relative_to(self.home)) for p in self.home.rglob('*') if p.is_file())

    def assert_rejected(self, args, message):
        result = self.run_cli(*args)
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, f'{args} should fail:\n{output}')
        self.assertIn(message, output, f'{args}:\n{output}')
        self.assertEqual(self.written_files(), [], f'{args} wrote files:\n{output}')

    def test_unknown_option_is_rejected_before_writing(self):
        for subcommand in ('setup', 'uninstall'):
            for args in (['--agnt', 'codex'], ['--yes', '--agnt=codex']):
                with self.subTest(subcommand=subcommand, args=args):
                    self.assert_rejected(['hooks', subcommand, *args], 'Unknown option --agnt')

    def test_agent_option_requires_a_value(self):
        for args in (['hooks', 'setup', '--agent'],
                     ['hooks', 'setup', '--agent', '--yes'],
                     ['hooks', 'setup', '--agent='],
                     ['hooks', 'uninstall', '--agent']):
            with self.subTest(args=args):
                self.assert_rejected(args, '--agent requires a value')

    def test_repeated_agent_with_different_values_is_rejected(self):
        self.assert_rejected(['hooks', 'setup', '--agent', 'codex', '--agent', 'pi'],
                             '--agent was given more than once with different values')

    def test_legacy_aliases_reject_unknown_options(self):
        for command in ('setup-hooks', 'uninstall-hooks'):
            with self.subTest(command=command):
                self.assert_rejected([command, '--agnt', 'codex'], 'Unknown option --agnt')

    def test_help_prints_usage_without_writing(self):
        for args in (['hooks', 'setup', '--help'], ['hooks', 'uninstall', '-h']):
            with self.subTest(args=args):
                result = self.run_cli(*args)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('Usage: cmux hooks setup', result.stdout)
                self.assertEqual(self.written_files(), [])

    def test_documented_forms_still_work(self):
        for args in (['hooks', 'setup', 'pi', '--yes'],
                     ['hooks', 'setup', '--agent', 'pi', '-y'],
                     ['hooks', 'setup', '--agent=pi'],
                     ['hooks', 'setup', 'pi', '--agent', 'pi'],
                     ['hooks', 'setup', '--uninstall', 'pi']):
            with self.subTest(args=args):
                result = self.run_cli(*args)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('pi', result.stdout)


    def test_agent_name_aliases_still_resolve(self):
        for args, agent in ((['hooks', 'setup', 'agy', '--yes'], 'antigravity'),
                            (['hooks', 'setup', '--agent', 'rovo', '--yes'], 'rovodev'),
                            (['hooks', 'uninstall', '--agent=agy', '--yes'], 'antigravity')):
            with self.subTest(args=args):
                result = self.run_cli(*args)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(f'  {agent}:', result.stdout)


if __name__ == '__main__':
    unittest.main()
