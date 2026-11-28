"""A stage-table viewer that ends early still ends the host half's peer server.

2026-11-27: a stand-in pair's viewer exited 3 at the grant check (its Mac's launcher had no Screen
Recording), before stage-table.sh could post /done; the host half then served for 45 minutes until the
controller's silence stop, holding the bench Mac. screen-stream-eval.sh's EXIT cleanup now posts /done
for a stage-table viewer. This runs that cleanup against a real `screen-share-vs.py peer-serve`.
"""
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EVAL = ROOT / 'scripts/measure/screen-stream-eval.sh'
VS = ROOT / 'cmux-tui/crates/cmux-rd-host/scripts/screen-share-vs.py'
TOKEN = 'ab' * 32


def cleanup_function():
    text = EVAL.read_text()
    m = re.search(r'^cleanup\(\) \{\n.*?^\}\n', text, re.S | re.M)
    assert m, 'screen-stream-eval.sh has no cleanup()'
    return m.group(0)


def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


class ViewerEndsHostTests(unittest.TestCase):
    def run_cleanup(self, stage_table, viewer_of):
        bash = shutil.which('bash')
        if bash is None:
            self.skipTest('no bash')
        port = free_port()
        fn = cleanup_function().replace(':4181"', f':{port}"')
        self.assertIn(f':{port}"', fn, 'cleanup() posts /done to the stage-table port 4181')
        with tempfile.TemporaryDirectory() as tmp:
            token_file = Path(tmp) / 'token'
            token_file.write_text(TOKEN + '\n')
            serve = subprocess.Popen([sys.executable, '-I', str(VS), 'peer-serve', '--bind', '127.0.0.1',
                                      '--port', str(port), '--token-file', str(token_file), '--hold-s', '60'],
                                     stdout=subprocess.PIPE, text=True)
            try:
                self.assertIn('listening', serve.stdout.readline())
                script = (f'{fn}\nstage_table={stage_table} viewer_of={viewer_of} peer_token={TOKEN}\n'
                          'pids=()\ncleanup\n')
                subprocess.run([bash, '-c', script], check=True, timeout=30)
                try:
                    serve.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    return None
                return serve.stdout.read()
            finally:
                if serve.poll() is None:
                    serve.kill()
                    serve.wait()

    def test_a_stage_table_viewer_ends_the_host_server(self):
        out = self.run_cleanup('wired', '127.0.0.1')
        self.assertIsNotNone(out, 'the host server still ran after the viewer exited')
        self.assertIn('done from 127.0.0.1', out)

    def test_a_run_without_stage_table_posts_nothing(self):
        self.assertIsNone(self.run_cleanup('""', '127.0.0.1'))


if __name__ == '__main__':
    unittest.main()
