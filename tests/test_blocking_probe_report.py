#!/usr/bin/env python3
"""Regression tests for scripts/measure/blocking-probe-report.py and the blocking probe's wiring.

The report splits the probe's dumps into app_main, app_chromium and daemon_request; the probe stays a
measurement tool that nothing in cmux links. No app, no build, no atos needed (the frames stay unresolved off
macOS). Run: python3 -I tests/test_blocking_probe_report.py
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPORT = os.path.join(ROOT, "scripts/measure/blocking-probe-report.py")
HARNESS = os.path.join(ROOT, "scripts/measure/blocking-probe.sh")
PROBE = os.path.join(ROOT, "scripts/measure/blocking-probe/probe.c")

APP_DUMP = "\n".join([
    "#final\t1", "#threads\tmain", "#process\tcmux DEV", "#uptime_ms\t5000", "#dropped\t0", "#calls\t10",
    "#record_ns\t1000",
    "selftest\tmain\t3\t300\t100\tlibsystem_kernel.dylib|0x1|open;",
    "file-io:open\tmain\t2\t5000000\t3000000\tlibsystem_kernel.dylib|0x10|open;"
    "cmux DEV.debug.dylib|0x100|$s13CmuxNextStore4loadyyF;cmux DEV.debug.dylib|0x180|$s13CmuxNextStore4mainyyF;",
    "sync-wait:dispatch_semaphore_wait\tmain\t1\t2000000\t2000000\tlibdispatch.dylib|0x20|dispatch_semaphore_wait;"
    "Chromium Embedded Framework|0x5000|cef_do_message_loop_work;"
    "cmux DEV.debug.dylib|0x200|$s15CmuxNextBrowser4pumpyyF;",
    "not a dump line",
]) + "\n"
DAEMON_DUMP = "\n".join([
    "#final\t0", "#threads\tmux-conn,surface-", "#process\tcmux-tui", "#calls\t5", "#record_ns\t500",
    "selftest\tprobe\t3\t300\t100\tlibsystem_kernel.dylib|0x1|open;",
    "socket-read:recv\tmux-conn\t4\t8000000\t4000000\tlibsystem_kernel.dylib|0x30|recv;"
    "cmux-tui|0x1000|_ZN3std2io4Read4read17h0123456789abcdefE;"
    "cmux-tui|0x2000|_ZN13cmux_tui_core6server6listen5serve17h0123456789abcdefE;",
    "file-io:fsync\tsurface-\t1\t1500000\t1500000\tlibsystem_kernel.dylib|0x40|fsync;"
    "cmux-tui|0x3000|_ZN13cmux_tui_core7surface4sync17h0123456789abcdefE;",
]) + "\n"
# A dump from the probe before the thread column: five fields, the main thread.
LEGACY_DUMP = "#final\t1\nio:read\t1\t1000000\t1000000\tcmux DEV.debug.dylib|0x300|$s13CmuxNextStore4readyyF;\n"


class ReportSections(unittest.TestCase):
    def run_report(self, dumps):
        work = tempfile.mkdtemp(prefix="blocking-probe-report-")
        app = os.path.join(work, "cmux DEV.app")
        for relative in ("Contents/MacOS/cmux DEV", "Contents/MacOS/cmux DEV.debug.dylib",
                         "Contents/Resources/bin/cmux-tui",
                         "Contents/Frameworks/Chromium Embedded Framework.framework/Versions/A/"
                         "Chromium Embedded Framework"):
            path = os.path.join(app, relative)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            open(path, "w").close()
        paths = []
        for index, text in enumerate(dumps):
            path = os.path.join(work, f"probe-{100 + index}.tsv")
            with open(path, "w") as f:
                f.write(text)
            paths.append(path)
        out = os.path.join(work, "out")
        run = subprocess.run([sys.executable, "-I", REPORT, "--app", app, "--launches", "1", "--out", out, *paths],
                             capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        with open(os.path.join(out, "blocking-probe.json")) as f:
            report = json.load(f)
        with open(os.path.join(out, "blocking-probe.md")) as f:
            markdown = f.read()
        return report, markdown

    def test_three_sections_split_app_chromium_and_daemon(self):
        report, markdown = self.run_report([APP_DUMP, DAEMON_DUMP])
        sections = report["sections"]
        self.assertEqual(set(sections), {"app_main", "app_chromium", "daemon_request"})
        for name in sections:
            self.assertIn(f"## {name}:", markdown)

        (main_site,) = sections["app_main"]
        self.assertEqual(main_site["module"], "CmuxNextStore")
        self.assertEqual(main_site["total_ms"], 5.0)
        self.assertEqual(main_site["threads"], {"main": 2})

        (chromium_site,) = sections["app_chromium"]
        self.assertIn("Chromium Embedded Framework+0x5000", chromium_site["site"])
        self.assertIn("CmuxNextBrowser", chromium_site["via"])
        self.assertEqual(chromium_site["kinds"], {"sync-wait:dispatch_semaphore_wait": 1})

        daemon = {site["symbol"]: site for site in sections["daemon_request"]}
        self.assertEqual(len(daemon), 2)
        listen = daemon["_ZN13cmux_tui_core6server6listen5serve17h0123456789abcdefE"]  # past Rust std's frame
        self.assertEqual(listen["module"], "cmux_tui_core")
        self.assertNotEqual(listen["owner"], "unowned")
        self.assertEqual(listen["threads"], {"mux-conn": 4})
        self.assertEqual(sections["daemon_request"][0]["symbol"], listen["symbol"])  # worst first

        summary = report["summary"]
        self.assertEqual(summary["dumps"], {"final": 1, "periodic only": 1, "daemon": 1})
        self.assertEqual(summary["bad_lines"], 1)
        self.assertEqual(summary["calls_timed"], 15)
        self.assertEqual(summary["sections"]["daemon_request"]["by_thread"], {"mux-conn": 4, "surface-": 1})
        self.assertNotIn("selftest", json.dumps(sections))

    def test_empty_sections_still_present_and_legacy_rows_read(self):
        report, markdown = self.run_report([LEGACY_DUMP])
        self.assertEqual(report["sections"]["app_chromium"], [])
        self.assertEqual(report["sections"]["daemon_request"], [])
        self.assertEqual(report["sections"]["app_main"][0]["threads"], {"main": 1})
        self.assertEqual(markdown.count("None recorded."), 2)


class ProbeWiring(unittest.TestCase):
    def test_nothing_in_cmux_links_the_probe(self):
        # Only the probe's own measurement files (and plans) name its source or its dylib: no package, project,
        # build script or app source does.
        tracked = subprocess.run(["git", "-C", ROOT, "grep", "-l", "-e", "blocking-probe/probe.c",
                                  "-e", "blocking-probe.dylib", "--", ".", ":!plans",
                                  ":!scripts/measure/blocking-probe*", ":!tests/test_blocking_probe_report.py"],
                                 capture_output=True, text=True).stdout.split()
        self.assertEqual(tracked, [])

    def test_harness_carries_the_daemon_thread_filter(self):
        harness = open(HARNESS).read()
        probe = open(PROBE).read()
        self.assertIn('daemon_threads="mux-conn,mux-control-dispatch,mux-line-out,mux-pty-input,mux-attach-out,'
                      'surface-"', harness)
        self.assertIn('CMUX_BLOCKING_PROBE_CHILD=cmux-tui:--headless:$daemon_threads', harness)
        for name in ("CMUX_PROBE_THREADS", "CMUX_BLOCKING_PROBE_CHILD", "CMUX_BLOCKING_PROBE_ARG",
                     "CMUX_BLOCKING_PROBE_OUT"):
            self.assertIn(f'getenv("{name}")', probe)
        self.assertEqual(subprocess.run(["bash", "-n", HARNESS]).returncode, 0)


if __name__ == "__main__":
    unittest.main()
