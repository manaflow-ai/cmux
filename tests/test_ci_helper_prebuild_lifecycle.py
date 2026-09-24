#!/usr/bin/env python3
"""The optional prebuild cannot delay or change the authoritative build result."""
import importlib.util
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

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
            result = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, timeout=8)
            return result

    def test_optional_work_does_not_mutate_the_shared_cua_source_cache(self):
        # The prebuild may be killed mid-run, so it may only compile a source
        # the caller already prepared; tests/test_cmux_cua_build_cache_safety.py
        # checks that --compile-prepared writes no Git state.
        prebuild = (ROOT / "scripts/ci/prebuild-app-helpers.sh").read_text()
        calls = [line for line in prebuild.splitlines() if "build-cmux-cua.sh" in line and not line.lstrip().startswith("#")]
        self.assertEqual(len(calls), 1, calls)
        self.assertIn("--compile-prepared", calls[0])
        workflow = (ROOT / ".github/workflows/nightly.yml").read_text()
        prepare = workflow.index("./scripts/build-cmux-cua.sh --prepare-source")
        self.assertLess(prepare, workflow.index("python3 scripts/ci/run-with-helper-prebuild.py"))

    def test_failed_build_does_not_wait_for_hung_helper(self):
        result = self.run_case("import signal; signal.pause()", "raise SystemExit(17)")
        self.assertEqual(result.returncode, 17, result.stderr)

    def test_helper_deadline_with_real_processes_keeps_build(self):
        # Nightly fork run 35976212299: the deadline kill raised EPERM on macOS,
        # crashed the wrapper, and orphaned a healthy xcodebuild.
        helper = "import subprocess,sys,signal; subprocess.Popen([sys.executable,'-c','import signal; signal.pause()']); signal.pause()"
        result = self.run_case(helper, "import time; time.sleep(2); raise SystemExit(0)", timeout=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("reached its deadline", result.stdout)

    def simulated(self, helper_status, ticks):
        spec = importlib.util.spec_from_file_location("runner", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        helper = Mock(returncode=helper_status)
        helper.poll.return_value = helper_status
        build = Mock(returncode=0)
        build.poll.side_effect = [None, 0]
        with tempfile.TemporaryDirectory() as tmp:
            with patch.object(module.subprocess, "Popen", side_effect=[helper, build]), \
                 patch.object(module.time, "monotonic", side_effect=ticks), \
                 patch.object(module.time, "sleep"), \
                 patch.object(module, "stop_group") as stop:
                result = module.run(["helper"], ["build"], str(Path(tmp)/"log"), 10)
                return result, stop.call_args_list

    def test_failed_helper_does_not_fail_successful_build(self):
        result, stopped = self.simulated(23, [0])
        self.assertEqual(result, 0)
        self.assertEqual(len(stopped), 3)

    def test_completed_helper_is_not_reported_as_timed_out(self):
        # Only the initial clock read is available; a completed helper must not
        # consume the deadline check or wait for optional work.
        result, _ = self.simulated(0, [0])
        self.assertEqual(result, 0)

    def test_helper_deadline_does_not_stop_build(self):
        result, stopped = self.simulated(None, [0, 11])
        self.assertEqual(result, 0)
        self.assertEqual(len(stopped), 3)

    def test_cancellation_kills_helper_descendants(self):
        with tempfile.TemporaryDirectory() as tmp:
            marker = Path(tmp) / "escaped"
            child = f"import signal,pathlib; signal.signal(signal.SIGTERM, lambda *_: (pathlib.Path({str(marker)!r}).touch(), exit(0))); print('child ready',flush=True); signal.pause()"
            helper = f"import subprocess,sys,signal; subprocess.Popen([sys.executable,'-c',{child!r}]); signal.pause()"
            log = Path(tmp) / "helper.log"
            code = (
                "import importlib.util; "
                f"s=importlib.util.spec_from_file_location('runner',{str(SCRIPT)!r}); "
                "m=importlib.util.module_from_spec(s); s.loader.exec_module(m); "
                f"raise SystemExit(m.run({[sys.executable,'-c',helper]!r}, "
                f"{[sys.executable,'-c','import signal; signal.pause()']!r}, {str(log)!r}, 10))"
            )
            proc = subprocess.Popen([sys.executable, "-c", code], stdout=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    if log.exists() and "child ready" in log.read_text():
                        break
                    time.sleep(.02)
                else:
                    self.fail("helper did not start")
                proc.send_signal(signal.SIGTERM)
                self.assertEqual(proc.wait(timeout=3), 143)
                self.assertTrue(marker.exists(), "helper grandchild did not receive cancellation")
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()


if __name__ == "__main__":
    unittest.main()
