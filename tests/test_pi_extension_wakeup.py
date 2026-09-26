#!/usr/bin/env python3
"""Exercise the generated Pi bridge without a live app or model (Bun or Node 22.18+)."""
import json
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]


def extension_source():
    override = os.environ.get('CMUX_TEST_PI_EXTENSION_PATH')
    if override:
        return Path(override).read_text()
    return '\n'.join(
        (ROOT / f'CLI/CMUXCLI+PiExtensionSource{part}.swift')
        .read_text().split('#"""\n', 1)[1].rsplit('"""#', 1)[0]
        for part in ['Part1', 'Diagnostics', 'Dispatch', 'Part2'])


class WakeupTests(unittest.TestCase):
    def test_turn_id_fallbacks_and_explicit_ids(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'bridge.ts').write_text(extension_source() +
                '\nexport { beginTurn, currentTurnId, finishTurn };\n')
            script = root / 'check.mts'
            script.write_text('''
import assert from 'node:assert/strict';
import {beginTurn, currentTurnId, finishTurn} from './bridge.ts';
const states = new Map();
// Feed or shutdown can arrive without a prior start.
const first = currentTurnId(states, 'helpers', {});
assert.equal(currentTurnId(states, 'helpers', {}), first);
assert.equal(beginTurn(states, 'helpers', {}), first);
assert.equal(finishTurn(states, 'helpers', {}), first);
assert.notEqual(finishTurn(states, 'helpers', {}), first);
for (const key of ['turn_id', 'turnId', 'turnID']) {
  const id = `explicit-${key}`;
  assert.equal(beginTurn(states, 'helpers', {[key]: id}), id);
  assert.equal(currentTurnId(states, 'helpers', {}), id);
  assert.equal(finishTurn(states, 'helpers', {}), id);
}
assert.equal(currentTurnId(states, 'helpers', {turn_id: 'feed-explicit'}), 'feed-explicit');
assert.equal(currentTurnId(states, 'helpers', {}), 'feed-explicit');
assert.equal(finishTurn(states, 'helpers', {turn_id: 'finish-explicit'}), 'finish-explicit');
''')
            result = subprocess.run([shutil.which('bun') or 'node', str(script)], cwd=root,
                                    capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_custom_message_runs_and_continuations(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            extension = root / 'bridge.ts'
            extension.write_text(extension_source())
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
            env = {key: os.environ[key] for key in ('PATH', 'HOME') if key in os.environ}
            env.update(CMUX_PI_CMUX_BIN=str(cli),
                       CMUX_SURFACE_ID='fake-surface', CMUX_WORKSPACE_ID='fake-workspace',
                       CMUX_DEBUG_LOG=str(root / 'diagnostics'))
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
            ids = [p['turn_id'] for _, p in lifecycle]
            self.assertEqual(len(set(ids)), 3)
            self.assertEqual(ids, [ids[i] for i in (0, 3, 6) for _ in range(3)])
            self.assertEqual(lifecycle[3][1]['prompt'], 'normal prompt')
            self.assertNotIn('prompt', lifecycle[6][1])
            self.assertIn('wake final', json.dumps(lifecycle[7][1]))


    def test_lifecycle_and_reload(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'bridge.ts').write_text(extension_source())
            (root / 'package.json').write_text(json.dumps({
                'name': '@earendil-works/pi-coding-agent', 'version': '0.85.1', 'type': 'module'}))
            cli = root / 'fake-cmux'
            cli.write_text('#!/usr/bin/env python3\nimport json,sys\n'
                           'data=sys.stdin.read()\n'
                           f'with open({str(root / "calls")!r}, "a") as f:\n'
                           ' f.write(json.dumps([sys.argv[1:], json.loads(data) if data else None])+"\\n")\n'
                           'print("{}")\n')
            cli.chmod(0o755)
            (root / 'pi').write_text('''
import bridge from './bridge.ts';
const ctx = {cwd: process.cwd(), isIdle: () => true,
  sessionManager: {getSessionId: () => 'same-session'}};
// Factory reconstruction is Pi's reload lifecycle, not a live /reload.
function instance() {
  const handlers = new Map();
  bridge({on(name, fn) { handlers.set(name, fn); }});
  const emit = (name, event = {}) => handlers.get(name)?.(event, ctx);
  const end = text => emit('agent_end', {messages: [{role:'assistant', content:text}]});
  return {emit, end};
}
let {emit, end} = instance();
await emit('session_start');
await emit('before_agent_start', {prompt:'ordinary'});
await emit('agent_start');
await end('intermediate');
await emit('agent_start'); // automatic retry
await end('retried');
await emit('before_agent_start', {prompt:'queued followup'});
await emit('agent_start');
await end('ordinary final');
await emit('agent_settled');
await emit('agent_settled');
await emit('agent_start'); // idle custom-message / Sentinel wakeup
await end('wake final');
await emit('agent_settled');
await emit('agent_settled');
await emit('session_shutdown', {reason:'reload'}); // drains all queued fake calls
({emit, end} = instance());
await emit('session_start', {reason:'reload'});
await emit('before_agent_start', {prompt:'after reload'});
await emit('agent_start');
await end('reload final');
await emit('agent_settled');
await emit('agent_settled');
await emit('before_agent_start', {prompt:'explicit', turn_id:'provided-id'});
await emit('agent_start');
await end('explicit final');
await emit('agent_settled');
await emit('session_shutdown', {reason:'quit'});
''')
            # Do not inherit live socket, launch, diagnostic, or credential configuration.
            env = {key: os.environ[key] for key in ('PATH', 'HOME') if key in os.environ}
            env.update(CMUX_PI_CMUX_BIN=str(cli), CMUX_SURFACE_ID='fake-surface',
                       CMUX_WORKSPACE_ID='fake-workspace', CMUX_DEBUG_LOG=str(root / 'diagnostics'))
            result = subprocess.run([shutil.which('bun') or 'node', str(root / 'pi')], cwd=root, env=env,
                                    capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = [json.loads(line) for line in (root / 'calls').read_text().splitlines()]
            lifecycle = [(args[2], payload) for args, payload in calls
                         if args[:2] == ['hooks', 'pi'] and args[2] != 'session-start']
            self.assertEqual([name for name, _ in lifecycle],
                             ['prompt-submit', 'prompt-submit', 'notification', 'stop'] +
                             ['prompt-submit', 'notification', 'stop'] * 3)
            ids = [p['turn_id'] for _, p in lifecycle]
            ordinary, wake, reload = ids[0], ids[4], ids[7]
            self.assertEqual(len({ordinary, wake, reload}), 3,
                             'Fresh extensions must not reuse persistent receipt keys')
            self.assertEqual(ids, [ordinary]*4 + [wake]*3 + [reload]*3 + ['provided-id']*3)
            for value in (ordinary, wake, reload):
                self.assertEqual(uuid.UUID(value).version, 4)
            notifications = [p for name, p in lifecycle if name == 'notification']
            self.assertEqual([p['message'] for p in notifications],
                             ['ordinary final', 'wake final', 'reload final', 'explicit final'])
            receipts = set()
            visible = []
            for payload in notifications:
                key = (payload['session_id'], payload['turn_id'])
                if key not in receipts:
                    receipts.add(key)
                    visible.append(payload['message'])
            self.assertEqual(visible, ['ordinary final', 'wake final', 'reload final', 'explicit final'])
            self.assertTrue(all(p['cmux_notification_routed'] for name, p in lifecycle if name == 'stop'))


if __name__ == '__main__':
    unittest.main()
