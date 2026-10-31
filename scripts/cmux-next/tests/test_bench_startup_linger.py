#!/usr/bin/env python3
"""bench-startup.py's linger probe: after the app's quit it reports every process of the bundle with its exit time,
names the ones alive past LINGER_LIMIT_S, and ends none of them. Fake bundle processes (`sleep` copied into a
`<bundle>/Contents/MacOS/` path), no app. Run: python3 -I scripts/cmux-next/tests/test_bench_startup_linger.py"""
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

    def watch(self):
        out = io.StringIO()
        with redirect_stdout(out):
            report = bench_startup.watch_linger(self.tag, time.monotonic())
        return report, out.getvalue()

    def test_a_short_lived_helper_is_reported_with_its_exit_time(self):
        p = self.start(0.6)
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

    def test_no_process_is_an_empty_report(self):
        report, _ = self.watch()
        self.assertEqual((report["at_quit"], report["still"], report["past_limit"]), ([], [], []))


if __name__ == "__main__":
    unittest.main()
