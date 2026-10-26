#!/usr/bin/env python3
"""Regression tests for scripts/measure/blocking-probe-report.py and the blocking probe's selection rules.

The report splits the probe's dumps into app_main, app_chromium, daemon_request and daemon_input_wait, and checks
the harness's preflight dumps; the probe's thread patterns and argument gate (blocking-probe/probe_match.h) are
compiled with the host's C compiler and run on the daemon's real thread names and argv. The probe itself
(dyld interposing) runs only in the fleet preflight of scripts/measure/blocking-probe.sh. No app, no build, no
atos needed (the frames stay unresolved off macOS). Run: python3 -I tests/test_blocking_probe_report.py
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPORT = os.path.join(ROOT, "scripts/measure/blocking-probe-report.py")
HARNESS = os.path.join(ROOT, "scripts/measure/blocking-probe.sh")
MATCH_H = os.path.join(ROOT, "scripts/measure/blocking-probe/probe_match.h")

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
    "#final\t0", "#threads\tmux-conn,surface-*-host", "#process\tcmux-tui", "#calls\t5", "#record_ns\t500",
    "selftest\tprobe\t3\t300\t100\tlibsystem_kernel.dylib|0x1|open;",
    "file-io:open\tmux-conn\t4\t8000000\t4000000\tlibsystem_kernel.dylib|0x30|open;"
    "cmux-tui|0x1000|_ZN3std2fs4File4open17h0123456789abcdefE;"
    "cmux-tui|0x2000|_ZN13cmux_tui_core6server6listen5serve17h0123456789abcdefE;",
    "file-io:fsync\tsurface-*-host\t1\t1500000\t1500000\tlibsystem_kernel.dylib|0x40|fsync;"
    "cmux-tui|0x3000|_ZN13cmux_tui_core7surface4sync17h0123456789abcdefE;",
    # A whole shell lifetime and an idle socket: far longer than any blocking work, never ranked with it.
    "input-wait:waitpid\tsurface-*-host\t1\t90000000000\t90000000000\tlibsystem_kernel.dylib|0x50|wait4;"
    "cmux-tui|0x4000|_ZN13cmux_tui_core7surface5spawn4wait17h0123456789abcdefE;",
    "input-wait:recv\tmux-conn\t9\t60000000000\t30000000000\tlibsystem_kernel.dylib|0x60|recvfrom;"
    "cmux-tui|0x2000|_ZN13cmux_tui_core6server6listen5serve17h0123456789abcdefE;",
]) + "\n"
# A dump from the probe before the thread column: five fields, the main thread.
LEGACY_DUMP = "#final\t1\nio:read\t1\t1000000\t1000000\tcmux DEV.debug.dylib|0x300|$s13CmuxNextStore4readyyF;\n"
# cmux's CEF shim makes its own stat under Chromium's frame: the site is cmux's (app_main), not Chromium's.
SHIM_DUMP = "\n".join([
    "#final\t1", "#threads\tmain",
    "file-io:stat\tmain\t1\t1200000\t1200000\tlibsystem_kernel.dylib|0x70|stat;"
    "libcmux_cef_shim.dylib|0x900|cmux_page_scheme_resolve;"
    "Chromium Embedded Framework|0x6000|cef_resource_handler;"
    "cmux DEV.debug.dylib|0x200|$s15CmuxNextBrowser4pumpyyF;",
]) + "\n"
# Two cmux callers reach one Chromium frame: the caller with more time is "via", whichever entry comes last.
VIA_DUMP = "\n".join([
    "#final\t1", "#threads\tmain",
    "sync-wait:pthread_cond_wait\tmain\t5\t10000000\t2000000\tlibsystem_pthread.dylib|0x1|cond_wait;"
    "Chromium Embedded Framework|0x7000|cef_run_loop;cmux DEV.debug.dylib|0x400|$s15CmuxNextBrowser5heavyyyF;",
    "sync-wait:pthread_cond_wait\tmain\t1\t3000000\t3000000\tlibsystem_pthread.dylib|0x2|cond_wait;"
    "Chromium Embedded Framework|0x7000|cef_run_loop;cmux DEV.debug.dylib|0x500|$s15CmuxNextBrowser5lightyyF;",
]) + "\n"


def write_dumps(work, dumps):
    paths = []
    for index, text in enumerate(dumps):
        path = os.path.join(work, f"probe-run-{100 + index}.tsv")
        with open(path, "w") as f:
            f.write(text)
        paths.append(path)
    return paths


def report_cli(*args):
    return subprocess.run([sys.executable, "-I", REPORT, *args], capture_output=True, text=True)


class ReportSections(unittest.TestCase):
    def run_report(self, dumps):
        work = tempfile.mkdtemp(prefix="blocking-probe-report-")
        self.addCleanup(shutil.rmtree, work, True)
        app = os.path.join(work, "cmux DEV.app")
        for relative in ("Contents/MacOS/cmux DEV", "Contents/MacOS/cmux DEV.debug.dylib",
                         "Contents/Resources/bin/cmux-tui", "Contents/Frameworks/libcmux_cef_shim.dylib",
                         "Contents/Frameworks/Chromium Embedded Framework.framework/Versions/A/"
                         "Chromium Embedded Framework"):
            path = os.path.join(app, relative)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            open(path, "w").close()
        out = os.path.join(work, "out")
        run = report_cli("--app", app, "--launches", "1", "--out", out, *write_dumps(work, dumps))
        self.assertEqual(run.returncode, 0, run.stderr)
        with open(os.path.join(out, "blocking-probe.json")) as f:
            report = json.load(f)
        with open(os.path.join(out, "blocking-probe.md")) as f:
            markdown = f.read()
        return report, markdown

    def test_four_sections_split_app_chromium_and_daemon(self):
        report, markdown = self.run_report([APP_DUMP, DAEMON_DUMP])
        sections = report["sections"]
        self.assertEqual(set(sections), {"app_main", "app_chromium", "daemon_request", "daemon_input_wait"})
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
        self.assertEqual(listen["kinds"], {"file-io:open": 4})  # the idle recv at the same site is not added
        self.assertEqual(sections["daemon_request"][0]["symbol"], listen["symbol"])  # worst first

        summary = report["summary"]
        self.assertEqual(summary["dumps"], {"final": 1, "periodic only": 1, "daemon": 1})
        self.assertEqual(summary["bad_lines"], 1)
        self.assertEqual(summary["calls_timed"], 15)
        self.assertEqual(summary["sections"]["daemon_request"]["by_thread"], {"mux-conn": 4, "surface-*-host": 1})
        self.assertNotIn("selftest", json.dumps(sections))

    def test_input_waits_never_rank_with_blocking_work(self):
        report, _ = self.run_report([DAEMON_DUMP])
        sections = report["sections"]
        request_kinds = {kind for site in sections["daemon_request"] for kind in site["kinds"]}
        self.assertEqual(request_kinds, {"file-io:open", "file-io:fsync"})
        self.assertEqual(sections["daemon_request"][0]["total_ms"], 8.0)  # not the 90 s waitpid
        waits = sections["daemon_input_wait"]
        self.assertEqual([site["kinds"] for site in waits],
                         [{"input-wait:waitpid": 1}, {"input-wait:recv": 9}])  # apart, worst first

    def test_cef_shim_frame_is_cmux_code(self):
        report, _ = self.run_report([SHIM_DUMP])
        (site,) = report["sections"]["app_main"]
        self.assertEqual(site["symbol"], "cmux_page_scheme_resolve")
        self.assertEqual(report["sections"]["app_chromium"], [])

    def test_via_is_the_caller_with_the_most_time(self):
        report, _ = self.run_report([VIA_DUMP])
        (site,) = report["sections"]["app_chromium"]
        self.assertIn("heavy", site["via"])
        self.assertEqual(site["max_ms"], 3.0)

    def test_empty_sections_still_present_and_legacy_rows_read(self):
        report, markdown = self.run_report([LEGACY_DUMP])
        self.assertEqual(report["sections"]["app_chromium"], [])
        self.assertEqual(report["sections"]["daemon_request"], [])
        self.assertEqual(report["sections"]["app_main"][0]["threads"], {"main": 1})
        self.assertEqual(markdown.count("None recorded."), 3)


# The probe's launch window dumps (<dump>.window, CMUX_BLOCKING_PROBE_UNTIL_MARK): each app launch's main-thread
# entries copied when the app sent the mark. Launch 100 and 101 sent startup_complete; 102 sent only another mark.
def window_dump(mark, ms, rows):
    return "\n".join([f"#window\t{mark}", f"#window_ms\t{ms}", "#threads\tmain", "#process\tcmux DEV", *rows]) + "\n"


LAUNCH_OPEN = ("file-io:open\tmain\t1\t3000000\t3000000\tlibsystem_kernel.dylib|0x10|open;"
               "cmux DEV.debug.dylib|0x100|$s13CmuxNextStore4loadyyF;cmux DEV.debug.dylib|0x180|$s13CmuxNextStore4mainyyF;")
LAUNCH_CHROMIUM = ("sync-wait:dispatch_semaphore_wait\tmain\t1\t2000000\t2000000\tlibdispatch.dylib|0x20|wait;"
                   "Chromium Embedded Framework|0x5000|cef_do_message_loop_work;"
                   "cmux DEV.debug.dylib|0x200|$s15CmuxNextBrowser4pumpyyF;")
LAUNCH_SELFTEST = "selftest\tmain\t3\t300\t100\tlibsystem_kernel.dylib|0x1|open;"


class LaunchWindow(unittest.TestCase):
    def run_report(self, dumps, windows, *extra, code=0):
        """dumps: texts named probe-run-<100 + i>.tsv; windows: {index: text} written as that dump's .window."""
        work = tempfile.mkdtemp(prefix="blocking-probe-window-")
        self.addCleanup(shutil.rmtree, work, True)
        app = os.path.join(work, "cmux DEV.app")
        for relative in ("Contents/MacOS/cmux DEV", "Contents/MacOS/cmux DEV.debug.dylib",
                         "Contents/Resources/bin/cmux-tui"):
            path = os.path.join(app, relative)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            open(path, "w").close()
        paths = write_dumps(work, dumps)
        for index, text in windows.items():
            with open(paths[index] + ".window", "w") as f:
                f.write(text)
            paths.append(paths[index] + ".window")
        out = os.path.join(work, "out")
        run = report_cli("--app", app, "--launches", str(len(dumps)), *extra, "--out", out, *paths)
        self.assertEqual(run.returncode, code, run.stderr)
        with open(os.path.join(out, "blocking-probe.json")) as f:
            report = json.load(f)
        with open(os.path.join(out, "blocking-probe.md")) as f:
            markdown = f.read()
        return report, markdown, run

    def test_launch_section_lists_main_thread_calls_before_the_mark(self):
        windows = {0: window_dump("startup_complete", 900, [LAUNCH_SELFTEST, LAUNCH_OPEN, LAUNCH_CHROMIUM]),
                   1: window_dump("startup_complete", 1100, [LAUNCH_OPEN]),
                   2: window_dump("first_window_frame_committed", 300, [LAUNCH_OPEN])}
        report, markdown, _ = self.run_report([APP_DUMP, APP_DUMP, APP_DUMP, DAEMON_DUMP], windows,
                                              "--until-mark", "startup_complete")
        sections = report["sections"]
        self.assertEqual(list(sections)[0], "launch")
        self.assertIn("## launch: App main thread before the startup_complete mark", markdown)
        self.assertLess(markdown.index("## launch:"), markdown.index("## app_main:"))
        cmux, chromium = sections["launch"]  # worst first
        self.assertEqual((cmux["by"], cmux["module"], cmux["launches"], cmux["count"], cmux["total_ms"]),
                         ("cmux", "CmuxNextStore", 2, 2, 6.0))
        self.assertEqual((chromium["by"], chromium["launches"]), ("chromium", 1))
        self.assertIn("Chromium Embedded Framework+0x5000", chromium["site"])
        self.assertIn("CmuxNextBrowser", chromium["via"])
        self.assertNotIn("selftest", json.dumps(sections["launch"]))
        launch = report["summary"]["launch"]
        self.assertEqual((launch["windows"], launch["app_dumps"]), (2, 3))
        self.assertEqual(launch["missing"], ["probe-run-102.tsv"])  # its app never sent startup_complete
        self.assertEqual(launch["other_marks"], ["probe-run-102.tsv.window"])
        self.assertEqual(launch["mark_ms"], {"p50": 1100, "max": 1100})
        self.assertIn("Missing (the app never sent the mark", markdown)
        # The whole-run sections still read the process dumps only, as without --until-mark.
        self.assertEqual(report["summary"]["dumps"], {"final": 3, "periodic only": 1, "daemon": 1})
        self.assertEqual(sections["app_main"][0]["count"], 6)

    def test_without_until_mark_the_report_is_unchanged(self):
        windows = {0: window_dump("startup_complete", 900, [LAUNCH_OPEN])}
        with_windows, markdown, _ = self.run_report([APP_DUMP, DAEMON_DUMP], windows)
        plain, plain_markdown, _ = self.run_report([APP_DUMP, DAEMON_DUMP], {})
        self.assertEqual(with_windows, plain)
        self.assertEqual(markdown, plain_markdown)
        self.assertEqual(set(plain["sections"]), {"app_main", "app_chromium", "daemon_request", "daemon_input_wait"})
        self.assertNotIn("launch", plain["summary"])

    def test_no_window_for_the_mark_fails_and_says_so(self):
        _, markdown, run = self.run_report([APP_DUMP], {}, "--until-mark", "startup_complete", code=1)
        self.assertIn("no launch window ends at startup_complete", run.stderr)
        self.assertIn("0 launch windows of 1 app dumps", markdown)

    def test_select_never_picks_a_window(self):
        work = tempfile.mkdtemp(prefix="blocking-probe-window-select-")
        self.addCleanup(shutil.rmtree, work, True)
        (app,) = write_dumps(work, [APP_DUMP])
        with open(app + ".window", "w") as f:
            f.write(window_dump("startup_complete", 900, [LAUNCH_OPEN]))
        self.assertEqual(report_cli("--select", "main", app, app + ".window").stdout.split(), [app])


