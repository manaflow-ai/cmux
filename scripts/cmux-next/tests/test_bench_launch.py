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
6. No environment variable passes the GUI-session gate; the one launch without a session is the explicit socket-only
   check, and its report says so.
7. After a signal exit the crash-report wait wakes on the report folder, also for an account that never crashed (no
   report folder yet), and says when it could watch no folder instead of returning at once in silence.
8. `BenchApp.record` writes cmux-perf-result/v1 that the real perf_result.py accepts, with a full build sha, a
   stated or derived config, the store's host class, the display Hz, and the features.list snapshot launch() read
   (a relaunch reads its own; record after stop() keeps it; no snapshot refuses). perf_result.py is loaded by file
   path, and every bench that imports bench_launch still loads under `python3 -I`.
9. bench_env.py names a Swift read site for every switch the bench app gets, the launch passes exactly its fixed
   switches and config keys, and no switch is one the app strips at launch.
10. The control socket probe (p08-startup-019) times the first answer, not the first accept: a request sent into a
   listener that answers late is timed at its answer; the verdict is the p50 of answer minus first frame against
   the budget, and a run with no answer or no frame fails it.
11. `own_responsibility` (p01-process-089) spawns the app with responsibility disclaimed (a fake libsystem records the
   calls), refuses to launch when this system cannot disclaim, and its stand-in Popen reaps and signals the child.
12. `after-kill` (p01-process-152): each relaunch after SIGKILL of the app was a clean launch, reattached to the
   running daemon and drew every terminal screen within the budget of its first frame; a run that started a daemon,
   sent no drawn mark, came up in restart-loop safe mode or (with relaunchReattach on) drew an earlier quit's terminal
   frame or window picture fails it. Each app lives past the quick-crash window before its kill. The flow kills only
   the app it started.

