"""A two-Mac targets viewer that ends early tells the host, which stops waiting for it.

The stage-table viewer's early exit held the host Mac 45 minutes (test_stage_table_viewer_done.py); the
targets path had the same shape: a viewer that ended before peer.py agent connected left the host waiting
30 minutes for agent.json, and one that ended mid-run left each call waiting 15 minutes. The viewer's EXIT
cleanup now posts /bye with its exit code; the host's wait loop and peer.py call end on bye.json. This runs
that cleanup against a real `peer.py serve`, then a real `peer.py call`.
"""
import json
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EVAL = ROOT / 'scripts/measure/screen-stream-eval.sh'
PEER = ROOT / 'scripts/measure/screen-stream-eval/peer.py'
TOKEN = 'cd' * 32


def cleanup_function():
    m = re.search(r'^cleanup\(\) \{\n.*?^\}\n', EVAL.read_text(), re.S | re.M)
    assert m, 'screen-stream-eval.sh has no cleanup()'
    return m.group(0)


def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


class ViewerByeTests(unittest.TestCase):
    def setUp(self):
        self.bash = shutil.which('bash')
        if self.bash is None:
            self.skipTest('no bash')
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        (self.tmp / 'token').write_text(TOKEN + '\n')
        self.folder = self.tmp / 'peer'
        self.port = free_port()
        self.server = subprocess.Popen([sys.executable, '-I', str(PEER), 'serve', '127.0.0.1', str(self.port),
                                        str(self.tmp / 'token'), str(self.folder)])
        self.addCleanup(self.stop_server)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                socket.create_connection(('127.0.0.1', self.port), timeout=0.5).close()
                return
            except OSError:
                time.sleep(0.1)
        self.fail('peer.py serve did not listen')

    def stop_server(self):
        self.server.kill()
        self.server.wait()

    def viewer_exits(self, code):
        script = (f'{cleanup_function()}\nviewer_of=127.0.0.1 peer_port={self.port} peer_token={TOKEN}\n'
                  f'pids=()\ntrap cleanup EXIT\nexit {code}\n')
        subprocess.run([self.bash, '-c', script], timeout=30)

    def test_an_early_viewer_exit_leaves_bye_with_its_code(self):
        self.viewer_exits(3)
        bye = self.folder / 'bye.json'
        self.assertTrue(bye.is_file(), 'the host has no word that the viewer ended')
        self.assertEqual(json.loads(bye.read_text()), {'exit': 3})

    def test_a_call_ends_once_the_viewer_said_bye(self):
        self.viewer_exits(1)
        start = time.monotonic()
        rc = subprocess.run([sys.executable, '-I', str(PEER), 'call', str(self.folder), 'rd', 'latency-view',
                             'key', '5', str(self.tmp / 'raw')], capture_output=True, text=True, timeout=60)
        self.assertEqual(rc.returncode, 1)
        self.assertIn('ended before latency-view answered', rc.stderr)
        self.assertLess(time.monotonic() - start, 30, 'the call waited for a viewer that had gone')


if __name__ == '__main__':
    unittest.main()
