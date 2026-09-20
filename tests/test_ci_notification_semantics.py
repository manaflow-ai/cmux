#!/usr/bin/env python3
"""Execute the notification gates with controlled test-runner outcomes."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
SUITES = [
    "AgentNotificationRegressionTests",
    "AgentJournalLifecycleCenterTests",
    "FeedWaiterRegistryTests",
    "ClaudeBackgroundWorkNotifyTests",
    "OpenCodeHookRegressionTests",
]


def step_script(job, name):
    workflow = yaml.safe_load((ROOT / ".github/workflows/ci.yml").read_text())
    return next(s["run"] for s in workflow["jobs"][job]["steps"] if s.get("name") == name)


class NotificationSemanticsTests(unittest.TestCase):
    def run_gate(self, outcome="pass", fail_suite=SUITES[1]):
        script = step_script("app-host-unit-tests", "Run agent notification semantics")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            helpers = root / "scripts/ci"
            helpers.mkdir(parents=True)
            console = helpers / "run-in-console-session.sh"
            console.write_text('#!/bin/bash\nexec "$@"\n')
            console.chmod(0o755)
            runner = helpers / "run-app-host-xcodebuild.sh"
            runner.write_text("""#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ['CALLS'], 'a') as f:
    f.write(json.dumps({'args': args, 'path': os.getenv('TEST_RUNNER_PATH'),
                        'bun': os.getenv('TEST_RUNNER_BUN_INSTALL')}) + '\\n')
suite = next(a.split('/', 1)[1] for a in args if a.startswith('-only-testing:'))
outcome = os.environ['OUTCOME'] if suite == os.environ['FAIL_SUITE'] else 'pass'
if outcome == 'crash':
    print('The test runner timed out while preparing to run tests.')
    sys.exit(65)
if outcome == 'zero':
    print('Executed 0 tests, with 0 failures (0 unexpected) in 0.0 seconds')
elif outcome == 'failure':
    print('Executed 3 tests, with 1 failure (0 unexpected) in 0.1 seconds')
    sys.exit(65)
elif suite == 'OpenCodeHookRegressionTests':
    print('Executed 3 tests, with 0 failures (0 unexpected) in 0.1 seconds')
else:
    print('Test run with 4 tests in 1 suite passed after 0.1 seconds.')
""")
            runner.chmod(0o755)
            shutil.copy2(ROOT / "scripts/ci/require_selected_test_execution.sh", helpers)
            bindir = root / "bin"
            bindir.mkdir()
            for command in ("node", "bun"):
                executable = bindir / command
                executable.write_text("#!/bin/bash\nexit 0\n")
                executable.chmod(0o755)
            calls = root / "calls.jsonl"
            env = dict(os.environ, PATH=f"{bindir}:{os.environ['PATH']}",
                       RUNNER_TEMP=str(root), CALLS=str(calls), OUTCOME=outcome,
                       FAIL_SUITE=fail_suite, CMUX_APP_HOST_XCTESTRUN="/products/cmux-unit.xctestrun")
            result = subprocess.run(["/bin/bash", "-c", script], cwd=root, env=env,
                                    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            invocations = [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []
            return result, invocations

    def test_every_suite_runs_once_from_the_compiled_product(self):
        result, calls = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(len(calls), len(SUITES))
        for suite, call in zip(SUITES, calls):
            args = call["args"]
            self.assertIn(f"-only-testing:cmuxTests/{suite}", args)
            self.assertEqual(args[args.index("-xctestrun") + 1], "/products/cmux-unit.xctestrun")
            self.assertIn("test-without-building", args)
            self.assertNotIn("test", args)
            self.assertNotIn("build-for-testing", args)
            self.assertTrue(call["path"])
            self.assertTrue(call["bun"])

    def test_assertion_failure_cannot_pass(self):
        result, _ = self.run_gate("failure")
        self.assertEqual(result.returncode, 65, result.stdout)

    def test_host_failure_cannot_pass(self):
        result, _ = self.run_gate("crash")
        self.assertEqual(result.returncode, 65, result.stdout)

    def test_empty_filter_cannot_pass(self):
        for suite in SUITES:
            with self.subTest(suite=suite):
                result, _ = self.run_gate("zero", suite)
                self.assertNotEqual(result.returncode, 0, result.stdout)


if __name__ == "__main__":
    unittest.main()
