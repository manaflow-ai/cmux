#!/usr/bin/env python3
"""nightly-next-one refuses its secrets while a process of the job outlives its step (refuse_stray_processes.py).

One job builds, signs and publishes, so a detached process left by a build script, a dependency or the app would
run beside the keychain and the publication secrets. The check counts every process carrying this job's
RUNNER_TRACKING_ID or working under the runner's _work dir or $RUNNER_TEMP, except the runner, the processes of the
job hooks its Runner.Worker was started with, and the check's own process tree.
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
HOOKS = "/Users/ci/actions-runner/glaeda-hooks"
PYTHON = "/opt/homebrew/Cellar/python@3.13/3.13.15/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python"


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

    def hooked(self, **extra):
        """The first one-job nightly (run 43366166125): the job-started hook's admission holder and telemetry
        sampler, forks of the hook that run for the whole job with its environment."""
        table = self.table(**extra)
        table[200] = P(100, table[200].command, True, table[200].cwd,
                       (f"{HOOKS}/job-started.sh", f"{HOOKS}/job-completed.sh"))
        table[1000] = P(1, f"{PYTHON} {HOOKS}/glaeda-cmux-runner-hook job-started", True, "/")
        table[1001] = P(1, f"{PYTHON} {HOOKS}/glaeda-cmux-runner-hook job-started", True, "/")
        return table

    def test_the_runners_job_hook_processes_are_not_strays(self):
        table = self.hooked()
        hooks = stray.hook_dirs(table, 400, [WORK])
        self.assertEqual(hooks, [HOOKS])
        self.assertEqual(stray.strays(table, 400, [WORK], hooks), [])
        table[1002] = P(1, f"{HOOKS}/listen.sh", True, "/")
        self.assertEqual(stray.strays(table, 400, [WORK], hooks), [])
        self.assertEqual(stray.strays(table, 400, [WORK]), [1000, 1001, 1002], "without a hook they are strays")

    def test_only_a_program_of_the_hook_directory_is_spared(self):
        table = self.hooked()
        hooks = stray.hook_dirs(table, 400, [WORK])
        table[1100] = P(1, f"node {WORK}/cmux/cmux/web/watch.js {HOOKS}/glaeda-cmux-runner-hook", True, "/")
        table[1101] = P(1, f"/bin/cat -n {HOOKS}/job-started.sh", True, "/")
        table[1102] = P(1, f"{PYTHON} {HOOKS}-evil/glaeda-cmux-runner-hook", True, "/")
        table[1103] = P(1, f"{PYTHON} {HOOKS}/deeper/tool", True, "/")
        table[1104] = P(1, f"{PYTHON} glaeda-hooks/glaeda-cmux-runner-hook", False, f"{WORK}/cmux/cmux")
        table[1105] = P(1, "node build-helper.js", True, "/")
        self.assertEqual(stray.strays(table, 400, [WORK], hooks), [1100, 1101, 1102, 1103, 1104, 1105])

    def test_the_hook_directory_comes_from_this_jobs_worker_alone(self):
        """A step can set the variable for itself and for its children, never for the Runner.Worker above it."""
        table = self.table()
        table[300] = P(200, table[300].command, True, table[300].cwd, ("/tmp/evil/job-started.sh",))
        table[400] = P(300, table[400].command, True, table[400].cwd, ("/tmp/evil/job-started.sh",))
        table[910] = P(1, "/Users/ci/actions-runner-2/bin/Runner.Worker spawnclient 1 2", False, "/",
                       ("/Users/ci/actions-runner-2/glaeda-hooks/job-started.sh",))
        self.assertEqual(stray.hook_dirs(table, 400, [WORK]), [])
        self.assertEqual(stray.hook_dirs({400: table[400]}, 400, [WORK]), [], "no Runner.Worker above it")

    def test_a_hook_the_job_could_write_is_not_taken(self):
        for hook in (f"{WORK}/cmux/cmux/hooks/job-started.sh", f"{WORK}/_temp/job-started.sh", "/job-started.sh"):
            table = self.table()
            table[200] = P(100, table[200].command, True, table[200].cwd, (hook,))
            self.assertEqual(stray.hook_dirs(table, 400, [WORK]), [], hook)

    def test_ps_lists_the_hooks_after_the_arguments(self):
        line = (f"/Users/ci/actions-runner/bin/Runner.Worker spawnclient 1 2 HOME=/Users/ci "
                f"ACTIONS_RUNNER_HOOK_JOB_STARTED={HOOKS}/job-started.sh PATH=/usr/bin "
                f"ACTIONS_RUNNER_HOOK_JOB_COMPLETED={HOOKS}/job-completed.sh")
        self.assertEqual(stray.HOOK_IN_PS.findall(line), [f"{HOOKS}/job-started.sh", f"{HOOKS}/job-completed.sh"])
        self.assertEqual(stray.HOOK_IN_PS.findall("env NOT_ACTIONS_RUNNER_HOOK_JOB_STARTED=/x/y.sh"), [])
        self.assertEqual(stray.HOOK_IN_PS.findall("sh ACTIONS_RUNNER_HOOK_JOB_STARTED=relative/y.sh"), [])


DEV = "/Applications/Xcode_26.6.app/Contents/Developer"


class BuildDaemons(unittest.TestCase):
    """Run 43431310245: actool's two ibtoolds, detached with the job's environment, refused the signing secrets."""

    def test_only_this_jobs_ibtoold_of_the_selected_xcode_is_ended(self):
        table = Strays.table(Strays())
        table[61313] = P(1, f"{DEV}/usr/bin/ibtoold --sending-client-environment LLBUILD_BUILD_ID=1", True, "/")
        table[61315] = P(1, f"{DEV}/usr/bin/ibtoold --sending-client-environment LLBUILD_BUILD_ID=1", True, "/")
        table[61400] = P(1, "/Applications/Xcode_26.5.app/Contents/Developer/usr/bin/ibtoold", True, "/")
        table[61401] = P(1, f"{DEV}/usr/bin/ibtoold", False, "/")  # another job's or the user's: not a stray
        table[61402] = P(1, f"{WORK}/_temp/usr/bin/ibtoold", True, "/")
        table[61403] = P(1, "ibtoold", True, "/")
        table[61404] = P(1, f"{DEV}/usr/bin/actool --compile x", True, "/")
        table[61405] = P(1, "node build-helper.js", True, "/")
        found = stray.strays(table, 400, [WORK])
        self.assertEqual(found, [61313, 61315, 61400, 61402, 61403, 61404, 61405])
        self.assertEqual(stray.build_daemons(table, found, DEV), [61313, 61315])
        self.assertEqual(stray.build_daemons(table, found, DEV + "/"), [61313, 61315])
        self.assertEqual(stray.build_daemons(table, found, ""), [], "no Developer directory, nothing ended")


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

    def test_a_process_the_job_started_hook_left_passes_under_a_worker_with_that_hook(self):
        """The check runs under a stand-in Runner.Worker started with a job hook, as the runner starts it; the
        hook's own detached process (an interpreter running the hook's script, as glaeda's holder is) carries the
        tracking id for the whole job. A step's variable spares nothing."""
        with tempfile.TemporaryDirectory() as tmp:
            work, hooks, bin_dir = Path(tmp) / "_work", Path(tmp) / "glaeda-hooks", Path(tmp) / "bin"
            for made in (work / "_temp", work / "cmux", hooks, bin_dir):
                made.mkdir(parents=True)
            worker, holder = bin_dir / "Runner.Worker", hooks / "holder"
            worker.symlink_to(sys.executable)
            holder.write_text("import time\ntime.sleep(300)\n")
            run_step = [str(worker), "-c", "import subprocess, sys; sys.exit(subprocess.call(sys.argv[1:]))"]
            env = dict(os.environ, RUNNER_TRACKING_ID=f"test-hook-{os.getpid()}", RUNNER_TEMP=str(work / "_temp"),
                       RUNNER_WORKSPACE=str(work / "cmux"))
            env.pop("ACTIONS_RUNNER_HOOK_JOB_STARTED", None)
            hooked = dict(env, ACTIONS_RUNNER_HOOK_JOB_STARTED=str(hooks / "job-started.sh"))
            check = [sys.executable, "-c", "import sys; sys.path.insert(0, sys.argv[1]); import refuse_stray_processes "
                     "as s; s.GRACE_S = 0; sys.exit(s.main())", str(SCRIPT.parent)]
            child = subprocess.Popen([sys.executable, str(holder)], env=env, cwd="/", start_new_session=True)
            try:
                under_hook = subprocess.run([*run_step, *check], env=hooked, capture_output=True, text=True,
                                            timeout=120)
                self.assertEqual(under_hook.returncode, 0, under_hook.stdout + under_hook.stderr)
                self.assertIn(str(hooks), under_hook.stdout)
                no_hook = subprocess.run([*run_step, *check], env=env, capture_output=True, text=True, timeout=120)
                self.assertEqual(no_hook.returncode, 1, no_hook.stdout)
                self.assertIn(f"pid {child.pid}", no_hook.stdout)
                step_only = subprocess.run(check, env=hooked, capture_output=True, text=True, timeout=120)
                self.assertEqual(step_only.returncode, 1, step_only.stdout)
            finally:
                child.kill()
                child.wait()

    def test_the_build_step_ends_its_build_daemon_and_the_check_then_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            work, dev = Path(tmp) / "_work", Path(tmp) / "Developer"
            for made in (work / "_temp", work / "cmux", dev / "usr/bin"):
                made.mkdir(parents=True)
            daemon = dev / "usr/bin/ibtoold"
            daemon.symlink_to(Path(subprocess.run(["which", "sleep"], capture_output=True, text=True).stdout.strip()))
            env = dict(os.environ, RUNNER_TRACKING_ID=f"test-daemon-{os.getpid()}", RUNNER_TEMP=str(work / "_temp"),
                       RUNNER_WORKSPACE=str(work / "cmux"), DEVELOPER_DIR=str(dev))
            check = [sys.executable, "-c", "import sys; sys.path.insert(0, sys.argv[1]); import refuse_stray_processes "
                     "as s; s.GRACE_S = 0; sys.exit(s.main())", str(SCRIPT.parent)]
            child = subprocess.Popen([str(daemon), "300"], env=env, cwd="/", start_new_session=True)
            other = subprocess.Popen(["sleep", "300"], env=env, cwd="/", start_new_session=True)
            try:
                refused = subprocess.run(check, env=env, capture_output=True, text=True, timeout=120)
                self.assertEqual(refused.returncode, 1, refused.stdout)
                ended = subprocess.run([sys.executable, str(SCRIPT), "--end-build-daemons"], env=env,
                                       capture_output=True, text=True, timeout=120)
                self.assertEqual(ended.returncode, 0, ended.stdout + ended.stderr)
                self.assertIn(f"pid {child.pid}", ended.stdout)
                child.wait(timeout=30)
                self.assertIsNone(other.poll(), "a stray that is not a build daemon is left for the check")
                still = subprocess.run(check, env=env, capture_output=True, text=True, timeout=120)
                self.assertEqual(still.returncode, 1, still.stdout)
                self.assertIn(f"pid {other.pid}", still.stdout)
                self.assertNotIn(f"pid {child.pid}", still.stdout)
                other.kill()
                other.wait()
                self.assertEqual(subprocess.run(check, env=env, capture_output=True, text=True,
                                                timeout=120).returncode, 0)
            finally:
                for proc in (child, other):
                    if proc.poll() is None:
                        proc.kill()
                        proc.wait()


if __name__ == "__main__":
    unittest.main()
