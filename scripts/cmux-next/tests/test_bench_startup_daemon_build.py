#!/usr/bin/env python3
"""bench-startup.py reports a launch as "not run" when its daemons are not the build under test (lead 2026-11-01).

The cmux-tui and acpmux daemons outlive the app. A fleet step runs a fresh copy of the app at a new path, and
bench-startup stopped only the processes of THAT path (tag_pids), so a daemon of the same tag left by an earlier step,
copy or commit kept running, and the new app attached to it. Such a round measures the old daemon. These tests need no
app: daemon_verdict() is pure, and the stop test uses `sleep` copies in two fake bundles.
Run: python3 -I scripts/cmux-next/tests/test_bench_startup_daemon_build.py"""
import importlib.util, io, json, os, shutil, subprocess, sys, tempfile, time, unittest
from contextlib import redirect_stderr, redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
spec = importlib.util.spec_from_file_location("bench_startup", os.path.join(HERE, "..", "bench-startup.py"))
bench_startup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench_startup)

APP = "/Users/cmux/steps/job-b/home/DerivedData/cmux-split-spring/Build/Products/Release/cmux DEV split-spring.app"
OLD = "/Users/cmux/steps/job-a/home/DerivedData/cmux-split-spring/Build/Products/Release/cmux DEV split-spring.app"


def daemon(name, bundle, started):
    return {"name": name, "pid": 4242, "build_id": "x", "started_wall": started,
            "exe": f"{bundle}/Contents/Resources/bin/{name}"}


class Verdict(unittest.TestCase):
    def test_the_daemons_of_the_app_under_test_make_a_run(self):
        v = bench_startup.daemon_verdict(APP, [daemon("cmux-tui", APP, 1000.5), daemon("acpmux", APP, 1001)], 1000.0)
        self.assertEqual(v["verdict"], "run", v["reasons"])

    def test_a_daemon_of_another_app_copy_is_not_run(self):
        v = bench_startup.daemon_verdict(APP, [daemon("cmux-tui", OLD, 1000.5)], 1000.0)
        self.assertEqual(v["verdict"], "not_run")
        self.assertIn("not a binary of the app under test", v["reasons"][0])

    def test_a_daemon_started_before_the_launch_is_not_run(self):
        v = bench_startup.daemon_verdict(APP, [daemon("cmux-tui", APP, 900.0)], 1000.0)
        self.assertEqual(v["verdict"], "not_run")
        self.assertIn("left from an earlier launch", v["reasons"][0])

    def test_a_stale_acpmux_alone_is_not_run(self):
        v = bench_startup.daemon_verdict(APP, [daemon("cmux-tui", APP, 1000.5), daemon("acpmux", OLD, 1000.5)], 1000.0)
        self.assertEqual(v["verdict"], "not_run")

    def test_no_owner_is_not_run(self):
        self.assertEqual(bench_startup.daemon_verdict(APP, [], 1000.0)["verdict"], "not_run")


