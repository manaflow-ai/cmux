"""A screen-share-vs-pair host half that exits early still ends the viewer half.

The host half posted /done to the viewer's peer-serve only at its normal end; each early exit 3 after the viewer
answered (no LAN address, the rd tools build, the NIGHTLY helper, the rig) left the viewer Mac serving its whole
hold-s= (3600 s by default). The EXIT trap now posts it. This runs the real script as the host half, stubbed to
have no LAN address, against a real `screen-share-vs.py peer-serve`.
"""
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PAIR = ROOT / 'scripts/measure/screen-share-vs-pair.sh'
VS = ROOT / 'cmux-tui/crates/cmux-rd-host/scripts/screen-share-vs.py'
TOKEN = 'ef' * 32


def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


class HostEarlyExitTests(unittest.TestCase):
    def test_an_early_host_exit_ends_the_viewer_server(self):
        bash = shutil.which('bash')
        if bash is None:
            self.skipTest('no bash')
        port = free_port()
        script, n = re.subn(r'^peer_port=4181$', f'peer_port={port}', PAIR.read_text(), flags=re.M)
        self.assertEqual(n, 1, 'screen-share-vs-pair.sh sets peer_port=4181 once')
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / 'pair.sh').write_text(script)
            (tmp / 'cmux-tui').symlink_to(ROOT / 'cmux-tui')
            stub = tmp / 'bin'
            stub.mkdir()
            (stub / 'ipconfig').write_text('#!/bin/sh\nexit 1\n')  # no LAN address: the host's first exit 3
            (stub / 'ipconfig').chmod(0o755)
            (tmp / 'token').write_text(TOKEN + '\n')
            serve = subprocess.Popen([sys.executable, '-I', str(VS), 'peer-serve', '--bind', '127.0.0.1',
                                      '--port', str(port), '--token-file', str(tmp / 'token'), '--hold-s', '120'],
                                     stdout=subprocess.PIPE, text=True)
            try:
                self.assertIn('listening', serve.stdout.readline())
                partner = subprocess.run(['hostname', '-s'], capture_output=True, text=True).stdout.strip()
                env = dict(os.environ, PATH=f'{stub}:{os.environ["PATH"]}')
                host = subprocess.run([bash, str(tmp / 'pair.sh'), 'mode=run', f'partner={partner}',
                                       'partner-ip=127.0.0.1', f'peer-token={TOKEN}'],
                                      cwd=tmp, env=env, capture_output=True, text=True, timeout=120)
                self.assertEqual(host.returncode, 3, host.stdout + host.stderr)
                self.assertIn('SSVP no LAN address', host.stdout)
                try:
                    serve.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    self.fail('the viewer server still ran after the host half exited')
                self.assertIn('done from 127.0.0.1', serve.stdout.read())
            finally:
                if serve.poll() is None:
                    serve.kill()
                    serve.wait()
                serve.stdout.close()


if __name__ == '__main__':
    unittest.main()
