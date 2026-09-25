#!/usr/bin/env python3
"""Exercise the real session forwarder against a protocol-faithful local socket."""
import base64
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

from claude_teams_test_utils import resolve_cmux_cli


class CodexToolFeedWorkerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='cx-feed-', dir='/tmp')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.spool = self.root / 'spool'
        self.spool.mkdir(mode=0o700)
        self.path = self.root / 's'
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(str(self.path))
        self.server.listen(8)
        self.server.settimeout(0.2)
        self.addCleanup(self.server.close)
        self.frames = []
        self.connections = 0
        self.condition = threading.Condition()
        self.stopping = threading.Event()
        self.addCleanup(self.stopping.set)
        threading.Thread(target=self.accept, daemon=True).start()
        env = {k: v for k, v in os.environ.items() if not k.startswith('CMUX_')}
        env.update(CMUX_SOCKET_PATH=str(self.path), CMUX_CODEX_FEED_DIR=str(self.spool),
                   CMUX_WORKSPACE_ID='11111111-1111-1111-1111-111111111111',
                   CMUX_SURFACE_ID='22222222-2222-2222-2222-222222222222')
        # The forwarder observes this owner's PID across exec, exactly as it
        # observes the real wrapper/Codex process. Closing stdin ends the owner.
        owner = '''import os,subprocess,sys
os.environ['CMUX_CODEX_PID']=str(os.getpid())
p=subprocess.Popen([sys.argv[1], 'hooks', 'codex', 'tool-feed-worker'],
                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
print(p.pid, flush=True)
sys.stdin.read()
'''
        self.owner = subprocess.Popen([sys.executable, '-c', owner, str(resolve_cmux_cli())],
                                      stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE, env=env, text=True)
        self.worker_pid = int(self.owner.stdout.readline())
        self.addCleanup(self.stop_owner)

    def stop_owner(self):
        if self.owner.poll() is None:
            self.owner.stdin.close()
            self.owner.wait(timeout=10)
        deadline = time.monotonic() + 10
        while self.spool.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertFalse(self.spool.exists(), 'forwarder must remove its spool after parent exit')
        self.owner.stdout.close()
        self.owner.stderr.close()

    def accept(self):
        while not self.stopping.is_set():
            try:
                conn, _ = self.server.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            self.connections += 1
            threading.Thread(target=self.handle, args=(conn,), daemon=True).start()

    def handle(self, conn):
        with conn, conn.makefile('rb') as stream:
            for line in stream:
                try:
                    frame = json.loads(line)
                except ValueError:
                    conn.sendall(b'OK\n')
                    continue
                with self.condition:
                    self.frames.append(frame)
                    self.condition.notify_all()
                # Like the app, do not reply to one-way telemetry. A stray
                # reply would corrupt the next acknowledged request's stream.
                if 'id' in frame:
                    result = {}
                    if frame.get('method') == 'agent.resolve_delivery_target':
                        result = {'source': 'surface',
                                  'workspace_id': '11111111-1111-1111-1111-111111111111',
                                  'surface_id': '22222222-2222-2222-2222-222222222222'}
                    conn.sendall((json.dumps({'id': frame['id'], 'ok': True, 'result': result}) + '\n').encode())

    def publish(self, slot, event, payload):
        (self.spool / str(slot)).write_bytes(event.encode() + b'\n' + json.dumps(payload).encode() + b'\0')
        (self.spool / f'{slot}.ready').touch()

    def await_feed(self, count):
        with self.condition:
            ready = self.condition.wait_for(
                lambda: sum(f.get('method') == 'feed.push' for f in self.frames) >= count, timeout=15)
        self.assertTrue(ready, self.frames)
        return [f['params']['event'] for f in self.frames if f.get('method') == 'feed.push']

    def test_reuses_connection_across_pre_and_post_tool_batches(self):
        for i in range(8):
            event = 'pre-tool-use' if i % 2 == 0 else 'post-tool-use'
            self.publish(i, event, {'session_id': 'worker-test', 'tool_name': 'Read',
                                   'request_id': str(i), 'tool_input': {'file_path': '/tmp/日本語'}})
            events = self.await_feed(i + 1)
            self.assertEqual(events[-1]['hook_event_name'], 'PreToolUse' if i % 2 == 0 else 'PostToolUse')
            self.assertEqual(events[-1]['session_id'], 'cmux-feed-v1:' +
                             base64.b64encode(b'codex').decode() + ':' +
                             base64.b64encode(b'worker-test').decode())
        self.assertEqual(self.connections, 1, 'all tool events must share one socket')
        self.assertEqual(len({e['_ppid'] for e in events}), 1)
        self.assertEqual(events[0]['_ppid'], self.owner.pid)

    def test_previously_installed_commands_use_the_worker_connection(self):
        env = {k: v for k, v in os.environ.items() if not k.startswith('CMUX_')}
        env.update(CMUX_SOCKET_PATH=str(self.path), CMUX_CODEX_FEED_DIR=str(self.spool),
                   CMUX_SURFACE_ID='22222222-2222-2222-2222-222222222222')
        commands = [['hooks', 'enqueue', 'codex', 'pre-tool-use'],
                    ['hooks', 'feed', '--source', 'codex', '--event', 'PostToolUse'],
                    ['feed-hook', '--source', 'codex', '--event', 'PreToolUse']]
        for index, command in enumerate(commands):
            result = subprocess.run([str(resolve_cmux_cli()), *command], env=env,
                                    input='{"session_id":"legacy","tool_name":"Read"}',
                                    text=True, capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, '{}\n')
            self.await_feed(index + 1)
        self.assertEqual(self.connections, 1)

    def test_completion_without_request_identity_needs_only_one_way_telemetry(self):
        self.publish(0, 'post-tool-use', {'session_id': 'worker-test', 'tool_name': 'Read'})
        self.await_feed(1)
        self.assertEqual([f['method'] for f in self.frames], ['feed.push'])

    def test_spool_event_cannot_dispatch_an_approval_or_lifecycle_hook(self):
        self.publish(0, 'pre-tool-use', {'session_id': 'worker-test',
                                       'hook_event_name': 'PermissionRequest', 'tool_name': 'Bash'})
        events = self.await_feed(1)
        self.assertEqual(events[0]['hook_event_name'], 'PreToolUse')
        self.assertEqual([f['method'] for f in self.frames], ['feed.push'])


if __name__ == '__main__':
    unittest.main()