class Hosts(unittest.TestCase):
    """Terminal hosts run from host-exe/<sha256 of the bundle's binary>/<name>, outside the bundle, and keep their
    binary until their terminal ends (DAEMON SKEW 2703): a host of another build makes the round not run."""

    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="hosts-")
        self.app = os.path.join(self.root, "cmux DEV hosttest.app")
        bin_dir = os.path.join(self.app, "Contents/Resources/bin")
        os.makedirs(bin_dir)
        for name, body in (("cmux-tui", b"new tui build"), ("cmux-tui-host", b"new slim host build")):
            with open(os.path.join(bin_dir, name), "wb") as f:
                f.write(body)
        import hashlib
        self.new = hashlib.sha256(b"new slim host build").hexdigest()
        self.old = hashlib.sha256(b"an older build").hexdigest()

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def owner(self):
        return {"name": "cmux-tui", "pid": 1, "build_id": "b", "started_wall": 1000.5,
                "exe": os.path.join(self.app, "Contents/Resources/bin/cmux-tui")}

    def host(self, digest):
        return {"name": "terminal-host", "pid": 2, "build_id": None, "started_wall": 1000.6,
                "exe": f"/Users/cmux/Library/Application Support/cmux-tui/host-exe/{digest}/cmux-tui-host"}

    def test_a_host_copy_of_the_bundles_binary_is_the_build(self):
        v = bench_startup.daemon_verdict(self.app, [self.owner(), self.host(self.new)], 1000.0)
        self.assertEqual(v["verdict"], "run", v["reasons"])

    def test_a_host_of_another_build_is_not_run(self):
        v = bench_startup.daemon_verdict(self.app, [self.owner(), self.host(self.old)], 1000.0)
        self.assertEqual(v["verdict"], "not_run")
        self.assertIn("terminal-host", v["reasons"][0])

    def test_an_older_host_of_the_build_still_counts(self):
        # Restart adopts hosts and warm keeps the prime's: hosts are judged by binary only (review of #29878).
        old_host = self.host(self.new)
        old_host["started_wall"] = 10.0
        self.assertEqual(bench_startup.daemon_verdict(self.app, [self.owner(), old_host], 1000.0)["verdict"], "run")

    def test_a_host_command_is_recognized(self):
        self.assertTrue(bench_startup.is_host_command("cmux-tui __terminal-host --owner a:b@1"))
        self.assertTrue(bench_startup.is_host_command("cmux-holder --socket /tmp/x.sock"))
        self.assertTrue(bench_startup.is_host_command("/x/acpmux __agent-host --id 1"))
        self.assertFalse(bench_startup.is_host_command("/x/cmux-tui --headless --session s"))

    def test_an_agent_host_outside_the_bundle_is_not_run(self):
        agent = {"name": "agent-host", "pid": 3, "build_id": None, "started_wall": 1000.6,
                 "exe": "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/acpmux"}
        self.assertEqual(bench_startup.daemon_verdict(self.app, [self.owner(), agent], 1000.0)["verdict"], "not_run")


class FloorOrder(unittest.TestCase):
    """Review of #29878, finding 1: the warm and restart floor must be taken before the run starts any daemon (reset,
    seed, stop, prime), so the daemon these modes keep on purpose is not called left over."""

    def test_the_floor_is_taken_before_the_prime_launch(self):
        events = []
        bench_startup.STEP_STARTED_WALL.clear()

        class Prime:
            def __init__(self, *a, **k):
                events.append(("prime", time.time()))

            def wait_for(self, *a, **k):
                return True

            def quit(self):
                pass

        class Stop(Exception):
            pass

        def measured(*a, **k):
            raise Stop()  # the measured launch: the order up to here is what is tested

        launches = iter([Prime, measured])
        patches = {"app_pids": lambda tag: [], "tag_pids": lambda tag: [], "stop": lambda pids, timeout=10: None,
                   "tag_daemon_pids": lambda tag: [], "other_copy_apps": lambda tag: [],
                   "end_tag_hosts": lambda tag: None,  # never the real teardown of a same-named tag on a Mac
                   "Launch": lambda *a, **k: next(launches)(*a, **k)}
        saved = {k: getattr(bench_startup, k, None) for k in patches}
        try:
            for k, v in patches.items():
                setattr(bench_startup, k, v)
            with self.assertRaises(Stop):
                bench_startup.one_run("floortest", "warm", 5, None)
        finally:
            for k, v in saved.items():
                if v is not None:
                    setattr(bench_startup, k, v)
        floor = bench_startup.STEP_STARTED_WALL.get("floortest")
        self.assertIsNotNone(floor, "no floor taken")
        self.assertLessEqual(floor, events[0][1], "the floor was taken after the prime launch started its daemon")


class NotRunIsNeverCounted(unittest.TestCase):
    """Review finding 2: a not-run round is never a pass or a fail: it stays out of the table, budgets, orders and A/B."""

    def runs(self):
        good = {"first_terminal_frame": 700.0, "daemons": {"verdict": "run"}}
        stale = {"first_terminal_frame": 99999.0, "daemons": {"verdict": "not_run", "reasons": ["old daemon"]}}
        return {"t": {"cold": [good, stale]}}

    def test_budgets_ignore_a_not_run_round(self):
        results = self.runs()
        counted = {t: {m: [r for r in rs if bench_startup.counts(r)] for m, rs in ms.items()} for t, ms in results.items()}
        self.assertEqual(bench_startup.check_budgets(counted, ["first_terminal_frame=1000"]), [])

    def test_bench_ab_takes_no_sample_from_a_not_run_round(self):
        spec2 = importlib.util.spec_from_file_location(
            "bench_ab", os.path.join(HERE, "..", "..", "measure", "bench-ab", "bench_ab.py"))
        bench_ab = importlib.util.module_from_spec(spec2)
        spec2.loader.exec_module(bench_ab)
        out = bench_ab.samples_launch(self.runs())
        self.assertEqual(out["cold"]["first_terminal_frame"], [700.0])
        self.assertNotIn("not_run", out["cold"])  # never an A/B metric row