# blocking-probe.sh's preflight program: the app, an inert hop (one wanted argument), the owner (both).
PREFLIGHT_APP = "#final\t1\n#threads\tmain\n#process\tpreflight\nselftest\tmain\t3\t300\t100\tlibc|0x1|open;\n"
PREFLIGHT_OWNER = ("#final\t1\n#threads\tprobe-test-*-host\n#process\tpreflight\n"
                   "selftest\tprobe\t3\t300\t100\tlibc|0x1|open;\n"
                   "file-io:stat\tprobe-test-*-host\t1\t500\t500\tlibc|0x2|stat;\n"
                   "input-wait:read\tprobe-test-*-host\t1\t500\t500\tlibc|0x3|read;\n")
# With a launch window: the app spawns its chain, sends preflight_mark, then checks access("/").
PREFLIGHT_APP_MARKED = (PREFLIGHT_APP + "process-spawn:posix_spawn\tmain\t1\t900\t900\tlibc|0x6|posix_spawn;\n"
                        "file-io:access\tmain\t1\t500\t500\tlibc|0x5|access;\n")
PREFLIGHT_WINDOW = window_dump("preflight_mark", 5, ["process-spawn:posix_spawn\tmain\t1\t900\t900\tlibc|0x6|posix_spawn;",
                                                     "process-wait:waitpid\tmain\t1\t900\t900\tlibc|0x7|wait4;"])


