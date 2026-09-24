#!/usr/bin/env python3
"""Managed SSH must keep a cmux-tui-owned workload alive across selection.

Requires a launched tagged app, its bundled CLI in CMUXTERM_CLI, CMUX_TAG,
CMUX_SOCKET_PATH, and a disposable Linux SSH fixture in CMUX_SSH_TEST_HOST.
The fixture needs python3 and a compatible cmux-tui installation. No default
socket, GUI automation, or customer process arguments are used.
"""

import fcntl
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import subprocess
import time

from cmux import cmux


WORKLOAD = r'''
import os, pathlib, sys
token = sys.argv[1]
owners = []
pid = os.getpid()
while pid > 1:
    root = pathlib.Path('/proc') / str(pid)
    owners.append(root.joinpath('comm').read_text().strip())
    fields = root.joinpath('stat').read_text().rsplit(')', 1)[1].split()
    pid = int(fields[1])
print('@' + token + ':pid=' + str(os.getpid()), flush=True)
print('@' + token + ':tui=' + str(int('cmux-tui' in owners)), flush=True)
print('@' + token + ':legacy=' + str(int('cmuxd-remote' in owners)), flush=True)
for line in sys.stdin:
    request = line.strip()
    if request == token + ':quit':
        print('@' + token + ':exited', flush=True)
        break
    if request.startswith(token + ':ping='):
        print('@' + token + ':pong=' + request.split('=', 1)[1]
              + ':pid=' + str(os.getpid()), flush=True)
'''


def main():
    tag = os.environ['CMUX_TAG']
    assert re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)+', tag), 'Use an isolated dev tag'
    socket_path = os.environ['CMUX_SOCKET_PATH']
    assert socket_path == f'/tmp/cmux-debug-{tag}.sock', 'Socket must match the tag'
    cli = Path(os.environ['CMUXTERM_CLI']).resolve(strict=True)
    host = os.environ['CMUX_SSH_TEST_HOST']
    token = secrets.token_hex(4)
    evidence = {'tag': tag, 'socket': socket_path, 'selections': []}
    environment = {key: value for key, value in os.environ.items() if key not in {
        'CMUX_SOCKET', 'CMUX_SOCKET_PASSWORD', 'CMUX_WORKSPACE_ID',
        'CMUX_SURFACE_ID', 'CMUX_TAB_ID', 'CMUX_PANEL_ID', 'CMUXD_UNIX_PATH',
    }}
    lock_path = Path('/tmp/cmux-issue-wave/gui-proof.lock')
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open('a') as lock, cmux(socket_path) as client:
        fcntl.flock(lock, fcntl.LOCK_EX)

        def identify():
            identity = client._call('system.identify')
            assert identity['socket_path'] == socket_path, identity
            assert identity['bundle_identifier'] == (
                'com.cmuxterm.app.debug.' + tag.replace('-', '.')
            ), identity
            bundle = Path(identity['app_bundle_path']).resolve(strict=True)
            assert cli == bundle / 'Contents/Resources/bin/cmux', (cli, bundle)
            return identity

        def mutate(method, params=None):
            identify()
            return client._call(method, params or {})

        def wait_line(surface, expected, timeout=60):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                text = client.read_terminal_text(surface)
                for line in text.splitlines():
                    match = re.fullmatch(expected, line.strip())
                    if match:
                        return match
                time.sleep(0.05)
            # Do not dump the host's terminal contents into test reports.
            raise AssertionError(f'No workload response matching {expected!r}')

        evidence['identity'] = identify()
        window = mutate('window.create')['window_id']
        surface = None
        workspace = None
        try:
            control = client._call('workspace.list', {'window_id': window})['workspaces'][0]['id']
            command = shlex.join(['python3', '-u', '-c', WORKLOAD, token])
            arguments = ['ssh', host, '--window', window, '--no-focus',
                         '--name', f'ssh-tui-selection-{token}', '--command', command]
            if os.environ.get('CMUX_SSH_TEST_PORT'):
                arguments += ['--port', os.environ['CMUX_SSH_TEST_PORT']]
            if os.environ.get('CMUX_SSH_TEST_IDENTITY'):
                arguments += ['--identity', os.environ['CMUX_SSH_TEST_IDENTITY']]
            identify()
            result = subprocess.run(
                [str(cli), '--socket', socket_path, '--json', *arguments],
                env=environment, capture_output=True, text=True, timeout=120,
            )
            assert result.returncode == 0, f'cmux ssh failed (status {result.returncode})'
            created = json.loads(result.stdout)
            workspace = created['workspace_id']
            surfaces = client._call('surface.list', {'workspace_id': workspace})['surfaces']
            assert len(surfaces) == 1, 'Expected one managed SSH workload'
            surface = surfaces[0]['id']
            prefix = '@' + token
            pid = wait_line(surface, prefix + r':pid=(\d+)').group(1)
            tui = wait_line(surface, prefix + r':tui=([01])').group(1)
            legacy = wait_line(surface, prefix + r':legacy=([01])').group(1)
            evidence['ownership'] = {'pid': pid, 'cmux_tui': tui, 'cmuxd_remote': legacy}
            assert (tui, legacy) == ('1', '0'), evidence['ownership']
            for sequence in range(6):
                mutate('workspace.select', {'workspace_id': control})
                started = time.monotonic()
                mutate('workspace.select', {'workspace_id': workspace})
                selected_ms = (time.monotonic() - started) * 1000
                assert identify()['focused']['workspace_id'] == workspace
                assert client._call('surface.list', {'workspace_id': workspace})['surfaces'][0]['id'] == surface
                mutate('surface.send_text', {
                    'workspace_id': workspace, 'surface_id': surface,
                    'text': f'{token}:ping={sequence}\n',
                })
                wait_line(surface, prefix + f':pong={sequence}:pid={pid}', timeout=10)
                evidence['selections'].append({'sequence': sequence, 'select_ms': selected_ms})
            evidence['result'] = 'same cmux-tui-owned process responded after every selection'
        finally:
            try:
                if surface is not None:
                    mutate('surface.send_text', {
                        'workspace_id': workspace, 'surface_id': surface,
                        'text': f'{token}:quit\n',
                    })
                    wait_line(surface, '@' + token + ':exited', timeout=10)
            finally:
                mutate('window.close', {'window_id': window})
                print(json.dumps(evidence, indent=2))


if __name__ == '__main__':
    main()
