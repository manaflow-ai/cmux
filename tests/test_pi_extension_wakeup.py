#!/usr/bin/env python3
"""Exercise the generated Pi bridge without a live app or model (Bun or Node 22.18+)."""
import json
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class WakeupTests(unittest.TestCase):
    def test_custom_message_runs_and_continuations(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            extension = root / 'bridge.ts'
            override = os.environ.get('CMUX_TEST_PI_EXTENSION_PATH')
            if override:
                extension.write_text(Path(override).read_text())
            else:
                parts = ['Part1', 'Diagnostics', 'Dispatch', 'Part2']
                extension.write_text('\n'.join(
                    (ROOT / f'CLI/CMUXCLI+PiExtensionSource{part}.swift')
                    .read_text().split('#"""\n', 1)[1].rsplit('"""#', 1)[0]
                    for part in parts))
            cli = root / 'cmux'
            cli.write_text('#!/usr/bin/env python3\nimport json,sys\n'
                           f'with open({str(root / "calls")!r}, "a") as f:\n'
                           ' f.write(json.dumps([sys.argv[1:], json.load(sys.stdin)])+"\\n")\n'
                           'print("{}")\n')
            cli.chmod(0o755)
            (root / 'package.json').write_text(json.dumps({
                'name': '@earendil-works/pi-coding-agent', 'version': '0.85.1', 'type': 'module'}))
            script = root / 'pi'
            script.write_text('''
import bridge from './bridge.ts';
const handlers = new Map();
bridge({on(name, fn) { handlers.set(name, fn); }});
const ctx = {cwd: process.cwd(), isIdle: () => true,
  sessionManager: {getSessionId: () => 'wakeup-test'}};
const emit = (name, event = {}) => handlers.get(name)?.(event, ctx);
const end = (text) => emit('agent_end', {messages: [{role: 'assistant', content: text}]});
await emit('session_start');
// First-ever custom message: no before_agent_start.
await emit('agent_start');
await end('first custom');
await emit('agent_settled');
// Normal input emits both hooks, but must claim only one turn.
await emit('before_agent_start', {prompt: 'normal prompt'});
await emit('agent_start');
await end('intermediate');
// Retry or queued continuation belongs to the same unsettled turn.
await emit('agent_start');
await end('normal final');
await emit('agent_settled');
await emit('agent_settled');
// Idle custom message after settlement must reopen running state.
await emit('agent_start');
await end('wake final');
await emit('agent_settled');
await emit('agent_settled');
await emit('session_shutdown', {reason: 'quit'});
''')
            env = dict(os.environ, CMUX_PI_CMUX_BIN=str(cli),
                       CMUX_SURFACE_ID='00000000-0000-0000-0000-000000008672',
                       CMUX_WORKSPACE_ID='00000000-0000-0000-0000-000000008673')
            env.pop('CMUX_PI_HOOKS_DISABLED', None)
            runtime = shutil.which('bun') or 'node'
            result = subprocess.run([runtime, str(script)], cwd=root, env=env,
                                    capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = [json.loads(line) for line in (root / 'calls').read_text().splitlines()]
            lifecycle = [(args[2], payload) for args, payload in calls
                         if args[:2] == ['hooks', 'pi'] and args[2] in
                         ['prompt-submit', 'notification', 'stop']]
            self.assertEqual([name for name, _ in lifecycle],
                             ['prompt-submit', 'notification', 'stop'] * 3)
            self.assertEqual([p['turn_id'] for _, p in lifecycle],
                             [f'wakeup-test:turn-{i}' for i in range(1, 4) for _ in range(3)])
            self.assertEqual(lifecycle[3][1]['prompt'], 'normal prompt')
            self.assertNotIn('prompt', lifecycle[6][1])
            self.assertIn('wake final', json.dumps(lifecycle[7][1]))


if __name__ == '__main__':
    unittest.main()
