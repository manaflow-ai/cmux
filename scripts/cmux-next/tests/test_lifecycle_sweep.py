#!/usr/bin/env python3
"""lifecycle-sweep.py's own harness (p02-threads 307, RUN-12), against a model of the app: its socket, its process,
its daemon and Chromium helpers, and the detector's table and fault lines. No app, GUI or build; Linux is fine.

1. One run is three launches (cold from an empty saved session, warm, after the update relaunch), each read once
   before its end, with the traps on at every launch in trap mode and off in record mode; each lifecycle step sends
   its input (simulated sleep then wake, the display change, the appearance round, the daemon's SIGKILL to the pid
   debug.daemon names, the Chromium renderers' SIGKILL, the updater's stage then relaunch, the two quits).
2. RUN-12's verdict: clean only with every launch read in trap mode, 0 sites, 0 traps, 0 overflow and no SIGTRAP; a
   site the read missed (a quit path) comes from the detector's fault line of that launch, and a trap line in app.log
   is a site too. A record run files its sites as p02-threads-R-lifecycle-<Module> and passes.
3. A step whose recovery does not happen (no new daemon, an app that stops answering, a quit that does not exit 0)
   fails the run with STEP_EXIT, and the later launches still run.
4. The daemon kill never signals a pid outside this bundle; the Chromium crash only the app's own renderers and this
   bundle's Chromium Host.

Run: python3 -I scripts/cmux-next/tests/test_lifecycle_sweep.py
"""
import contextlib, importlib.util, io, json, os, signal, subprocess, sys, tempfile, types, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
sys.path.insert(0, SCRIPTS)
spec = importlib.util.spec_from_file_location("lifecycle_sweep", os.path.join(SCRIPTS, "lifecycle-sweep.py"))
lc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lc)
import blocking_sites  # noqa: E402

APP = "/fleet/cmux DEV lifecycle.app"
SIGTRAP_EXIT = -signal.SIGTRAP


class Clock:
    """A fake monotonic clock that sleep() advances."""

    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.now += max(seconds, 0.01)


class FakeProcess:
    """`hung`: a main thread that hangs, so the app never answers and ignores SIGTERM (QuitSignal runs on main)."""

    def __init__(self, pid):
        self.pid, self.code, self.hung = pid, None, False
        self.signals = []

    def poll(self):
        return self.code

    def terminate(self):
        self.signals.append("TERM")
        if self.code is None and not self.hung:
            self.code = -signal.SIGTERM

    def kill(self):
        self.signals.append("KILL")
        if self.code is None:
            self.code = -signal.SIGKILL

    def wait(self, timeout=None):
        if self.code is None:
            raise subprocess.TimeoutExpired("cmux DEV lifecycle", timeout)
        return self.code