Runs on any Mac, no GUI session or build needed (the session read is injected or the check is `--socket-only`, and a
copy of /bin/sleep stands in for the app's executable). Signals only the processes it starts. On Linux, 8 and 9 and
the tests that need no macOS tool run; the rest are skipped.

    python3 -m unittest scripts/cmux-next/tests/test_bench_launch.py
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import resource
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
import bench_launch as bl  # noqa: E402

ROOT = HERE.parent.parent
# sw_vers, launchctl, pmset, kqueue and a copy of /bin/sleep as the app: macOS only.
ON_MAC = unittest.skipUnless(sys.platform == "darwin", "needs macOS tools")
# No test changes the host's sound output: osascript answers nothing unless a test gives its own fake.
os.environ["BENCH_LAUNCH_OSASCRIPT"] = "/usr/bin/false"
# No test moves a real tag's saved state (bench_launch.start_fresh): every tag root is under a temporary base.
os.environ["BENCH_LAUNCH_STATE_BASE"] = tempfile.mkdtemp(prefix="bench-launch-state-")


def fake_bundle(folder: str, tag: str) -> str:
    """A `cmux DEV <tag>.app` whose main executable is a copy of /bin/sleep."""
    app = os.path.join(os.path.realpath(folder), f"cmux DEV {tag}.app")
    macos = os.path.join(app, "Contents/MacOS")
    os.makedirs(macos)
    # copy, not copy2: copy2 also copies /bin/sleep's system flags, and chflags fails with EPERM for a normal
    # account (Python 3.9 of Xcode 26.6 on aws-m4pro-3, macOS 27.0.1).
    shutil.copy("/bin/sleep", os.path.join(macos, "cmux DEV"))
    return app


OK_SESSION = {"ok": True, "user": "worker", "console_user": "worker", "screen_locked": False,
              "detail": "worker is the console user"}
NO_SESSION = {"ok": False, "user": "worker", "console_user": None, "screen_locked": None,
              "detail": "nobody is logged in on the console (login window); worker has no GUI session"}


@ON_MAC
class SessionGateTests(unittest.TestCase):
    """No environment variable turns the GUI-session gate off (deep review of fleet-gui, findings 3 and 7): a step
    that exported BENCH_LAUNCH_ANY_SESSION=1 got past it, and every bench in that environment then measured a display
    that does not tick and wrote its frame rows as a normal run."""

    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="bench-launch-gate-")
        self.tag = f"bl-gate-{os.getpid()}"

    def tearDown(self):
        shutil.rmtree(self.folder, ignore_errors=True)

    def test_a_launch_without_a_gui_session_starts_no_app_whatever_the_environment(self):
        app = bl.BenchApp(fake_bundle(self.folder, self.tag), out=os.path.join(self.folder, "out"), teardown=False)
        with mock.patch.object(bl, "gui_session", return_value=NO_SESSION), \
                mock.patch.dict(os.environ, {"BENCH_LAUNCH_ANY_SESSION": "1"}):
            with self.assertRaises(bl.LaunchError) as refused:
                app.launch(timeout=5)
        try:
            self.assertEqual(refused.exception.reason, "no-gui-session")
            self.assertIsNone(app.process, "the gate let an app start with no GUI session")
        finally:
            if app.process and app.process.poll() is None:
                app.process.kill()  # the exact process this test made launch() start
                app.process.wait()

    def test_the_bench_session_check_cannot_be_skipped(self):
        with mock.patch.object(bl, "gui_session", return_value=NO_SESSION), \
                mock.patch.dict(os.environ, {"BENCH_LAUNCH_ANY_SESSION": "1"}), \
                mock.patch.object(bl, "note"):
            with self.assertRaises(SystemExit) as refused:
                bl.require_gui_session("test", argv=[])
        self.assertEqual(refused.exception.code, 1)


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

    @ON_MAC
    def test_a_check_refused_as_tag_in_use_leaves_the_running_app_alive(self):
        app = fake_bundle(self.folder, self.tag)
        live = subprocess.Popen([os.path.join(app, "Contents/MacOS/cmux DEV"), "300"])
        self.started.append(live)
        report_path = os.path.join(self.folder, "check.json")
        result = subprocess.run(
            [sys.executable, str(HERE / "bench_launch.py"), "check", "--socket-only", "--app", app, "--timeout", "5",
             "--out", os.path.join(self.folder, "out"), "--json", report_path],
            capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("tag-in-use", result.stdout)
        self.assertIsNone(live.poll(), "the refused check's teardown ended the live app of the bundle:\n" + result.stdout)
        with open(report_path) as f:
            report = json.load(f)
        self.assertEqual(report.get("reason"), "tag-in-use")
        self.assertIs(report.get("socket_only"), True, "a socket-only check's report does not say so")
        self.assertIn("ok", report.get("gui_session") or {}, "a socket-only check's report has no gui_session")

    @ON_MAC
    def test_a_launch_with_an_injected_session_is_refused_as_tag_in_use_and_stops_nothing(self):
        app_path = fake_bundle(self.folder, self.tag)
        live = subprocess.Popen([os.path.join(app_path, "Contents/MacOS/cmux DEV"), "300"])
        self.started.append(live)
        app = bl.BenchApp(app_path, out=os.path.join(self.folder, "out"), session=lambda: OK_SESSION)
        with mock.patch.object(bl, "note"):
            with self.assertRaises(bl.LaunchError) as refused:
                app.launch(timeout=5)
            app.stop()  # what every bench's finally runs: the bundle's live app is another run's
        self.assertEqual(refused.exception.reason, "tag-in-use")
        self.assertIsNone(app.process)
        self.assertEqual(refused.exception.report.get("gui_session"), OK_SESSION)
        self.assertIsNone(live.poll(), "stop() after a refused launch ended the live app of the bundle")

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


@ON_MAC
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
        bench = bl.BenchApp(app, out=os.path.join(self.folder, "out"), teardown=False, session=lambda: OK_SESSION)
        with self.assertRaises(bl.LaunchError):
            bench.launch(timeout=5)
        with open(seen) as f:
            self.assertEqual(f.read().strip(), str(self.launchd))
        self.assertIn(f"maxfiles {self.launchd} (caller {self.raised})", bench.limits)
        self.assertEqual(resource.getrlimit(resource.RLIMIT_NOFILE)[0], self.raised)

    def test_launch_arguments_reach_the_app_and_only_its_process(self):
        """BenchApp(args=...) appends to the app's argv (NSArgumentDomain), no defaults domain is written."""
        app = os.path.join(os.path.realpath(self.folder), f"cmux DEV bl-args-{os.getpid()}.app")
        os.makedirs(os.path.join(app, "Contents/MacOS"))
        seen = os.path.join(self.folder, "argv")
        main = os.path.join(app, "Contents/MacOS/cmux DEV")
        with open(main, "w") as f:
            f.write(f"#!/bin/sh\nprintf '%s\\n' \"$@\" > '{seen}'\n")  # records its argv, then exits
        os.chmod(main, 0o755)
        bench = bl.BenchApp(app, out=os.path.join(self.folder, "out"), teardown=False, session=lambda: OK_SESSION,
                            args=["-AppleShowScrollBars", "Always"])
        with self.assertRaises(bl.LaunchError):
            bench.launch(timeout=5)
        with open(seen) as f:
            self.assertEqual(f.read().splitlines(), ["-AppleShowScrollBars", "Always"])

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
        os.environ.update(BENCH_LAUNCH_PMSET=self.pmset, BENCH_LAUNCH_TEST_NO_SUDO="1",
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
        return bl.BenchApp(app, out=os.path.join(self.folder, "out"), teardown=False, session=lambda: OK_SESSION,
                           **kwargs)

    def launch_reason(self, bench):
        with self.assertRaises(bl.LaunchError) as caught:
            bench.launch(timeout=5)
        return caught.exception.reason

    @ON_MAC
    def test_host_facts_record_low_power_mode_and_null_without_the_key(self):
        self.set_state("1")
        self.assertIs(bl.host_facts()["low_power_mode"], True)
        self.set_state("0")
        self.assertIs(bl.host_facts()["low_power_mode"], False)
        self.set_state("none")
        self.assertIsNone(bl.host_facts()["low_power_mode"])

    @ON_MAC
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

    @ON_MAC
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

    @ON_MAC
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


@ON_MAC
class SoundTests(unittest.TestCase):
    def setUp(self):
        self.folder = os.path.realpath(tempfile.mkdtemp(prefix="bench-launch-sound-"))
        script = os.path.join(self.folder, "osascript")
        with open(script, "w") as f:
            f.write(FAKE_OSASCRIPT)
        os.chmod(script, 0o755)
        self.muted("false")
        self.saved_env = dict(os.environ)
        os.environ.update(BENCH_LAUNCH_OSASCRIPT=script,
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
            bl.BenchApp(self.app, out=os.path.join(self.folder, "out"), teardown=False,
                        session=lambda: OK_SESSION).launch(timeout=5)

    def test_a_launch_mutes_the_sound_output(self):
        self.launch()
        self.assertEqual(self.muted(), "true")

    def test_keep_leaves_the_sound_output(self):
        os.environ["BENCH_LAUNCH_AUDIO"] = "keep"
        self.launch()
        self.assertEqual(self.muted(), "false")


@ON_MAC
class CrashReportWaitTests(unittest.TestCase):
    """The crash-report wait after a signal exit (deep review of fleet-gui, fix review): with no folder it could watch
    it returned at once, so on an account that never crashed (no ~/Library/Logs/DiagnosticReports yet; ReportCrash
    creates it with the first report) and outside _analyticsusers (the system folder is 0770) the .ips that ReportCrash
    writes a few seconds after the exit was missing from the LaunchError report."""

    WAIT = 10  # the wait diagnose() gives ReportCrash

    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="bench-launch-crash-")
        self.tag = f"bl-crash-{os.getpid()}"
        self.app = bl.BenchApp(fake_bundle(self.folder, self.tag), out=os.path.join(self.folder, "out"),
                               teardown=False)
        self.app.launched_at = time.time()

    def tearDown(self):
        shutil.rmtree(self.folder, ignore_errors=True)

    def write_report(self, folder):
        """What ReportCrash does for the account's first crash: create its report folder, then write the .ips."""
        os.makedirs(folder, exist_ok=True)
        path = os.path.join(folder, "cmux DEV-2026-10-23-120000.ips")
        with open(path, "w") as report:
            report.write(json.dumps({"app_name": "cmux DEV"}) + "\n" + json.dumps({"procPath": self.app.binary}))
        return path

    def test_a_report_written_into_a_report_folder_that_did_not_exist_yet_is_found_before_the_deadline(self):
        home = os.path.join(self.folder, "home")
        os.makedirs(home)  # an account that has never crashed: no Library/Logs/DiagnosticReports
        mine = os.path.join(home, "Library/Logs/DiagnosticReports")
        system = os.path.join(self.folder, "system-reports-unreadable")  # stands in for a 0770 folder it cannot open
        written = []
        # ReportCrash writes the .ips a moment after the process ends (seconds on a real host).
        writer = threading.Timer(0.5, lambda: written.append(self.write_report(mine)))
        with mock.patch.object(bl, "crash_report_folders", return_value=(mine, system)):
            writer.start()
            started = time.monotonic()
            try:
                found = self.app.wait_for_crash_report(exit_code=-11, wait=self.WAIT)
            finally:
                writer.join()
            waited = time.monotonic() - started
        self.assertEqual(found, written, "the report ReportCrash wrote during the wait was not found")
        self.assertLess(waited, self.WAIT, "the wait ran to its deadline instead of waking on the new report")
        self.assertEqual(self.app.crash_report_wait["watched"], [mine])

    def test_a_report_created_before_its_body_is_written_is_found_when_the_body_lands(self):
        mine = os.path.join(self.folder, "reports")
        os.makedirs(mine)
        path = os.path.join(mine, "cmux DEV-2026-10-23-120001.ips")
        body = json.dumps({"app_name": "cmux DEV"}) + "\n" + json.dumps({"procPath": self.app.binary})
        # The file appears empty first (one folder event), and its body lands later (no folder event, only a write
        # to the file itself).
        create = threading.Timer(0.3, lambda: open(path, "w").close())
        fill = threading.Timer(0.8, lambda: open(path, "a").write(body))
        with mock.patch.object(bl, "crash_report_folders", return_value=(mine, os.path.join(self.folder, "none"))):
            create.start()
            fill.start()
            started = time.monotonic()
            try:
                found = self.app.wait_for_crash_report(exit_code=-6, wait=self.WAIT)
            finally:
                create.join()
                fill.join()
            waited = time.monotonic() - started
        self.assertEqual(found, [path])
        self.assertLess(waited, self.WAIT, "the wait slept to its deadline after the report's body was written")

    def test_the_wait_reads_the_folders_only_at_its_start_and_after_each_change_and_never_sleeps(self):
        """The wait is driven by the folder and file events, not by a period (fix review of deep-fleet-gui, finding 8's
        sleep-poll): a pass that reads the folders follows its start or a change, and nothing in the wait sleeps. A
        deadline check alone (`waited < WAIT`) passes a 0.5 s or 5 s sleep-poll, so this counts the reads instead.
        Red on the sleep-poll at 464dd10a87f: it calls time.sleep(0.5) and reads the folders every 0.5 s while the
        report's body is not written (about five reads for two changes)."""
        home = os.path.join(self.folder, "home")
        mine = os.path.join(home, "Library/Logs/DiagnosticReports")
        os.makedirs(mine)
        path = os.path.join(mine, "cmux DEV-2026-10-23-120002.ips")
        body = json.dumps({"app_name": "cmux DEV"}) + "\n" + json.dumps({"procPath": self.app.binary})
        changes = 2  # the report file appears empty, then its body lands (as in the test above, further apart)
        create = threading.Timer(0.3, lambda: open(path, "w").close())
        fill = threading.Timer(1.6, lambda: open(path, "a").write(body))
        # account_home is patched too so the same test drives the sleep-poll at 464dd10a87f, which had no
        # crash_report_folders (create=True); there it reads this home's folder and the system one.
        with mock.patch.object(bl, "account_home", return_value=home), \
                mock.patch.object(bl, "crash_report_folders", create=True,
                                  return_value=(mine, os.path.join(self.folder, "none"))), \
                mock.patch.object(bl, "crash_reports", wraps=bl.crash_reports) as reads, \
                mock.patch.object(bl.time, "sleep", wraps=time.sleep) as sleeps:
            create.start()
            fill.start()
            try:
                found = self.app.wait_for_crash_report(exit_code=-6, wait=self.WAIT)
            finally:
                create.join()
                fill.join()
        self.assertEqual(found, [path])
        self.assertEqual(sleeps.call_count, 0, f"the wait slept: {sleeps.call_args_list}")
        self.assertLessEqual(reads.call_count, 1 + changes,
                             f"the wait read the folders {reads.call_count} times for {changes} changes: a pass "
                             "that no change woke")

    def test_a_later_launchs_report_carries_no_earlier_crash_report_wait(self):
        """`crash_report_wait` describes this launch's wait or is absent (fix review of deep-fleet-gui): one BenchApp
        launches again (holder-dogfood keeps one), and a launch that exits with a code or goes silent after an earlier
        launch's signal exit reported the folders that earlier wait watched as its own."""
        blocker = os.path.join(self.folder, "a-file")
        open(blocker, "w").close()  # folders below a file: the earlier wait has nothing to watch and ends at once
        folders = (os.path.join(blocker, "DiagnosticReports"), os.path.join(blocker, "system"))
        with mock.patch.object(bl, "crash_report_folders", return_value=folders):
            self.app.wait_for_crash_report(exit_code=-11, wait=self.WAIT)  # launch 1 ended on a signal
            self.assertIsNotNone(self.app.crash_report_wait)
            # Launch 2 of the same object exits 1 before its socket answers.
            self.app.read_session = lambda: OK_SESSION
            self.app.process = subprocess.Popen([sys.executable, "-c", "raise SystemExit(1)"])
            self.app.process.wait()
            reason, report = self.app.diagnose(None, 5)
        self.assertEqual(reason, "exited")
        self.assertNotIn("crash_report_wait", report, "launch 2's report carries launch 1's crash-report wait")
        self.assertIsNone(self.app.crash_report_wait)

    def test_a_wait_with_no_folder_it_can_watch_says_so(self):
        blocker = os.path.join(self.folder, "a-file")
        open(blocker, "w").close()  # a folder below a regular file can be neither made nor opened
        mine, system = os.path.join(blocker, "DiagnosticReports"), os.path.join(blocker, "system")
        with mock.patch.object(bl, "crash_report_folders", return_value=(mine, system)):
            found = self.app.wait_for_crash_report(exit_code=-11, wait=self.WAIT)
        self.assertEqual(found, [])
        wait = self.app.crash_report_wait
        self.assertEqual(wait["watched"], [], "a folder below a file counted as watched")
        self.assertEqual(sorted(wait["unwatched"]), sorted([mine, system]),
                         "the report does not say which folders the wait could not watch")


@ON_MAC
class FreshStateTests(unittest.TestCase):
    def setUp(self):
        self.folder = os.path.realpath(tempfile.mkdtemp(prefix="bench-launch-fresh-"))
        self.saved_env = dict(os.environ)
        os.environ.update(BENCH_LAUNCH_ANY_SESSION="1", BENCH_LAUNCH_PMSET="/usr/bin/false",
                          BENCH_LAUNCH_LPM_MARKER=os.path.join(self.folder, "lpm.json"),
                          BENCH_LAUNCH_STATE_BASE=os.path.join(self.folder, "appsupport-cmux"))
        os.environ.pop("BENCH_LAUNCH_KEEP_STATE", None)
        self.tag = f"bl-fresh-{os.getpid()}"
        app = os.path.join(self.folder, f"cmux DEV {self.tag}.app")
        os.makedirs(os.path.join(app, "Contents/MacOS"))
        main = os.path.join(app, "Contents/MacOS/cmux DEV")
        with open(main, "w") as f:
            f.write("#!/bin/sh\nexit 0\n")
        os.chmod(main, 0o755)
        self.app = app
        self.root = os.path.join(self.folder, "appsupport-cmux", "tags", self.tag)
        os.makedirs(os.path.join(self.root, "tui"))
        with open(os.path.join(self.root, "tui", "session.json"), "w") as f:
            f.write('{"workspaces": 60}')

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.saved_env)
        shutil.rmtree(self.folder, ignore_errors=True)

    def launch(self, **kwargs):
        with self.assertRaises(bl.LaunchError):
            bl.BenchApp(self.app, out=os.path.join(self.folder, "out"), teardown=False, session=lambda: OK_SESSION,
                        **kwargs).launch(timeout=5)

    def test_a_launch_starts_from_an_empty_saved_session(self):
        self.launch()
        self.assertFalse(os.path.exists(self.root), "the tag's earlier state is still where the app reads it")
        self.assertTrue(os.path.exists(os.path.join(self.root + ".bench-prev", "tui", "session.json")))
        os.makedirs(self.root)  # a second run: the newer state replaces the one kept before
        with open(os.path.join(self.root, "marker"), "w") as f:
            f.write("2")
        self.launch()
        self.assertTrue(os.path.exists(os.path.join(self.root + ".bench-prev", "marker")))

    def test_keep_state_leaves_it(self):
        os.environ["BENCH_LAUNCH_KEEP_STATE"] = "1"
        self.launch()
        self.assertTrue(os.path.exists(os.path.join(self.root, "tui", "session.json")))


class LeftDaemonTests(unittest.TestCase):
    """A daemon an earlier run of the tag left (no app of it runs) refuses a fresh-state launch: moving the state
    aside would not make the session empty, the app would adopt that daemon and its workspaces."""

    def setUp(self):
        self.folder = os.path.realpath(tempfile.mkdtemp(prefix="bench-launch-left-"))
        self.tag = f"bl-left-{os.getpid()}"
        self.app = record_bundle(self.folder, self.tag, main="#!/bin/sh\nexit 0\n")
        tui = os.path.join(self.app, "Contents/Resources/bin/cmux-tui")
        os.makedirs(os.path.dirname(tui))
        shutil.copy("/bin/sleep", tui)
        self.daemon = subprocess.Popen([tui, "300"])
        self.root = os.path.join(self.folder, "appsupport-cmux", "tags", self.tag)
        os.makedirs(os.path.join(self.root, "tui"))
        self.patches = [mock.patch.dict(os.environ, {"BENCH_LAUNCH_STATE_BASE": os.path.join(self.folder,
                                                                                            "appsupport-cmux")}),
                        mock.patch.object(bl, "lpm_switch_problem", return_value=None),
                        mock.patch.object(bl, "low_power_mode", return_value=False),
                        mock.patch.object(bl, "mute_output", return_value="muted"),
                        mock.patch.object(bl, "host_facts", return_value={}),
                        mock.patch.object(bl, "note")]
        for patch in self.patches:
            patch.start()
        os.environ.pop("BENCH_LAUNCH_KEEP_STATE", None)

    def tearDown(self):
        for patch in reversed(self.patches):
            patch.stop()
        if self.daemon.poll() is None:
            self.daemon.kill()  # the exact process this test started
        self.daemon.wait()
        shutil.rmtree(self.folder, ignore_errors=True)

    def bench(self, **kwargs):
        return bl.BenchApp(self.app, out=os.path.join(self.folder, "out"), session=lambda: OK_SESSION, **kwargs)

    def test_a_fresh_launch_beside_a_left_daemon_is_refused_and_moves_nothing(self):
        for teardown in (False, True):
            with self.subTest(teardown=teardown), contextlib.redirect_stdout(io.StringIO()):
                bench = self.bench(teardown=teardown)
                with self.assertRaises(bl.LaunchError) as refused:
                    bench.launch(timeout=5)
                bench.stop()  # what every bench's finally runs: the left daemon is another run's
            self.assertEqual(refused.exception.reason, "tag-in-use")
            self.assertEqual(refused.exception.report.get("pids"), [self.daemon.pid])
            self.assertIsNone(bench.process)
            self.assertTrue(os.path.isdir(self.root), "the left daemon's state moved out from under it")
            self.assertIsNone(self.daemon.poll())

    def test_a_relaunch_on_the_kept_state_adopts_the_daemon(self):
        bench = self.bench(teardown=False, fresh_state=False)
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(bl.LaunchError) as failed:
            bench.launch(timeout=5)  # the stand-in app exits at once: launched, then app-exited
        self.assertNotEqual(failed.exception.reason, "tag-in-use")
        self.assertIsNotNone(bench.process)


PERF_RESULT_PATH = ROOT / "scripts/perf-lab/perf_result.py"
perf_result = bl.load_by_path("perf_result", str(PERF_RESULT_PATH))  # the real writer
store = bl.load_by_path("perf_lab_store", str(ROOT / "scripts/perf-lab/store.py"))
HOST = bl.host_record("Apple M4 Pro", 48 * 2**30, "26.1", "25B78", 120)
FEATURES = ({"perfLabKillProbe": {"state": "off", "source": "remote"},
             "tabSwitchFastPath": {"state": "on", "source": "default"}}, "fh-1", "off")


def record_bundle(folder: str, tag: str, commit=None, marker=False, debug_dylib=False, main=None,
                  stamped=None) -> str:
    """A `cmux DEV <tag>.app` with an Info.plist and a main executable that may carry the bench-hooks marker, or
    `main` as its executable's text (a script the launch can start). `stamped` is its reload.sh --config name."""
    import plistlib
    app = os.path.join(os.path.realpath(folder), f"cmux DEV {tag}.app")
    os.makedirs(os.path.join(app, "Contents/MacOS"))
    info = {"CFBundleIdentifier": f"com.cmuxterm.app.debug.{tag}", "CFBundleExecutable": "cmux DEV"}
    if commit:
        info["CMUXCommit"] = commit
    if stamped:
        info[bl.BUILD_CONFIG_KEY] = stamped
    with open(os.path.join(app, "Contents/Info.plist"), "wb") as f:
        plistlib.dump(info, f)
    executable = os.path.join(app, "Contents/MacOS/cmux DEV")
    with open(executable, "wb") as f:
        f.write(main.encode() if main else
                b"\xcf\xfa\xed\xfe" + b"\0" * 4096 + (bl.BENCH_HOOKS_MARKER if marker else b"") + b"\0" * 64)
    os.chmod(executable, 0o755)
    if debug_dylib:
        open(os.path.join(app, "Contents/MacOS/cmux DEV.debug.dylib"), "wb").close()
    return app


def result_lines(out: str) -> list:
    """Every result line in `out`, each checked by the real perf_result.validation_errors."""
    lines = []
    for path in sorted(Path(out).glob("*.ndjson")):
        for text in path.read_text().splitlines():
            line = json.loads(text)
            assert perf_result.validation_errors(line) == [], perf_result.validation_errors(line)
            lines.append(line)
    return lines


# Runs only a script's top-level imports and the sys.path setup they need (each statement that names sys.path, and
# the assignments it uses): no argument parsing, no main. Prints {"error": None or {type, import_error, message}}.
IMPORT_ONLY = r'''
import ast, json, sys
path = sys.argv[1]
tree = ast.parse(open(path).read(), path)
def names_used(node):
    return {n.id for n in ast.walk(node) if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Load)}
def assigned(node):
    return {n.id for t in getattr(node, "targets", []) for n in ast.walk(t) if isinstance(n, ast.Name)}
def is_import(node):
    return isinstance(node, (ast.Import, ast.ImportFrom)) or (
        isinstance(node, ast.Try) and all(isinstance(n, (ast.Import, ast.ImportFrom)) for n in node.body))
keep = {i for i, node in enumerate(tree.body)
        if is_import(node) or (isinstance(node, (ast.Expr, ast.Assign)) and "sys.path" in ast.unparse(node))}
needed = set().union(*(names_used(tree.body[i]) for i in keep))
grew = True
while grew:
    grew = False
    for i, node in enumerate(tree.body):
        if i not in keep and isinstance(node, ast.Assign) and assigned(node) & needed:
            keep.add(i)
            needed |= names_used(node)
            grew = True
module = ast.Module(body=[tree.body[i] for i in sorted(keep)], type_ignores=[])
error = None
try:
    exec(compile(module, path, "exec"), {"__name__": "bench_import_check", "__file__": path})
except BaseException as caught:
    error = {"type": type(caught).__name__, "import_error": isinstance(caught, ImportError), "message": str(caught)}
print(json.dumps({"error": error}))
'''


class RecordTests(unittest.TestCase):
    """BenchApp.record writes cmux-perf-result/v1 through the real perf_result.py, with its build, host, Hz and the
    launch's features and safe mode filled in (p12-perf-process-162)."""

    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="bench-record-")
        self.out = os.path.join(self.folder, "out")

    def tearDown(self):
        shutil.rmtree(self.folder, ignore_errors=True)

    def bench(self, app, features=FEATURES, **kwargs):
        bench = bl.BenchApp(app, out=self.out, teardown=False, host=lambda: dict(HOST), **kwargs)
        bench.features = features  # what launch() read (RelaunchTests drives the launch itself)
        return bench

    def test_record_writes_valid_result_v1_with_a_build_a_host_and_the_features(self):
        app = self.bench(record_bundle(self.folder, "rec", commit="a" * 40), perf_session="stress")
        path = app.record("tab-switch", "key_to_frame_ms", "ms", [4.1, 3.9, 5.2], "lower", "chromium",
                          target_ref="tab-switch-p95")
        [line] = result_lines(self.out)
        self.assertEqual(line["schema"], "cmux-perf-result/v1")
        self.assertEqual((line["story"], line["metric"], line["unit"], line["better"], line["engine"]),
                         ("tab-switch", "key_to_frame_ms", "ms", "lower", "chromium"))
        self.assertEqual(line["samples"], [4.1, 3.9, 5.2], "raw samples, not a summary")
        self.assertEqual(line["target_ref"], {"target": "tab-switch-p95"})
        self.assertEqual(line["session"], "stress")
        self.assertEqual(line["build"], {"sha": "a" * 40, "config": "release",
                                         "measure_version": bl.PERF_LAB_MEASURE_VERSION})
        self.assertEqual(line["host"], HOST)
        self.assertEqual(line["host"]["class"], "apple-m4-pro/48gb/120hz", "the store's series-key host part")
        self.assertRegex(line["host"]["fingerprint"], r"^[0-9a-f]{64}$")
        self.assertEqual((line["features"], line["features_hash"], line["safe_mode"]), FEATURES)
        [back] = perf_result.read_file(path)
        self.assertEqual(back.to_dict(), line)

    def test_every_result_of_one_bench_app_names_one_run(self):
        app = self.bench(record_bundle(self.folder, "run", commit="a" * 40))
        app.record("launch", "cold_ms", "ms", [800], "lower", "none")
        app.record("launch", "warm_ms", "ms", [300], "lower", "none")
        first, second = result_lines(self.out)
        self.assertEqual(first["run"], second["run"])
        given = perf_result.Run(id="job-7-attempt-2", started_at="2026-10-25T12:00:00.000000Z")
        other = self.bench(record_bundle(os.path.join(self.folder, "o"), "run2", commit="a" * 40), run=given)
        other.out = os.path.join(self.folder, "out2")
        other.record("launch", "cold_ms", "ms", [800], "lower", "none")
        self.assertEqual(result_lines(other.out)[0]["run"], given.to_dict())

    def test_record_without_a_launch_snapshot_refuses_and_writes_nothing(self):
        app = self.bench(record_bundle(self.folder, "nosnap", commit="a" * 40), features=None)
        with self.assertRaises(bl.RecordError) as caught:
            app.record("s", "m", "ms", [1.0], "lower", "none")
        self.assertIn("features.list", str(caught.exception))
        self.assertEqual(list(Path(self.out).glob("*.ndjson")), [])

    def test_a_build_without_features_list_records_no_registry_and_other_answers_no_snapshot(self):
        missing = {"error": {"code": "method_not_found", "message": "unknown method features.list"}}
        self.assertEqual(bl.features_snapshot(missing), ({}, None, None))
        for reply in ({"error": "refused", "unreachable": True}, {"error": {"code": "internal", "message": "x"}},
                      {"features": "nope"}, None):
            self.assertIsNone(bl.features_snapshot(reply), reply)
        reply = {"features": [{"name": "tabSwitchFastPath", "state": "on", "source": "default"}],
                 "features_hash": "fh-9", "safe_mode": "inactive"}
        self.assertEqual(bl.features_snapshot(reply),
                         ({"tabSwitchFastPath": {"state": "on", "source": "default"}}, "fh-9", "inactive"))
        self.assertIsNone(bl.features_snapshot({"features": []})[1], "the app's own hash or none, never a made-up one")
        app = self.bench(record_bundle(self.folder, "noreg", commit="a" * 40), features=bl.features_snapshot(missing))
        app.record("s", "m", "ms", [1.0], "lower", "none")
        [line] = result_lines(self.out)
        self.assertEqual((line["features"], line["features_hash"], line["safe_mode"]), ({}, None, None))

    def test_the_host_class_leaves_out_the_macos_build_and_the_fingerprint_does_not(self):
        updated = bl.host_record("Apple M4 Pro", 48 * 2**30, "26.2", "25C10", 120)
        self.assertEqual(updated["class"], HOST["class"])
        self.assertNotEqual(updated["fingerprint"], HOST["fingerprint"])
        at_60 = bl.host_record("Apple M4 Pro", 48 * 2**30, "26.1", "25B78", 60)
        self.assertNotEqual(at_60["class"], HOST["class"])
        self.assertEqual(HOST["class"], store.host_class(chip="Apple M4 Pro", memory_gb=48, display_hz=120))
        self.assertEqual(bl.host_record("Apple M4 Pro", 48 * 2**30, "26.1", "25B78", 120), HOST, "stable")

    def test_a_host_without_chip_memory_or_hz_is_env_invalid(self):
        for args in ((None, 48 * 2**30, "26.1", "25B78", 120), ("Apple M4 Pro", None, "26.1", "25B78", 120),
                     ("Apple M4 Pro", 48 * 2**30, "26.1", "25B78", None), ("Apple M4 Pro", 48 * 2**30, "26.1", "25B78", 0)):
            with self.assertRaises(bl.RecordError) as caught:
                bl.host_record(*args)
            self.assertIn("env-invalid", str(caught.exception), args)

    def test_the_build_config_comes_from_the_bundle_and_a_bench_build_states_which(self):
        def config(want, stated=None, **kwargs):
            app = record_bundle(os.path.join(self.folder, f"{want}-{stated}"), "cfg", commit="b" * 40, **kwargs)
            return bl.build_config(app, os.path.join(app, "Contents/MacOS/cmux DEV"), stated)
        self.assertEqual(config("release"), "release")
        self.assertEqual(config("debug", debug_dylib=True), "debug")
        self.assertEqual(config("bench", "bench", marker=True), "bench")
        self.assertEqual(config("checks", "bench-checks", marker=True), "bench-checks")
        with self.assertRaises(bl.RecordError):
            config("ambiguous", marker=True)  # bench or bench-checks: the executable does not say
        with self.assertRaises(bl.RecordError):
            config("lie", "bench", debug_dylib=True)
        with self.assertRaises(bl.RecordError):
            config("lie2", "release", marker=True)

    def test_a_tagged_bench_build_names_its_own_config(self):
        # Bench and bench-checks executables look alike; reload.sh stamps the config.
        def config(want, stated=None, **kwargs):
            app = record_bundle(os.path.join(self.folder, f"{want}-{stated}"), "cfg", commit="b" * 40, **kwargs)
            return bl.build_config(app, os.path.join(app, "Contents/MacOS/cmux DEV"), stated)
        self.assertEqual(config("bench", marker=True, stamped="bench"), "bench")
        self.assertEqual(config("checks", marker=True, stamped="bench-checks"), "bench-checks")
        self.assertEqual(config("agree", "bench-checks", marker=True, stamped="bench-checks"), "bench-checks")
        self.assertEqual(config("release", stamped="release"), "release")
        for want, stated, kwargs in (("disagree", "bench", {"marker": True, "stamped": "bench-checks"}),
                                     ("stamp-lies", None, {"marker": True, "stamped": "release"}),
                                     ("stamp-lies2", None, {"stamped": "bench"})):
            with self.assertRaises(bl.RecordError, msg=want):
                config(want, stated, **kwargs)

    def test_the_build_sha_is_the_bundles_or_the_fleet_steps_never_this_checkouts_head(self):
        app = record_bundle(self.folder, "sha")
        self.assertEqual(bl.build_sha(app, environ={"CMUX_CI_SHA": "c" * 40}), "c" * 40)
        for environ in ({}, {"CMUX_CI_SHA": "not-a-sha"}):
            with self.assertRaises(bl.RecordError):
                bl.build_sha(app, environ=environ)
        stamped = record_bundle(os.path.join(self.folder, "s"), "stamped", commit="d" * 40)
        self.assertEqual(bl.build_sha(stamped, environ={"CMUX_CI_SHA": "c" * 40}), "d" * 40, "the bundle's own first")
        head = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
        if not head:
            self.skipTest("not a git checkout")
        short = record_bundle(os.path.join(self.folder, "short"), "short", commit=head[:12])
        self.assertEqual(bl.build_sha(short, environ={}), head, "a nightly's short CMUXCommit, resolved")
        unknown = record_bundle(os.path.join(self.folder, "unknown"), "unknown", commit="0123456789ab")
        with self.assertRaises(bl.RecordError):
            bl.build_sha(unknown, environ={})

    def test_an_invalid_result_raises_and_writes_nothing(self):
        app = self.bench(record_bundle(self.folder, "bad", commit="f" * 40))
        with self.assertRaises(perf_result.ResultError):
            app.record("s", "m", "ms", [], "lower", "chromium")
        with self.assertRaises(perf_result.ResultError):
            app.record("s", "m", "ms", [1.0], "lower", "gecko")
        self.assertEqual(list(Path(self.out).glob("*.ndjson")), [])

    def test_record_loads_the_real_perf_result_by_file_path_under_isolated_mode(self):
        app = record_bundle(self.folder, "iso", commit="1" * 40)
        code = ("import json, sys; sys.path.insert(0, sys.argv[1]); import bench_launch as bl; "
                "host = bl.host_record('Apple M4', 16 * 2**30, '26.1', '25B78', 60); "
                "app = bl.BenchApp(sys.argv[2], out=sys.argv[3], teardown=False, host=lambda: host); "
                "app.features = ({}, None, None); "
                "app.record('s', 'm', 'ms', [2.5], 'lower', 'webkit'); "
                "print(json.dumps({'loaded': sys.modules['perf_result'].__file__}))")
        done = subprocess.run([sys.executable, "-I", "-c", code, str(HERE), app, self.out], cwd="/",
                              capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(os.path.realpath(json.loads(done.stdout)["loaded"]), os.path.realpath(PERF_RESULT_PATH))
        [line] = result_lines(self.out)
        self.assertEqual((line["engine"], line["host"]["display_hz"], line["build"]["sha"]), ("webkit", 60, "1" * 40))

    def import_only(self, path):
        """The error (None, or {type, import_error, message}) of running `path`'s imports alone under `python3 -I`
        from `/`: no script folder or cwd on sys.path, no argument parsing, no main (IMPORT_ONLY)."""
        done = subprocess.run([sys.executable, "-I", "-c", IMPORT_ONLY, str(path)], cwd="/", capture_output=True,
                              text=True, timeout=120)
        self.assertEqual(done.returncode, 0, done.stderr[-2000:])
        return json.loads(done.stdout)["error"]

    def test_every_bench_that_imports_bench_launch_still_imports_under_isolated_mode(self):
        """Each bench's imports resolve under `python3 -I`, and every name a bench imports from bench_launch, also
        inside a function, exists. On Linux a macOS library a bench loads at import (libproc) is not an import
        failure; on a Mac every bench must import cleanly."""
        import ast
        wanted, benches = set(), []
        for path in sorted(HERE.glob("*.py")):
            if path.name == "bench_launch.py" or "bench_launch" not in path.read_text(errors="replace"):
                continue
            benches.append(path)
            for node in ast.walk(ast.parse(path.read_text())):
                if isinstance(node, ast.ImportFrom) and node.module == "bench_launch":
                    wanted.update(alias.name for alias in node.names)
        self.assertTrue(benches)
        self.assertEqual(sorted(n for n in wanted if not hasattr(bl, n)), [], "names benches import that bench_launch lacks")
        for path in benches:
            error = self.import_only(path)
            if sys.platform == "darwin":
                self.assertIsNone(error, f"{path.name} does not import under -I")
            else:
                self.assertFalse(error and error["import_error"], f"{path.name} does not import under -I: {error}")

    def test_the_import_harness_catches_a_bench_that_needs_its_folder_on_sys_path(self):
        lone = os.path.join(self.folder, "lone-bench.py")
        with open(lone, "w") as f:
            f.write("import argparse\nopts = argparse.ArgumentParser().parse_args()\nfrom bench_launch import BenchApp\n")
        error = self.import_only(lone)
        self.assertEqual((error or {}).get("type"), "ModuleNotFoundError", error)
        fixed = os.path.join(self.folder, "fixed-bench.py")
        with open(fixed, "w") as f:
            f.write(f"import argparse, sys\nopts = argparse.ArgumentParser().parse_args()\nHERE = {str(HERE)!r}\n"
                    "sys.path.insert(0, HERE)\nfrom bench_launch import BenchApp\nmain()\n")
        self.assertIsNone(self.import_only(fixed), "the harness runs the sys.path setup and the imports, nothing else")


class RelaunchTests(unittest.TestCase):
    """The features snapshot belongs to one launch: launch() reads it once the app answers, record() after stop() still
    has it, and a second launch of the same BenchApp records its own (review of p12-perf-process-162, finding 1).

    The app is a script that sleeps; the control socket is a stand-in (``rpc_at`` patched) and its file is made at
    the spawn, so this runs on Linux too."""

    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="bench-relaunch-")
        self.tag = f"bl-relaunch-{os.getpid()}"
        self.socket_file = f"/tmp/cmux-debug-{self.tag}.sock"
        self.saved_env = dict(os.environ)
        os.environ.update(BENCH_LAUNCH_LIMITS="inherit", BENCH_LAUNCH_PMSET="/nonexistent/pmset",
                          BENCH_LAUNCH_LPM_MARKER=os.path.join(self.folder, "lpm.json"))
        self.reply = None
        self.app = bl.BenchApp(record_bundle(self.folder, self.tag, commit="9" * 40, main="#!/bin/sh\nexec sleep 300\n"),
                               out=os.path.join(self.folder, "out"), teardown=False, session=lambda: OK_SESSION,
                               host=lambda: dict(HOST))

    def tearDown(self):
        if self.app.process and self.app.process.poll() is None:
            self.app.process.kill()
            self.app.process.wait()
        os.environ.clear()
        os.environ.update(self.saved_env)
        with contextlib.suppress(FileNotFoundError):
            os.unlink(self.socket_file)
        shutil.rmtree(self.folder, ignore_errors=True)

    def rpc(self, path, method, params=None, timeout=60):
        if method == "debug.windows":
            return {"windows": [{"id": 1}]}
        if method == "features.list":
            return self.reply
        if method == "debug.quit":
            self.app.process.terminate()
            with contextlib.suppress(FileNotFoundError):
                os.unlink(self.socket_file)
            return {}
        return {"error": {"code": "method_not_found", "message": method}}

    def launch(self, reply):
        self.reply = reply
        self.app.launch(timeout=20, on_start=lambda process: open(self.socket_file, "w").close())

    def test_a_relaunch_records_its_own_features_and_a_record_after_stop_keeps_them(self):
        first = {"features": [{"name": "tabSwitchFastPath", "state": "off", "source": "default"}],
                 "features_hash": "fh-a", "safe_mode": "off"}
        second = {"features": [{"name": "tabSwitchFastPath", "state": "on", "source": "env"}],
                  "features_hash": "fh-b", "safe_mode": "inactive"}
        with mock.patch.object(bl, "rpc_at", self.rpc):
            self.launch(first)
            self.app.stop(quit_timeout=10)
            self.app.record("launch", "warm_ms", "ms", [300], "lower", "none")  # after stop: the launch's snapshot
            self.launch(second)
            self.app.stop(quit_timeout=10)
            self.app.record("launch", "warm_ms", "ms", [310], "lower", "none")
            self.launch({"error": "refused", "unreachable": True})
            self.app.stop(quit_timeout=10)
            with self.assertRaises(bl.RecordError):
                self.app.record("launch", "warm_ms", "ms", [320], "lower", "none")
        lines = sorted(result_lines(self.app.out), key=lambda line: line["samples"])
        self.assertEqual([(line["features"], line["features_hash"], line["safe_mode"]) for line in lines],
                         [({"tabSwitchFastPath": {"state": "off", "source": "default"}}, "fh-a", "off"),
                          ({"tabSwitchFastPath": {"state": "on", "source": "env"}}, "fh-b", "inactive")])