class Preflight(unittest.TestCase):
    def check(self, dumps):
        work = tempfile.mkdtemp(prefix="blocking-probe-preflight-")
        self.addCleanup(shutil.rmtree, work, True)
        return report_cli("--preflight", *write_dumps(work, dumps))

    def test_working_chain_passes(self):
        run = self.check([PREFLIGHT_APP, PREFLIGHT_OWNER])
        self.assertEqual(run.returncode, 0, run.stderr)

    def test_a_recording_hop_fails(self):
        hop = PREFLIGHT_OWNER.replace("#process\tpreflight", "#process\thop")
        self.assertIn("must stay inert", self.check([PREFLIGHT_APP, PREFLIGHT_OWNER, hop]).stderr)

    def test_an_unwatched_thread_recorded_fails(self):
        owner = PREFLIGHT_OWNER + "file-io:access\tprobe-test-*-host\t1\t500\t500\tlibc|0x4|access;\n"
        self.assertIn("probe-test-1-wait", self.check([PREFLIGHT_APP, owner]).stderr)

    def test_a_pipe_read_counted_as_blocking_fails(self):
        owner = PREFLIGHT_OWNER.replace("input-wait:read", "io:read")
        self.assertIn("input-wait:read", self.check([PREFLIGHT_APP, owner]).stderr)

    def check_window(self, window, app=None):
        work = tempfile.mkdtemp(prefix="blocking-probe-preflight-window-")
        self.addCleanup(shutil.rmtree, work, True)
        paths = write_dumps(work, [app or PREFLIGHT_APP_MARKED, PREFLIGHT_OWNER])
        if window is not None:
            with open(paths[0] + ".window", "w") as f:
                f.write(window)
            paths.append(paths[0] + ".window")
        return report_cli("--preflight", "--until-mark", "preflight_mark", *paths)

    def test_launch_window_chain_passes(self):
        run = self.check_window(PREFLIGHT_WINDOW)
        self.assertEqual(run.returncode, 0, run.stderr)

    def test_a_missing_launch_window_fails(self):
        self.assertIn("did not see the app's preflight_mark mark", self.check_window(None).stderr)

    def test_a_launch_window_with_calls_after_the_mark_fails(self):
        late = PREFLIGHT_WINDOW + "file-io:access\tmain\t1\t500\t500\tlibc|0x5|access;\n"
        self.assertIn("calls made after the mark", self.check_window(late).stderr)

    def test_a_launch_window_with_calls_on_the_probes_mark_descriptor_fails(self):
        # The preflight app makes LaunchMarkSink's fcntls and writes an earlier mark before the launch mark: on the
        # descriptor the probe opened, so they must not reach the window as if the app blocked on them.
        for row in ("io:write\tmain\t1\t400\t400\tlibsystem_kernel.dylib|0x8|write;preflight|0x40|send_marks;",
                    "file-io:fcntl\tmain\t3\t300\t100\tlibsystem_kernel.dylib|0x9|fcntl;preflight|0x40|send_marks;"):
            with self.subTest(row=row.split("\t")[0]):
                self.assertIn("calls on its own mark descriptor",
                              self.check_window(PREFLIGHT_WINDOW + row + "\n").stderr)

    def test_a_launch_window_without_the_spawn_fails(self):
        empty = window_dump("preflight_mark", 5, [])
        self.assertIn("lacks the app's spawn", self.check_window(empty).stderr)

    def test_an_app_dump_without_the_access_after_the_mark_fails(self):
        self.assertIn("lacks its access after the mark", self.check_window(PREFLIGHT_WINDOW, PREFLIGHT_APP).stderr)

    def test_a_window_without_until_mark_fails(self):
        work = tempfile.mkdtemp(prefix="blocking-probe-preflight-stray-")
        self.addCleanup(shutil.rmtree, work, True)
        app, owner = write_dumps(work, [PREFLIGHT_APP, PREFLIGHT_OWNER])
        with open(app + ".window", "w") as f:
            f.write(PREFLIGHT_WINDOW)
        self.assertIn("without a launch window asked for",
                      report_cli("--preflight", app, owner, app + ".window").stderr)

    def test_select_splits_app_and_daemon_dumps(self):
        work = tempfile.mkdtemp(prefix="blocking-probe-select-")
        self.addCleanup(shutil.rmtree, work, True)
        app, owner = write_dumps(work, [PREFLIGHT_APP, PREFLIGHT_OWNER])
        missing = os.path.join(work, "probe-run-*.tsv")  # an unmatched shell glob
        self.assertEqual(report_cli("--select", "daemon", app, owner, missing).stdout.split("\n")[0], owner)
        self.assertEqual(report_cli("--select", "main", app, owner, missing).stdout.split("\n")[0], app)


