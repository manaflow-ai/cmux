"""scripts/ci/shard1_background.sh: a react-apps-check shard 1 check started in the background hands its output and
exit status to its own later step, and runs inline whenever the background run cannot answer (never started, or its
process died without a status), so the check never goes unrun."""
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/shard1_background.sh"


class Shard1BackgroundTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.env = dict(os.environ, RUNNER_TEMP=self.temp.name)

    def run_script(self, *args):
        return subprocess.run(["bash", str(SCRIPT), *args], env=self.env, capture_output=True, text=True, timeout=60)

    def test_wait_hands_back_the_background_output_and_status(self):
        for code in (0, 3):
            with self.subTest(code=code):
                started = self.run_script("start", f"c{code}", "--", "bash", "-c", f"sleep 1; echo out-{code}; exit {code}")
                self.assertEqual(started.returncode, 0, started.stderr)
                waited = self.run_script("wait", f"c{code}", "--", "bash", "-c", "echo inline; exit 9")
                self.assertEqual(waited.returncode, code, waited.stdout)
                self.assertIn(f"out-{code}", waited.stdout)
                self.assertNotIn("inline", waited.stdout)

    def test_the_background_run_overlaps_the_steps_after_its_start(self):
        began = time.monotonic()
        self.assertEqual(self.run_script("start", "slow", "--", "sleep", "3").returncode, 0)
        self.assertLess(time.monotonic() - began, 2, "start returns before the check ends")
        self.assertEqual(self.run_script("wait", "slow", "--", "false").returncode, 0)

    def test_a_check_that_never_started_runs_inline(self):
        waited = self.run_script("wait", "never", "--", "bash", "-c", "echo inline; exit 4")
        self.assertEqual(waited.returncode, 4)
        self.assertIn("inline", waited.stdout)

    def test_a_process_that_died_without_a_status_runs_inline(self):
        self.assertEqual(self.run_script("start", "dies", "--", "sleep", "30").returncode, 0)
        pid = int((Path(self.temp.name) / "shard1-background/dies.pid").read_text())
        time.sleep(0.5)  # the child is its own process group once setsid has run
        os.killpg(pid, 9)
        time.sleep(0.5)
        waited = self.run_script("wait", "dies", "--", "bash", "-c", "echo inline; exit 0")
        self.assertEqual(waited.returncode, 0, waited.stdout)
        self.assertIn("ended without a status", waited.stdout)
        self.assertIn("inline", waited.stdout)

    def test_a_bad_name_or_usage_is_refused(self):
        self.assertEqual(self.run_script("start", "a/b", "--", "true").returncode, 2)
        self.assertEqual(self.run_script("start", "x").returncode, 2)


if __name__ == "__main__":
    unittest.main()