class AllNotRun(unittest.TestCase):
    """Review 3 of #29878: a tag and mode whose every run is not run must keep its report and not read as a pass."""

    def run_main(self, run, argv):
        json_path = os.path.join(tempfile.mkdtemp(), "report.json")
        patches = {"require_gui_session": lambda name: None, "one_run": lambda *a, **k: dict(run),
                   "stop": lambda pids, timeout=10: None, "tag_pids": lambda tag: []}
        saved = {k: getattr(bench_startup, k) for k in patches}
        argv_saved = sys.argv
        code = 0
        try:
            for k, v in patches.items():
                setattr(bench_startup, k, v)
            sys.argv = ["bench-startup.py", "--tag", "t", "--runs", "2", "--mode", "cold", "--json", json_path] + argv
            with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                try:
                    bench_startup.main()
                except SystemExit as exit_:
                    code = exit_.code if isinstance(exit_.code, int) else 1
        finally:
            for k, v in saved.items():
                setattr(bench_startup, k, v)
            sys.argv = argv_saved
        return code, json_path

    def test_hangs_with_no_counted_run_keeps_the_report(self):
        stale = {"first_terminal_frame": 700.0, "stalls": [], "daemons": {"verdict": "not_run", "reasons": ["old"]}}
        code, path = self.run_main(stale, ["--hangs", "50"])
        self.assertTrue(os.path.exists(path), "the JSON report was lost")

    def test_no_counted_run_is_not_a_pass(self):
        stale = {"first_terminal_frame": 700.0, "daemons": {"verdict": "not_run", "reasons": ["old"]}}
        code, path = self.run_main(stale, [])
        self.assertNotEqual(code, 0, "every run not run must not exit 0 (a pass)")
        self.assertNotEqual(code, 1, "and not 1 (a budget fail)")
        with open(path) as f:
            self.assertIn("not_run", json.load(f))


class Helpers(unittest.TestCase):
    def test_etime_has_no_time_zone(self):
        self.assertEqual(bench_startup.wall_from_etime("01:02", 1000.0), 1000.0 - 62)
        self.assertEqual(bench_startup.wall_from_etime("1-02:03:04", 100000.0), 100000.0 - (86400 + 7384))
        self.assertIsNone(bench_startup.wall_from_etime("garbage", 1.0))

    def test_a_reported_build_that_differs_is_not_run(self):
        app = APP
        d = daemon("cmux-tui", app, 1000.5)
        d["build_id"] = "old-build"
        v = bench_startup.daemon_verdict(app, [d], 1000.0, {"cmux-tui": "new-build"})
        self.assertEqual(v["verdict"], "not_run")
        self.assertIn("reports build old-build", " ".join(v["reasons"]))

    def test_the_exec_path_is_not_argv0(self):
        # Hosts set argv[0] to "cmux-tui" and holders to "cmux-holder" (host_exe.rs, holder_runtime/service.rs); the
        # verdict needs the real exec path. On this host, our own process's exec path is the python binary.
        exe = bench_startup.process_exe(os.getpid())
        if sys.platform == "darwin":
            self.assertEqual(os.path.realpath(exe), os.path.realpath(sys.executable))
        src = open(spec.origin).read()
        body = src[src.index("def process_exe("):src.index("def process_exe(") + 900]
        self.assertNotIn('"comm="', body)

    def test_a_differing_acpmux_build_is_not_run(self):
        app = APP
        d = daemon("acpmux", app, 1000.5)
        d["build_id"] = "aaa111 2026-10-30"
        owner = daemon("cmux-tui", app, 1000.5)
        v = bench_startup.daemon_verdict(app, [owner, d], 1000.0, {"acpmux": "bbb222 2026-10-31"})
        self.assertEqual(v["verdict"], "not_run")

    def test_a_holder_is_matched_by_its_program_not_a_mention(self):
        self.assertTrue(bench_startup.is_host_command("/x/host-exe/abc/cmux-holder --socket /tmp/s.sock"))
        self.assertFalse(bench_startup.is_host_command("/usr/bin/grep cmux-holder some.log"))

    def test_pgrep_is_this_users_only(self):
        src = open(spec.origin).read()
        body = src[src.index("def pgrep("):src.index("def pgrep(") + 500]
        self.assertIn('"-U"', body)


