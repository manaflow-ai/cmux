#!/usr/bin/env python3
"""Exercise Depot's launch contract with a fake Xcode process, never an app."""

import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
JOB = yaml.safe_load((ROOT / ".github/workflows/test-depot.yml").read_text())["jobs"]["tests"]


class DepotAppHostTests(unittest.TestCase):
    def setUp(self):
        """Sandbox the real launcher; simulate only Xcode and the OS session hop."""
        self.temporary = tempfile.TemporaryDirectory(prefix="cmux-depot-contract-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.runner_temp = self.root / "runner-temp"
        self.runner_temp.mkdir()
        self.scripts = self.root / "scripts/ci"
        shutil.copytree(ROOT / "scripts/ci", self.scripts)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        # The OS GUI-session hop is the only mocked wrapper boundary. The
        # app-host launcher, kernel lock, home publication and teardown run.
        self.write_executable(self.scripts / "run-in-console-session.sh", """#!/bin/bash
export CMUX_FIXTURE_CONSOLE_SESSION=1
exec "$@"
""")
        self.write_executable(self.bin / "lsof-fixture", "#!/bin/sh\nexit 0\n")
        self.write_executable(self.bin / "xcodebuild", """#!/usr/bin/env python3
import fcntl, json, os, pathlib, sys
env = os.environ
with open(env['CMUX_FIXTURE_CALLS'], 'a') as calls:
    calls.write(json.dumps({'args': sys.argv[1:], 'home': env['HOME'],
                          'host_home': env.get('TEST_RUNNER_HOME'),
                          'host_ci': env.get('TEST_RUNNER_CI')}) + '\\n')
assert env.get('CMUX_FIXTURE_CONSOLE_SESSION') == '1', 'app host bypassed console session'
if '-resolvePackageDependencies' in sys.argv or '-only-testing:cmuxUITests' in sys.argv:
    assert sys.argv[sys.argv.index('-derivedDataPath') + 1] == env['CMUX_DERIVED_DATA_PATH']
    raise SystemExit(0)
assert env.get('TEST_RUNNER_CMUX_TEST_PROCESS') == '1', 'missing early test-process marker'
assert env.get('TEST_RUNNER_CI') == 'true', 'CI identity lost before hook deadlines'
assert env.get('TEST_RUNNER_HOME') != env['HOME'], 'host shares driver home'
assert env.get('TEST_RUNNER_CMUX_APP_HOST_ISOLATION_REQUIRED') == '1'
host_home = pathlib.Path(env['TEST_RUNNER_HOME'])
assert host_home.is_dir()
assert env['TEST_RUNNER_CFFIXED_USER_HOME'] == str(host_home)
assert env['TEST_RUNNER_XDG_CONFIG_HOME'] == str(host_home / '.config')
assert env['TEST_RUNNER_SSH_AUTH_SOCK'] == ''
assert sys.argv[sys.argv.index('-derivedDataPath') + 1] == env['CMUX_DERIVED_DATA_PATH']
assert env['CMUX_APP_HOST_XCODEBUILD_ATTEMPTS'] == '1', 'semantic failure must not retry'
with open(env['CMUX_APP_HOST_TEST_LOCK_FILE'], 'r+') as lock:
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        pass
    else:
        raise AssertionError('app host ran without the machine lock')
result_path = pathlib.Path(sys.argv[sys.argv.index('-resultBundlePath') + 1])
result_path.mkdir()  # Like Xcode, refuse an existing result bundle.
print('cmux DEV [default] reading configuration file path=' + str(host_home / 'Library/Application Support/com.mitchellh.ghostty/config.ghostty'))
print('SocketControlServer: Listening on /tmp/cmux-xctest-fixture.sock')
if env.get('CMUX_FIXTURE_OUTCOME') == 'assertion':
    print('Test run with 2 tests in 1 suite failed after 0.001 seconds.')
    raise SystemExit(65)
print('Test run with 2 tests in 1 suite passed after 0.001 seconds.')
""")
        self.environment = {
            key: value for key, value in os.environ.items()
            if not key.startswith(("CMUX_", "TEST_RUNNER_", "GITHUB_"))
        }
        self.environment.update({key: str(value) for key, value in JOB.get("env", {}).items()})
        self.environment.update({
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "GITHUB_ENV": str(self.root / "github-env"),
            "GITHUB_STEP_SUMMARY": str(self.root / "summary.md"),
            "GITHUB_WORKSPACE": str(self.root),
            "GITHUB_REPOSITORY_ID": "12532",
            "GITHUB_RUN_ID": str(secrets.randbelow(10**14)),
            "GITHUB_RUN_ATTEMPT": "1",
            "RUNNER_TEMP": str(self.runner_temp),
            "CI": "true",
            "GITHUB_ACTIONS": "true",
            "UNIT_TEST_SUITES": "ClaudeFixture,CodexFixture",
            "TEST_FILTER": "",
            "TEST_TIMEOUT": "120",
            "CMUX_CI_APP_HOST_CLEANUP_TEST_HELPER": "1",
            "CMUX_APP_HOST_LSOF": str(self.bin / "lsof-fixture"),
            "CMUX_APP_HOST_TEST_LOCK_FILE": str(self.root / "test.lock"),
            "CMUX_FIXTURE_CALLS": str(self.root / "calls.jsonl"),
        })
        self.results = self.runner_temp / (
            "cmux-unit-results-" + self.environment["GITHUB_RUN_ID"] + "-1"
        )
        self.environment["TEST_RESULTS_ROOT"] = str(self.results)

    def write_executable(self, path, text):
        """Install an executable fixture inside this test's temporary checkout."""
        path.write_text(text)
        path.chmod(0o755)

    def step(self, name):
        """Execute a checked-in workflow step and carry its published environment."""
        step = next((step for step in JOB["steps"] if step.get("name") == name), None)
        self.assertIsNotNone(step, name)
        result = subprocess.run(
            ["bash", "-c", step["run"]], cwd=self.root, env=self.environment,
            capture_output=True, text=True,
        )
        env_path = self.root / "github-env"
        if env_path.exists():
            for line in env_path.read_text().splitlines():
                key, value = line.split("=", 1)
                self.environment[key] = value
        return result

    def prepare(self):
        """Create the same scoped build and configuration roots as the hosted job."""
        for name in ("Prepare isolated DerivedData", "Prepare isolated app-host home"):
            result = self.step(name)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.addCleanup(self.teardown_host)

    def teardown_host(self):
        """Verify all setup-owned paths are reclaimed through normal teardown."""
        result = self.step("Clean up isolated app-host home")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for key in ("CMUX_APP_HOST_HOME", "CMUX_APP_HOST_RECEIPT_DIR", "CMUX_APP_HOST_CONFIRMATION_FILE"):
            self.assertFalse(Path(self.environment[key]).exists(), key)

    def assert_selected_suites(self, expected_invocations=2):
        """Require one invocation for each selector, including on a failing run."""
        calls = [json.loads(line) for line in (self.root / "calls.jsonl").read_text().splitlines()]
        self.assertEqual(len(calls), expected_invocations)
        self.assertCountEqual(
            ["-only-testing:cmuxTests/ClaudeFixture", "-only-testing:cmuxTests/CodexFixture"],
            [arg for call in calls for arg in call["args"] if arg.startswith("-only-testing:cmuxTests/")],
        )

    def test_selected_suites_use_shared_isolated_console_launch(self):
        """The real launch wrapper supplies isolation, CI identity, and locking."""
        self.prepare()
        result = self.step("Run unit tests")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_selected_suites()
        self.assertEqual(result.stdout.count("category=tests passed"), 2)
        self.assertEqual(len(list(self.results.glob("suite.*/result.xcresult"))), 2)

    def test_assertions_stay_red_without_retrying_or_dropping_later_suites(self):
        """A first-suite failure neither retries nor prevents the second suite."""
        self.prepare()
        self.environment["CMUX_FIXTURE_OUTCOME"] = "assertion"
        result = self.step("Run unit tests")
        self.assertNotEqual(result.returncode, 0)
        self.assert_selected_suites()
        self.assertEqual(result.stdout.count("category=test assertion failure"), 2)

    def test_cross_account_hop_transfers_only_build_and_individual_results(self):
        """Exercise the real console wrapper with simulated privileged OS calls."""
        shutil.copy2(ROOT / "scripts/ci/run-in-console-session.sh", self.scripts)
        console_home = self.root / "console-home"
        console_home.mkdir()
        self.environment["CMUX_FIXTURE_CONSOLE_HOME"] = str(console_home)
        self.environment["CMUX_FIXTURE_OWNERSHIP"] = str(self.root / "ownership.jsonl")
        self.write_executable(self.bin / "stat", """#!/usr/bin/env python3
import getpass, os, sys
if sys.argv[1:] == ['-f', '%Su', '/dev/console']:
    print('fixture-console')
elif sys.argv[1:3] == ['-f', '%Su']:
    print(getpass.getuser())
else:
    os.execv('/usr/bin/stat', ['/usr/bin/stat', *sys.argv[1:]])
""")
        self.write_executable(self.bin / "id", """#!/usr/bin/env python3
import os, sys
if sys.argv[1:] == ['-u', 'fixture-console']:
    print('501')
else:
    os.execv('/usr/bin/id', ['/usr/bin/id', *sys.argv[1:]])
""")
        self.write_executable(self.bin / "dscl", """#!/usr/bin/env python3
import os
print('NFSHomeDirectory: ' + os.environ['CMUX_FIXTURE_CONSOLE_HOME'])
""")
        self.write_executable(self.bin / "sudo", """#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
while args and args[0].startswith('-'):
    flag = args.pop(0)
    if flag == '-u': args.pop(0)
if args[0] == 'chown':
    with open(os.environ['CMUX_FIXTURE_OWNERSHIP'], 'a') as output:
        output.write(json.dumps(args) + '\\n')
    raise SystemExit(0)
if args[:2] == ['launchctl', 'asuser']:
    assert args[3] == 'sudo'
    os.environ['CMUX_FIXTURE_CONSOLE_SESSION'] = '1'
    args = args[3:]
os.execvp(args[0], args)
""")
        self.prepare()
        resolved = self.step("Resolve Swift packages")
        self.assertEqual(resolved.returncode, 0, resolved.stdout + resolved.stderr)
        result = self.step("Run unit tests")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        ui = self.step("Run UI tests")
        self.assertEqual(ui.returncode, 0, ui.stdout + ui.stderr)
        self.assert_selected_suites(expected_invocations=4)
        transfers = [json.loads(line)[-1] for line in (self.root / "ownership.jsonl").read_text().splitlines()]
        self.assertEqual(transfers.count(self.environment["CMUX_DERIVED_DATA_PATH"]), 4)
        self.assertNotIn(str(self.results), transfers)
        for bundle in self.results.glob("suite.*/result.xcresult"):
            self.assertIn(str(bundle.parent), transfers)


if __name__ == "__main__":
    unittest.main()
