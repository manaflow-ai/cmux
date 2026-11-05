#!/usr/bin/env python3
"""Fleet-only before/after CLI directory benchmark with a real guest-program provider.

Peak RSS covers the CLI alone; the provider and post-run JSON validation are excluded.
Three alternating samples on identical directories. Old large-list refusal is not
comparable successful work. Guest processes, HTTP server and temporary files are bounded.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer


def run(command, *, data=None, output=subprocess.PIPE, timeout=60):
    with subprocess.Popen(command, stdin=subprocess.PIPE, stdout=output,
                          stderr=subprocess.PIPE, start_new_session=True) as child:
        try:
            stdout, stderr = child.communicate(input=data, timeout=timeout)
        except BaseException:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.communicate()
            raise
        return child.returncode, stdout, stderr


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--before', required=True, type=Path)
    parser.add_argument('--after', required=True, type=Path)
    args = parser.parse_args()
    if sys.platform != 'linux':
        parser.error('run on fleet Linux with GNU time')
    class Provider(BaseHTTPRequestHandler):
        pages = 0
        largest = 0
        def log_message(self, *_):
            pass
        def do_POST(self):
            request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            if self.path.endswith('/client-session'):
                body = {'ok': True, 'value': {
                    'machine': 'vm_abcdefghij0123456789', 'vm_id': 'benchmark-vm',
                    'linux_user': 'cmux', 'token': 'benchmark-token', 'ssh': None,
                    'expires_at': int(time.time() * 1000) + 900000,
                    'api_base_url': f'http://127.0.0.1:{self.server.server_port}'}}
            else:
                command = shlex.split(request['command'])
                assert command[0:2] == ['python3', '-c'] and command[3] == 'dir'
                code, out, err = run(command)
                type(self).pages += 1
                type(self).largest = max(type(self).largest, len(out))
                assert len(out) <= 2 * 1024 * 1024 + 4096
                body = {'statusCode': code, 'stdout': out.decode(), 'stderr': err.decode()}
            encoded = json.dumps(body).encode()
            self.send_response(200)
            self.send_header('Content-Length', str(len(encoded)))
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(encoded)

    server = HTTPServer(('127.0.0.1', 0), Provider)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    results = []
    try:
        with tempfile.TemporaryDirectory(prefix='cmux-directory-benchmark-') as scratch:
            root = Path(scratch)
            for count in (1000, 11050):
                directory = root / str(count)
                directory.mkdir()
                names = {'\x01' * 60 + f'{n:06}' for n in range(count)}
                for name in names:
                    (directory / name).touch()
                samples = {'before': [], 'after': []}
                for sample in range(3):
                    for label in (('before', 'after') if sample % 2 == 0 else ('after', 'before')):
                        request = json.dumps({
                            'api': f'http://127.0.0.1:{server.server_port}',
                            'credential': 'benchmark-credential', 'team': 'team_benchmark',
                            'machine': 'vm_abcdefghij0123456789', 'op': 'dir',
                            'path': str(directory), 'cache_dir': str(root / f'{count}-{label}-{sample}')
                        }).encode()
                        Provider.pages = Provider.largest = 0
                        usage = root / 'usage'
                        response = root / 'response'
                        with response.open('wb') as output:
                            code, _, err = run(['/usr/bin/time', '-q', '-f', '%e\t%M', '-o', str(usage),
                                                str(getattr(args, label).resolve()), 'cloud', 'machine-io'],
                                               data=request, output=output, timeout=180)
                        value = json.loads(response.read_bytes())  # Outside the measured process.
                        refused = label == 'before' and count == 11050
                        assert code == (1 if refused else 0), err.decode()
                        assert value['route'] == 'direct'
                        assert value['status'] == (413 if refused else 200), value
                        if not refused:
                            entries = value['body']['entries']
                            assert len(entries) == count and {e['name'] for e in entries} == names
                            if count == 11050:
                                assert response.stat().st_size > 4 * 1024 * 1024
                        elapsed, rss = usage.read_text().strip().split('\t')
                        samples[label].append({'seconds': float(elapsed), 'rss_kib': int(rss),
                                               'pages': Provider.pages, 'largest_page': Provider.largest,
                                               'bytes': response.stat().st_size, 'refused': refused})
                result = {'entries': count, 'samples': samples}
                for metric in ('seconds', 'rss_kib'):
                    before, after = (statistics.median(x[metric] for x in samples[label])
                                     for label in ('before', 'after'))
                    result[metric] = {'before': before, 'after': after,
                                      'delta': after - before if count == 1000 else None}
                results.append(result)
    finally:
        server.shutdown()
        worker.join(timeout=5)
        server.server_close()
    print(json.dumps(results, indent=2))


if __name__ == '__main__':
    main()
