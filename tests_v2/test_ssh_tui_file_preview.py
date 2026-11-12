#!/usr/bin/env python3
"""Click a file printed by an actual managed, cmux-tui-owned SSH workload.

Requires a disposable Linux CMUX_SSH_TEST_HOST and a launched tagged app with
the existing terminal Cmd-click harness enabled for `preview file.txt` in grid
mode. CMUX_PREVIEW_HARNESS_STATE and CMUX_PREVIEW_HARNESS_COMMAND identify its
state/command files. CMUXTERM_CLI must be the tagged app's bundled CLI.
No raw-SSH or manually configured remote-workspace substitute is accepted.
"""

import fcntl
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import subprocess
import tempfile
import time

from cmux import cmux


WORKLOAD = r'''
import os, pathlib, shutil, socket, sys, tempfile
token = sys.argv[1]
directory = tempfile.mkdtemp(prefix='cmux-preview-' + token + '-')
owners = []
pid = os.getpid()
while pid > 1:
    root = pathlib.Path('/proc') / str(pid)
    owners.append(pathlib.Path(os.readlink(str(root / 'exe')).removesuffix(' (deleted)')).name)
    pid = int(root.joinpath('stat').read_text().rsplit(')', 1)[1].split()[1])
try:
    os.chdir(directory)
    pathlib.Path('preview file.txt').write_text('REMOTE_PREVIEW_' + token + '\n')
    print('\033[2J\033[H', end='')
    print('\033]7;file://' + socket.gethostname() + directory + '\033\\', end='')
    for _ in range(48):
        print('preview file.txt    OtherFile')
    print('@' + token + ':cwd=' + directory)
    print('@' + token + ':tui=' + str(int('cmux-tui' in owners)))
    print('@' + token + ':legacy=' + str(int('cmuxd-remote' in owners)), flush=True)
    for line in sys.stdin:
        if line.strip() == token + ':quit':
            break
finally:
    shutil.rmtree(directory)
    print('@' + token + ':cleaned', flush=True)
    for line in sys.stdin:
        if line.strip() == token + ':exit':
            break
'''