class World:
    """The app as the sweep sees it, one launch at a time: socket replies, processes, a daemon, Chromium helpers and
    the detector's table. `behavior` hooks change one part (a site per launch, a daemon that never comes back)."""

    def __init__(self, mode="trap", **behavior):
        self.mode, self.behavior = mode, behavior
        self.calls, self.kills, self.envs, self.fresh = [], [], [], []
        self.next_pid, self.process, self.daemon = 1000, None, None
        self.renderers, self.sites, self.log = [], [], None
        self.launch_index, self.processes = 0, []

    def pid(self):
        self.next_pid += 1
        return self.next_pid

    # BenchApp's seam.
    def make_bench(self, app, out, env, window, screen, log_name, teardown, fresh_state):
        world = self
        self.envs.append(env)
        self.fresh.append(fresh_state)

        class Bench:
            socket = "/tmp/cmux-debug-lifecycle.sock"
            ready_seconds = 1.5

            def __init__(self):
                self.app, self.process = app, None

            def launch(self, timeout, on_start):
                world.launch_index += 1
                fail = world.behavior.get("launch_fails")
                hangs = world.behavior.get("launch_hangs")
                self.process = FakeProcess(world.pid())
                world.process = self.process
                world.processes.append(self.process)
                on_start(self.process)
                if hangs and hangs(world.launch_index):
                    self.process.hung = True  # bench_launch's deadline passes; the process is left running
                    raise SystemExit("bench-launch: no window answered debug.windows in 180 s")
                if fail and fail(world.launch_index):
                    self.process.code = SIGTRAP_EXIT
                    raise SystemExit("bench-launch: exited (code -5)")
                if world.daemon is None:
                    world.daemon = world.pid()
                world.renderers = [world.pid(), world.pid()]
                world.sites = list((world.behavior.get("sites") or {}).get(world.launch_index, []))
                for site in (world.behavior.get("quit_faults") or {}).get(world.launch_index, []):
                    world.quit_faults.append((self.process.pid, site))
        return Bench()

    quit_faults = []

    def table(self):
        rows = {1: (0, "/sbin/launchd"), 77: (1, "/usr/bin/other")}
        if self.process and self.process.code is None:
            rows[self.process.pid] = (1, f"{APP}/Contents/MacOS/cmux DEV lifecycle")
            for r in self.renderers:
                rows[r] = (self.process.pid, f"{APP}/Contents/Frameworks/cmux DEV lifecycle Helper (Renderer).app/x")
        if self.daemon:
            rows[self.daemon] = (1, f"{APP}/Contents/Resources/bin/cmux-tui --headless --session x")
        return rows

    def kill(self, pid, signum):
        self.kills.append((pid, signum))
        if pid == self.daemon:
            self.daemon = None if self.behavior.get("daemon_stays_dead") else self.pid()
        elif pid in self.renderers:
            self.renderers.remove(pid)
            if self.behavior.get("crash_kills_app"):
                self.process.code = -signal.SIGSEGV

    def rpc_at(self, path, method, params=None, timeout=60):
        self.calls.append((method, params))
        if self.process is None or self.process.code is not None:
            return {"error": "connection refused", "unreachable": True}
        if self.process.hung:
            return {"error": "timed out", "unreachable": True}
        if method == "debug.daemon":
            return {"connection": "connected", "pid": self.daemon} if self.daemon else {"connection": "disconnected"}
        if method == "debug.blocking":
            return {"compiled_in": True, "mode": self.mode, "pool_mode": self.mode, "overflow": 0,
                    "sites": [dict(s) for s in self.sites]}
        if method == "debug.appearance":
            mode = (params or {}).get("mode")
            return {"effective": "dark" if mode == "dark" else "light"}
        if method == "action.run" and (params or {}).get("action") in ("quitKeepSessions", "quitEndSessions"):
            self.end_launch((params or {}).get("action"))
            return {"error": "connection reset", "unreachable": True}
        if method == "debug.updater" and (params or {}).get("action") == "relaunch":
            self.end_launch("relaunch")
            return {"relaunching": True}
        if method == "debug.cef":
            return {"state": "ready"}
        return {}

    def end_launch(self, how):
        code = (self.behavior.get("exit_codes") or {}).get(self.launch_index, 0)
        self.process.code = code
        if how == "quitEndSessions":
            self.daemon = None


class FakeLog:
    def __init__(self, live=True, error=None):
        self.pids, self.sites, self.live, self.error = set(), [], live, error

    def report(self):
        return {"live": self.live, "error": self.error, "sites": len(self.sites)}


class FakeLogStream:
    """`log stream` as BlockingLog starts it: its merged output lines and whether it has exited."""

    def __init__(self, lines, code=None):
        self.stdout, self.code, self.killed = io.StringIO("".join(lines)), code, False

    def poll(self):
        return self.code

    def kill(self):
        self.killed, self.code = True, -signal.SIGKILL

    def send_signal(self, signum):
        if self.code is None:
            self.code = 0

    def wait(self, timeout=None):
        return self.code


class FakeStress:
    class Stress:
        web_dev_config = None

        def __init__(self, rpc, log=None, settle=1.0):
            self.refusals = []

        def build_light(self, kinds):
            return "ws-1", ["p-1", "p-2"]

    @staticmethod
    def cef_problems(cef, web_dev_config=None):
        return []


