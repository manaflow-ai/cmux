"""Exercise lock contention with harmless Python children, never Xcode."""
import fcntl
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'scripts/lib/xcodebuild-slot.py'


class SlotTests(unittest.TestCase):
    def command(self, root, code, slots=1, wait=1):
        return [sys.executable, str(HELPER), str(root), str(slots), str(wait),
                sys.executable, '-c', code]

    def test_busy_slot_times_out_without_executing_or_disturbing_owner(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with (root / 'slot-1.lock').open('w') as owner:
                fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
                before = time.monotonic()
                result = subprocess.run(self.command(root, "print('SHOULD NOT RUN')"),
                                        capture_output=True, text=True, timeout=4)
                self.assertEqual(result.returncode, 124, result.stderr)
                self.assertNotIn('SHOULD NOT RUN', result.stdout)
                self.assertIn('compilation has not started', result.stderr)
                self.assertIn('timed out', result.stderr)
                self.assertLess(time.monotonic() - before, 3)
                with (root / 'slot-1.lock').open() as probe:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_uses_another_slot_and_preserves_child_exit(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with (root / 'slot-1.lock').open('w') as owner:
                fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
                result = subprocess.run(self.command(root, 'raise SystemExit(17)', slots=2),
                                        capture_output=True, text=True, timeout=4)
                self.assertEqual(result.returncode, 17, result.stderr)
                with (root / 'slot-2.lock').open() as probe:
                    fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_cancel_waiter_leaves_no_lock_holder(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with (root / 'slot-1.lock').open('w') as owner:
                fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
                child = subprocess.Popen(self.command(root, 'pass', wait=30), stderr=subprocess.PIPE, text=True)
                try:
                    self.assertIn('compilation has not started', child.stderr.readline())
                    child.terminate()
                    child.wait(timeout=2)
                finally:
                    if child.poll() is None:
                        child.kill()
                        child.wait()
                    child.stderr.close()
            result = subprocess.run(self.command(root, "print('acquired')"), capture_output=True, text=True, timeout=3)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), 'acquired')

    def test_guard_rejects_reload_before_setup(self):
        env = dict(os.environ, CMUX_LOCAL_BUILD_GUARD_ACTIVE='1')
        env.pop('CMUX_ALLOW_LOCAL_XCODEBUILD', None)
        with tempfile.TemporaryDirectory() as tmp:
            script = Path(tmp) / 'reload.sh'
            shutil.copy2(ROOT / 'scripts/reload.sh', script)
            result = subprocess.run(['bash', str(script), '--tag', 'slot-guard-test'],
                                    env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn('cmux-ci', result.stderr)


if __name__ == '__main__':
    unittest.main()
