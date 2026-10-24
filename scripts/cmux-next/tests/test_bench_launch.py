#!/usr/bin/env python3
"""bench_launch.py never cuts off a live same-tag app (review 2 of pl-fleet-gui).

1. `check` against a bundle whose app already runs refuses with tag-in-use, and its stop() must not run the tag
   teardown: that teardown ends every process of the bundle, which here is the live app, not one this run started.
2. The pre-launch socket probe unlinks only a socket nothing listens on: a socket that accepts but does not answer in
   time (a busy main thread, a long restore) belongs to a live app of the tag (another bundle path).
3. The app starts with launchd's soft limits (a Finder launch's), not the caller's raised ones: a bench at 65536
   open files hid a crash at 256 (cmux-lawrence-2, 2026-10-23). Also `finder-exec`, and the caller's limits are
   restored after the launch.
4. Low Power Mode (a fake pmset): host_facts records it; a launch in Low Power Mode is refused unless the bench passes
   low_power_mode_ok=True; a bench switches it only in an exclusive step and switches it back at exit, SIGTERM and
   SIGHUP; a launch after a switch nobody proved undone is refused while Low Power Mode differs from its value
   before that switch.
5. Sound (a fake osascript): a launch mutes the sound output, BENCH_LAUNCH_AUDIO=keep leaves it.

Runs on any Mac, no GUI session or build needed (BENCH_LAUNCH_ANY_SESSION=1, a copy of /bin/sleep stands in for the
app's executable). Signals only the processes it starts.

    python3 scripts/cmux-next/tests/test_bench_launch.py
"""

from __future__ import annotations

import os
import resource
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
import bench_launch as bl  # noqa: E402

# No test changes the host's sound output: osascript answers nothing unless a test gives its own fake.
os.environ["BENCH_LAUNCH_OSASCRIPT"] = "/usr/bin/false"


def fake_bundle(folder: str, tag: str) -> str:
    """A `cmux DEV <tag>.app` whose main executable is a copy of /bin/sleep."""
    app = os.path.join(os.path.realpath(folder), f"cmux DEV {tag}.app")
    macos = os.path.join(app, "Contents/MacOS")
    os.makedirs(macos)
    # copy, not copy2: copy2 also copies /bin/sleep's system flags, and chflags fails with EPERM for a normal
    # account (Python 3.9 of Xcode 26.6 on aws-m4pro-3, macOS 27.0.1).
    shutil.copy("/bin/sleep", os.path.join(macos, "cmux DEV"))
    return app


class TagInUseTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="bench-launch-test-")
        self.tag = f"bl-test-{os.getpid()}"
        self.started: list[subprocess.Popen] = []

    def tearDown(self):
        for process in self.started:
            if process.poll() is None:
                process.kill()  # the exact process this test started
                process.wait()
        shutil.rmtree(self.folder, ignore_errors=True)

    def test_a_check_refused_as_tag_in_use_leaves_the_running_app_alive(self):
        app = fake_bundle(self.folder, self.tag)
        live = subprocess.Popen([os.path.join(app, "Contents/MacOS/cmux DEV"), "300"])
        self.started.append(live)
        result = subprocess.run(
            [sys.executable, str(HERE / "bench_launch.py"), "check", "--app", app, "--timeout", "5",
             "--out", os.path.join(self.folder, "out")],
            env=dict(os.environ, BENCH_LAUNCH_ANY_SESSION="1"), capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("tag-in-use", result.stdout)
        self.assertIsNone(live.poll(), "the refused check's teardown ended the live app of the bundle:\n" + result.stdout)

    def test_a_socket_that_accepts_but_does_not_answer_is_in_use(self):
        path = os.path.join(self.folder, "silent.sock")
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(path)
        listener.listen(4)  # never accepts or answers: connect() still succeeds through the backlog
        try:
            self.assertTrue(bl.socket_in_use(path), "a live socket that answers slowly counted as free")
        finally:
            listener.close()

    def test_a_socket_nothing_listens_on_is_free(self):
        path = os.path.join(self.folder, "stale.sock")
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(path)
        listener.close()  # the file stays, nothing listens: connect() is refused
        self.assertTrue(os.path.exists(path))
        self.assertFalse(bl.socket_in_use(path))
        self.assertFalse(bl.socket_in_use(os.path.join(self.folder, "missing.sock")))

    def test_the_state_socket_and_its_tmp_link_are_probed_once(self):
        target = os.path.join(self.folder, "state.sock")
        open(target, "w").close()
        link = os.path.join(self.folder, "link.sock")
        os.symlink(target, link)
        self.assertEqual(bl.unique_paths([target, link]), [target])


LAUNCHCTL_SAMPLE = """\tcpu         unlimited      unlimited
\tstack       8372224        67092480
\tcore        0              unlimited
\tmaxproc     8000           12000
\tmaxfiles    256            unlimited
"""


class FinderLimitsTests(unittest.TestCase):
    """The caller raises its soft open-file limit above launchd's, as the fleet job shells do."""

    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="bench-launch-limits-")
        self.saved = resource.getrlimit(resource.RLIMIT_NOFILE)
        self.launchd = bl.launchd_soft_limits()["maxfiles"]
        soft, hard = self.saved
        self.raised = min(self.launchd + 1000, hard)
        if self.raised == self.launchd:
            self.skipTest(f"the hard open-file limit is launchd's soft one ({hard}): nothing to lower")
        resource.setrlimit(resource.RLIMIT_NOFILE, (self.raised, hard))

    def tearDown(self):
        resource.setrlimit(resource.RLIMIT_NOFILE, self.saved)
        shutil.rmtree(self.folder, ignore_errors=True)

    def test_launchctl_limit_output_parses_to_soft_limits(self):
        self.assertEqual(bl.launchd_soft_limits(LAUNCHCTL_SAMPLE),
                         {"cpu": resource.RLIM_INFINITY, "stack": 8372224, "core": 0, "maxproc": 8000, "maxfiles": 256})

    def test_a_child_started_inside_gets_launchds_soft_limit_and_the_caller_gets_its_own_back(self):
        with bl.finder_limits(LAUNCHCTL_SAMPLE) as changed:
            inside = subprocess.run(["/bin/sh", "-c", "ulimit -Sn"], capture_output=True, text=True).stdout.strip()
        self.assertEqual(inside, "256")
        self.assertEqual(changed["maxfiles"], [self.raised, 256])
        self.assertEqual(resource.getrlimit(resource.RLIMIT_NOFILE)[0], self.raised)

    def test_the_launched_app_gets_launchds_soft_limit(self):
        app = os.path.join(os.path.realpath(self.folder), f"cmux DEV bl-limits-{os.getpid()}.app")
        os.makedirs(os.path.join(app, "Contents/MacOS"))
        seen = os.path.join(self.folder, "nofile")
        main = os.path.join(app, "Contents/MacOS/cmux DEV")
        with open(main, "w") as f:
            f.write(f"#!/bin/sh\nulimit -Sn > '{seen}'\n")  # records its limit, then exits: the launch fails fast
        os.chmod(main, 0o755)
        bench = bl.BenchApp(app, out=os.path.join(self.folder, "out"), teardown=False)
        os.environ["BENCH_LAUNCH_ANY_SESSION"] = "1"
        try:
            with self.assertRaises(bl.LaunchError):
                bench.launch(timeout=5)
        finally:
            os.environ.pop("BENCH_LAUNCH_ANY_SESSION")
        with open(seen) as f:
            self.assertEqual(f.read().strip(), str(self.launchd))
        self.assertIn(f"maxfiles {self.launchd} (caller {self.raised})", bench.limits)
        self.assertEqual(resource.getrlimit(resource.RLIMIT_NOFILE)[0], self.raised)

    def test_inherit_and_a_silent_launchctl_apply_nothing_and_say_so(self):
        with bl.finder_limits("") as changed:
            inside = subprocess.run(["/bin/sh", "-c", "ulimit -Sn"], capture_output=True, text=True).stdout.strip()
        self.assertIsNone(changed)
        self.assertEqual(inside, str(self.raised))
        self.assertIn("NOT a Finder launch", bl.limits_line(changed))
        os.environ["BENCH_LAUNCH_LIMITS"] = "inherit"
        try:
            with bl.finder_limits(LAUNCHCTL_SAMPLE) as changed:
                self.assertIsNone(changed)
                self.assertIn("BENCH_LAUNCH_LIMITS=inherit", bl.limits_line(changed))
        finally:
            os.environ.pop("BENCH_LAUNCH_LIMITS")

    def test_a_caller_holding_launchds_maxfiles_is_refused_with_a_reason(self):
        held = [os.open("/dev/null", os.O_RDONLY) for _ in range(40)]
        try:
            with self.assertRaises(bl.LaunchError) as caught:
                with bl.finder_limits("\tmaxfiles 32 unlimited\n"):
                    pass
            self.assertEqual(caught.exception.reason, "caller-fds")
            self.assertEqual(resource.getrlimit(resource.RLIMIT_NOFILE)[0], self.raised)
        finally:
            for fd in held:
                os.close(fd)

    def test_finder_exec_runs_the_command_with_launchds_soft_limit(self):
        out = subprocess.run([sys.executable, str(HERE / "bench_launch.py"), "finder-exec", "--", "/bin/sh", "-c",
                              "ulimit -Sn"], capture_output=True, text=True, timeout=60)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.strip().splitlines()[-1], str(self.launchd))


