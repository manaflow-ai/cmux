#!/usr/bin/env python3
"""`cmux hooks setup copilot` writes a hooks file Copilot CLI actually loads.

Copilot CLI reads hooks from `~/.copilot/hooks/*.json` (or `$COPILOT_HOME/hooks/`)
as a `version: 1` file with camelCase events and `bash`/`timeoutSec` entries. It
no longer reads `~/.copilot/config.json`, which is where cmux used to write
Claude-style nested groups under PascalCase keys, so a clean install never fired.

Each case runs the real CLI against a temporary home with a fake `copilot`
binary on PATH and no app socket.
"""
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

from claude_teams_test_utils import resolve_cmux_cli

EXPECTED_EVENTS = {"sessionStart", "agentStop", "notification", "sessionEnd", "preToolUse"}
LIFECYCLE_SUBCOMMANDS = {
    "sessionStart": "session-start",
    "agentStop": "stop",
    "notification": "stop",
    "sessionEnd": "session-end",
}


def legacy_config(user_command="echo user-hook"):
    """The shape cmux used to write into ~/.copilot/config.json, plus one user hook."""
    def cmux_group(subcommand):
        return {"hooks": [{"type": "command", "timeout": 5000,
                           "command": f"cmux hooks copilot {subcommand}"}]}
    return {
        "theme": "dark",
        "hooks": {
            "SessionStart": [cmux_group("session-start")],
            "Stop": [cmux_group("stop"),
                     {"hooks": [{"type": "command", "command": user_command, "timeout": 1000}]}],
            "SessionEnd": [cmux_group("session-end")],
        },
    }


class CopilotHooksFileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='cmux-copilot-hooks-')
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.home = root / 'home'
        self.home.mkdir()
        self.copilot_dir = self.home / '.copilot'
        self.copilot_dir.mkdir()
        bin_dir = root / 'bin'
        bin_dir.mkdir()
        fake = bin_dir / 'copilot'
        fake.write_text('#!/bin/sh\nexit 0\n')
        fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
        self.bin_dir = bin_dir
        self.cli = str(resolve_cmux_cli())

    def run_cli(self, *args, extra_env=None):
        env = {
            'HOME': str(self.home),
            'CFFIXED_USER_HOME': str(self.home),
            'PATH': f'{self.bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin',
            'TMPDIR': os.environ.get('TMPDIR', '/tmp'),
            'CMUX_CLI_SENTRY_DISABLED': '1',
            'CMUX_SOCKET_PATH': str(Path(self.temp.name) / 'no-socket.sock'),
        }
        env.update(extra_env or {})
        return subprocess.run([self.cli, *args], env=env, stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=60, check=False)

    def setup(self, *args, **kwargs):
        result = self.run_cli('hooks', 'setup', '--agent', 'copilot', '--yes', *args, **kwargs)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def uninstall(self, **kwargs):
        result = self.run_cli('hooks', 'uninstall', '--agent', 'copilot', '--yes', **kwargs)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def hooks_file(self, copilot_dir=None):
        return (copilot_dir or self.copilot_dir) / 'hooks' / 'cmux.json'

    def assert_native_hooks_file(self, path):
        self.assertTrue(path.is_file(), f'{path} was not written')
        document = json.loads(path.read_text())
        self.assertEqual(document.get('version'), 1, document)
        hooks = document.get('hooks')
        self.assertIsInstance(hooks, dict, document)
        self.assertEqual(set(hooks), EXPECTED_EVENTS, hooks)
        for event, entries in hooks.items():
            self.assertEqual(len(entries), 1, (event, entries))
            entry = entries[0]
            self.assertEqual(entry.get('type'), 'command', (event, entry))
            self.assertIsInstance(entry.get('bash'), str, (event, entry))
            self.assertIn('copilot', entry['bash'], (event, entry))
            self.assertIsInstance(entry.get('timeoutSec'), int, (event, entry))
            self.assertGreater(entry['timeoutSec'], 0, (event, entry))
            for stale_key in ('command', 'timeout', 'hooks'):
                self.assertNotIn(stale_key, entry, (event, entry))
            if event in LIFECYCLE_SUBCOMMANDS:
                self.assertIn(f'hooks enqueue copilot {LIFECYCLE_SUBCOMMANDS[event]}',
                              entry['bash'], (event, entry))
            else:
                self.assertIn('hooks feed --source copilot --event preToolUse',
                              entry['bash'], (event, entry))
        return document

    def test_setup_writes_a_native_hooks_file_and_leaves_config_json_alone(self):
        self.setup()
        self.assert_native_hooks_file(self.hooks_file())
        self.assertFalse((self.copilot_dir / 'config.json').exists(),
                         'setup must not create config.json; Copilot CLI ignores hooks there')

    def test_setup_honors_copilot_home(self):
        override = Path(self.temp.name) / 'copilot-home'
        override.mkdir()
        self.setup(extra_env={'COPILOT_HOME': str(override)})
        self.assert_native_hooks_file(self.hooks_file(override))
        self.assertFalse(self.hooks_file().exists(), 'HOME/.copilot must stay untouched under COPILOT_HOME')

    def test_setup_is_idempotent(self):
        self.setup()
        first = self.hooks_file().read_text()
        result = self.setup()
        self.assertEqual(self.hooks_file().read_text(), first)
        self.assertIn('already up to date', result.stdout + result.stderr)

    def test_setup_removes_legacy_entries_from_config_json_but_keeps_user_hooks(self):
        config = self.copilot_dir / 'config.json'
        config.write_text(json.dumps(legacy_config()))
        self.setup()
        self.assert_native_hooks_file(self.hooks_file())
        migrated = json.loads(config.read_text())
        self.assertEqual(migrated.get('theme'), 'dark', migrated)
        self.assertEqual(set(migrated.get('hooks', {})), {'Stop'}, migrated)
        self.assertEqual(migrated['hooks']['Stop'],
                         [{"hooks": [{"type": "command", "command": "echo user-hook", "timeout": 1000}]}],
                         migrated)

    def test_setup_prunes_the_commands_an_older_cmux_really_wrote(self):
        # The old installer put the same shell dispatch strings this version
        # generates into config.json, as nested groups under PascalCase keys.
        # Harvest them from a fresh install so the fixture is the real thing.
        self.setup()
        installed = json.loads(self.hooks_file().read_text())['hooks']
        session_start = installed['sessionStart'][0]['bash']
        feed = installed['preToolUse'][0]['bash'].replace('--event preToolUse', '--event PreToolUse')
        self.assertIn('hooks enqueue copilot session-start', session_start)
        self.assertIn('--event PreToolUse', feed)
        config = self.copilot_dir / 'config.json'
        config.write_text(json.dumps({
            "hooks": {
                "SessionStart": [{"hooks": [{"type": "command", "command": session_start, "timeout": 5000}]}],
                "PreToolUse": [{"hooks": [{"type": "command", "command": feed, "timeout": 120000}]},
                               {"hooks": [{"type": "command", "command": "echo mine", "timeout": 1000}]}],
            },
        }))
        result = self.setup()
        self.assertIn('Removed 2 cmux hook(s)', result.stdout + result.stderr)
        migrated = json.loads(config.read_text())
        self.assertEqual(migrated, {"hooks": {"PreToolUse": [
            {"hooks": [{"type": "command", "command": "echo mine", "timeout": 1000}]}]}}, migrated)

    def test_uninstall_removes_the_file_and_legacy_entries_only(self):
        self.setup()
        # Written after setup, so it is uninstall's own pruning under test.
        config = self.copilot_dir / 'config.json'
        config.write_text(json.dumps(legacy_config()))
        theirs = self.copilot_dir / 'hooks' / 'theirs.json'
        theirs.write_text('{"version": 1, "hooks": {}}')
        self.uninstall()
        self.assertFalse(self.hooks_file().exists(), 'uninstall must remove hooks/cmux.json')
        self.assertTrue(theirs.is_file(), 'uninstall must not touch other hook files')
        migrated = json.loads(config.read_text())
        self.assertEqual(set(migrated.get('hooks', {})), {'Stop'}, migrated)
        self.assertEqual(migrated['hooks']['Stop'][0]['hooks'][0]['command'], 'echo user-hook', migrated)

    def test_uninstall_leaves_a_cmux_json_it_did_not_write(self):
        foreign = self.hooks_file()
        foreign.parent.mkdir()
        foreign.write_text('{"version": 1, "hooks": {"agentStop": [{"bash": "say done"}]}}')
        self.uninstall()
        self.assertTrue(foreign.is_file(), 'a hooks/cmux.json without cmux commands is not ours to delete')

    def test_uninstall_without_anything_installed_succeeds(self):
        result = self.uninstall()
        self.assertFalse(self.hooks_file().exists())
        self.assertIn('copilot', result.stdout.lower())


if __name__ == '__main__':
    unittest.main()
