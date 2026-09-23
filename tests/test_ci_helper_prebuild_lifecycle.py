#!/usr/bin/env python3
"""The optional prebuild cannot delay or change the authoritative build result."""
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/run-with-helper-prebuild.py"


class LifecycleTests(unittest.TestCase):
    def run_case(self, helper, build, timeout=5):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "helper.log"
            code = (
                "import importlib.util; "
                f"s=importlib.util.spec_from_file_location('runner',{str(SCRIPT)!r}); "
                "m=importlib.util.module_from_spec(s); s.loader.exec_module(m); "
                f"raise SystemExit(m.run({[sys.executable, '-c', helper]!r}, "
                f"{[sys.executable, '-c', build]!r}, {str(log)!r}, {timeout}))"
            )
            started = time.monotonic()
            result = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, timeout=8)
            return result, time.monotonic() - started

    def test_failed_build_does_not_wait_for_hung_helper(self):
        result, elapsed = self.run_case("import time; time.sleep(60)", "raise SystemExit(17)")
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertLess(elapsed, 3)

    def test_failed_helper_does_not_fail_successful_build(self):
        result, _ = self.run_case("raise SystemExit(23)", "import time; time.sleep(.2)")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_helper_deadline_does_not_stop_build(self):
        result, _ = self.run_case("import time; time.sleep(60)", "import time; time.sleep(.5)", .1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("deadline", result.stdout)

    def test_cancellation_kills_helper_descendants(self):
        with tempfile.TemporaryDirectory() as tmp:
            marker = Path(tmp) / "escaped"
            child = f"import time,pathlib; time.sleep(2); pathlib.Path({str(marker)!r}).touch()"
            helper = f"import subprocess,sys,time; subprocess.Popen([sys.executable,'-c',{child!r}]); print('ready',flush=True); time.sleep(60)"
            log = Path(tmp) / "helper.log"
            code = (
                "import importlib.util; "
                f"s=importlib.util.spec_from_file_location('runner',{str(SCRIPT)!r}); "
                "m=importlib.util.module_from_spec(s); s.loader.exec_module(m); "
                f"raise SystemExit(m.run({[sys.executable,'-c',helper]!r}, "
                f"{[sys.executable,'-c','import time; time.sleep(60)']!r}, {str(log)!r}, 10))"
            )
            proc = subprocess.Popen([sys.executable, "-c", code], stdout=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    if log.exists() and "ready" in log.read_text():
                        break
                    time.sleep(.02)
                else:
                    self.fail("helper did not start")
                proc.send_signal(signal.SIGTERM)
                self.assertEqual(proc.wait(timeout=3), 143)
                time.sleep(2)
                self.assertFalse(marker.exists(), "helper grandchild escaped cancellation")
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()


if __name__ == "__main__":
    unittest.main()