FAKE_PMSET = """#!/bin/sh
# A fake pmset: `-g` prints the state file's Low Power Mode (no key when the file holds "none"); `-a lowpowermode N`
# writes N unless the file "stuck" exists (a switch back that does not take).
state="$(dirname "$0")/state"
if [ "$1" = "-g" ]; then
  echo "System-wide power settings:"
  echo "Currently in use:"
  echo " sleep                0"
  v="$(cat "$state")"
  [ "$v" = none ] || echo " lowpowermode         $v"
  exit 0
fi
if [ "$1" = "-a" ] && [ "$2" = lowpowermode ]; then
  [ -e "$(dirname "$0")/stuck" ] && [ "$3" = 0 ] && exit 0
  echo "$3" > "$state"; exit 0
fi
exit 1
"""


class LowPowerModeTests(unittest.TestCase):
    def setUp(self):
        self.folder = os.path.realpath(tempfile.mkdtemp(prefix="bench-launch-lpm-"))
        self.pmset = os.path.join(self.folder, "pmset")
        with open(self.pmset, "w") as f:
            f.write(FAKE_PMSET)
        os.chmod(self.pmset, 0o755)
        self.set_state("0")
        self.saved_env = dict(os.environ)
        os.environ.update(BENCH_LAUNCH_PMSET=self.pmset, BENCH_LAUNCH_TEST_NO_SUDO="1", BENCH_LAUNCH_ANY_SESSION="1",
                          BENCH_LAUNCH_LPM_MARKER=os.path.join(self.folder, "lpm-marker.json"))
        os.environ.pop("CMUX_CI_STEP_CLASS", None)
        self.tag = f"bl-lpm-{os.getpid()}"

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.saved_env)
        shutil.rmtree(self.folder, ignore_errors=True)

    def set_state(self, value):
        with open(os.path.join(self.folder, "state"), "w") as f:
            f.write(value + "\n")

    def state(self):
        with open(os.path.join(self.folder, "state")) as f:
            return f.read().strip()

    def bench(self, **kwargs):
        app = os.path.join(self.folder, f"cmux DEV {self.tag}.app")
        if not os.path.exists(app):
            os.makedirs(os.path.join(app, "Contents/MacOS"))
            main = os.path.join(app, "Contents/MacOS/cmux DEV")
            with open(main, "w") as f:
                f.write("#!/bin/sh\nexit 0\n")  # exits at once: a launch that passes the checks fails "exited"
            os.chmod(main, 0o755)
        return bl.BenchApp(app, out=os.path.join(self.folder, "out"), teardown=False, **kwargs)

    def launch_reason(self, bench):
        with self.assertRaises(bl.LaunchError) as caught:
            bench.launch(timeout=5)
        return caught.exception.reason

    def test_host_facts_record_low_power_mode_and_null_without_the_key(self):
        self.set_state("1")
        self.assertIs(bl.host_facts()["low_power_mode"], True)
        self.set_state("0")
        self.assertIs(bl.host_facts()["low_power_mode"], False)
        self.set_state("none")
        self.assertIsNone(bl.host_facts()["low_power_mode"])

    def test_a_launch_in_low_power_mode_is_refused_unless_the_bench_allows_it(self):
        self.set_state("1")
        bench = self.bench()
        self.assertEqual(self.launch_reason(bench), "low-power-mode")
        self.assertIsNone(bench.process, "the refused launch started the app")
        self.assertEqual(self.launch_reason(self.bench(low_power_mode_ok=True)), "exited")
        self.set_state("none")  # a Mac whose pmset has no lowpowermode key
        self.assertEqual(self.launch_reason(self.bench()), "exited")

    def test_a_switch_outside_an_exclusive_step_is_refused(self):
        with self.assertRaises(bl.LaunchError) as caught:
            with bl.LowPowerModeSwitch(True):
                pass
        self.assertEqual(caught.exception.reason, "low-power-mode-switch")
        self.assertEqual(self.state(), "0")

    def test_a_switch_is_undone_at_exit_and_proved(self):
        os.environ["CMUX_CI_STEP_CLASS"] = "exclusive"
        with bl.LowPowerModeSwitch(True):
            self.assertEqual(self.state(), "1")
            self.assertEqual(self.launch_reason(self.bench(low_power_mode_ok=True)), "exited")
        self.assertEqual(self.state(), "0")
        self.assertFalse(os.path.exists(os.environ["BENCH_LAUNCH_LPM_MARKER"]))
        self.assertEqual(self.launch_reason(self.bench()), "exited")

    def test_a_switch_is_undone_at_sigterm_and_sighup(self):
        for sig in (signal.SIGTERM, signal.SIGHUP):
            child = subprocess.Popen(
                [sys.executable, "-c", "import os, sys, time; sys.path.insert(0, sys.argv[1]); import bench_launch as bl\n"
                 "with bl.LowPowerModeSwitch(True):\n    print('on', flush=True)\n    time.sleep(60)\n", str(HERE)],
                env=dict(os.environ, CMUX_CI_STEP_CLASS="exclusive"), stdout=subprocess.PIPE, text=True)
            try:
                lines = []
                while not lines or lines[-1] not in ("on", ""):
                    lines.append(child.stdout.readline().strip())  # the switch's own notes come first
                self.assertEqual(lines[-1], "on", lines)
                self.assertEqual(self.state(), "1")
                child.send_signal(sig)  # the process this test started
                child.wait(30)
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait()
                child.stdout.close()
            self.assertEqual(child.returncode, -sig)
            self.assertEqual(self.state(), "0", f"Low Power Mode stayed on after {sig.name}")
            self.assertFalse(os.path.exists(os.environ["BENCH_LAUNCH_LPM_MARKER"]))

    def test_a_switch_nobody_proved_undone_refuses_later_launches(self):
        os.environ["CMUX_CI_STEP_CLASS"] = "exclusive"
        open(os.path.join(self.folder, "stuck"), "w").close()  # the switch back does not take
        with self.assertRaises(bl.LaunchError) as caught:
            with bl.LowPowerModeSwitch(True):
                pass
        self.assertEqual(caught.exception.reason, "low-power-mode-not-restored")
        self.assertEqual(self.state(), "1")
        self.assertTrue(os.path.exists(os.environ["BENCH_LAUNCH_LPM_MARKER"]), "the unproved switch left no record")
        # Still on: no later launch runs, even one that allows Low Power Mode.
        self.assertEqual(self.launch_reason(self.bench(low_power_mode_ok=True)), "low-power-mode-not-restored")
        # Back to the value from before the switch (someone switched it back): the record clears, launches run.
        os.unlink(os.path.join(self.folder, "stuck"))
        self.set_state("0")
        self.assertEqual(self.launch_reason(self.bench()), "exited")
        self.assertFalse(os.path.exists(os.environ["BENCH_LAUNCH_LPM_MARKER"]))

