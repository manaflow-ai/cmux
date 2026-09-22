#!/usr/bin/env python3

import os
import pathlib
import subprocess
import tempfile
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
RUNNER = ROOT / "scripts" / "ci" / "run-swift-testing-suites.sh"


def run_runner(package: pathlib.Path, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    process = subprocess.Popen(
        [str(RUNNER), str(package)],
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    deadline = time.monotonic() + 30
    while process.poll() is None:
        if time.monotonic() >= deadline:
            process.kill()
            output, _ = process.communicate()
            raise AssertionError(f"runner failed to exit within test deadline\n{output}")
        time.sleep(0.05)
    output, _ = process.communicate()
    return subprocess.CompletedProcess(process.args, process.returncode, output)


class SwiftTestingSuiteTimeoutTests(unittest.TestCase):
    def test_suite_processes_reuse_the_list_build(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = pathlib.Path(temp_dir)
            calls = temp / "calls.txt"
            fake_swift = temp / "swift"
            fake_swift.write_text(
                "#!/usr/bin/env bash\n"
                "printf '%s\\n' \"$*\" >> \"$CMUX_SWIFT_TEST_CALLS\"\n"
                "if [[ \"$*\" == *\"test list\"* ]]; then\n"
                "  echo 'ExampleTests.FirstSuite/testOne()'\n"
                "  echo 'ExampleTests.SecondSuite/testTwo()'\n"
                "fi\n",
                encoding="utf-8",
            )
            fake_swift.chmod(0o755)
            package = temp / "ExampleTests"
            package.mkdir()
            env = os.environ.copy()
            env["PATH"] = f"{temp}:{env['PATH']}"
            env["CMUX_SWIFT_TEST_CALLS"] = str(calls)

            completed = run_runner(package, env)

            self.assertEqual(completed.returncode, 0, completed.stdout)
            invocations = calls.read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(invocations), 3, invocations)
            self.assertIn("test list", invocations[0])
            self.assertNotIn("--skip-build", invocations[0])
            for invocation in invocations[1:]:
                self.assertIn("--filter", invocation)
                self.assertIn("--skip-build", invocation)

    def test_timeout_retry_reuses_the_existing_build(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = pathlib.Path(temp_dir)
            calls = temp / "calls.txt"
            attempts = temp / "attempts.txt"
            fake_swift = temp / "swift"
            fake_swift.write_text(
                "#!/usr/bin/env bash\n"
                "printf '%s\\n' \"$*\" >> \"$CMUX_SWIFT_TEST_CALLS\"\n"
                "if [[ \"$*\" == *\"test list\"* ]]; then\n"
                "  echo 'ExampleTests.RetrySuite/testOne()'\n"
                "  exit 0\n"
                "fi\n"
                "if [[ \"$*\" != *\"--skip-build\"* ]]; then\n"
                "  exit 91\n"
                "fi\n"
                "count=0\n"
                "if [[ -f \"$CMUX_SWIFT_TEST_ATTEMPTS\" ]]; then count=$(cat \"$CMUX_SWIFT_TEST_ATTEMPTS\"); fi\n"
                "count=$((count + 1))\n"
                "printf '%s' \"$count\" > \"$CMUX_SWIFT_TEST_ATTEMPTS\"\n"
                "if [[ \"$count\" -eq 1 ]]; then exit 124; fi\n",
                encoding="utf-8",
            )
            fake_swift.chmod(0o755)
            package = temp / "ExampleTests"
            package.mkdir()
            env = os.environ.copy()
            env["PATH"] = f"{temp}:{env['PATH']}"
            env["CMUX_SWIFT_TEST_CALLS"] = str(calls)
            env["CMUX_SWIFT_TEST_ATTEMPTS"] = str(attempts)

            completed = run_runner(package, env)

            self.assertEqual(completed.returncode, 0, completed.stdout)
            invocations = calls.read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(invocations), 3, invocations)
            self.assertEqual(attempts.read_text(encoding="utf-8"), "2")
            for invocation in invocations[1:]:
                self.assertIn("--skip-build", invocation)
            self.assertIn("retrying RetrySuite once", completed.stdout)

    def test_hung_suite_is_terminated_before_the_job_timeout(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = pathlib.Path(temp_dir)
            fake_swift = temp / "swift"
            fake_swift.write_text(
                "#!/usr/bin/env bash\n"
                "if [[ \"$*\" == *\"test list\"* ]]; then\n"
                "  echo 'ExampleTests.HangingSuite/testNeverFinishes()'\n"
                "  exit 0\n"
                "fi\n"
                "sleep 30\n",
                encoding="utf-8",
            )
            fake_swift.chmod(0o755)
            package = temp / "ExampleTests"
            package.mkdir()
            env = os.environ.copy()
            env["PATH"] = f"{temp}:{env['PATH']}"
            env["CMUX_SWIFT_TEST_SUITE_TIMEOUT_SECONDS"] = "1"

            completed = run_runner(package, env)

            self.assertEqual(completed.returncode, 124, completed.stdout)
            self.assertEqual(completed.stdout.count("timed out after 1s"), 2)
            self.assertIn("retrying HangingSuite once", completed.stdout)


if __name__ == "__main__":
    unittest.main()
