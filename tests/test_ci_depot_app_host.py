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
            "TEST_RESULTS_ROOT": str(self.root / "results"),
            "CMUX_CI_APP_HOST_CLEANUP_TEST_HELPER": "1",
            "CMUX_APP_HOST_LSOF": str(self.bin / "lsof-fixture"),
            "CMUX_APP_HOST_TEST_LOCK_FILE": str(self.root / "test.lock"),
            "CMUX_FIXTURE_CALLS": str(self.root / "calls.jsonl"),
        })

    def write_executable(self, path, text):
        path.write_text(text)
        path.chmod(0o755)

    def step(self, name):
        step = next((step for step in JOB["steps"] if step.get("name") == name), None)
        self.assertIsNotNone(step, name)
        result = subprocess.run(
            ["bash", "-c", step["run"]], cwd=self.root, env=self.environment,
            capture_output=True, text=True, timeout=40,
        )
        env_path = self.root / "github-env"
        if env_path.exists():
            for line in env_path.read_text().splitlines():
                key, value = line.split("=", 1)
                self.environment[key] = value
        return result

    def prepare(self):
        for name in ("Prepare isolated DerivedData", "Prepare isolated app-host home"):
            result = self.step(name)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.addCleanup(self.teardown_host)

    def teardown_host(self):
        result = self.step("Clean up isolated app-host home")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(Path(self.environment["CMUX_APP_HOST_HOME"]).exists())

    def test_selected_suites_use_shared_isolated_console_launch(self):
        self.prepare()
        result = self.step("Run unit tests")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = [json.loads(line) for line in (self.root / "calls.jsonl").read_text().splitlines()]
        self.assertEqual(len(calls), 2)
        self.assertEqual(result.stdout.count("category=tests passed"), 2)
        self.assertEqual(len(list((self.root / "results").glob("suite.*/result.xcresult"))), 2)

    def test_assertions_stay_red_without_retrying_or_dropping_later_suites(self):
        self.prepare()
        self.environment["CMUX_FIXTURE_OUTCOME"] = "assertion"
        result = self.step("Run unit tests")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len((self.root / "calls.jsonl").read_text().splitlines()), 2)
        self.assertEqual(result.stdout.count("category=test assertion failure"), 2)


if __name__ == "__main__":
    unittest.main()