FAKE_OSASCRIPT = """#!/bin/sh
# A fake osascript: the file muted holds true or false.
state="$(dirname "$0")/muted"
case "$2" in
  "output muted of (get volume settings)") cat "$state" ;;
  "set volume with output muted") echo true > "$state" ;;
  *) exit 1 ;;
esac
"""


class SoundTests(unittest.TestCase):
    def setUp(self):
        self.folder = os.path.realpath(tempfile.mkdtemp(prefix="bench-launch-sound-"))
        script = os.path.join(self.folder, "osascript")
        with open(script, "w") as f:
            f.write(FAKE_OSASCRIPT)
        os.chmod(script, 0o755)
        self.muted("false")
        self.saved_env = dict(os.environ)
        os.environ.update(BENCH_LAUNCH_OSASCRIPT=script, BENCH_LAUNCH_ANY_SESSION="1",
                          BENCH_LAUNCH_PMSET="/usr/bin/false",
                          BENCH_LAUNCH_LPM_MARKER=os.path.join(self.folder, "lpm-marker.json"))
        os.environ.pop("BENCH_LAUNCH_AUDIO", None)
        app = os.path.join(self.folder, f"cmux DEV bl-sound-{os.getpid()}.app")
        os.makedirs(os.path.join(app, "Contents/MacOS"))
        main = os.path.join(app, "Contents/MacOS/cmux DEV")
        with open(main, "w") as f:
            f.write("#!/bin/sh\nexit 0\n")
        os.chmod(main, 0o755)
        self.app = app

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.saved_env)
        shutil.rmtree(self.folder, ignore_errors=True)

    def muted(self, value=None):
        path = os.path.join(self.folder, "muted")
        if value is not None:
            with open(path, "w") as f:
                f.write(value + "\n")
        with open(path) as f:
            return f.read().strip()

    def launch(self):
        with self.assertRaises(bl.LaunchError):
            bl.BenchApp(self.app, out=os.path.join(self.folder, "out"), teardown=False).launch(timeout=5)

    def test_a_launch_mutes_the_sound_output(self):
        self.launch()
        self.assertEqual(self.muted(), "true")

    def test_keep_leaves_the_sound_output(self):
        os.environ["BENCH_LAUNCH_AUDIO"] = "keep"
        self.launch()
        self.assertEqual(self.muted(), "false")


if __name__ == "__main__":
    unittest.main()
