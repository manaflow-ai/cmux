#!/usr/bin/env python3
"""nightly-next-one refuses its secrets while a process of the job outlives its step (refuse_stray_processes.py).

One job builds, signs and publishes, so a detached process left by a build script, a dependency or the app would
run beside the keychain and the publication secrets. The check counts every process carrying this job's
RUNNER_TRACKING_ID or working under the runner's _work dir or $RUNNER_TEMP, except the runner and the check's own
process tree.
"""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/refuse_stray_processes.py"
sys.path.insert(0, str(ROOT / "scripts/ci"))

import refuse_stray_processes as stray  # noqa: E402

P = stray.Proc
WORK = "/Users/ci/actions-runner/_work"


class Strays(unittest.TestCase):
    def table(self, **extra):
        base = {
            1: P(0, "launchd", False, "/"),
            100: P(1, "/Users/ci/actions-runner/bin/Runner.Listener run", False, "/Users/ci/actions-runner"),
            200: P(100, "/Users/ci/actions-runner/bin/Runner.Worker spawnclient 1 2", True, f"{WORK}/cmux/cmux"),
            300: P(200, "/bin/bash -e /Users/ci/actions-runner/_work/_temp/step.sh", True, f"{WORK}/cmux/cmux"),
            400: P(300, "python3 refuse_stray_processes.py", True, f"{WORK}/cmux/cmux"),
            401: P(400, "/bin/ps -E", True, f"{WORK}/cmux/cmux"),
            500: P(1, "/usr/sbin/cfprefsd agent", False, "/"),
        }
        base.update(extra)
        return base

    def test_the_runner_and_this_steps_tree_are_not_strays(self):
        self.assertEqual(stray.strays(self.table(), 400, [WORK]), [])

    def test_a_detached_process_with_the_tracking_id_is_a_stray(self):
        table = self.table()
        table[600] = P(1, "node build-helper.js", True, "/tmp")
        self.assertEqual(stray.strays(table, 400, [WORK]), [600])

    def test_a_process_working_under_the_runner_is_a_stray(self):
        table = self.table()
        table[700] = P(1, "cmux-next --daemon", False, f"{WORK}/cmux/cmux/build-universal")
        table[701] = P(1, "zig build", False, f"{WORK}/_temp/zig")
        self.assertEqual(stray.strays(table, 400, [WORK]), [700, 701])

    def test_a_child_an_earlier_step_left_under_the_worker_is_a_stray(self):
        table = self.table()
        table[800] = P(200, "bun install", True, f"{WORK}/cmux/cmux/web")
        self.assertEqual(stray.strays(table, 400, [WORK]), [800])

    def test_another_runners_job_is_not_this_jobs(self):
        table = self.table()
        table[900] = P(1, "xcodebuild", False, "/Users/ci/actions-runner-2/_work/cmux/cmux")
        self.assertEqual(stray.strays(table, 400, [WORK]), [])


@unittest.skipUnless(sys.platform.startswith("linux"), "reads /proc")
class LiveCheck(unittest.TestCase):
    def run_check(self, env):
        return subprocess.run([sys.executable, str(SCRIPT)], env=env, capture_output=True, text=True, timeout=120)

    def test_a_detached_child_fails_the_check_and_none_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp) / "_work"
            (work / "_temp").mkdir(parents=True)
            (work / "cmux").mkdir()
            tracking = f"test-{os.getpid()}"
            env = dict(os.environ, RUNNER_TRACKING_ID=tracking, RUNNER_TEMP=str(work / "_temp"),
                       RUNNER_WORKSPACE=str(work / "cmux"))
            self.assertEqual(self.run_check(env).returncode, 0)
            child = subprocess.Popen(["sleep", "300"], env=env, cwd="/", start_new_session=True)
            try:
                result = subprocess.run(
                    [sys.executable, "-c", "import sys; sys.path.insert(0, sys.argv[1]); import refuse_stray_processes "
                     "as s; s.GRACE_S = 0; sys.exit(s.main())", str(SCRIPT.parent)],
                    env=env, capture_output=True, text=True, timeout=120)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn(f"pid {child.pid}", result.stdout)
            finally:
                child.kill()
                child.wait()


if __name__ == "__main__":
    unittest.main()