class FakeTeardown:
    def __init__(self):
        self.remembered, self.ended = 0, 0

    def remember(self):
        self.remembered += 1

    def end(self):
        self.ended += 1


def run_sweep(world, mode="trap", skip=(), traps=(), log=None):
    world.quit_faults = []
    out = tempfile.mkdtemp(prefix="lifecycle-test-")
    opts = types.SimpleNamespace(app=APP, tag="lifecycle", blocking_report=mode, skip=list(skip), settle=0.5, app_env=[])
    clock, log, teardown = Clock(), log or FakeLog(), FakeTeardown()
    sweep = lc.Sweep(opts, out, world.make_bench, teardown, FakeStress, log, world.rpc_at, table=world.table,
                     kill=world.kill, sleep=clock.sleep, clock=clock)
    with contextlib.redirect_stdout(io.StringIO()):
        sweep.run()
    log.sites = list(world.quit_faults)
    report = lc.report_of(sweep, mode, list(traps), log.report(), {"sha": "a" * 40, "host": "test", "macos": "26"})
    return sweep, report, teardown, out


class LifecycleRunTests(unittest.TestCase):
    def test_a_clean_trap_run_is_three_launches_each_read_once_with_every_step_and_exits_0(self):
        world = World()
        sweep, report, teardown, _ = run_sweep(world)
        self.assertEqual([l["name"] for l in report["launches"]], ["cold", "warm", "after-update"])
        self.assertEqual(world.fresh, [True, False, False])  # only the cold launch starts from an empty session
        self.assertTrue(all(e["CMUX_BLOCKING_TRAP"] == "1" and e["CMUX_BLOCKING_TRAP_POOL"] == "1" for e in world.envs))
        self.assertEqual([r["step"] for r in report["steps"]], list(lc.STEPS))
        self.assertEqual(report["failed_steps"], [])
        self.assertEqual([m for m, _ in world.calls].count("debug.blocking"), 3)
        self.assertEqual([r["quit_exit"] for r in sweep.reads], [0, 0, 0])
        self.assertTrue(report["blocking"]["run12"]["clean"], report["blocking"]["run12"])
        self.assertTrue(report["blocking"]["run12"]["whole_catalog"])
        self.assertEqual(lc.exit_status(report), 0)
        self.assertEqual(teardown.ended, 1)

    def test_each_step_sends_its_lifecycle_input_in_order(self):
        world = World()
        run_sweep(world)
        calls = world.calls
        wake = [p["phase"] for m, p in calls if m == "debug.simulate.wake"]
        self.assertEqual(wake, ["sleep", "wake"])
        self.assertEqual(sum(1 for m, _ in calls if m == "debug.simulate.display"), 1)
        self.assertEqual([p["mode"] for m, p in calls if m == "debug.appearance"], ["dark", "light", "system"])
        self.assertEqual([p["action"] for m, p in calls if m == "debug.updater"], ["stage", "relaunch"])
        quits = [p["action"] for m, p in calls if m == "action.run"]
        self.assertEqual(quits, ["quitKeepSessions", "quitEndSessions"])
        # The update relaunch ends the warm launch: its read comes before the stage.
        order = [m for m, p in calls if m in ("debug.blocking", "debug.updater")]
        self.assertEqual(order[:3], ["debug.blocking", "debug.blocking", "debug.updater"])

    def test_the_daemon_kill_signals_only_the_daemon_debug_daemon_names_and_waits_for_a_new_one(self):
        world = World()
        sweep, report, teardown, _ = run_sweep(world)
        killed = [pid for pid, sig in world.kills if sig == signal.SIGKILL]
        row = next(r for r in report["steps"] if r["step"] == "daemon-kill")
        self.assertTrue(row["ok"], row)
        self.assertIn(row["detail"]["killed"], killed)
        self.assertNotEqual(row["detail"]["new"], row["detail"]["killed"])
        self.assertNotIn(77, killed)
        self.assertGreaterEqual(teardown.remembered, 7)  # each launch twice, and the new daemon

    def test_a_daemon_outside_this_bundle_is_never_killed(self):
        world = World()
        original = world.table

        def table():
            rows = original()
            if world.daemon:
                rows[world.daemon] = (1, "/Applications/cmux.app/Contents/Resources/bin/cmux-tui --headless")
            return rows
        world.table = table
        _, report, _, _ = run_sweep(world)
        self.assertFalse([k for k in world.kills if k[0] == world.daemon])
        row = next(r for r in report["steps"] if r["step"] == "daemon-kill")
        self.assertFalse(row["ok"])
        self.assertIn("no daemon of this bundle", row["detail"]["error"])
        self.assertEqual(lc.exit_status(report), lc.STEP_EXIT)

    def test_no_reconnect_after_the_daemon_kill_fails_the_step_and_the_run_goes_on(self):
        world = World(daemon_stays_dead=True)
        _, report, _, _ = run_sweep(world)
        row = next(r for r in report["steps"] if r["step"] == "daemon-kill")
        self.assertFalse(row["ok"])
        self.assertIn("no reconnect", row["detail"]["error"])
        self.assertIn("launch-after-update", [r["step"] for r in report["steps"]])
        self.assertEqual(lc.exit_status(report), lc.STEP_EXIT)

    def test_the_chromium_crash_ends_only_this_apps_renderers_and_the_app_must_survive_it(self):
        world = World()
        _, report, _, _ = run_sweep(world)
        row = next(r for r in report["steps"] if r["step"] == "chromium-crash")
        self.assertTrue(row["ok"], row)
        self.assertEqual({kind for _, kind in row["detail"]["killed"]}, {"renderer"})
        dying = World(crash_kills_app=True)
        _, report, _, _ = run_sweep(dying)
        row = next(r for r in report["steps"] if r["step"] == "chromium-crash")
        self.assertFalse(row["ok"])
        self.assertIn("no longer answers", row["detail"]["error"])
        self.assertIn("chromium-crash", report["failed_steps"])

    def test_chromium_victims_are_the_apps_renderers_and_this_bundles_host_only(self):
        rows = {10: (1, f"{APP}/Contents/MacOS/cmux DEV lifecycle"),
                11: (10, f"{APP}/Contents/Frameworks/x Helper (Renderer).app/x"),
                12: (10, f"{APP}/Contents/Frameworks/x Helper (GPU).app/x"),
                13: (1, f"{APP}/Contents/MacOS/cmux DEV lifecycle Chromium Host --type=browser"),
                14: (99, "/Applications/cmux.app/Contents/Frameworks/x Helper (Renderer).app/x"),
                15: (1, "/Applications/cmux.app/Contents/MacOS/cmux Chromium Host")}
        self.assertEqual(lc.chromium_victims(rows, 10, APP), [(11, "renderer"), (13, "chromium-host")])

    def test_a_quit_that_does_not_exit_0_fails_and_is_on_the_launchs_read(self):
        world = World(exit_codes={1: 6})
        sweep, report, _, _ = run_sweep(world)
        row = next(r for r in report["steps"] if r["step"] == "quit")
        self.assertFalse(row["ok"])
        self.assertEqual(sweep.reads[0]["quit_exit"], 6)
        self.assertEqual(lc.exit_status(report), lc.STEP_EXIT)

    def test_a_launch_that_never_answers_and_ignores_term_is_killed_and_the_run_still_reports(self):
        # A hung main thread never handles the SIGTERM: the sweep kills it, then goes on to the next launch.
        world = World(launch_hangs=lambda index: index == 1)
        sweep, report, teardown, out = run_sweep(world)
        hung = world.processes[0]
        self.assertEqual(hung.signals, ["TERM", "KILL"])
        self.assertEqual(sweep.reads[0]["quit_exit"], -signal.SIGKILL)
        self.assertEqual([l["name"] for l in report["launches"]], ["cold", "warm", "after-update"])
        self.assertIn("launch-cold", report["failed_steps"])
        self.assertIn("launch-after-update", [r["step"] for r in report["steps"] if r["ok"]])
        self.assertFalse(report["blocking"]["run12"]["clean"])
        self.assertEqual(lc.exit_status(report), lc.BLOCKING_EXIT)
        self.assertEqual(teardown.ended, 1)
        lc.write_report(report, out)
        for name in ("lifecycle.json", "lifecycle.md", "blocking-tasks.json"):
            self.assertTrue(os.path.exists(os.path.join(out, name)), name)


