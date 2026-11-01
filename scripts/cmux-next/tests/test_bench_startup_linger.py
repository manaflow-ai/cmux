#!/usr/bin/env python3
"""bench-startup.py's linger probe: after the app's quit it reports every process of the bundle with its exit time,
names the ones alive past LINGER_LIMIT_S, and ends none of them. It also watches the helpers under
`Contents/Resources/bin/` (acpmux, cmux-browser-host): an idle acpmux outlived every quit while the probe, which read
only `Contents/MacOS/`, reported none (PR #30090). Fake bundle processes (`sleep` copied into a bundle path, or run
with that path as its argv[0]), no app. Run: python3 -I scripts/cmux-next/tests/test_bench_startup_linger.py"""
import importlib.util, io, os, shutil, subprocess, sys, tempfile, time, unittest
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("bench_startup", os.path.join(HERE, "..", "bench-startup.py"))
bench_startup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench_startup)


class Linger(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="linger-")
        self.tag = "lingertest"
        app = os.path.join(self.root, f"cmux DEV {self.tag}.app")
        helper = os.path.join(app, "Contents/Frameworks/cmux DEV Helper (Renderer).app/Contents/MacOS")
        os.makedirs(helper)
        self.helper = os.path.join(helper, "cmux DEV Helper (Renderer)")
        shutil.copy(shutil.which("sleep"), self.helper)
        self.bin = os.path.join(app, "Contents/Resources/bin")
        os.makedirs(self.bin)
        bench_startup.APPS[self.tag] = app
        self.procs = []

    def tearDown(self):
        for p in self.procs:
            if p.poll() is None:
                p.kill()  # this test's own child
                p.wait()
        bench_startup.APPS.pop(self.tag, None)
        shutil.rmtree(self.root, ignore_errors=True)

    def start(self, seconds):
        p = subprocess.Popen([self.helper, str(seconds)])
        self.procs.append(p)
        return p

    def start_helper(self, name, seconds, *flags):
        """A fake helper whose command line is `<bundle>/Contents/Resources/bin/<name> [flags] <seconds>` (bash's
        `exec -a` names the sleep's argv[0]; ps and pgrep read argv)."""
        argv0 = " ".join([os.path.join(self.bin, name), *flags])
        p = subprocess.Popen(["bash", "-c", 'exec -a "$0" sleep "$1"', argv0, str(seconds)])
        self.procs.append(p)
        return p

    def watch(self):
        out = io.StringIO()
        with redirect_stdout(out):
            report = bench_startup.watch_linger(self.tag, time.monotonic())
        return report, out.getvalue()

    def test_a_short_lived_helper_is_reported_with_its_exit_time(self):
        p = self.start(3)  # under LINGER_LIMIT_S; long enough that a loaded host (pgrep ~0.7 s) sees it at the quit
        report, text = self.watch()
        self.assertIn(p.pid, [r["pid"] for r in report["at_quit"]])
        self.assertLess(report["exit_s"][p.pid], bench_startup.LINGER_LIMIT_S)
        self.assertEqual(report["past_limit"], [])
        self.assertEqual(report["still"], [])
        self.assertIn("BENCH-LINGER ", text)

    def test_a_helper_alive_past_the_limit_is_named_and_left_running(self):
        saved = bench_startup.LINGER_LIMIT_S, bench_startup.LINGER_WAIT_S
        bench_startup.LINGER_LIMIT_S, bench_startup.LINGER_WAIT_S = 0.3, 1.0
        try:
            p = self.start(30)
            report, text = self.watch()
        finally:
            bench_startup.LINGER_LIMIT_S, bench_startup.LINGER_WAIT_S = saved
        self.assertEqual([r["pid"] for r in report["still"]], [p.pid])
        self.assertEqual(report["still_running_after_s"], 1.0)
        self.assertIn(f"LINGER: {p.pid}", text)
        self.assertIsNone(p.poll(), "the probe must never end a process itself")

    def test_the_bench_clock_times_each_mark_from_the_spawn(self):
        # A fake app: it sleeps 0.5 s before it writes main_start, so the bench's own clock must see the gap whatever
        # value (ms since p_starttime) the line carries.
        fake = os.path.join(self.root, "fake-app.py")
        with open(fake, "w") as f:
            f.write("import os, sys, time\nfd = int(os.environ['CMUX_NEXT_LAUNCH_MARKS_FD'])\ntime.sleep(0.5)\n"
                    "os.write(fd, b'main_start 9999\\nfirst_terminal_frame 10100\\n')\ntime.sleep(5)\n")
        saved = bench_startup.app_binary
        bench_startup.app_binary = lambda tag: sys.executable
        try:
            launch = bench_startup.Launch.__new__(bench_startup.Launch)
            read_fd, write_fd = os.pipe()
            launch.spawned_at = time.monotonic()
            launch.process = subprocess.Popen([sys.executable, fake], env={"CMUX_NEXT_LAUNCH_MARKS_FD": str(write_fd)},
                                              pass_fds=(write_fd,))
            launch.popen_returned_at = time.monotonic()
            self.procs.append(launch.process)
            os.close(write_fd)
            launch.read_fd, launch.buffer, launch.marks, launch.arrived = read_fd, b"", {}, {}
            launch.wait_for(["first_terminal_frame"], 10, any_of=True)
        finally:
            bench_startup.app_binary = saved
            os.close(read_fd)
        self.assertEqual(launch.marks["main_start"], 9999.0)  # the app's own value, kept
        self.assertGreaterEqual(launch.arrived["main_start"], 450)  # the bench saw the 0.5 s itself
        self.assertLess(launch.arrived["main_start"], 5000)

    def test_an_idle_acpmux_under_resources_bin_alive_past_the_limit_is_named(self):
        saved = bench_startup.LINGER_LIMIT_S, bench_startup.LINGER_WAIT_S
        bench_startup.LINGER_LIMIT_S, bench_startup.LINGER_WAIT_S = 0.3, 1.0
        try:
            p = self.start_helper("acpmux", 30, "daemon", "run", "--ready-fd", "3")
            time.sleep(0.2)  # bash has exec'd the sleep
            report, text = self.watch()
        finally:
            bench_startup.LINGER_LIMIT_S, bench_startup.LINGER_WAIT_S = saved
        self.assertEqual([r["pid"] for r in report["still"]], [p.pid])
        self.assertIn(f"LINGER: {p.pid}", text)
        self.assertIsNone(p.poll(), "the probe must never end a process itself")

    def test_a_short_lived_browser_host_is_reported_with_its_exit_time(self):
        p = self.start_helper("cmux-browser-host", 3, "serve", "--supervised")
        time.sleep(0.2)
        report, _ = self.watch()
        self.assertIn(p.pid, [r["pid"] for r in report["at_quit"]])
        self.assertLess(report["exit_s"][p.pid], bench_startup.LINGER_LIMIT_S)
        self.assertEqual(report["still"], [])

    def test_the_kept_cmux_tui_daemon_is_listed_as_kept_and_not_waited_for(self):
        # plans/cmux-next/quit-persistence.md: a quit that keeps sessions keeps the cmux-tui daemon (its terminals).
        saved = bench_startup.LINGER_LIMIT_S, bench_startup.LINGER_WAIT_S
        bench_startup.LINGER_LIMIT_S, bench_startup.LINGER_WAIT_S = 0.3, 5.0
        try:
            p = self.start_helper("cmux-tui", 30, "--headless", "--session", "cmux-app-lingertest")  # local_owner.rs order
            time.sleep(0.2)
            started = time.monotonic()
            report, _ = self.watch()
            took = time.monotonic() - started
        finally:
            bench_startup.LINGER_LIMIT_S, bench_startup.LINGER_WAIT_S = saved
        self.assertEqual([r["pid"] for r in report["kept"]], [p.pid])
        self.assertEqual(report["still"], [])
        self.assertEqual(report["past_limit"], [])
        self.assertLess(took, 4.0, "the probe waited for a documented survivor")
        self.assertIsNone(p.poll())

    def test_an_ssh_or_cloud_link_is_not_kept(self):
        # `cmux-tui remote connect ... --headless --exit-with-parent` ends with the app: it is watched, not kept.
        saved = bench_startup.LINGER_LIMIT_S, bench_startup.LINGER_WAIT_S
        bench_startup.LINGER_LIMIT_S, bench_startup.LINGER_WAIT_S = 0.3, 1.0
        try:
            p = self.start_helper("cmux-tui", 30, "remote", "connect", "host", "--headless", "--exit-with-parent")
            time.sleep(0.2)
            report, _ = self.watch()
        finally:
            bench_startup.LINGER_LIMIT_S, bench_startup.LINGER_WAIT_S = saved
        self.assertEqual(report["kept"], [])
        self.assertEqual([r["pid"] for r in report["still"]], [p.pid])

    def test_the_survivor_rules(self):
        app = os.path.join(self.root, f"cmux DEV {self.tag}.app/Contents/Resources/bin")
        row = lambda pid, ppid, words: {"pid": pid, "ppid": ppid, "command": f"{app}/{words}"}
        tui = row(10, 1, "cmux-tui --headless --session s")
        chief = row(20, 1, "optchat-chief host --daemon-socket x")
        chief_acpmux = row(21, 20, "acpmux daemon run")
        role = bench_startup.kept_role
        self.assertTrue(role(tui, None, None))
        self.assertTrue(role(row(11, 10, "cmux-agent-screen-detection"), tui, None))
        self.assertIsNone(role(row(12, 1, "cmux-agent-screen-detection"), None, None), "a plugin with no kept daemon")
        self.assertTrue(role(chief, None, None))
        self.assertIsNone(role(row(22, 1, "optchat-chief usage"), None, None), "a one-shot Chief command")
        self.assertTrue(role(chief_acpmux, chief, None))
        self.assertTrue(role(row(23, 21, "acpmux router"), chief_acpmux, chief))
        self.assertIsNone(role(row(30, 1, "acpmux daemon run --ready-fd 3"), None, None), "the app's own acpmux")
        self.assertIsNone(role(row(31, 10, "cmux-browser-host serve --supervised"), tui, None), "the browser host")

    def test_no_process_is_an_empty_report(self):
        report, _ = self.watch()
        self.assertEqual((report["at_quit"], report["still"], report["past_limit"]), ([], [], []))


if __name__ == "__main__":
    unittest.main()
