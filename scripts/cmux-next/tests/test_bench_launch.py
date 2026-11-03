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

Runs on any Mac, no GUI session or build needed (the session read is injected or the check is `--socket-only`, and a
copy of /bin/sleep stands in for the app's executable). Signals only the processes it starts.

    python3 scripts/cmux-next/tests/test_bench_launch.py
"""

from __future__ import annotations

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


if __name__ == "__main__":
    unittest.main()
