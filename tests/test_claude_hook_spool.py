#!/usr/bin/env python3
"""Queued Claude hooks publish to the session spool instead of launching the CLI.

Runs the hook commands from `cmux hooks claude inject-settings` exactly as
Claude Code does (`/bin/sh -c`), against a protocol-faithful local socket and
the real `cmux hooks claude spool-forwarder`. Each hook's CLI reference is a
counting shim, so the test observes how many CLI processes the hooks start.
"""
import fcntl
import json
import os
from pathlib import Path
import shlex
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

from claude_teams_test_utils import resolve_cmux_cli

WORKSPACE = '11111111-1111-1111-1111-111111111111'
SURFACE = '22222222-2222-2222-2222-222222222222'


class ClaudeHookSpoolTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='cl spool-', dir='/tmp')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cli = str(resolve_cmux_cli())
        self.socket_path = self.root / 's'
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(str(self.socket_path))
        self.server.listen(16)
        self.server.settimeout(0.2)
        self.addCleanup(self.server.close)
        self.frames = []
        self.rejected_seq = set()
        self.condition = threading.Condition()
        self.stopping = threading.Event()
        self.addCleanup(self.stopping.set)
        threading.Thread(target=self.accept, daemon=True).start()

        self.launches = self.root / 'cli-launches'
        self.shim = self.root / 'cmux-shim'
        self.shim.write_text(
            f'#!/bin/sh\necho "$*" >> {shlex.quote(str(self.launches))}\n'
            f'exec {shlex.quote(self.cli)} "$@"\n')
        self.shim.chmod(0o755)

        base = {k: v for k, v in os.environ.items() if not k.startswith('CMUX_')}
        settings = subprocess.run([self.cli, 'hooks', 'claude', 'inject-settings'], env=base,
                                  capture_output=True, text=True, timeout=30, check=True)
        hooks = json.loads(settings.stdout)['hooks']
        self.commands = {}
        for event, groups in hooks.items():
            for group in groups:
                for hook in group['hooks']:
                    if 'hooks enqueue claude' in hook['command']:
                        sub = hook['command'].split('hooks enqueue claude ', 1)[1].split()[0]
                        self.commands.setdefault(sub, hook['command'])
        self.assertIn('pre-tool-use', self.commands)
        self.assertIn('stop', self.commands)

        self.spool = self.root / 'spool'
        self.spool.mkdir(mode=0o700)
        self.env = dict(base, CMUX_SOCKET_PATH=str(self.socket_path),
                        CMUX_WORKSPACE_ID=WORKSPACE, CMUX_SURFACE_ID=SURFACE,
                        CMUX_CLAUDE_HOOK_SPOOL_DIR=str(self.spool),
                        CMUX_CLAUDE_HOOK_CMUX_BIN=str(self.shim),
                        CLAUDE_CONFIG_DIR='/tmp/claude config\nwith newline')
        self.owner = None
        self.forwarder_lock = None

    def start_forwarder(self):
        # The forwarder watches its parent, as it watches Claude after the
        # wrapper's exec. Closing the owner's stdin ends the "session".
        owner = '''import os,subprocess,sys
os.environ['CMUX_CLAUDE_PID']=str(os.getpid())
forwarder = subprocess.Popen([sys.argv[1], 'hooks', 'claude', 'spool-forwarder'],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
print(os.getpid(), forwarder.pid, flush=True)
sys.stdin.read()
'''
        env = {k: v for k, v in self.env.items() if k != 'CMUX_CLAUDE_HOOK_CMUX_BIN'}
        self.owner = subprocess.Popen([sys.executable, '-c', owner, self.cli],
                                      stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                      env=env, text=True)
        self.addCleanup(self.stop_owner)
        line = self.owner.stdout.readline()
        self.assertTrue(line.strip(), 'owner exited before reporting its pids')
        _, _ = map(int, line.split())
        deadline = time.monotonic() + 15
        while not (self.spool / 'keys').exists():
            self.assertLess(time.monotonic(), deadline, 'forwarder never published its key list')
            time.sleep(0.02)
        self.forwarder_lock = os.open(self.spool / 'forwarder.lock', os.O_RDWR)

    def stop_owner(self):
        if not self.owner:
            return
        if self.owner.poll() is None:
            self.owner.stdin.close()
            self.owner.wait(timeout=10)
        self.owner.stdout.close()
        if self.forwarder_lock is None:
            return

        # The forwarder holds this lock for its whole life, so taking it proves it exited.
        deadline = time.monotonic() + 10
        while True:
            try:
                fcntl.lockf(self.forwarder_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                os.close(self.forwarder_lock)
                self.forwarder_lock = None
                return
            except BlockingIOError:
                self.assertLess(time.monotonic(), deadline, 'forwarder did not exit after owner exited')
                time.sleep(0.02)

    def accept(self):
        while not self.stopping.is_set():
            try:
                conn, _ = self.server.accept()
            except socket.timeout:
                continue
            except OSError:
                return
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
                if frame.get('method') == 'agent.hook.enqueue' and \
                        json.loads(frame['params']['payload']).get('seq') in self.rejected_seq:
                    # The app's reply when replaceable tool telemetry is already
                    # outstanding for this lane.
                    error = {'code': 'queue_full', 'message': 'Agent hook delivery queue is full'}
                    conn.sendall((json.dumps({'id': frame['id'], 'ok': False, 'error': error}) + '\n').encode())
                    continue
                if 'id' in frame:
                    result = {'queued': True} if frame.get('method') == 'agent.hook.enqueue' else {}
                    conn.sendall((json.dumps({'id': frame['id'], 'ok': True, 'result': result}) + '\n').encode())

    def run_hook(self, subcommand, payload):
        result = subprocess.run(['/bin/sh', '-c', self.commands[subcommand]], env=self.env,
                                input=json.dumps(payload), text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), '{}')

    def admitted(self, count):
        with self.condition:
            ready = self.condition.wait_for(
                lambda: sum(f.get('method') == 'agent.hook.enqueue' for f in self.frames) >= count,
                timeout=20)
        enqueued = [f['params'] for f in self.frames if f.get('method') == 'agent.hook.enqueue']
        self.assertTrue(ready, enqueued)
        return enqueued

    def cli_launches(self):
        return self.launches.read_text().splitlines() if self.launches.exists() else []

    def block_key_publication(self):
        sentinel = self.root / 'sentinel'
        sentinel.write_text('do not follow or delete')
        (self.spool / 'keys.tmp').symlink_to(sentinel)
        return sentinel

    def run_forwarder_to_exit(self):
        # This test process owns the child, just like the wrapper after exec.
        result = subprocess.run(
            [self.cli, 'hooks', 'claude', 'spool-forwarder'],
            env=dict(self.env, CMUX_CLAUDE_PID=str(os.getpid())),
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_failed_key_publication_cleans_uninitialized_spool(self):
        sentinel = self.block_key_publication()
        self.run_forwarder_to_exit()
        self.assertFalse(self.spool.exists())
        self.assertEqual(sentinel.read_text(), 'do not follow or delete')

    def test_lifetime_lock_contention_does_not_cleanup_spool(self):
        for name in ('forwarder.lock', 'drain.lock'):
            (self.spool / name).touch()
        lock = os.open(self.spool / 'forwarder.lock', os.O_RDWR)
        try:
            fcntl.lockf(lock, fcntl.LOCK_EX)
            self.run_forwarder_to_exit()
            self.assertEqual(sorted(p.name for p in self.spool.iterdir()),
                             ['drain.lock', 'forwarder.lock'])
        finally:
            os.close(lock)

    def test_failed_key_publication_preserves_previous_key_list(self):
        sentinel = self.block_key_publication()
        keys = 'CMUX_SURFACE_ID\nCMUX_CLAUDE_PID\n'
        (self.spool / 'keys').write_text(keys)
        self.run_forwarder_to_exit()
        self.assertEqual((self.spool / 'keys').read_text(), keys)
        self.assertEqual(sentinel.read_text(), 'do not follow or delete')

    def test_failed_key_publication_preserves_queued_records(self):
        sentinel = self.block_key_publication()
        record = self.spool / '1.0-1.rec'
        payload = (b'cmux-agent-hook-v1\nclaude\nstop\nCMUX_SURFACE_ID='
                   + SURFACE.encode() + b'\0\0{"session_id":"retained"}')
        record.write_bytes(payload)
        self.run_forwarder_to_exit()
        self.assertEqual(record.read_bytes(), payload)
        self.assertEqual(sentinel.read_text(), 'do not follow or delete')

    def test_live_forwarder_admits_events_in_order_without_cli_launches(self):
        self.start_forwarder()
        sequence = [('prompt-submit', {'prompt': 'hi'}),
                    ('pre-tool-use', {'tool_name': 'Read', 'tool_input': {'file_path': '/tmp/日本語'}}),
                    ('pre-tool-use', {'tool_name': 'Bash', 'tool_input': {'command': "echo 'a\nb'"}}),
                    ('stop', {'stop_hook_active': False})]
        for index, (subcommand, payload) in enumerate(sequence):
            self.run_hook(subcommand, dict(payload, session_id='spool-test', seq=index))
        enqueued = self.admitted(len(sequence))
        self.assertEqual(self.cli_launches(), [], 'spooled hooks must not start the CLI')
        self.assertEqual([p['subcommand'] for p in enqueued], [s for s, _ in sequence])
        self.assertEqual([json.loads(p['payload'])['seq'] for p in enqueued], list(range(len(sequence))))
        self.assertEqual(json.loads(enqueued[1]['payload'])['tool_input']['file_path'], '/tmp/日本語')
        for params in enqueued:
            self.assertEqual(params['agent'], 'claude')
            self.assertEqual(params['environment']['CMUX_SURFACE_ID'], SURFACE)
            self.assertEqual(params['environment']['CLAUDE_CONFIG_DIR'], self.env['CLAUDE_CONFIG_DIR'])
            self.assertTrue(params['environment']['CMUX_CLAUDE_PID'].isdigit())
        self.assertEqual(sorted(p.name for p in self.spool.iterdir() if p.suffix == '.rec'), [])

    def test_a_rejected_event_does_not_stop_the_forwarder(self):
        self.rejected_seq = {1}
        self.start_forwarder()
        for index, subcommand in enumerate(['pre-tool-use', 'pre-tool-use', 'prompt-submit', 'stop']):
            self.run_hook(subcommand, {'session_id': 'spool-test', 'seq': index, 'tool_name': 'Read'})
        enqueued = self.admitted(4)
        self.assertEqual([json.loads(p['payload'])['seq'] for p in enqueued], [0, 1, 2, 3])
        self.assertEqual(self.cli_launches(), [], 'a queue_full reply must not end the forwarder')

    def test_connect_failure_preserves_unsent_event_for_fallback(self):
        self.start_forwarder()
        drain_lock = os.open(self.spool / 'drain.lock', os.O_RDWR)
        try:
            # Keep the live forwarder out until the producer has published and
            # acknowledged the event. Its first connect must then fail.
            fcntl.lockf(drain_lock, fcntl.LOCK_EX)
            offline_socket = self.root / 'offline-socket'
            self.socket_path.rename(offline_socket)
            self.run_hook('stop', {'session_id': 'spool-test', 'seq': 0})
            self.assertEqual(len(list(self.spool.glob('*.rec'))), 1)
            self.assertEqual(self.cli_launches(), [])
        finally:
            os.close(drain_lock)

        forwarder_lock = os.open(self.spool / 'forwarder.lock', os.O_RDWR)
        try:
            deadline = time.monotonic() + 10
            while True:
                try:
                    fcntl.lockf(forwarder_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    self.assertLess(time.monotonic(), deadline, 'forwarder did not exit after connect failure')
                    time.sleep(0.02)
            self.assertEqual(len(list(self.spool.glob('*.rec'))), 1,
                             'a record that was never sent must remain available for fallback')
        finally:
            os.close(forwarder_lock)

        offline_socket.rename(self.socket_path)
        self.run_hook('prompt-submit', {'session_id': 'spool-test', 'seq': 1})
        enqueued = self.admitted(2)
        self.assertEqual([json.loads(p['payload'])['seq'] for p in enqueued], [0, 1])
        self.assertEqual(len(self.cli_launches()), 1)
        self.assertEqual(list(self.spool.glob('*.rec')), [])

    def test_forwarder_removes_the_spool_after_the_session_ends(self):
        self.start_forwarder()
        self.run_hook('stop', {'session_id': 'spool-test'})
        self.admitted(1)
        self.stop_owner()
        deadline = time.monotonic() + 10
        while self.spool.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertFalse(self.spool.exists())
        self.run_hook('session-end', {'session_id': 'spool-test'})
        self.assertEqual(self.admitted(2)[-1]['subcommand'], 'session-end')
        self.assertEqual(len(self.cli_launches()), 1, 'a retired spool falls back to the CLI')

    def test_fallback_admits_an_earlier_spooled_event_first(self):
        # Hold the forwarder lock the way a live forwarder does, publish, then
        # let the "forwarder" die before it drains.
        (self.spool / 'keys').write_text('CMUX_SURFACE_ID\nCMUX_CLAUDE_PID\n')
        for name in ('forwarder.lock', 'drain.lock'):
            (self.spool / name).touch()
        lock = os.open(self.spool / 'forwarder.lock', os.O_RDWR)
        fcntl.lockf(lock, fcntl.LOCK_EX)
        self.run_hook('pre-tool-use', {'session_id': 'spool-test', 'seq': 0})
        self.assertEqual(len([p for p in self.spool.iterdir() if p.suffix == '.rec']), 1)
        os.close(lock)
        self.run_hook('stop', {'session_id': 'spool-test', 'seq': 1})
        enqueued = self.admitted(2)
        self.assertEqual([json.loads(p['payload'])['seq'] for p in enqueued], [0, 1])
        self.assertEqual(len(self.cli_launches()), 1)
        self.assertEqual([p for p in self.spool.iterdir() if p.suffix == '.rec'], [])

    def test_without_a_forwarder_every_event_takes_the_cli_path(self):
        self.run_hook('pre-tool-use', {'session_id': 'spool-test', 'seq': 0})
        self.run_hook('stop', {'session_id': 'spool-test', 'seq': 1})
        enqueued = self.admitted(2)
        self.assertEqual([json.loads(p['payload'])['seq'] for p in enqueued], [0, 1])
        self.assertEqual(len(self.cli_launches()), 2)
        self.assertEqual([p['environment']['CMUX_CLAUDE_PID'] for p in enqueued],
                         [str(os.getpid()), str(os.getpid())],
                         'fallback must retain the hook parent PID, not the intermediate zsh PID')


if __name__ == '__main__':
    unittest.main()