def main():
    tag = os.environ['CMUX_TAG']
    assert re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)+', tag)
    socket_path = os.environ['CMUX_SOCKET_PATH']
    assert socket_path == f'/tmp/cmux-debug-{tag}.sock'
    cli = Path(os.environ['CMUXTERM_CLI']).resolve(strict=True)
    bundle = cli.parents[3]
    assert bundle.name == f'cmux DEV {tag}.app'
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    state_path = Path(os.environ['CMUX_PREVIEW_HARNESS_STATE'])
    command_path = Path(os.environ['CMUX_PREVIEW_HARNESS_COMMAND'])
    token = secrets.token_hex(8)
    evidence = {'tag': tag, 'socket': socket_path, 'identity_checks': []}
    lock_path = Path('/tmp/cmux-issue-wave/gui-proof.lock')
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    environment = {k: v for k, v in os.environ.items() if not k.startswith('CMUX_')}
    environment['CMUX_SOCKET_PATH'] = socket_path

    with lock_path.open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)

        def call(method, params=None):
            # Bootstrap can outlast the server's idle-connection deadline.
            # Never retry an ambiguous mutation; use a fresh connection per request.
            with cmux(socket_path) as request:
                return request._call(method, params)

        def identify():
            result = call('system.identify')
            assert result['socket_path'] == socket_path
            assert result['bundle_identifier'] == info['CFBundleIdentifier']
            assert Path(result['app_bundle_path']).resolve() == bundle
            evidence['identity_checks'].append(result)
            return result

        def mutate(method, params):
            identify()
            return call(method, params)

        def wait_for(predicate, timeout=60):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                value = predicate()
                if value:
                    return value
                time.sleep(0.3)
            raise AssertionError('Timed out waiting for managed SSH preview assertion')

        def line(pattern):
            with cmux(socket_path) as request:
                text = request.read_terminal_text(surface)
            return next((match for value in text.splitlines()
                         if (match := re.fullmatch(pattern, value.strip()))), None)

        window = mutate('window.create', {})['window_id']
        workspace = surface = None
        try:
            args = ['ssh', os.environ['CMUX_SSH_TEST_HOST'], '--window', window,
                    '--name', f'ssh-preview-{token}', '--command',
                    shlex.join(['python3', '-u', '-c', WORKLOAD, token])]
            for variable, option in [('CMUX_SSH_TEST_PORT', '--port'),
                                     ('CMUX_SSH_TEST_IDENTITY', '--identity')]:
                if os.environ.get(variable):
                    args += [option, os.environ[variable]]
            ssh_options = json.loads(os.environ.get('CMUX_SSH_TEST_OPTIONS_JSON', '[]'))
            assert isinstance(ssh_options, list) and all(isinstance(value, str) for value in ssh_options)
            for value in ssh_options:
                args += ['--ssh-option', value]
            identify()
            launched = subprocess.run([str(cli), '--socket', socket_path, '--id-format', 'uuids', '--json', *args],
                                      env=environment, capture_output=True, text=True, timeout=120)
            assert launched.returncode == 0, f'cmux ssh exited {launched.returncode}'
            workspace = json.loads(launched.stdout)['workspace_id']
            rows = call('surface.list', {'workspace_id': workspace})['surfaces']
            assert len(rows) == 1
            surface = rows[0]['id']
            cwd = wait_for(lambda: line('@' + token + r':cwd=(/.*)')).group(1)
            tui = wait_for(lambda: line('@' + token + r':tui=([01])')).group(1)
            legacy = wait_for(lambda: line('@' + token + r':legacy=([01])')).group(1)
            evidence['ownership'] = {'cmux_tui': tui, 'cmuxd_remote': legacy}
            assert (tui, legacy) == ('1', '0'), evidence['ownership']
            evidence['catalog_before_click'] = call('surface.catalog', {})
            mutate('window.focus', {'window_id': window})
            mutate('workspace.select', {'workspace_id': workspace})

            def harness_ready():
                state = json.loads(state_path.read_text())
                return state if (state.get('ready') == '1' and
                                 state.get('surfaceId', '').lower() == surface.lower()) else None

            wait_for(harness_ready)
            request_id = secrets.token_hex(16)
            identify()
            staging = command_path.with_suffix('.pending')
            staging.write_text(json.dumps({'id': request_id, 'action': 'cmd_click_token'}))
            staging.replace(command_path)
            wait_for(lambda: json.loads(state_path.read_text()).get('lastCommandId') == request_id)

            def preview():
                rows = call('surface.list', {'workspace_id': workspace})['surfaces']
                return next((row for row in rows if row['type'] == 'filepreview'), None)

            evidence['preview'] = wait_for(preview, timeout=30)
            cache = Path(tempfile.gettempdir()) / 'cmux-remote-terminal-previews'
            expected = 'REMOTE_PREVIEW_' + token + '\n'
            assert any(path.read_text() == expected for path in cache.rglob('preview file.txt'))
            evidence['remote_bytes_verified'] = True
            # Keep the old workload alive after its cleanup receipt, then replace it
            # through the same public action used by CLI respawn.
            mutate('surface.send_text', {'workspace_id': workspace, 'surface_id': surface,
                                         'text': token + ':quit\n'})
            wait_for(lambda: line('@' + token + ':cleaned'), timeout=10)
            token = secrets.token_hex(8)
            replacement = mutate('surface.respawn', {
                'workspace_id': workspace, 'surface_id': surface,
                'command': shlex.join(['python3', '-u', '-c', WORKLOAD, token]),
                'working_directory': '/', 'focus': False,
            })
            assert replacement['surface_id'].lower() == surface.lower()
            replacement_cwd = wait_for(lambda: line('@' + token + r':cwd=(/.*)')).group(1)
            replacement_tui = wait_for(lambda: line('@' + token + r':tui=([01])')).group(1)
            replacement_legacy = wait_for(lambda: line('@' + token + r':legacy=([01])')).group(1)
            assert replacement_cwd != cwd
            assert (replacement_tui, replacement_legacy) == ('1', '0')
            evidence['respawn'] = {'surface_id': surface, 'identity_preserved': True,
                                   'cmux_tui': replacement_tui, 'cmuxd_remote': replacement_legacy}
        finally:
            try:
                if surface:
                    mutate('surface.send_text', {'workspace_id': workspace,
                                                'surface_id': surface, 'text': token + ':quit\n'})
                    wait_for(lambda: line('@' + token + ':cleaned'), timeout=10)
                    mutate('surface.send_text', {'workspace_id': workspace,
                                                'surface_id': surface, 'text': token + ':exit\n'})
            finally:
                mutate('window.close', {'window_id': window})
                print(json.dumps(evidence, indent=2))


if __name__ == '__main__':
    main()