class LifecycleBlockingTests(unittest.TestCase):
    def test_a_site_in_a_read_fails_run12_and_is_filed_under_the_lifecycle_sweeps_id(self):
        world = World(sites={2: [{"kind": "file-io", "context": "main", "location": "CmuxNextApp/Warm.swift:4", "count": 2}]})
        _, report, _, out = run_sweep(world)
        run12 = report["blocking"]["run12"]
        self.assertFalse(run12["clean"])
        self.assertIn("CmuxNextApp/Warm.swift file-io", "; ".join(run12["problems"]))
        self.assertEqual(lc.exit_status(report), lc.BLOCKING_EXIT)
        task = report["blocking"]["tasks"][0]
        self.assertEqual(task["id"], "p02-threads-R-lifecycle-CmuxNextApp")
        self.assertEqual(task["depends_on"], ["p02-threads-307"])
        self.assertIn("lifecycle-sweep.py --blocking-report=trap (RUN-12)", task["acceptance"])
        lc.write_report(report, out)
        with open(os.path.join(out, "blocking-tasks.json")) as f:
            self.assertEqual(json.load(f)["tasks"][0]["id"], "p02-threads-R-lifecycle-CmuxNextApp")
        with open(os.path.join(out, "lifecycle.md")) as f:
            self.assertIn("RUN-12: NOT clean", f.read())

    def test_a_quit_path_site_comes_from_its_launchs_fault_line(self):
        # The detector's table ends with the launch: a site of the quit after the read is only in the fault log.
        site = {"kind": "lock-wait", "context": "main", "location": "CmuxNextApp/QuitFlush.swift:9"}
        listed = {"kind": "file-io", "context": "main", "location": "CmuxNextApp/Shown.swift:3", "count": 1}
        world = World(mode="record", sites={1: [listed]}, quit_faults={1: [site, listed]})
        sweep, report, _, _ = run_sweep(world, mode="record")
        groups = {(g["file_id"], g["kind"]): g for g in report["blocking"]["groups"]}
        self.assertIn(("CmuxNextApp/QuitFlush.swift", "lock-wait"), groups)
        self.assertEqual(groups[("CmuxNextApp/QuitFlush.swift", "lock-wait")]["sessions"], ["cold after its read"])
        self.assertEqual(groups[("CmuxNextApp/Shown.swift", "file-io")]["count"], 1)  # the read had it: not twice
        self.assertNotIn("run12", report["blocking"])  # a record run's sites are its output
        self.assertEqual(lc.exit_status(report), 0)
        self.assertTrue(all(e["CMUX_BLOCKING_TRAP"] == "0" for e in world.envs))

    def test_a_trap_run_without_its_fault_log_is_not_clean(self):
        # The sites after each read (the quits, the update relaunch) are only in the fault log: no log, no RUN-12.
        world = World()
        _, report, _, out = run_sweep(world, log=FakeLog(live=False, error="log stream exited during the run (code 1)"))
        run12 = report["blocking"]["run12"]
        self.assertFalse(run12["clean"])
        self.assertIn("no fault log (log stream exited during the run (code 1))", "; ".join(run12["problems"]))
        self.assertEqual(lc.exit_status(report), lc.BLOCKING_EXIT)
        lc.write_report(report, out)
        with open(os.path.join(out, "lifecycle.md")) as f:
            self.assertIn("RUN-12: NOT clean", f.read())

    def test_a_log_stream_that_exits_at_once_is_not_live(self):
        out = tempfile.mkdtemp(prefix="lifecycle-log-")
        refused = FakeLogStream(["log: Must be admin to run 'stream' command\n"], code=64)
        log = lc.BlockingLog(os.path.join(out, "blocking.log"), popen=lambda *a, **k: refused).start()
        self.assertFalse(log.live)
        self.assertIn("did not attach: log: Must be admin", log.report()["error"])
        silent = FakeLogStream([], code=1)
        log = lc.BlockingLog(os.path.join(out, "blocking.log"), popen=lambda *a, **k: silent).start()
        self.assertEqual((log.live, log.report()["error"]), (False, "log stream did not attach: no output"))
        log.stop()  # nothing to stop

    def test_a_log_stream_that_attaches_is_live_until_it_exits_on_its_own(self):
        out = tempfile.mkdtemp(prefix="lifecycle-log-")
        stream = FakeLogStream(['Filtering the log data using "subsystem == x"\n'])
        log = lc.BlockingLog(os.path.join(out, "blocking.log"), popen=lambda *a, **k: stream).start()
        self.assertTrue(log.live)
        log.stop()
        self.assertEqual(log.report(), {"live": True, "error": None, "sites": 0})
        died = FakeLogStream(['Filtering the log data using "subsystem == x"\n'])
        log = lc.BlockingLog(os.path.join(out, "blocking.log"), popen=lambda *a, **k: died).start()
        died.code = 1  # it stopped mid-run
        log.stop()
        self.assertFalse(log.report()["live"])
        self.assertIn("exited during the run (code 1)", log.report()["error"])

    def test_a_fault_line_from_another_process_is_not_a_site(self):
        log = lc.BlockingLog("/dev/null")
        log.pids = {5}
        line = ('{"processID": %d, "eventMessage": "blocking file-io on the main thread at CmuxNextApp/A.swift:1: move it"}')
        log.take(line % 6)
        log.take("not json")
        log.take(line % 5)
        self.assertEqual(log.sites, [(5, {"kind": "file-io", "context": "main", "location": "CmuxNextApp/A.swift:1"})])

    def test_a_trap_in_app_log_or_a_sigtrap_exit_fails_run12(self):
        world = World()
        _, report, _, _ = run_sweep(world, traps=[{"kind": "file-io", "context": "pool", "location": "CmuxNextApp/W.swift:2"}])
        self.assertFalse(report["blocking"]["run12"]["clean"])
        world = World(exit_codes={3: SIGTRAP_EXIT})
        _, report, _, _ = run_sweep(world)
        self.assertIn("trapped while it quit", "; ".join(report["blocking"]["run12"]["problems"]))
        self.assertEqual(lc.exit_status(report), lc.BLOCKING_EXIT)

    def test_a_launch_that_traps_before_it_answers_is_unread_and_the_next_launches_still_run(self):
        world = World(launch_fails=lambda index: index == 2)
        sweep, report, _, _ = run_sweep(world)
        self.assertEqual(sweep.reads[1]["exit"], SIGTRAP_EXIT)
        problems = "; ".join(report["blocking"]["run12"]["problems"])
        self.assertIn("warm launch 2 exited on SIGTRAP", problems)
        self.assertIn("launch-warm", report["failed_steps"])
        self.assertIn("update-install", report["failed_steps"])
        self.assertEqual(report["launches"][2]["name"], "after-update")
        self.assertEqual(lc.exit_status(report), lc.BLOCKING_EXIT)

    def test_a_skip_makes_the_run_partial_and_update_install_falls_back_to_quit(self):
        world = World()
        _, report, _, _ = run_sweep(world, skip=["display", "update-install"])
        self.assertFalse(report["blocking"]["run12"]["whole_catalog"])
        steps = [r["step"] for r in report["steps"]]
        self.assertNotIn("display", steps)
        self.assertEqual(steps.count("quit"), 2)
        self.assertNotIn("debug.updater", [m for m, _ in world.calls])
        planned = [s["step"] for launch in lc.plan(["update-install"]) for s in launch["steps"]]
        self.assertEqual(planned.count("quit"), 2)