class BenchEnvTests(unittest.TestCase):
    """Every switch the bench app gets has a Swift read site (scripts/perf-lab/bench_env.py), and the launch passes
    exactly those switches (p12-perf-process-162)."""

    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="bench-env-")
        self.env = bl.bench_env

    def tearDown(self):
        shutil.rmtree(self.folder, ignore_errors=True)

    def test_every_switch_names_a_read_site_that_reads_it(self):
        self.assertEqual(self.env.read_site_problems(str(ROOT)), [])
        for switch in self.env.SWITCHES:
            self.assertTrue(switch.read_site.endswith(".swift"), switch)
            self.assertIn(switch.kind, self.env.KINDS, switch)

    def test_the_check_names_a_read_site_that_lost_its_switch_or_does_not_exist(self):
        broken = self.env.Switch("CMUX_NEXT_NOT_READ_ANYWHERE", "env", "1", "test",
                                 self.env.SWITCHES[0].read_site)
        missing = self.env.Switch("CMUX_NEXT_NO_READER_YET", "env", "1", "test", "Packages/none/Missing.swift")
        with mock.patch.object(self.env, "SWITCHES", (broken, missing)):
            problems = self.env.read_site_problems(str(ROOT))
        self.assertEqual(len(problems), 2, problems)
        self.assertIn("CMUX_NEXT_NOT_READ_ANYWHERE", problems[0])
        self.assertIn("does not exist", problems[1], "a switch with no reader yet is not listed")

    def test_the_check_runs_under_isolated_mode(self):
        done = subprocess.run([sys.executable, "-I", str(ROOT / "scripts/perf-lab/bench_env.py"), "--check"], cwd="/",
                              capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 0, done.stderr)

    def test_the_check_refuses_a_switch_the_app_strips_at_launch(self):
        """A CMUX_ name that is not CMUX_NEXT_ is deleted by LaunchIdentity before any reader runs, even when its read
        site names it (CMUX_FEATURES_SAFE_MODE in the spec, task 094): the check fails on it."""
        site = os.path.join(self.folder, "FeatureSafeMode.swift")
        with open(site, "w") as f:
            f.write('let off = ProcessInfo.processInfo.environment["CMUX_FEATURES_SAFE_MODE"] == "off"\n')
        stripped = self.env.Switch("CMUX_FEATURES_SAFE_MODE", "env", "off", "test", "FeatureSafeMode.swift")
        with mock.patch.object(self.env, "SWITCHES", (stripped,)):
            problems = self.env.read_site_problems(self.folder)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("LaunchIdentity strips", problems[0])
        self.assertTrue(self.env.stripped_at_launch("CMUX_DEV_BACKEND_MODE"))
        self.assertFalse(self.env.stripped_at_launch("CMUX_NEXT_NO_ACTIVATE"))
        self.assertFalse(self.env.stripped_at_launch("ACPMUX_AGENT_LAUNCH"))

    def test_the_launch_passes_the_fixed_switches_and_the_config_keys_and_no_unset_one(self):
        app = bl.BenchApp(record_bundle(self.folder, "env"), out=os.path.join(self.folder, "out"), teardown=False)
        env = app.environment()
        for name, value in self.env.fixed_env().items():
            self.assertEqual(env.get(name), value, name)
        launch_names = {s.name for s in self.env.SWITCHES if s.kind == "env-launch"}
        self.assertEqual(launch_names - set(env), set())
        for name in self.env.unset_env():
            self.assertNotIn(name, env)
        self.assertNotIn("CMUX_DEV_BACKEND_MODE", env, "the app strips it and nothing reads it")
        with open(env["CMUX_NEXT_CONFIG_FILE"]) as f:
            config = json.load(f)
        self.assertIs(config["updates"]["checkAutomatically"], False)
        self.assertEqual(config["appearance"], {"backgroundOpacity": 1}, "the bench's own config stays")

    def test_a_benchs_own_config_value_wins(self):
        app = bl.BenchApp(record_bundle(self.folder, "own"), out=os.path.join(self.folder, "out"), teardown=False,
                          config={"updates": {"checkAutomatically": True, "channel": "nightly"}})
        with open(app.environment()["CMUX_NEXT_CONFIG_FILE"]) as f:
            config = json.load(f)
        self.assertEqual(config["updates"], {"checkAutomatically": True, "channel": "nightly"})


