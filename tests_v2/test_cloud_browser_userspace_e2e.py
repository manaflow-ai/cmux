#!/usr/bin/env python3
"""Real-VM browser evidence fixture and assertions for userspace Cloud routing.

Provisioning and actual command-clicks are external to this harness: run them on
an isolated tagged app through Computer Use. ``prepare`` installs the fixture on
two explicitly supplied disposable VMs and prints localhost links in one remote
terminal each. ``assert`` checks pages that the real command-clicks opened.
``cleanup`` removes only this run's fixture directories and workspaces. It never
creates/deletes VMs or touches another app/socket.

Examples (on the leased Mac; CMUX_SOCKET_PATH must name the tagged app):
  python3 test_cloud_browser_userspace_e2e.py prepare --vm-a VM_A --vm-b VM_B --state evidence/state.json
  python3 test_cloud_browser_userspace_e2e.py assert --state evidence/state.json --label initial
  python3 test_cloud_browser_userspace_e2e.py cleanup --state evidence/state.json
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import html
import http.server
import json
import os
import pathlib
import shlex
import struct
import time
import uuid


PAGE_SCRIPT = r"""
const out = document.querySelector('#result');
const show = () => out.textContent = JSON.stringify(window.evidence, null, 2);
window.evidence = {initial: INITIAL, location: location.href, fragment: location.hash, done: false};
(async () => {
  try {
    window.evidence.get = await fetch('/api/get?encoded=a%2Fb&duplicate=1&duplicate=2').then(r => r.json());
    window.evidence.post = await fetch('/api/post?mode=echo', {
      method: 'POST', headers: {'Content-Type': 'application/json', 'X-Fixture': 'cwg-e2e'},
      body: JSON.stringify({vm: window.evidence.initial.identity, text: 'hello / ? # ☁'})
    }).then(r => r.json());
    window.evidence.websocket = await new Promise((resolve, reject) => {
      const ws = new WebSocket('ws://' + location.host + '/ws?channel=cwg');
      const timeout = setTimeout(() => { ws.close(); reject(new Error('WebSocket timeout')); }, 10000);
      ws.onopen = () => ws.send('cwg-websocket-' + window.evidence.initial.identity);
      ws.onmessage = e => {clearTimeout(timeout); resolve(JSON.parse(e.data)); ws.close();};
      ws.onerror = () => {clearTimeout(timeout); reject(new Error('WebSocket error'));};
    });
    window.evidence.done = true;
    document.querySelector('#status').textContent = 'PASS: GET, POST and WebSocket';
  } catch (error) {
    window.evidence.error = String(error);
    document.querySelector('#status').textContent = 'FAIL: ' + error;
  }
  show();
})();
show();
"""


def serve(identity: str, bind: str, port: int) -> None:
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def payload(self, body: str = '') -> dict:
            return dict(identity=identity, bind=bind, host=self.headers.get('Host'),
                        path=self.path, method=self.command, body=body,
                        fixture_header=self.headers.get('X-Fixture'))

        def reply(self, body: bytes, content_type: str) -> None:
            self.send_response(200)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path.startswith('/ws'):
                self.websocket()
            elif self.path.startswith('/api/'):
                self.reply(json.dumps(self.payload()).encode(), 'application/json')
            else:
                payload = json.dumps(self.payload()).replace('</', '<\\/')
                script = PAGE_SCRIPT.replace('INITIAL', payload)
                color = '#174d78' if identity.endswith('-A') else '#734020'
                page = f'''<!doctype html><meta charset="utf-8"><title>{html.escape(identity)}</title>
<style>body{{background:{color};color:#fff;font:16px system-ui;margin:32px}}h1{{font-size:34px}}pre{{font:13px monospace;white-space:pre-wrap;background:#0006;padding:18px;border-radius:8px}}a{{color:#fff}}</style>
<h1>{html.escape(identity)}</h1><h2 id="status">Checking browser requests…</h2>
<p>Server bind: {html.escape(bind)}:{port}. Visible origin: <span id="origin"></span></p>
<pre id="result"></pre><a href="/reload?marker=reload#reloaded">Navigate again</a>
<script>document.querySelector('#origin').textContent=location.origin;</script><script>{script}</script>'''
                self.reply(page.encode(), 'text/html; charset=utf-8')

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get('Content-Length', '0'))).decode()
            self.reply(json.dumps(self.payload(body)).encode(), 'application/json')

        def websocket(self):
            key = self.headers.get('Sec-WebSocket-Key', '')
            accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            self.send_response(101)
            self.send_header('Upgrade', 'websocket')
            self.send_header('Connection', 'Upgrade')
            self.send_header('Sec-WebSocket-Accept', accept)
            self.end_headers()
            header = self.rfile.read(2)
            if len(header) != 2:
                return
            length = header[1] & 127
            if length == 126:
                length = struct.unpack('!H', self.rfile.read(2))[0]
            elif length == 127:
                length = struct.unpack('!Q', self.rfile.read(8))[0]
            if length > 65536:
                raise ValueError('fixture frame exceeded limit')
            mask = self.rfile.read(4) if header[1] & 128 else b''
            data = self.rfile.read(length)
            if mask:
                data = bytes(value ^ mask[index % 4] for index, value in enumerate(data))
            response = json.dumps(dict(self.payload(), echo=data.decode())).encode()
            prefix = bytes([0x81, len(response)]) if len(response) < 126 else b'\x81\x7e' + struct.pack('!H', len(response))
            self.wfile.write(prefix + response)
            self.wfile.flush()
            self.close_connection = True

    server = http.server.ThreadingHTTPServer((bind, port), Handler)
    print(json.dumps(dict(ready=True, identity=identity, bind=bind, port=port)), flush=True)
    server.serve_forever()


def client():
    from cmux import cmux
    path = os.environ['CMUX_SOCKET_PATH']
    if not path.startswith('/tmp/cmux-debug-'):
        raise ValueError('Use an explicit isolated tagged debug socket')
    return cmux(path)


def save(path: pathlib.Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + '\n')


def vm_exec(c, machine: str, command: str) -> dict:
    result = c._call('vm.exec', dict(id=machine, command=command, timeout_ms=30000), timeout_s=45)
    if result.get('exit_code') != 0:
        raise RuntimeError(json.dumps(result))
    return result


def prepare(args) -> None:
    if args.vm_a == args.vm_b:
        raise ValueError('Two distinct VMs are required')
    if args.state.exists():
        raise ValueError('Existing state must be cleaned up before preparing another run')
    run = 'cwg-' + uuid.uuid4().hex[:8]
    state = dict(run=run, socket=os.environ['CMUX_SOCKET_PATH'], fixtures=[], build_sha=args.build_sha)
    save(args.state, state)
    with client() as c:
        source = base64.b64encode(pathlib.Path(__file__).read_bytes()).decode()
        for label, machine, bind in [('A', args.vm_a, '0.0.0.0'), ('B', args.vm_b, '127.0.0.1')]:
            identity = run + '-' + label
            remote_dir = '/tmp/' + identity
            fixture = dict(machine=machine, identity=identity, bind=bind, remote_dir=remote_dir)
            state['fixtures'].append(fixture)
            save(args.state, state)
            command = 'python3 -c ' + shlex.quote(
                'import base64,pathlib,subprocess; '
                f'p=pathlib.Path({remote_dir!r}); p.mkdir(exist_ok=False); '
                f'(p/"fixture.py").write_bytes(base64.b64decode({source!r})); '
                f'log=open(p/"server.log","wb"); '
                f'child=subprocess.Popen(["python3",str(p/"fixture.py"),"serve","--identity",{identity!r},"--bind",{bind!r}],'
                'stdin=subprocess.DEVNULL,stdout=log,stderr=log,start_new_session=True); '
                '(p/"server.pid").write_text(str(child.pid)); print(child.pid)')
            vm_exec(c, machine, command)
            probe = 'python3 -c ' + shlex.quote(
                'import urllib.request,time\n'
                'deadline=time.monotonic()+10\n'
                'while True:\n'
                ' try:\n'
                '  print(urllib.request.urlopen("http://127.0.0.1:8000/api/ready",timeout=1).read().decode()); break\n'
                ' except OSError:\n'
                '  if time.monotonic()>=deadline: raise\n'
                '  time.sleep(.1)')
            fixture['server_probe'] = json.loads(vm_exec(c, machine, probe)['stdout'])
            workspace = c._call('vm.workspace_new', dict(id=machine, name=identity, focus=False), timeout_s=240)
            fixture.update(workspace)
            c._call('workspace.status.set', dict(workspace_id=workspace['workspace_id'], status='none'))
            fixture['status'] = c._call('vm.status', dict(id=machine), timeout_s=120)
            links = [f'http://0.0.0.0:8000/probe/{label}?encoded=a%2Fb&duplicate=1&duplicate=2#frag-{label}',
                     f'http://localhost:8000/probe/{label}?encoded=a%2Fb&duplicate=1&duplicate=2#frag-{label}',
                     f'http://127.0.0.1:8000/probe/{label}?encoded=a%2Fb&duplicate=1&duplicate=2#frag-{label}']
            fixture['links'] = links
            command = 'clear; printf "\\n%s\\n\\n" ' + ' '.join(shlex.quote(link) for link in links)
            c._call('vm.terminal_write', dict(id=machine, terminal_id=workspace['terminal_id'], text=command, keys=['enter']), timeout_s=120)
            save(args.state, state)
    print(json.dumps(state, indent=2))


def evaluate(c, surface: str) -> dict:
    return (c._call('browser.eval', dict(surface_id=surface, script='window.evidence || null')) or {}).get('value')


def assert_pages(args) -> None:
    state = json.loads(args.state.read_text())
    if state['socket'] != os.environ['CMUX_SOCKET_PATH']:
        raise ValueError('State belongs to another tagged app')
    records = []
    with client() as c:
        for fixture in state['fixtures']:
            surfaces = c._call('surface.list', dict(workspace_id=fixture['workspace_id']))
            browsers = [row for row in surfaces['surfaces'] if row.get('type') == 'browser']
            if not browsers:
                raise AssertionError('No command-click browser in ' + fixture['identity'])
            for browser in browsers:
                surface = browser.get('id') or browser.get('surface_id')
                deadline = time.monotonic() + 30
                evidence = None
                while time.monotonic() < deadline:
                    evidence = evaluate(c, surface)
                    if evidence and (evidence.get('done') or evidence.get('error')):
                        break
                    time.sleep(.2)
                if not evidence or not evidence.get('done'):
                    raise AssertionError(f'{surface}: page requests failed: {evidence}')
                from urllib.parse import urlsplit
                location = urlsplit(evidence['location'])
                assert location.hostname.startswith('10.'), evidence
                assert location.port == 8000, evidence
                assert location.path == '/probe/' + fixture['identity'][-1], evidence
                assert location.query == 'encoded=a%2Fb&duplicate=1&duplicate=2', evidence
                assert location.fragment == 'frag-' + fixture['identity'][-1], evidence
                for key in ['initial', 'get', 'post', 'websocket']:
                    request = evidence[key]
                    assert request['identity'] == fixture['identity'], evidence
                    assert request['host'] == location.netloc, evidence
                    assert request['bind'] == fixture['bind'], evidence
                assert evidence['initial']['path'] == location.path + '?' + location.query, evidence
                assert evidence['get']['path'] == '/api/get?encoded=a%2Fb&duplicate=1&duplicate=2', evidence
                assert evidence['post']['method'] == 'POST', evidence
                assert evidence['post']['fixture_header'] == 'cwg-e2e', evidence
                assert json.loads(evidence['post']['body']) == dict(vm=fixture['identity'], text='hello / ? # ☁'), evidence
                assert evidence['websocket']['echo'] == 'cwg-websocket-' + fixture['identity'], evidence
                assert evidence['websocket']['path'] == '/ws?channel=cwg', evidence
                records.append(dict(machine=fixture['machine'], identity=fixture['identity'], surface=surface, evidence=evidence))
        hosts = {urlsplit(row['evidence']['location']).hostname for row in records}
        assert len(hosts) == 2, records
    result = dict(label=args.label, build_sha=state['build_sha'], socket=state['socket'], captured_at=time.time(), records=records)
    save(args.state.parent / (args.label + '.json'), result)
    print(json.dumps(result, indent=2))


def cleanup(args) -> None:
    state = json.loads(args.state.read_text())
    if state['socket'] != os.environ['CMUX_SOCKET_PATH']:
        raise ValueError('State belongs to another tagged app')
    errors = []
    with client() as c:
        for fixture in reversed(state['fixtures']):
            try:
                if fixture.get('workspace_id'):
                    c._call('workspace.close', dict(workspace_id=fixture['workspace_id']))
                if fixture.get('remote_workspace_id'):
                    c._call('vm.workspace_delete', dict(id=fixture['machine'], workspace_id=fixture['remote_workspace_id']), timeout_s=120)
                command = 'python3 -c ' + shlex.quote(
                    'import os,pathlib,signal,shutil; '
                    f'p=pathlib.Path({fixture["remote_dir"]!r}); '
                    'pid=int((p/"server.pid").read_text()); os.kill(pid,signal.SIGTERM); shutil.rmtree(p)')
                vm_exec(c, fixture['machine'], command)
            except Exception as error:
                errors.append(dict(identity=fixture['identity'], error=str(error)))
    save(args.state.parent / 'cleanup.json', dict(errors=errors, captured_at=time.time()))
    if errors:
        raise RuntimeError(json.dumps(errors))
    print('Fixture cleanup complete. The caller must delete both disposable VMs.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('serve')
    p.add_argument('--identity', required=True)
    p.add_argument('--bind', default='127.0.0.1')
    p.add_argument('--port', type=int, default=8000)
    p = sub.add_parser('prepare')
    p.add_argument('--vm-a', required=True)
    p.add_argument('--vm-b', required=True)
    p.add_argument('--build-sha', required=True)
    p.add_argument('--state', type=pathlib.Path, required=True)
    p = sub.add_parser('assert')
    p.add_argument('--state', type=pathlib.Path, required=True)
    p.add_argument('--label', required=True)
    p = sub.add_parser('cleanup')
    p.add_argument('--state', type=pathlib.Path, required=True)
    args = parser.parse_args()
    if args.command == 'serve':
        serve(args.identity, args.bind, args.port)
    elif args.command == 'prepare':
        prepare(args)
    elif args.command == 'assert':
        assert_pages(args)
    else:
        cleanup(args)


if __name__ == '__main__':
    main()