class StopEveryCopy(unittest.TestCase):
    """Cold mode must stop the tag's daemons of EVERY app copy, not only the copy this step runs."""

    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="daemon-copies-")
        self.procs = []
        self.tag = "copytest"
        sleep = shutil.which("sleep")
        self.bins = {}
        for copy in ("job-a", "job-b"):
            d = os.path.join(self.root, copy, f"DerivedData/cmux-{self.tag}/Build/Products/Release",
                             f"cmux DEV {self.tag}.app", "Contents/Resources/bin")
            os.makedirs(d)
            shutil.copy(sleep, os.path.join(d, "cmux-tui"))
            self.bins[copy] = os.path.join(d, "cmux-tui")
        bench_startup.APPS[self.tag] = os.path.dirname(os.path.dirname(os.path.dirname(self.bins["job-b"])))

    def tearDown(self):
        for p in self.procs:
            if p.poll() is None:
                p.kill()  # this test's own child
                p.wait()
        bench_startup.APPS.pop(self.tag, None)
        shutil.rmtree(self.root, ignore_errors=True)

    def test_cold_mode_selects_the_daemon_of_an_earlier_copy(self):
        old = subprocess.Popen([self.bins["job-a"], "30"])
        self.procs.append(old)
        time.sleep(0.3)
        # The pids cold mode stops before its launch (feat before this fix: tag_pids(tag), the step's own copy only).
        # stop() itself waits with kqueue (macOS only); the selection is what decides whether a stale daemon survives.
        select_pids = getattr(bench_startup, "tag_daemon_pids", None) or bench_startup.tag_pids
        self.assertIn(old.pid, select_pids(self.tag), "an earlier copy's daemon of this tag is not stopped")

    def test_a_longer_tag_is_never_selected(self):
        longer = os.path.join(self.root, "job-d", f"DerivedData/cmux-{self.tag}-spring/Build/Products/Release",
                              f"cmux DEV {self.tag}-spring.app", "Contents/Resources/bin")
        os.makedirs(longer)
        shutil.copy(shutil.which("sleep"), os.path.join(longer, "cmux-tui"))
        p = subprocess.Popen([os.path.join(longer, "cmux-tui"), "30"])
        self.procs.append(p)
        time.sleep(0.3)
        select_pids = getattr(bench_startup, "tag_daemon_pids", None) or bench_startup.tag_pids
        self.assertNotIn(p.pid, select_pids(self.tag))

    def test_another_copys_app_is_never_selected_but_reported(self):
        macos = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(self.bins["job-a"]))), "MacOS")
        os.makedirs(macos)
        app_bin = os.path.join(macos, f"cmux DEV {self.tag}")
        shutil.copy(shutil.which("sleep"), app_bin)
        p = subprocess.Popen([app_bin, "30"])
        self.procs.append(p)
        time.sleep(0.3)
        self.assertNotIn(p.pid, bench_startup.tag_daemon_pids(self.tag))
        self.assertIn(p.pid, bench_startup.other_copy_apps(self.tag))

    def test_another_tag_is_never_selected(self):
        other = os.path.join(self.root, "job-c", "DerivedData/cmux-othertag/Build/Products/Release",
                             "cmux DEV othertag.app", "Contents/Resources/bin")
        os.makedirs(other)
        shutil.copy(shutil.which("sleep"), os.path.join(other, "cmux-tui"))
        p = subprocess.Popen([os.path.join(other, "cmux-tui"), "30"])
        self.procs.append(p)
        time.sleep(0.3)
        select_pids = getattr(bench_startup, "tag_daemon_pids", None) or bench_startup.tag_pids
        self.assertNotIn(p.pid, select_pids(self.tag))

if __name__ == "__main__":
    unittest.main()
