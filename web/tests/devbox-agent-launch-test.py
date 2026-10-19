"""Behavioral coverage for the guest-side agent PTY supervisor."""

import os
from pathlib import Path
import re
import select
import shlex
import subprocess
import sys
import time
import unittest


class AgentLaunchTests(unittest.TestCase):
    def arguments(self, code, *extra):
        script = Path(__file__).resolve().parents[1] / "scripts" / "devbox-agent-launch.py"
        command = "python3 -c " + shlex.quote(code)
        return [sys.executable, str(script), "--command", command, "--ready", "READY", *extra]

    def run_probe(self, code, *extra):
        return subprocess.run(self.arguments(code, *extra), capture_output=True, text=True, timeout=5)

    def assert_reaped(self, output):
        pid = int(re.search(r"CHILD_PID:(\d+)", output).group(1))
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_colored_ready_marker_and_process_cleanup(self):
        result = self.run_probe(
            "import os,signal; print('CHILD_PID:'+str(os.getpid()),flush=True); "
            "os.write(1,b'RE\\x1b[32mAD'); os.write(1,b'Y\\x1b[0m\\n'); signal.pause()"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("agent-launch-ok", result.stdout)
        self.assert_reaped(result.stdout)

    def test_forbidden_gate_fails_even_when_ready_is_present(self):
        result = self.run_probe("print('Trust this folder? READY')", "--forbidden", "trust this folder")
        self.assertEqual(result.returncode, 1)
        self.assertIn("first-run gate still up", result.stderr)

    def test_exit_before_ready_fails(self):
        result = self.run_probe("print('not ready yet')")
        self.assertEqual(result.returncode, 1)
        self.assertIn("exited before", result.stderr)

    def test_timeout_reaps_the_child(self):
        result = self.run_probe(
            "import os,signal; print('CHILD_PID:'+str(os.getpid()),flush=True); signal.pause()",
            "--timeout", "2",
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("within 2.0 s", result.stderr)
        self.assert_reaped(result.stdout)

    def test_cancellation_reaps_the_child(self):
        with subprocess.Popen(self.arguments(
            "import os,signal; print('CHILD_PID:'+str(os.getpid()),flush=True); signal.pause()"
        ), stdout=subprocess.PIPE, stderr=subprocess.PIPE) as probe:
            output = b""
            deadline = time.monotonic() + 3
            try:
                while b"CHILD_PID:" not in output:
                    remaining = deadline - time.monotonic()
                    self.assertGreater(remaining, 0, output)
                    self.assertTrue(select.select([probe.stdout], [], [], remaining)[0])
                    output += os.read(probe.stdout.fileno(), 4096)
                probe.terminate()
                stdout, stderr = probe.communicate(timeout=3)
                self.assertEqual(probe.returncode, 1)
                self.assertIn(b"cancelled by signal", stderr)
                self.assert_reaped((output + stdout).decode())
            finally:
                if probe.poll() is None:
                    probe.kill()
                    probe.wait()


if __name__ == "__main__":
    unittest.main()