class FakeSpawnLibrary:
    """libsystem's posix_spawn calls as `disclaimed_spawn` makes them: each call is recorded and answers 0."""

    def __init__(self, disclaim=True, spawn_status=0):
        self.calls = []
        self.spawn_status = spawn_status
        names = ["posix_spawnattr_init", "posix_spawnattr_destroy", "posix_spawnattr_setflags",
                 "posix_spawn_file_actions_init", "posix_spawn_file_actions_destroy",
                 "posix_spawn_file_actions_addopen", "posix_spawn_file_actions_adddup2",
                 "posix_spawn_file_actions_addinherit_np"] + (["responsibility_spawnattrs_setdisclaim"] if disclaim else [])
        for name in names:
            setattr(self, name, self._recorder(name))

        def posix_spawn(pid, path, actions, attributes, argv, envp):
            self.calls.append(("posix_spawn", (path, list(argv), envp[0])))
            pid._obj.value = 4321
            return self.spawn_status
        self.posix_spawn = posix_spawn  # a plain function, as ctypes' are: the spawn sets its argtypes

    def _recorder(self, name):
        def call(*args):
            self.calls.append((name, args[1:]))
            return 0
        return call


class DisclaimedSpawnTests(unittest.TestCase):
    """own_responsibility (p01-process-089): the app is spawned with responsibility disclaimed, so tccd charges its
    privacy requests to it and not to the bench's parent chain; the stand-in Popen reaps and signals the child."""

    def test_spawn_disclaims_and_wires_the_descriptors(self):
        lib = FakeSpawnLibrary()
        process = bl.disclaimed_spawn(["/x/cmux DEV", "-a"], {"K": "v"}, 7, pass_fds=(9,), library=lib)
        self.assertEqual(process.pid, 4321)
        calls = dict((name, args) for name, args in lib.calls)
        self.assertEqual(calls["responsibility_spawnattrs_setdisclaim"], (1,))
        self.assertEqual(calls["posix_spawnattr_setflags"], (bl.POSIX_SPAWN_CLOEXEC_DEFAULT,))
        dup2 = [args for name, args in lib.calls if name == "posix_spawn_file_actions_adddup2"]
        self.assertEqual(dup2, [(7, 1), (7, 2)])
        self.assertEqual(calls["posix_spawn_file_actions_addopen"][:2], (0, b"/dev/null"))
        self.assertEqual(calls["posix_spawn_file_actions_addinherit_np"], (9,))
        self.assertEqual(calls["posix_spawn"], (b"/x/cmux DEV", [b"/x/cmux DEV", b"-a", None], b"K=v"))
        names = [name for name, _ in lib.calls]
        self.assertLess(names.index("responsibility_spawnattrs_setdisclaim"), names.index("posix_spawn"))
        self.assertIn("posix_spawnattr_destroy", names)

    def test_no_disclaim_refuses_to_launch(self):
        with self.assertRaises(bl.LaunchError) as raised:
            bl.disclaimed_spawn(["/x/cmux DEV"], {}, 7, library=FakeSpawnLibrary(disclaim=False))
        self.assertEqual(raised.exception.reason, "disclaim-unavailable")

    def test_a_failed_spawn_raises(self):
        with self.assertRaises(OSError):
            bl.disclaimed_spawn(["/x/cmux DEV"], {}, 7, library=FakeSpawnLibrary(spawn_status=2))

    def test_the_stand_in_popen_reaps_and_signals_its_child(self):
        done = bl.SpawnedProcess(os.spawnv(os.P_NOWAIT, "/bin/sh", ["sh", "-c", "exit 3"]))
        self.assertEqual(done.wait(10), 3)
        self.assertEqual(done.poll(), 3)
        sleeper = bl.SpawnedProcess(os.spawnv(os.P_NOWAIT, "/bin/sleep", ["sleep", "30"]))
        self.assertIsNone(sleeper.poll())
        with self.assertRaises(subprocess.TimeoutExpired):
            sleeper.wait(0.2)
        sleeper.terminate()
        self.assertEqual(sleeper.wait(10), -signal.SIGTERM)
        sleeper.kill()  # an ended child is not signalled again

    def test_launch_uses_it_only_when_asked(self):
        self.assertFalse(bl.BenchApp(record_bundle(tempfile.mkdtemp(prefix="disclaim-"), "plain"), teardown=False)
                         .own_responsibility)
        self.assertTrue(bl.BenchApp(record_bundle(tempfile.mkdtemp(prefix="disclaim-"), "own"), teardown=False,
                                    own_responsibility=True).own_responsibility)