@unittest.skipUnless(shutil.which("cc"), "no C compiler on this host")
class ProbeSelection(unittest.TestCase):
    """probe_match.h, compiled on this host, on the daemon's real thread names and the app's real argv."""

    @classmethod
    def setUpClass(cls):
        cls.work = tempfile.mkdtemp(prefix="blocking-probe-match-")
        driver = os.path.join(cls.work, "driver.c")
        with open(driver, "w") as f:
            f.write('#include "probe_match.h"\n#include <stdlib.h>\n'
                    "int main(int argc, char **argv) {\n"
                    "    if (argc >= 4 && strcmp(argv[1], \"name\") == 0) return probe_name_matches(argv[2], argv[3]) ? 0 : 1;\n"
                    "    if (argc >= 3 && strcmp(argv[1], \"argv\") == 0)\n"
                    "        return probe_argv_holds_all(argc - 2, (const char *const *)argv + 2, argv[2]) ? 0 : 1;\n"
                    "    return 2;\n}\n")
        cls.binary = os.path.join(cls.work, "driver")
        subprocess.run(["cc", "-Wall", "-Wextra", "-Werror", "-I", os.path.dirname(MATCH_H), "-o", cls.binary,
                        driver], check=True)
        # The harness's own list, as bash evaluates it.
        with open(HARNESS) as f:
            lines = [line for line in f.read().splitlines() if line.startswith("daemon_threads")]
        cls.patterns = subprocess.run(["bash", "-c", "\n".join(lines) + '\nprintf %s "$daemon_threads"'],
                                      capture_output=True, text=True, check=True).stdout.split(",")

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.work, True)

    def watched(self, name):
        return any(subprocess.run([self.binary, "name", p, name]).returncode == 0 for p in self.patterns)

    def holds(self, wanted, argv):
        # argv[0] of the driver's view is `wanted` itself (skipped as the program name).
        return subprocess.run([self.binary, "argv", wanted, *argv]).returncode == 0

    def test_patterns_watch_request_and_echo_threads_only(self):
        for name in ("mux-conn", "mux-ws-conn", "mux-control-dispatch", "mux-line-out", "mux-pty-input",
                     "mux-attach-out", "mux-render-attach-out", "mux-snapshot-attach-out", "mux-terminal-work",
                     "surface-7-host", "surface-12-host-frames", "surface-3-reader"):
            self.assertTrue(self.watched(name), name)
        for name in ("surface-7-wait", "surface-attach-0", "mux-server", "mux-conn-extra", "mux-deadline-0",
                     "mux-events-out"):
            self.assertFalse(self.watched(name), name)

    def test_every_pattern_names_a_thread_the_daemon_spawns(self):
        # A renamed thread would leave a pattern that watches nothing: each one is a thread name in cmux-tui (a
        # `.name("...")`, or a `format!("...")` handed to a spawn helper such as HostFrames::spawn).
        names = subprocess.run(["git", "-C", ROOT, "grep", "-h", "-o", "-E", r'(name\(|format!\()"[^"]+"',
                                "--", "cmux-tui/crates"], capture_output=True, text=True).stdout
        spawned = {re.sub(r"\{[^}]*\}", "*", m) for m in re.findall(r'"([^"]+)"', names)}
        for pattern in self.patterns:
            self.assertIn(pattern, spawned)

    def test_only_the_app_session_owner_records(self):
        wanted = "--headless,cmux-app-blocking-probe"
        self.assertTrue(self.holds(wanted, ["--headless", "--session", "cmux-app-blocking-probe", "--socket", "s"]))
        # `server ensure` (the app's own client), the Chief conversation owner and a cloud link stay inert.
        self.assertFalse(self.holds(wanted, ["--session", "cmux-app-blocking-probe", "--json", "server", "ensure"]))
        self.assertFalse(self.holds(wanted, ["--headless", "--session", "cmux-chief-1a2b", "--socket", "s"]))
        self.assertFalse(self.holds(wanted, ["remote", "connect", "--headless", "--json", "--exit-with-parent"]))


class ProbeWiring(unittest.TestCase):
    def test_nothing_in_cmux_links_the_probe(self):
        # Only the probe's own measurement files (and plans) name its source or its dylib: no package, project,
        # build script or app source does.
        tracked = subprocess.run(["git", "-C", ROOT, "grep", "-l", "-e", "blocking-probe/probe", "-e",
                                  "blocking-probe.dylib", "--", ".", ":!plans", ":!scripts/measure/blocking-probe*",
                                  ":!tests/test_blocking_probe_report.py"],
                                 capture_output=True, text=True).stdout.split()
        self.assertEqual(tracked, [])


if __name__ == "__main__":
    unittest.main()
