"""Cleanup never signals a recorded child after observing exit or PID reuse."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class CleanupTests(unittest.TestCase):
    def script(self, body):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            source = Path(os.environ.get('RD_CLEANUP_SCRIPT', str(Path(__file__).with_name('targets')/'rd.sh')))
            (root/'functions.sh').write_text(source.read_text().split('case "$verb" in')[0])
            (root/'pid').write_text('12345\n')
            (root/'pid.start').write_text('original birth\n')
            p = subprocess.run(['bash','-c','source "$TMP_EVAL/functions.sh" ignored\n'+body],
                               env={**os.environ,'TMP_EVAL':name,'EVAL_ROOT':name,'EVAL_BIN':name},
                               text=True, capture_output=True)
            self.assertEqual(p.returncode, 0, p.stderr)
            return p.stdout

    def test_observed_exit_cannot_fall_through_to_kill9(self):
        output = self.script('''
ps() { echo 'original birth'; }
kill() { if [[ "$1" == -0 ]]; then return 1; fi; echo "SIGNAL $*"; }
stop_pid "$TMP_EVAL/pid"
''')
        self.assertEqual(output.strip(), 'SIGNAL 12345')

    def test_recycled_pid_is_never_signalled(self):
        output = self.script('''
ps() { echo 'different birth'; }
kill() { echo "SIGNAL $*"; }
stop_pid "$TMP_EVAL/pid"
''')
        self.assertEqual(output, '')


if __name__ == '__main__':
    unittest.main()