class SocketProbeTests(unittest.TestCase):
    """10. The control socket probe (bench_launch.first_answer, socket_probe_summary, socket-probe)."""

    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="cnp-", dir="/tmp")
        self.addCleanup(shutil.rmtree, self.folder, True)
        self.path = os.path.join(self.folder, "s.sock")

    def serve_late(self, bind_after, answer_after):
        """A listener that binds after `bind_after` s, then accepts one request and answers it `answer_after` s
        after it arrived (the app binds in main() and reads requests once its methods are registered)."""
        def run():
            time.sleep(bind_after)  # test: the app's main() has not bound yet
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(self.path)
            server.listen(8)
            conn, _ = server.accept()
            buf = b""
            while not buf.endswith(b"\n"):
                buf += conn.recv(4096)
            time.sleep(answer_after)  # test: the method groups register after the first frame
            request = json.loads(buf)
            conn.sendall((json.dumps({"id": request["id"], "ok": True, "result": {"pong": True}}) + "\n").encode())
            conn.close()
            server.close()

        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 5)

    def paths(self):
        return [self.path] if os.path.exists(self.path) else []

    def test_the_first_answer_is_timed_at_the_answer_not_the_accept(self):
        self.serve_late(bind_after=0.05, answer_after=0.2)
        start = time.monotonic()
        took = bl.first_answer(self.paths, start, start + 5)
        self.assertIsNotNone(took)
        self.assertGreaterEqual(took, 0.25)
        self.assertLess(took, 5)

    def test_no_answer_when_the_app_ends_or_the_deadline_passes(self):
        start = time.monotonic()
        self.assertIsNone(bl.first_answer(self.paths, start, start + 5, alive=lambda: False))
        start = time.monotonic()
        self.assertIsNone(bl.first_answer(self.paths, start, start + 0.05))

    def test_the_verdict_is_the_p50_of_answer_after_frame_against_the_budget(self):
        runs = [{"first_answer_ms": 210, "first_frame_ms": 180}, {"first_answer_ms": 260, "first_frame_ms": 200},
                {"first_answer_ms": 400, "first_frame_ms": 220}]
        summary = bl.socket_probe_summary(runs, budget_ms=50)
        self.assertEqual(summary["answer_after_frame_p50_ms"], 60)
        self.assertFalse(summary["ok"])
        self.assertTrue(bl.socket_probe_summary(runs, budget_ms=60)["ok"])
        missing = runs + [{"first_answer_ms": None, "first_frame_ms": 190}]
        self.assertFalse(bl.socket_probe_summary(missing, budget_ms=500)["ok"], "a run with no answer fails")
        self.assertFalse(bl.socket_probe_summary([], budget_ms=500)["ok"])

    def test_the_command_reads_each_launchs_first_frame_and_stops_every_app(self):
        stopped = []

        class StubApp:
            def __init__(self, app, out=None):
                self.first_answer_ms = None

            def launch(self, timeout, probe_first_answer):
                assert probe_first_answer
                self.first_answer_ms = 230.0

            def rpc(self, method, params=None, timeout=60):
                assert method == "debug.timings"
                return {"launch_ms_since_process_start": {"first_window_frame_committed": 200.0}}

            def stop(self):
                stopped.append(True)

        opts = mock.Mock(app="/x/cmux DEV t.app", out=None, runs=3, timeout=10, budget_ms=50,
                         json=os.path.join(self.folder, "out.json"))
        with contextlib.redirect_stdout(io.StringIO()):
            code = bl.socket_probe(opts, make_app=StubApp)
        self.assertEqual(code, 0)
        self.assertEqual(len(stopped), 3)
        with open(opts.json) as f:
            result = json.loads(f.read())
        self.assertEqual(result["answer_after_frame_p50_ms"], 30)
        self.assertEqual(len(result["per_run"]), 3)


