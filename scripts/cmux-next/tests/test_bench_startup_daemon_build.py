#!/usr/bin/env python3
"""bench-startup.py reports a launch as "not run" when its daemons are not the build under test (lead 2026-11-01).

The cmux-tui and acpmux daemons outlive the app. A fleet step runs a fresh copy of the app at a new path, and
bench-startup stopped only the processes of THAT path (tag_pids), so a daemon of the same tag left by an earlier step,
copy or commit kept running, and the new app attached to it. Such a round measures the old daemon. These tests need no
app: daemon_verdict() is pure, and the stop test uses `sleep` copies in two fake bundles.
Run: python3 -I scripts/cmux-next/tests/test_bench_startup_daemon_build.py"""
import importlib.util, os, shutil, subprocess, sys, tempfile, time, unittest

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
