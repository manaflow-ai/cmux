#!/usr/bin/env python3
"""The producer-side generation helper must work without any app socket."""
import os
import subprocess
import tempfile
import unittest

from test_claude_hook_clear_running_status import resolve_cmux_cli


class ProcessGenerationTests(unittest.TestCase):
    def test_helper_runs_before_socket_setup_and_reports_a_stable_generation(self):
        cli = resolve_cmux_cli()
        with tempfile.TemporaryDirectory(prefix="cmux-generation-") as home:
            env = {
                "PATH": os.environ.get("PATH", ""),
                "HOME": home,
                "CFFIXED_USER_HOME": home,
                "CMUX_SOCKET_PATH": os.path.join(home, "missing.sock"),
            }
            first = subprocess.run([cli, "__process-generation", str(os.getpid())],
                                   env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(first.returncode, 0, first.stderr)
            parts = [int(part) for part in first.stdout.split()]
            self.assertEqual(len(parts), 2)
            self.assertGreater(parts[0], 0)
            second = subprocess.run([cli, "__process-generation", str(os.getpid())],
                                    env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(first.stdout, second.stdout, "generation must be stable")
            dead = subprocess.Popen(["/usr/bin/true"])
            dead.wait()
            missing = subprocess.run([cli, "__process-generation", str(dead.pid)],
                                     env=env, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(missing.returncode, 0, "a dead PID must fail closed")


if __name__ == "__main__":
    unittest.main()
