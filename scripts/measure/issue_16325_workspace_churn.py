"""Measure the issue's plain create/close workload; no pass/fail leak threshold."""
import json
import os
from pathlib import Path
import plistlib
import select
import shlex
import signal
import socket
import subprocess
import sys
import time

app, root = map(Path, sys.argv[1:])
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
bundle = info['CFBundleIdentifier']
assert bundle.startswith('com.cmuxterm.app.debug.'), bundle
results = root / 'results'
results.mkdir()
task_home = root / 'home'
task_home.mkdir()
markers = root / 'markers'
markers.mkdir()
sock_path = str(root / 'probe.sock')
env = {k: v for k, v in os.environ.items() if not k.startswith(('CMUX_', 'GHOSTTY_'))}
env.update(HOME=str(task_home), CFFIXED_USER_HOME=str(task_home), XDG_CONFIG_HOME=str(task_home / '.config'),
           CMUX_SOCKET_PATH=sock_path, CMUX_SOCKET_ENABLE='1', CMUX_SOCKET_MODE='allowAll',
           CMUX_DISABLE_SESSION_RESTORE='1', CMUX_UI_TEST_MODE='1', MallocStackLogging='1')
log = (results / 'app.log').open('w')
process = subprocess.Popen([str(app / 'Contents/MacOS' / info['CFBundleExecutable'])], env=env,
                           stdout=log, stderr=log)
request_id = 0
owned = []

def wait_file(path, directory, timeout=30):
    deadline = time.monotonic() + timeout
    fd = os.open(directory, os.O_RDONLY)
    try:
        with select.kqueue() as queue:
            queue.control([select.kevent(fd, filter=select.KQ_FILTER_VNODE,
                flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR, fflags=select.KQ_NOTE_WRITE)], 0)
            while not path.exists():
                if process.poll() is not None:
                    raise RuntimeError(f'App exited: {process.returncode}')
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(f'Readiness signal absent: {path.name}')
                queue.control(None, 1, remaining)
    finally:
        os.close(fd)

def call(method, params=None):
    global request_id
    request_id += 1
    with socket.socket(socket.AF_UNIX) as conn:
        conn.settimeout(30)
        conn.connect(sock_path)
        conn.sendall((json.dumps(dict(id=request_id, method=method, params=params or {})) + '\n').encode())
        with conn.makefile('rb') as stream:
            reply = json.loads(stream.readline())
    assert reply['id'] == request_id
    if not reply.get('ok'):
        raise RuntimeError(reply.get('error'))
    return reply.get('result') or {}

def create(index):
    marker = markers / str(index)
    result = call('workspace.create', {'title': f'issue-16325-{index}', 'cwd': str(task_home),
        'focus': False, 'initial_input': f'printf ready > {shlex.quote(str(marker))}; sleep 600\r'})
    wid = result['workspace_id']
    owned.append(wid)
    wait_file(marker, markers)
    return wid

def close(wid):
    call('workspace.close', {'workspace_id': wid})
    assert all(w['id'] != wid for w in call('workspace.list')['workspaces'])
    owned.remove(wid)

def snapshot(label):
    measurements = {}
    classes = ['__NSMallocBlock__', 'NSKeyValueDependencyContext', 'NSKeyValueDependency',
               'NSView', 'NSImageView', 'NSTextField', 'cmux_DEV.SidebarWorkspaceRowTableCellView']
    for cls in classes:
        r = subprocess.run(['/usr/bin/heap', f'--addresses={cls}', str(process.pid)],
                           capture_output=True, text=True, timeout=60, check=True)
        output = r.stdout + r.stderr
        (results / f'{label}-{cls}.txt').write_text(output)
        measurements[cls] = sum(f': {cls} ' in line for line in output.splitlines())
        if cls == '__NSMallocBlock__':
            for name in ['_commonAwake', 'reusableDependencyContextForKey',
                         '_observeAccessibilityDisplayShouldReduceAnimatedImages',
                         '_observeUserOverrideImageAnimationInWindow']:
                measurements[name] = sum(name in line for line in output.splitlines())
    measurements['workspace_count'] = len(call('workspace.list')['workspaces'])
    measurements['rss_kib'] = int(subprocess.check_output(['/bin/ps', '-o', 'rss=', '-p', str(process.pid)], text=True))
    print(label, json.dumps(measurements), flush=True)
    return measurements

try:
    wait_file(Path(sock_path), root)
    print('OS', subprocess.check_output(['/usr/bin/sw_vers'], text=True), flush=True)
    print('bundle', bundle, 'pid', process.pid, flush=True)
    # Warm one create/retire and establish four live shell workspaces.
    for i in range(4):
        create(i)
    call('workspace.select', {'workspace_id': owned[0]})
    close(create('warmup'))
    data = {'baseline': snapshot('baseline')}
    for batch, count in [('after40', 40), ('after60', 20)]:
        for i in range(count):
            close(create(f'{batch}-{i}'))
        data[batch] = snapshot(batch)
    (results / 'counts.json').write_text(json.dumps(data, indent=2))
finally:
    for wid in list(owned):
        try:
            close(wid)
        except Exception as error:
            print('cleanup', type(error).__name__, flush=True)
    # This PID was started above from a unique tag and isolated home.
    if process.poll() is None:
        process.send_signal(signal.SIGTERM)
        try:
            process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    log.close()