class AfterKillTests(unittest.TestCase):
    """11. The relaunch after kill -9 of the app (bench_launch after-kill: after_kill_row, after_kill_summary)."""

    MARKS = {"first_window_frame_committed": 180.0, "launch.visible_panes_shown": 300.0,
             "launch.visible_terminals_drawn": 390.0, "daemon_reattached": 150.0, "relaunch.saved_frames_skipped": 90.0,
             "relaunch.rings_unavailable": 90.0, "relaunch.host_unavailable": 90.0}

    LAYOUT = {"terminals": 2, "surface_swaps": 0, "extra_resizes": 0, "one_layout": True}

    @staticmethod
    def surfaces(*terminals):
        """A `debug.surfaces` reply with one terminal pane per (surface_swaps, full_resize) and a browser pane."""
        panes = [{"attach": "attached", "surface_swaps": swaps, "surface": {"render_counters": {"full_resize": resizes}}}
                 for swaps, resizes in terminals]
        return {"windows": [{"window": "1", "panes": panes + [{"kind": "browser"}]}]}

    def row(self, marks=None, recovery="clean", layout=LAYOUT):
        return bl.after_kill_row(self.MARKS if marks is None else marks, recovery, layout)

    def test_a_row_times_the_screens_from_the_first_frame_and_says_how_the_daemon_was_found(self):
        row = self.row()
        self.assertEqual(row["screens_after_first_frame_ms"], 210.0)
        self.assertEqual(row["panes_shown_ms"], 300.0)
        self.assertTrue(row["reattached"])
        self.assertFalse(row["daemon_started"])
        self.assertTrue(row["saved_frames_skipped"])
        self.assertFalse(row["saved_frame_shown"])
        self.assertFalse(row["saved_picture_shown"])
        self.assertEqual(row["recovery"], "clean")
        self.assertEqual(row["takeover"], {"rings": "unavailable", "host": "unavailable"})
        cold = self.row({"first_window_frame_committed": 180.0, "daemon.spawned": 40.0})
        self.assertIsNone(cold["screens_after_first_frame_ms"], "no drawn mark: not measured")
        self.assertTrue(cold["daemon_started"])
        self.assertFalse(cold["reattached"])
        self.assertEqual(cold["takeover"], {"rings": None, "host": None})

    def test_content_queued_with_no_frame_drawn_is_not_measured(self):
        queued = self.row({k: v for k, v in self.MARKS.items() if k != "launch.visible_terminals_drawn"})
        self.assertIsNone(queued["screens_after_first_frame_ms"],
                          "launch.visible_panes_shown is the content queued, not the screens drawn")
        self.assertFalse(bl.after_kill_summary([queued])["ok"])

    def test_the_verdict_is_every_relaunch_reattached_and_within_the_budget(self):
        good = [self.row(), self.row({**self.MARKS, "launch.visible_terminals_drawn": 470.0})]
        summary = bl.after_kill_summary(good)
        self.assertTrue(summary["ok"])
        self.assertEqual(summary["screens_after_first_frame_max_ms"], 290.0)
        self.assertEqual(summary["budget_ms"], 300)
        slow = good + [self.row({**self.MARKS, "launch.visible_terminals_drawn": 481.0})]
        self.assertFalse(bl.after_kill_summary(slow)["ok"], "301 ms after the first frame")
        started = [self.row({**self.MARKS, "daemon.spawned": 40.0})]
        started[0]["reattached"] = False
        self.assertFalse(bl.after_kill_summary(started)["ok"], "a relaunch that started the daemon lost the terminals")
        unmeasured = good + [self.row({"first_window_frame_committed": 180.0, "daemon_reattached": 1.0})]
        self.assertFalse(bl.after_kill_summary(unmeasured)["ok"])
        self.assertFalse(bl.after_kill_summary([])["ok"])

    def test_a_safe_mode_or_unread_recovery_run_fails_the_verdict(self):
        safe = [self.row(), self.row(recovery="restartedSafely")]
        summary = bl.after_kill_summary(safe)
        self.assertFalse(summary["ok"], "a restart-loop safe mode is another launch path than one kill -9")
        self.assertEqual(summary["not_clean_runs"], 1)
        self.assertFalse(bl.after_kill_summary([self.row(recovery=None)])["ok"], "a run whose recovery was not read")
        self.assertFalse(bl.after_kill_summary([self.row(recovery="restarted")])["ok"])

    def test_an_earlier_quits_frame_or_picture_fails_only_with_the_feature_on(self):
        for mark in ("terminal.launch_frame_shown", "launch_picture_shown"):
            stale = [self.row({**self.MARKS, mark: 200.0})]
            self.assertFalse(bl.after_kill_summary(stale, feature="on")["ok"], mark)
            self.assertEqual(bl.after_kill_summary(stale, feature="on")["stale_frame_runs"], 1, mark)
            self.assertTrue(bl.after_kill_summary(stale, feature="off")["ok"], "the off arm measures the old behavior")

    def test_the_terminals_must_lay_out_once_with_the_feature_on(self):
        once = bl.after_kill_layout(self.surfaces((0, 1), (0, 0)))
        self.assertEqual(once, {"terminals": 2, "surface_swaps": 0, "extra_resizes": 0, "one_layout": True})
        swapped = bl.after_kill_layout(self.surfaces((1, 1), (0, 1)))
        self.assertFalse(swapped["one_layout"], "a replay swapped in a fresh surface: the terminal was rebuilt")
        resized = bl.after_kill_layout(self.surfaces((0, 2)))
        self.assertEqual(resized["extra_resizes"], 1)
        self.assertFalse(resized["one_layout"], "a second grid size is a second layout")
        self.assertIsNone(bl.after_kill_layout({"windows": [{"panes": [{"kind": "browser"}]}]}))
        self.assertIsNone(bl.after_kill_layout(None))
        self.assertTrue(bl.after_kill_summary([self.row()])["ok"])
        for layout in (swapped, resized, None):
            summary = bl.after_kill_summary([self.row(layout=layout)])
            self.assertFalse(summary["ok"], layout)
            self.assertEqual(summary["relaid_out_runs"], 1)
            self.assertTrue(bl.after_kill_summary([self.row(layout=layout)], feature="off")["ok"], "the off arm")

    def test_the_run_is_complete_only_when_the_rings_and_the_host_were_taken_over(self):
        self.assertFalse(bl.after_kill_summary([self.row()])["complete"], "stand-in steps: not the whole task")
        took_over = {**self.MARKS, "relaunch.rings_mapping": 91.0, "relaunch.host_adopting": 92.0}
        del took_over["relaunch.rings_unavailable"], took_over["relaunch.host_unavailable"]
        summary = bl.after_kill_summary([self.row(took_over)])
        self.assertTrue(summary["complete"])
        self.assertEqual(summary["takeover_runs"], 1)
        self.assertFalse(bl.after_kill_summary([self.row(took_over)], feature="off")["complete"])

    def test_the_setup_splits_the_first_workspace_until_it_has_the_terminals(self):
        made = ["surface:1"]
        calls = []

        def cli(*args):
            calls.append(args)
            if args[0] == "list-workspaces":
                return "* workspace:3 main\n  workspace:4 other\n"
            if args[0] == "tree":
                return "".join(f'surface {ref} [terminal] "zsh" [selected]\n' for ref in made)
            if args[0] == "new-split":
                made.append(f"surface:{len(made) + 1}")
            return ""

        found = bl.after_kill_setup(cli, 3, poll=lambda _: None)
        self.assertEqual(found, ["surface:1", "surface:2", "surface:3"])
        splits = [call for call in calls if call[0] == "new-split"]
        self.assertEqual(len(splits), 2)
        self.assertTrue(all(call[2:6] == ("--workspace", "workspace:3", "--surface", call[5]) for call in splits))
        self.assertEqual(bl.after_kill_setup(lambda *a: "", 2, poll=lambda _: None, seconds=0),
                         "the launch shows no terminal in its first workspace")

    def test_the_command_kills_only_its_app_relaunches_on_the_kept_state_and_stops_once(self):
        events = []

        class Process:
            def send_signal(self, sig):
                events.append(("signal", sig))

            def wait(self, timeout=None):
                return -9

        class StubApp:
            def __init__(self, app, out=None, local_features=None):
                events.append(("features", local_features))
                self.fresh_state = True
                self.teardown = None
                self.process = Process()
                self.launches = 0

            def launch(self, timeout):
                self.launches += 1
                events.append(("launch", self.fresh_state))

            def quit_keep_sessions(self):
                events.append(("quit",))
                return {"quit": True, "seconds": 0.1, "error": ""}

            def rpc(self, method, params=None, timeout=60):
                events.append(("rpc", method))
                if method == "debug.crashes":
                    return {"launch": {"recovery": "clean"}}
                if method == "debug.surfaces":
                    return AfterKillTests.surfaces((0, 1), (0, 1))
                assert method == "debug.timings"
                return {"launch_ms_since_process_start": dict(AfterKillTests.MARKS)}

            def stop(self):
                events.append(("stop",))

        def run_cli(app, *args):
            if args[0] == "list-workspaces":
                return "workspace:1\n"
            if args[0] == "tree":
                return 'surface surface:1 [terminal] "a"\nsurface surface:2 [terminal] "b"\n'
            return ""

        out = tempfile.mkdtemp(prefix="after-kill-")
        self.addCleanup(shutil.rmtree, out, True)
        opts = mock.Mock(app="/x/cmux DEV t.app", out=None, runs=2, terminals=2, feature="on", timeout=10, settle=0,
                         mark_timeout=1, budget_ms=300, survive=62, json=os.path.join(out, "out.json"))
        now = [1000.0]

        def poll(seconds):
            events.append(("poll", seconds))
            now[0] += seconds

        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = bl.after_kill(opts, make_app=StubApp, run_cli=run_cli, poll=poll, clock=lambda: now[0])
        self.assertEqual(code, 0)
        self.assertEqual(events[0], ("features", {"relaunchReattach": True}))
        self.assertEqual([e for e in events if e[0] in ("launch", "quit", "signal", "stop")],
                         [("launch", True), ("quit",), ("launch", False), ("signal", signal.SIGKILL), ("launch", False),
                          ("signal", signal.SIGKILL), ("launch", False), ("stop",)])
        # Each app lives past the quick-crash window before its kill, so every relaunch is the launch after one kill -9.
        kills = [i for i, e in enumerate(events) if e[0] == "signal"]
        for kill in kills:
            self.assertIn(("poll", 62), events[kill - 2:kill], "the kill came inside the quick-crash window")
        self.assertEqual(sum(1 for e in events if e == ("rpc", "debug.crashes")), 2, "each run reads its recovery")
        with open(opts.json) as f:
            result = json.loads(f.read())
        self.assertEqual(result["runs"], 2)
        self.assertEqual(result["reattached_runs"], 2)
        self.assertTrue(result["ok"])

    def test_the_task_spelling_runs_the_same_command(self):
        with mock.patch.object(bl, "after_kill", return_value=0) as run:
            self.assertEqual(bl.main(["--after-kill", "--app", "/x/cmux DEV t.app", "--runs", "1"]), 0)
        self.assertEqual(run.call_args[0][0].runs, 1)
        self.assertEqual(run.call_args[0][0].feature, "on")


if __name__ == "__main__":
    unittest.main()
