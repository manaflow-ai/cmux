#!/usr/bin/env python3
"""Crash checks for a disposable Freestyle devbox, never a user's machine.

The caller creates and deletes the VM. This test kills each managed process,
waits for its replacement without a manual start, then checks systemd recovery
when each service's main process is killed. No bootstrap or repair runs here.
"""
import hashlib
import json
import os
import pathlib
import pwd
import signal
import socket
import subprocess
import time
assert pathlib.Path('/run/systemd/system').is_dir(), 'requires a disposable systemd devbox'
UID = pwd.getpwnam('cmux').pw_uid

def run(args, env=None):
    return subprocess.run(args, env=env, capture_output=True, text=True, timeout=10)

def unit_value(unit, key):
    result = run(['systemctl', 'show', unit, '-p', key, '--value'])
    assert result.returncode == 0, result.stderr
    return result.stdout.strip()

def pids(component):
    found = []
    for entry in pathlib.Path('/proc').iterdir():
        if not entry.name.isdigit():
            continue
        try:
            if entry.stat().st_uid != UID:
                continue
            argv = entry.joinpath('cmdline').read_bytes().split(b'\x00')
            args = [a.decode(errors='replace') for a in argv if a]
            if not args:
                continue
            executable = pathlib.Path(args[0]).name
            match = (
                executable in {'Xvnc', 'Xtigervnc'}
                if component == 'xvnc'
                else executable == component
            )
            if component == 'websockify':
                match = executable in {'python3', 'python'} and len(args) > 1 and (pathlib.Path(args[1]).name == 'websockify')
            if component == 'cmux-tui':
                match = executable == component and args[1:3] == ['server', 'start']
            if match:
                found.append(int(entry.name))
        except (FileNotFoundError, ProcessLookupError):
            pass
    return sorted(found)

def desktop_ready():
    env = dict(os.environ, DISPLAY=':1')
    return run(['curl', '-fsS', '--max-time', '2', 'http://127.0.0.1:6901/']).returncode == 0 and run(['xdpyinfo'], env).returncode == 0 and all((pids(c) for c in ['xvnc', 'openbox', 'tint2', 'vncconfig', 'websockify', 'at-spi-bus-launcher']))

def daemon_ready():
    try:
        with socket.create_connection(('127.0.0.1', 1337), timeout=1):
            pass
    except OSError:
        return False
    return run(['sudo', '-u', 'cmux', 'env', 'HOME=/home/cmux', '/home/cmux/.cmux/bin/cmux-tui', 'server', 'status', '--session', 'cloud']).returncode == 0

def wait_for(label, check, timeout=75):
    begin = time.monotonic()
    while time.monotonic() - begin < timeout:
        if check():
            print(json.dumps({'check': label, 'seconds': round(time.monotonic() - begin, 2), 'passed': True}), flush=True)
            return
        time.sleep(0.25)
    raise AssertionError('recovery timed out: ' + label)
for unit in ['cmux-tui-daemon', 'cmux-desktop']:
    assert unit_value(unit, 'Restart') == 'always'
    assert run(['systemctl', 'is-enabled', unit]).returncode == 0
wait_for('initial-daemon', daemon_ready)
wait_for('initial-desktop', desktop_ready)
identity_path = pathlib.Path('/home/cmux/.local/state/cmux/remote/sessions/Y2xvdWQ/auth/identity.json')
identity = hashlib.sha256(identity_path.read_bytes()).digest()
for component in ['cmux-tui', 'websockify', 'openbox', 'tint2', 'vncconfig', 'at-spi-bus-launcher', 'xvnc']:
    prior = pids(component)
    assert len(prior) == 1, (component, prior)
    unit = 'cmux-tui-daemon' if component == 'cmux-tui' else 'cmux-desktop'
    assert unit + '.service' in pathlib.Path(f'/proc/{prior[0]}/cgroup').read_text()
    os.kill(prior[0], signal.SIGKILL)
    ready = daemon_ready if component == 'cmux-tui' else desktop_ready
    wait_for(component, lambda: len(pids(component)) == 1 and pids(component) != prior and ready())
for unit in ['cmux-tui-daemon', 'cmux-desktop']:
    before = int(unit_value(unit, 'NRestarts'))
    pid = int(unit_value(unit, 'MainPID'))
    os.kill(pid, signal.SIGKILL)
    ready = daemon_ready if unit == 'cmux-tui-daemon' else desktop_ready
    wait_for(unit + '-systemd', lambda: int(unit_value(unit, 'NRestarts')) > before and unit_value(unit, 'ActiveState') == 'active' and ready())
assert hashlib.sha256(identity_path.read_bytes()).digest() == identity, 'recovery replaced the machine identity'
print('ALL RECOVERY CHECKS PASSED', flush=True)
