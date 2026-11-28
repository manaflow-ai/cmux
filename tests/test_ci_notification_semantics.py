#!/usr/bin/env python3
"""Execute the Swift package lane gates with controlled test-runner outcomes."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class NotificationSemanticsTests(unittest.TestCase):
    def run_packages(self, failing_package=""):
        script = f"bash '{ROOT / 'scripts/ci/package-test-lane.sh'}' packages\n"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for package in (ROOT / "Packages").glob("*/*"):
                if package.is_dir():
                    fake = root / package.relative_to(ROOT)
                    fake.mkdir(parents=True)
                    # The step's package selector only lists directories that hold a manifest.
                    (fake / "Package.swift").write_text("")
            helpers = root / "scripts/ci"
            helpers.mkdir(parents=True)
            shutil.copy(ROOT / "scripts/ci/select_package_tests.py", helpers)
            shutil.copy(ROOT / "scripts/ci/require_swift_test_execution.py", helpers)
            shutil.copy(ROOT / "scripts/ci/hung_test_watchdog.py", helpers)
            shutil.copy(ROOT / "scripts/ci/ci_process_tree.py", helpers)
            shutil.copy(ROOT / "scripts/ci/run_with_timeout.py", helpers)
            runner_temp = root / "runner-temp"
            runner_temp.mkdir()
            selected = runner_temp / "selected-packages.txt"
            package_names = sorted(
                package.name
                for package in (ROOT / "Packages").glob("*/*")
                if package.is_dir()
            )
            selected.write_text("\n".join(package_names) + "\n", encoding="utf-8")
            isolated = helpers / "run-swift-testing-suites.sh"
            isolated.write_text('#!/bin/bash\nexec swift test --package-path "$1"\n')
            isolated.chmod(0o755)
            bindir = root / "bin"
            bindir.mkdir()
            cargo = bindir / "cargo"
            cargo.write_text("#!/bin/bash\nexit 0\n")
            cargo.chmod(0o755)
            swift = bindir / "swift"
            swift.write_text("""#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['CALLS'], 'a') as f:
    f.write(json.dumps(args) + '\\n')
package = Path(args[args.index('--package-path') + 1]).name
if args[0] == 'build':
    # Rendezvous: mark this build running, then wait briefly for a second one.
    # The mark goes away when the build ends, so two marks at once prove two
    # prebuilds ran at the same time; serial builds never see each other.
    running = Path(os.environ['CALLS'] + '.running')
    running.mkdir(exist_ok=True)
    mark = running / package
    mark.touch()
    try:
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if len(list(running.iterdir())) >= 2:
                Path(os.environ['CALLS'] + '.overlap').touch()
                break
            time.sleep(0.05)
    finally:
        mark.unlink()
if package == os.environ['FAILING_PACKAGE']:
    print('error: compile failure')
    sys.exit(1)
print('Test run with 4 tests in 1 suite passed after 0.1 seconds.')
""")
            swift.chmod(0o755)
            calls = root / "calls.jsonl"
            env = dict(
                os.environ,
                PATH=f"{bindir}:{os.environ['PATH']}",
                CALLS=str(calls),
                FAILING_PACKAGE=failing_package,
                RUNNER_TEMP=str(runner_temp),
                SELECTED_PACKAGES=str(selected),
                SELECTED_COUNT=str(len(package_names)),
                CMUX_SWIFT_PACKAGE_BUILD_JOBS="3",
            )
            result = subprocess.run(["/bin/bash", "-c", script], cwd=root, env=env,
                                    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            self.prebuilds_overlapped = Path(str(calls) + ".overlap").exists()
            return result, [json.loads(line) for line in calls.read_text().splitlines()]

    def test_packages_prebuild_in_parallel_then_test_serially(self):
        result, calls = self.run_packages()
        self.assertEqual(result.returncode, 0, result.stdout)
        builds = [args for args in calls if args[0] == "build"]
        tests = [args for args in calls if args[0] == "test"]
        self.assertTrue(builds)
        self.assertTrue(all("--build-tests" in args for args in builds))
        # Every build precedes every test run.
        self.assertLess(max(calls.index(args) for args in builds),
                        min(calls.index(args) for args in tests))
        self.assertTrue(self.prebuilds_overlapped, "no two prebuilds ran at once")
        self.assertIn("at a time", result.stdout)

    def test_a_failing_package_does_not_hide_later_packages(self):
        # CMUXAuthCore sorts first, so every other package runs after it.
        result, calls = self.run_packages("CMUXAuthCore")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        ran = {Path(args[args.index('--package-path') + 1]).name for args in calls}
        self.assertIn("CmuxIrohTransport", ran)
        self.assertIn("CmuxUpdater", ran)
        self.assertIn(
            "::error title=Swift package tests failed::CMUXAuthCore failed with exit status 1",
            result.stdout,
        )
        self.assertEqual(result.stdout.count("::error title=Swift package tests failed::"), 1)
        table = result.stdout.split("Swift package test results:\n", 1)[1]
        self.assertRegex(table, r"CMUXAuthCore +failed \(exit 1\)")
        self.assertRegex(table, r"CmuxUpdater +passed")
        self.assertIn("1 of ", result.stdout)


if __name__ == "__main__":
    unittest.main()