class FaultLineTests(unittest.TestCase):
    """blocking_sites.blocking_fault reads the detector's own fault messages (BlockingViolationTable.drain)."""

    def test_each_contexts_fault_line_is_its_site(self):
        cases = {
            "blocking file-io on the main thread at CmuxNextApp/A.swift:12: move it off the main thread, or wrap it":
                {"kind": "file-io", "context": "main", "location": "CmuxNextApp/A.swift:12"},
            "blocking sync-wait on the cooperative pool or a GCD root queue at CmuxNextDaemon/B.swift:3: run it on a "
            "BackgroundWork lane (plans/cmux-next/threading-model.md)":
                {"kind": "sync-wait", "context": "pool", "location": "CmuxNextDaemon/B.swift:3"},
            "blocking fs-metadata in a .cpu lane item at CmuxNextFiles/C.swift:40: the .cpu lane is sized to the cores":
                {"kind": "wrong-lane", "context": "cpu-lane", "location": "CmuxNextFiles/C.swift:40"},
            "blocking lock-wait on a sync primitive in a BackgroundWork lane item at CmuxNextCompat/D.swift:7: a lane":
                {"kind": "lock-wait", "context": "lane-sync", "location": "CmuxNextCompat/D.swift:7"},
        }
        for message, site in cases.items():
            with self.subTest(message[:40]):
                self.assertEqual(blocking_sites.blocking_fault(message), site)
        self.assertIsNone(blocking_sites.blocking_fault("Fatal error: something else"))
        self.assertIsNone(blocking_sites.blocking_fault(None))

    def test_the_fault_messages_match_the_detectors_source(self):
        # The words the parser keys on are the detector's own: a reworded fault line must update the parser.
        path = os.path.join(SCRIPTS, "..", "..", "Packages/macOS/CmuxNext/Sources/CmuxNextCompat/Threading/"
                            "BlockingViolationTable.swift")
        with open(path) as f:
            source = f.read()
        for words in blocking_sites.FAULT_CONTEXTS:
            self.assertIn(f") {words} at \\(location, privacy: .public)", source)

    def test_the_every_action_sweep_keeps_its_own_ids_and_verdict_key(self):
        reads = [{"session": "light", "launch": 1, "exit": None,
                  "reply": {"compiled_in": True, "mode": "trap", "pool_mode": "trap", "overflow": 0, "sites": []}}]
        self.assertIn("run1", blocking_sites.blocking_section("trap", reads, []))
        self.assertIn("run12", blocking_sites.blocking_section("trap", reads, [], sweep="lifecycle"))
        self.assertEqual(blocking_sites.blocking_task_id("CmuxNextApp"), "p02-threads-R-every-action-CmuxNextApp")


class PlanTests(unittest.TestCase):
    def test_plan_only_needs_no_app_and_lists_every_step(self):
        out = tempfile.mkdtemp(prefix="lifecycle-plan-")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(lc.main(["--plan-only", "--out", out]), 0)
        with open(os.path.join(out, "lifecycle-plan.json")) as f:
            planned = json.load(f)
        self.assertEqual([s["step"] for launch in planned for s in launch["steps"]], list(lc.STEPS))
        self.assertTrue(all(s["does"] for launch in planned for s in launch["steps"]))

    def test_skip_refuses_a_launch_or_end_step_and_a_crash_without_its_session(self):
        for skip in ("launch-cold", "quit", "quit-end", "session"):
            with self.subTest(skip), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                lc.parse(["--plan-only", "--out", "/tmp", "--skip", skip])
        self.assertEqual(lc.parse(["--plan-only", "--out", "/tmp", "--skip", "session,chromium-crash"]).skip,
                         ["session", "chromium-crash"])


if __name__ == "__main__":
    unittest.main()
