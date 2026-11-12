#!/usr/bin/env python3

import json
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
    def test_a_local_dependency_in_an_empty_submodule_is_populated_first(self) -> None:
        """Fleet ci-steps check the ref out with every submodule deinitialized, so
        CmuxAppKitSupportUI (through CmuxWorkspaces' .package(path: vendor/bonsplit))
        failed at `swift test list`: vendor/bonsplit/Package.swift doesn't exist
        (step 97793621e02e, 2026-10-12). Only submodules a local dependency reaches
        are populated; ghostty is not."""
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = pathlib.Path(temp_dir)
            git_env = os.environ.copy()
            git_env.update(
                GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com",
                GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.com",
                GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="protocol.file.allow", GIT_CONFIG_VALUE_0="always",
            )

            def git(*args: str, cwd: pathlib.Path) -> None:
                subprocess.run(["git", *args], cwd=cwd, env=git_env, check=True, capture_output=True)

            for name in ("dep", "big"):
                source = temp / name
                source.mkdir()
                git("init", "-q", cwd=source)
                (source / "Package.swift").write_text(f"// {name}\n", encoding="utf-8")
                git("add", "-A", cwd=source)
                git("commit", "-qm", name, cwd=source)
            repo = temp / "repo"
            repo.mkdir()
            git("init", "-q", cwd=repo)
            git("submodule", "add", "-q", f"file://{temp / 'dep'}", "vendor/dep", cwd=repo)
            git("submodule", "add", "-q", f"file://{temp / 'big'}", "big", cwd=repo)
            for name, deps in (("App", ['"../Lib"']), ("Lib", ['"../../vendor/dep"'])):
                package = repo / "Packages" / name
                package.mkdir(parents=True)
                lines = "".join(f"        .package(path: {d}),\n" for d in deps)
                (package / "Package.swift").write_text(f"let package = Package(\n    dependencies: [\n{lines}    ]\n)\n", encoding="utf-8")
            git("add", "-A", cwd=repo)
            git("commit", "-qm", "repo", cwd=repo)
            git("submodule", "deinit", "-q", "-f", "--all", cwd=repo)

            fake_swift = temp / "bin" / "swift"
            fake_swift.parent.mkdir()
            fake_swift.write_text(
                "#!/usr/bin/env bash\n"
                f"root={repo}\n"
                "[ -f \"$root/vendor/dep/Package.swift\" ] || { echo \"error: $root/vendor/dep/Package.swift doesn't exist\" >&2; exit 1; }\n"
                "[ ! -f \"$root/big/Package.swift\" ] || { echo 'error: populated big, which no package reaches' >&2; exit 1; }\n"
                "if [ \"$1 $2\" = 'test list' ]; then echo 'ExampleTests.Suite/testOne()'; exit 0; fi\n"
                "echo 'Test run with 1 test passed after 0.001 seconds.'\n",
                encoding="utf-8",
            )
            fake_swift.chmod(0o755)
            env = git_env.copy()
            env["PATH"] = f"{fake_swift.parent}:{env['PATH']}"
            completed = run_runner(repo / "Packages" / "App", env)
            self.assertEqual(completed.returncode, 0, completed.stdout)

    def test_success_exit_requires_completed_nonzero_execution(self) -> None:
        for output in (
            "Test run with 0 tests passed after 0.001 seconds.",
            "Test run started.\nTest one() passed after 0.001 seconds.",
        ):
            with self.subTest(output=output), tempfile.TemporaryDirectory() as temp_dir:
                temp = pathlib.Path(temp_dir)
                fake_swift = temp / "swift"
                fake_swift.write_text(
                    "#!/usr/bin/env python3\n"
                    "import sys\n"
                    "if sys.argv[1:3] == ['test', 'list']:\n"
                    "    print('ExampleTests.Suite/testOne()')\n"
                    "else:\n"
                    f"    print({json.dumps(output)})\n",
                    encoding="utf-8",
                )
                fake_swift.chmod(0o755)
                env = os.environ.copy()
                env["PATH"] = f"{temp}:{env['PATH']}"
                completed = run_runner(temp, env)
                self.assertNotEqual(completed.returncode, 0, completed.stdout)
                self.assertIn("no completed nonzero", completed.stdout)

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
                "  exit 0\n"
                "fi\n"
                "echo 'Test run with 1 test passed after 0.001 seconds.'\n",
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

    def test_top_level_tests_are_not_dropped_when_a_suite_exists(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = pathlib.Path(temp_dir)
            fake_swift = temp / "swift"
            fake_swift.write_text(
                "#!/usr/bin/env python3\n"
                "import re, sys\n"
                "tests = ['ExampleTests.PassingSuite/testOne()', "
                "'ExampleTests.failsOutsideSuite()']\n"
                "if sys.argv[1:3] == ['test', 'list']:\n"
                "    print('\\n'.join(tests))\n"
                "    raise SystemExit(0)\n"
                "selected = [name for name in tests if "
                "re.search(sys.argv[sys.argv.index('--filter') + 1], name)]\n"
                "failed = 'ExampleTests.failsOutsideSuite()' in selected\n"
                "print(f'Test run with {len(selected)} tests "
                "{\"failed\" if failed else \"passed\"} after 0.001 seconds.')\n"
                "raise SystemExit(17 if failed else 0)\n",
                encoding="utf-8",
            )
            fake_swift.chmod(0o755)
            package = temp / "ExampleTests"
            package.mkdir()
            env = os.environ.copy()
            env["PATH"] = f"{temp}:{env['PATH']}"

            completed = run_runner(package, env)

            self.assertEqual(completed.returncode, 17, completed.stdout)
            self.assertIn("1 tests failed", completed.stdout)

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
                "if [[ \"$count\" -eq 1 ]]; then exit 124; fi\n"
                "echo 'Test run with 1 test passed after 0.001 seconds.'\n",
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
            self.assertIn("retrying ^ExampleTests\\.RetrySuite/ once", completed.stdout)

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
            self.assertIn("retrying ^ExampleTests\\.HangingSuite/ once", completed.stdout)


if __name__ == "__main__":
    unittest.main()
