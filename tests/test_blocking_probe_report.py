#!/usr/bin/env python3
"""Regression tests for scripts/measure/blocking-probe-report.py and the blocking probe's selection rules.

The report splits the probe's dumps into app_main, app_chromium, daemon_request and daemon_input_wait, and checks
the harness's preflight dumps; the probe's thread patterns and argument gate (blocking-probe/probe_match.h) are
compiled with the host's C compiler and run on the daemon's real thread names and argv. The probe itself
(dyld interposing) runs only in the fleet preflight of scripts/measure/blocking-probe.sh. No app, no build, no
atos needed (the frames stay unresolved off macOS). Run: python3 -I tests/test_blocking_probe_report.py
"""
import importlib.util
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

# The cross-process and loader kinds (probe.c) on the app's main thread: a keychain read and
# add, an XPC reply then a fork from one site, a plugin's dlopen, getpwuid_r and a nested run loop's mach receive.
CROSS_PROCESS_DUMP = "\n".join([
    "#final\t1", "#threads\tmain", "#process\tcmux DEV",
    "system-call:SecItemCopyMatching\tmain\t2\t6000000\t4000000\tSecurity|0x10|SecItemCopyMatching;"
    "cmux DEV.debug.dylib|0x700|$s13CmuxNextStore7keychainyyF;",
    "system-call:SecItemAdd\tmain\t1\t3000000\t3000000\tSecurity|0x20|SecItemAdd;"
    "cmux DEV.debug.dylib|0x700|$s13CmuxNextStore7keychainyyF;",
    "xpc-reply:xpc_connection_send_message_with_reply_sync\tmain\t1\t25000000\t25000000\tlibxpc.dylib|0x30|"
    "xpc_connection_send_message_with_reply_sync;cmux DEV.debug.dylib|0x800|$s14CmuxNextLaunch5agentyyF;",
    "process-spawn:fork\tmain\t1\t2000000\t2000000\tlibsystem_c.dylib|0x40|fork;"
    "cmux DEV.debug.dylib|0x800|$s14CmuxNextLaunch5agentyyF;",
    "library-load:dlopen\tmain\t1\t1500000\t1500000\tlibdyld.dylib|0x50|dlopen;"
    "cmux DEV.debug.dylib|0x900|$s14CmuxNextLaunch6pluginyyF;",
    "system-query:getpwuid_r\tmain\t1\t800000\t800000\tlibsystem_info.dylib|0x60|getpwuid_r;"
    "cmux DEV.debug.dylib|0x900|$s14CmuxNextLaunch6pluginyyF;",
    "mach-receive:mach_msg2\tmain\t1\t1200000\t1200000\tlibsystem_kernel.dylib|0x70|mach_msg2_internal;"
    "CoreFoundation|0x80|__CFRunLoopServiceMachPort;cmux DEV.debug.dylib|0x900|$s14CmuxNextLaunch6pluginyyF;",
]) + "\n"
DAEMON_MACH_DUMP = "\n".join([
    "#final\t1", "#threads\tmux-conn", "#process\tcmux-tui",
    "input-wait:mach_msg2\tmux-conn\t4\t40000000000\t20000000000\tlibsystem_kernel.dylib|0x90|mach_msg2_internal;"
    "cmux-tui|0x5000|_ZN13cmux_tui_core6server6listen5serve17h0123456789abcdefE;",
    "mach-receive:mach_msg2\tmux-conn\t1\t3000000\t3000000\tlibsystem_kernel.dylib|0x90|mach_msg2_internal;"
    "cmux-tui|0x6000|_ZN13cmux_tui_core6notify4post17h0123456789abcdefE;",
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

    def test_cross_process_and_loader_kinds_rank_by_their_cmux_site(self):
        report, _ = self.run_report([CROSS_PROCESS_DUMP, DAEMON_MACH_DUMP])
        sections, summary = report["sections"], report["summary"]
        main = {site["symbol"]: site for site in sections["app_main"]}
        self.assertEqual(main["$s13CmuxNextStore7keychainyyF"]["kinds"],
                         {"system-call:SecItemCopyMatching": 2, "system-call:SecItemAdd": 1})
        self.assertEqual(main["$s13CmuxNextStore7keychainyyF"]["total_ms"], 9.0)
        self.assertEqual(main["$s14CmuxNextLaunch5agentyyF"]["kinds"],
                         {"xpc-reply:xpc_connection_send_message_with_reply_sync": 1, "process-spawn:fork": 1})
        self.assertEqual(main["$s14CmuxNextLaunch6pluginyyF"]["kinds"],
                         {"library-load:dlopen": 1, "system-query:getpwuid_r": 1, "mach-receive:mach_msg2": 1})
        self.assertEqual(sections["app_main"][0]["symbol"], "$s14CmuxNextLaunch5agentyyF")  # worst first
        self.assertEqual(summary["sections"]["app_main"]["by_kind"],
                         {"system-call": 3, "xpc-reply": 1, "process-spawn": 1, "library-load": 1, "system-query": 1,
                          "mach-receive": 1})
        # A daemon thread's receive that waits for its next message is an input wait; a send waiting for its reply
        # is request work.
        (wait,) = sections["daemon_input_wait"]
        self.assertEqual(wait["kinds"], {"input-wait:mach_msg2": 4})
        (request,) = sections["daemon_request"]
        self.assertEqual(request["kinds"], {"mach-receive:mach_msg2": 1})
        self.assertEqual(summary["sections"]["daemon_input_wait"]["by_kind"], {"input-wait": 4})

    def test_old_fields_are_unchanged(self):
        # by_kind is the only new summary field; every old field keeps its name and value. Rows gain only
        # cmux_frame and pairs (the filing's inputs).
        report, markdown = self.run_report([APP_DUMP, DAEMON_DUMP])
        self.assertEqual(set(report["summary"]), {"launches", "dumps", "bad_lines", "calls_timed", "dropped",
                                                  "probe_overhead_ms_estimate", "sections"})
        main = report["summary"]["sections"]["app_main"]
        self.assertEqual(set(main), {"sites", "blocked_ms", "by_owner", "by_module", "by_thread", "by_kind"})
        self.assertEqual((main["sites"], main["blocked_ms"], main["by_thread"]), (1, 5.0, {"main": 2}))
        self.assertEqual(main["by_kind"], {"file-io": 2})
        (site,) = report["sections"]["app_main"]
        self.assertEqual(set(site), {"site", "symbol", "module", "owner", "count", "total_ms", "max_ms", "kinds",
                                     "threads", "via", "stack", "cmux_frame", "pairs"})
        self.assertIn("| # | total ms | max ms | calls | kinds | threads | site | via | module | owner |", markdown)

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
# Its cross-process and loader calls (cross_process): one row of each kind, one mach receive.
PREFLIGHT_CROSS_PROCESS = "".join(f"{kind}\tmain\t1\t{ns}\t{ns}\tlibsystem_kernel.dylib|0x{offset:x}|call;\n"
                                  for offset, (kind, ns) in enumerate([
                                      ("mach-receive:mach_msg", 5100000),
                                      ("xpc-reply:xpc_connection_send_message_with_reply_sync", 900000),
                                      ("library-load:dlopen", 40000),
                                      ("system-query:getpwuid_r", 300000),
                                      ("process-spawn:fork", 700000)], 0x20))
PREFLIGHT_APP = ("#final\t1\n#threads\tmain\n#process\tpreflight\nselftest\tmain\t3\t300\t100\tlibc|0x1|open;\n"
                 + PREFLIGHT_CROSS_PROCESS)
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

    def test_each_missing_cross_process_kind_fails(self):
        for row in PREFLIGHT_CROSS_PROCESS.splitlines():
            kind = row.split("\t")[0]
            with self.subTest(kind=kind):
                app = PREFLIGHT_APP.replace(row + "\n", "")
                self.assertIn(f"lacks its main-thread {kind}", self.check([app, PREFLIGHT_OWNER]).stderr)

    def test_the_run_loops_idle_wait_recorded_as_a_mach_receive_fails(self):
        idle = "mach-receive:mach_msg2\tmain\t1\t480000000\t480000000\tlibsystem_kernel.dylib|0x40|mach_msg2;\n"
        run = self.check([PREFLIGHT_APP + idle, PREFLIGHT_OWNER])
        self.assertEqual(run.returncode, 1)
        self.assertIn("2 main-thread mach receives, want 1", run.stderr)

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
        for row in ("file-io:access\tmain\t1\t500\t500\tlibc|0x5|access;", PREFLIGHT_CROSS_PROCESS.splitlines()[1]):
            with self.subTest(row=row.split("\t")[0]):
                self.assertIn("calls made after the mark", self.check_window(PREFLIGHT_WINDOW + row + "\n").stderr)

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
                    "    if (argc >= 5 && strcmp(argv[1], \"mach\") == 0) {\n"
                    "        const char *kind = probe_mach_kind(strtoull(argv[2], NULL, 0), atoi(argv[3]), atoi(argv[4]),\n"
                    "                                           \"mach-receive\", \"input-wait\");\n"
                    "        printf(\"%s\", kind != NULL ? kind : \"none\");\n"
                    "        return 0;\n"
                    "    }\n"
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
        # `.name("...")`, a `format!("...")` handed to a spawn helper such as HostFrames::spawn, or the name a
        # spawn helper takes first: echo_thread::spawn, cmux_threads::spawn, spawn_connection_reader).
        names = subprocess.run(["git", "-C", ROOT, "grep", "-h", "-o", "-E", r'(name\(|format!\(|spawn\w*\()"[^"]+"',
                                "--", "cmux-tui/crates"], capture_output=True, text=True).stdout
        spawned = {re.sub(r"\{[^}]*\}", "*", m) for m in re.findall(r'"([^"]+)"', names)}
        for pattern in self.patterns:
            self.assertIn(pattern, spawned)

    def mach_kind(self, options, blocking_thread, idle):
        return subprocess.run([self.binary, "mach", hex(options), str(blocking_thread), str(idle)],
                              capture_output=True, text=True, check=True).stdout

    def test_mach_calls_count_only_receives_that_block(self):
        send, receive = 0x1, 0x2  # MACH_SEND_MSG, MACH_RCV_MSG (probe.c asserts they are the SDK's)
        timeout = 0x100  # MACH_RCV_TIMEOUT: other option bits change nothing
        # Main thread (or the probe's self-test thread): every receive blocks, but the run loop's idle wait.
        self.assertEqual(self.mach_kind(receive | timeout, 1, 0), "mach-receive")
        self.assertEqual(self.mach_kind(send | receive, 1, 0), "mach-receive")
        self.assertEqual(self.mach_kind(receive, 1, 1), "none")
        # A send only never waits for a reply.
        self.assertEqual(self.mach_kind(send, 1, 0), "none")
        self.assertEqual(self.mach_kind(send, 0, 0), "none")
        # A watched worker: a receive alone waits for its next message; a send and receive waits for its reply.
        self.assertEqual(self.mach_kind(receive, 0, 0), "input-wait")
        self.assertEqual(self.mach_kind(send | receive, 0, 0), "mach-receive")
        # mach_msg2's 64-bit options keep the same low bits.
        self.assertEqual(self.mach_kind((1 << 40) | receive, 0, 0), "input-wait")

    def test_only_the_app_session_owner_records(self):
        wanted = "--headless,cmux-app-blocking-probe"
        self.assertTrue(self.holds(wanted, ["--headless", "--session", "cmux-app-blocking-probe", "--socket", "s"]))
        # `server ensure` (the app's own client), the Chief conversation owner and a cloud link stay inert.
        self.assertFalse(self.holds(wanted, ["--session", "cmux-app-blocking-probe", "--json", "server", "ensure"]))
        self.assertFalse(self.holds(wanted, ["--headless", "--session", "cmux-chief-1a2b", "--socket", "s"]))
        self.assertFalse(self.holds(wanted, ["remote", "connect", "--headless", "--json", "--exit-with-parent"]))


class ProbeWiring(unittest.TestCase):
    def read(self, relative):
        with open(os.path.join(ROOT, relative)) as f:
            return f.read()

    def test_probe_interposes_the_cross_process_and_loader_calls(self):
        probe = self.read("scripts/measure/blocking-probe/probe.c")
        interposed = set(re.findall(r"^DYLD_INTERPOSE\(\w+, (\w+)\)", probe, re.M))
        self.assertLessEqual({"xpc_connection_send_message_with_reply_sync", "mach_msg", "probe_mach_msg2_internal",
                              "posix_spawn", "posix_spawnp", "fork", "dlopen", "getpwuid", "getpwuid_r",
                              "SecItemCopyMatching", "SecItemAdd"}, interposed)
        self.assertIn('__asm("_mach_msg2_internal")', probe)

    def test_xpc_reply_is_a_detector_kind_the_server_takes(self):
        # The probe's xpc-reply is BlockingKind.xpcReply's raw value, and the hang report server's closed set
        # (wireSchema3.ts BLOCKING_KINDS) holds every app kind, so a report naming it is not dropped.
        swift = self.read("Packages/macOS/CmuxNext/Sources/CmuxNextCompat/Threading/BlockingKind.swift")
        kinds = {raw or name for name, raw in re.findall(r'^    case (\w+)(?: = "([^"]+)")?$', swift, re.M)}
        self.assertIn("xpc-reply", kinds)
        server = self.read("web/services/hangReports/wireSchema3.ts")
        block = server.split("export const BLOCKING_KINDS", 1)[1].split("]);", 1)[0]
        self.assertEqual(set(re.findall(r'"([^"]+)"', block)), kinds)

    def test_nothing_in_cmux_links_the_probe(self):
        # Only the probe's own measurement files (and plans) name its source or its dylib: no package, project,
        # build script or app source does.
        tracked = subprocess.run(["git", "-C", ROOT, "grep", "-l", "-e", "blocking-probe/probe", "-e",
                                  "blocking-probe.dylib", "--", ".", ":!plans", ":!scripts/measure/blocking-probe*",
                                  ":!tests/test_blocking_probe_report.py"],
                                 capture_output=True, text=True).stdout.split()
        self.assertEqual(tracked, [])


def load_report_module():
    spec = importlib.util.spec_from_file_location("blocking_probe_report", REPORT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# The sweep's every-action.json as the filing reads it: host, macOS and sha, and the measured actions (repeats).
SWEEP_JSON = {"env": {"host": "cmux20", "macos": "27.0.1", "machine": "arm64", "sha": "0123456789ab"},
              "sessions": [{"name": "light", "rows": [{"commit_ms": {"n": 3}}, {"skipped": "destructive"}],
                            "interactions": [{"commit_ms": {"n": 2}}]},
                           {"name": "stress", "rows": [{"commit_ms": {"n": 3}}, {"errors": ["harness"]}]}]}
# A Debug run with no cmux wait near 1 ms: 40 calls of 5 us; Chromium's pump waits 2 ms in total.
QUIET_APP = "\n".join([
    "#final\t1", "#threads\tmain",
    "file-io:stat\tmain\t40\t200000\t5000\tlibsystem_kernel.dylib|0x10|stat;"
    "cmux DEV.debug.dylib|0x100|$s13CmuxNextStore4loadyyF;",
    "sync-wait:pthread_cond_wait\tmain\t4\t2000000\t600000\tlibsystem_pthread.dylib|0x1|cond_wait;"
    "Chromium Embedded Framework|0x7000|cef_run_loop;cmux DEV.debug.dylib|0x400|$s15CmuxNextBrowser4pumpyyF;",
]) + "\n"
QUIET_DAEMON = "#final\t1\n#threads\tmux-conn\n"
# Many short cmux waits that add up to 2 ms: no single one reaches 1 ms, but the per-action bound is not shown.
BUSY_APP = "#final\t1\n#threads\tmain\nfile-io:stat\tmain\t400\t2000000\t5000\tlibsystem_kernel.dylib|0x10|stat;" \
           "cmux DEV.debug.dylib|0x100|$s13CmuxNextStore4loadyyF;\n"
# A worse site than APP_DUMP's, so CmuxNextStore.load moves from first to second.
WORSE_APP = "#final\t1\n#threads\tmain\nfile-io:fsync\tmain\t1\t9000000\t9000000\tlibsystem_kernel.dylib|0x11|fsync;" \
            "cmux DEV.debug.dylib|0x110|$s14CmuxNextTheme4saveyyF;\n"


class FilingRun(unittest.TestCase):
    """Runs the report with a sweep's every-action.json and reads its filing (no tests of its own)."""

    def run_filing(self, dumps, sweep=SWEEP_JSON, known=None, status=None):
        work = tempfile.mkdtemp(prefix="blocking-probe-filing-")
        self.addCleanup(shutil.rmtree, work, True)
        app = os.path.join(work, "cmux DEV.app")
        for relative in ("Contents/MacOS/cmux DEV", "Contents/MacOS/cmux DEV.debug.dylib",
                         "Contents/Resources/bin/cmux-tui"):
            path = os.path.join(app, relative)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            open(path, "w").close()
        args = ["--app", app, "--launches", "2", "--out", os.path.join(work, "out"), "--config", "bench"]
        if sweep is not None:
            with open(os.path.join(work, "every-action.json"), "w") as f:
                json.dump(sweep, f)
            args += ["--sweep-json", os.path.join(work, "every-action.json")]
        if known is not None:
            with open(os.path.join(work, "known.json"), "w") as f:
                json.dump(known, f)
            args += ["--known-sites", os.path.join(work, "known.json")]
        if status is not None:
            args += ["--sweep-status", str(status)]
        run = report_cli(*args, *write_dumps(work, dumps))
        self.assertEqual(run.returncode, 0, run.stderr)
        out = os.path.join(work, "out")
        with open(os.path.join(out, "blocking-probe-filing.json")) as f:
            filed = json.load(f)
        with open(os.path.join(out, "perf-lead-rows.md")) as f:
            rows = f.read().splitlines()
        with open(os.path.join(out, "blocking-probe.md")) as f:
            markdown = f.read()
        return filed, rows, markdown, run.stdout


class Filing(FilingRun):
    """Task 301: MQ-11 and MQ-13 tasks, the app_chromium hand-off and RUN-2, from the report's own rows."""

    def test_a_cmux_wait_of_1_ms_fails_run2_and_files_one_task_per_queue_entry(self):
        filed, rows, markdown, stdout = self.run_filing([APP_DUMP, DAEMON_DUMP])
        run2 = filed["run2"]
        self.assertEqual(run2["verdict"], "fail")
        self.assertEqual(run2["waits_ge_1ms_sites"], 1)
        self.assertEqual(run2["cmux_main_ms"], 5.0)
        self.assertEqual(run2["actions"], 9)  # 3 + 2 + 3 repeats and the harness row (1); the skipped row is none
        self.assertFalse(run2["target_met"])
        (task,) = filed["mq11"]
        self.assertEqual(task["machine_queue"], "MQ-11")
        self.assertEqual(task["module"], "CmuxNextStore")
        self.assertEqual((task["total_ms"], task["max_ms"]), (5.0, 3.0))
        self.assertIn("file-io:open 2", task["change"])
        self.assertTrue(task["id"].startswith("p02-threads-B11-"))
        # MQ-13: one task per (site, kind, thread); the idle recv at listen::serve is an input wait, not a task.
        self.assertEqual(sorted((t["kind"], t["thread"]) for t in filed["mq13"]),
                         [("file-io:fsync", "surface-*-host"), ("file-io:open", "mux-conn")])
        self.assertEqual(filed["mq13"][0]["total_ms"], 8.0)  # worst first
        self.assertEqual(filed["daemon"]["input_wait_ms"], 150000.0)
        # Chromium's 2 ms go to the CEF helper-app program as an open number.
        chromium = filed["app_chromium"]
        self.assertEqual((chromium["status"], chromium["total_ms"], chromium["program"]), ("open", 2.0, "p01-process"))
        self.assertIn("RUN-2 fail waits_ge_1ms_sites=1", stdout)
        self.assertIn("chromium=open", stdout)
        self.assertIn("## Filing (p02-threads-301)", markdown)
        # perf-lead.md section 5 rows: six cells each, with sha, host, macOS and config.
        self.assertEqual(len(rows), 2)
        for row in rows:
            self.assertEqual(row.count(" | "), 5, row)
            for fact in ("0123456789ab", "cmux20", "macOS 27.0.1", "config bench", "light + STRESS"):
                self.assertIn(fact, row)
        self.assertIn("RUN-2", rows[0])
        self.assertIn("app_chromium OPEN: 2.0 ms", rows[0])
        self.assertIn("1 dumps periodic only", rows[0])  # the daemon dump had no final write
        self.assertIn("MQ-13; not RUN-5", rows[1])
        self.assertIn("2 MQ-13 tasks", rows[1])

    def test_a_quiet_complete_run_passes_but_the_chromium_number_keeps_the_target_open(self):
        filed, rows, _, _ = self.run_filing([QUIET_APP, QUIET_DAEMON])
        run2 = filed["run2"]
        self.assertEqual((run2["verdict"], run2["incomplete"]), ("pass", []))
        self.assertEqual(filed["mq11"], [])  # 0.2 ms in total is under the 1 ms filing line
        self.assertFalse(run2["target_met"])
        self.assertEqual(filed["app_chromium"]["total_ms"], 2.0)
        self.assertIn("pass:", rows[0])
        filed, _, _, _ = self.run_filing([QUIET_APP.split("sync-wait")[0], QUIET_DAEMON])
        self.assertEqual(filed["app_chromium"]["status"], "zero")
        self.assertTrue(filed["run2"]["target_met"])

    def test_short_waits_that_add_up_or_a_missing_sweep_never_pass(self):
        filed, _, _, _ = self.run_filing([BUSY_APP, QUIET_DAEMON])
        self.assertEqual(filed["run2"]["verdict"], "unproved")
        self.assertEqual(filed["run2"]["waits_ge_1ms_sites"], 0)
        self.assertEqual(len(filed["mq11"]), 1)  # 2 ms in total: filed, though no single wait reached 1 ms
        filed, rows, _, _ = self.run_filing([QUIET_APP, QUIET_DAEMON], sweep=None)
        self.assertEqual(filed["run2"]["verdict"], "unproved")
        self.assertIn("no sweep actions read", filed["run2"]["incomplete"])
        self.assertIn("sha not recorded", rows[0])
        filed, _, _, _ = self.run_filing([QUIET_APP])
        self.assertIn("no daemon dump", filed["run2"]["incomplete"])

    def test_task_ids_follow_the_site_not_its_rank(self):
        before, _, _, _ = self.run_filing([APP_DUMP, DAEMON_DUMP])
        after, _, _, _ = self.run_filing([APP_DUMP, WORSE_APP, DAEMON_DUMP])
        self.assertEqual(after["mq11"][1]["id"], before["mq11"][0]["id"])
        self.assertNotEqual(after["mq11"][0]["id"], before["mq11"][0]["id"])
        self.assertEqual(sorted(t["id"] for t in after["mq13"]), sorted(t["id"] for t in before["mq13"]))
        self.assertEqual(len({t["id"] for t in after["mq13"]}), 2)

    def test_a_frame_with_no_cmux_image_is_not_filed(self):
        stray = "#final\t1\n#threads\tmain\nfile-io:open\tmain\t1\t4000000\t4000000\tlibsystem_kernel.dylib|0x1|open;\n"
        filed, _, _, _ = self.run_filing([stray, QUIET_DAEMON])
        self.assertEqual(filed["mq11"], [])
        self.assertEqual(filed["run2"]["no_cmux_frame_ms"], 4.0)
        self.assertEqual(filed["run2"]["waits_ge_1ms_sites"], 0)


class FilingSources(unittest.TestCase):
    """The file a site's atos line names, against the repo's own files, and the known MQ-13 list."""

    @classmethod
    def setUpClass(cls):
        cls.report = load_report_module()
        cls.index = cls.report.source_index(ROOT)

    def row(self, site, module, **extra):
        return {"site": site, "module": module, "owner": "o", "count": 1, "total_ms": 2.0, "max_ms": 2.0,
                "kinds": {"file-io:open": 1}, "stack": "", "cmux_frame": True,
                "pairs": [{"kind": "file-io:open", "thread": "mux-line-out", "count": 1, "total_ms": 2.0,
                           "max_ms": 2.0}], **extra}

    def test_an_atos_line_resolves_to_the_repo_file(self):
        row = self.row("serve (in cmux-tui) (bounded_outbound.rs:469)", "cmux_tui_core")
        source, candidates = self.report.source_of(row, self.index)
        self.assertEqual(source, "bounded_outbound.rs:469")
        self.assertEqual(candidates, ["cmux-tui/crates/cmux-tui-core/src/server/bounded_outbound.rs"])
        (task,) = self.report.mq11_tasks([row], self.index)
        self.assertEqual(task["files"], candidates)
        self.assertEqual(task["unresolved"], [])

    def test_a_file_name_with_no_single_file_is_unresolved_never_guessed(self):
        row = self.row("f (in cmux DEV.debug.dylib) (NoSuchFile.swift:3)", "CmuxNextStore")
        (task,) = self.report.mq11_tasks([row], self.index)
        self.assertEqual(task["files"], [])
        self.assertEqual(task["unresolved"], [{"source": "NoSuchFile.swift:3", "candidates": []}])

    def test_two_lines_of_one_function_are_two_mq13_tasks(self):
        # MQ-13 files each (location, kind, thread): the function alone would give both lines one id.
        first = self.row("serve (in cmux-tui) (bounded_outbound.rs:469)", "cmux_tui_core")
        second = self.row("serve (in cmux-tui) (bounded_outbound.rs:470)", "cmux_tui_core")
        tasks = self.report.mq13_tasks([first, second], self.index)
        self.assertEqual(len({t["id"] for t in tasks}), 2)
        self.assertEqual(sorted(t["location"] for t in tasks),
                         ["cmux-tui/crates/cmux-tui-core/src/server/bounded_outbound.rs:469",
                          "cmux-tui/crates/cmux-tui-core/src/server/bounded_outbound.rs:470"])
        # With no line from atos, the whole atos line is the location: two symbols stay two tasks.
        bare = [self.row("cmux_tui_core::a::f", "cmux_tui_core"), self.row("cmux_tui_core::a::g", "cmux_tui_core")]
        self.assertEqual(len({t["id"] for t in self.report.mq13_tasks(bare, self.index)}), 2)

    def known_list(self, rows, list_sha="HEAD", measured_sha="HEAD", root=ROOT):
        work = tempfile.mkdtemp(prefix="blocking-probe-known-")
        self.addCleanup(shutil.rmtree, work, True)
        path = os.path.join(work, "mq13-record-sites.json")
        with open(path, "w") as f:
            json.dump(rows, f)
        return self.report.known_sites(path, list_sha, measured_sha, root)

    def test_a_site_on_the_known_mq13_list_is_marked_at_its_path_kind_and_thread(self):
        known = self.known_list([{"location": "crates/cmux-tui-core/src/server/bounded_outbound.rs:469:21",
                                  "kind": "condvar-wait", "thread": "mux-line-out", "fixture": False}])
        self.assertEqual(known[2], "")
        site = "serve (in cmux-tui) (bounded_outbound.rs:469)"
        wait = self.row(site, "cmux_tui_core", pairs=[
            {"kind": "sync-wait:pthread_cond_wait", "thread": "mux-line-out", "count": 1, "total_ms": 2.0,
             "max_ms": 2.0},
            # The same location with another kind (a file open is no condition wait) and another thread: new.
            {"kind": "file-io:open", "thread": "mux-line-out", "count": 1, "total_ms": 2.0, "max_ms": 2.0},
            {"kind": "sync-wait:pthread_cond_wait", "thread": "mux-conn", "count": 1, "total_ms": 2.0,
             "max_ms": 2.0}])
        moved = self.row("serve (in cmux-tui) (bounded_outbound.rs:470)", "cmux_tui_core",
                         pairs=[wait["pairs"][0]])
        tasks = self.report.mq13_tasks([wait, moved], self.index, known)
        marked = {(t["kind"], t["thread"], t["location"].rsplit(":", 1)[1]): (t["known"], t["known_from"])
                  for t in tasks}
        self.assertEqual(marked, {
            ("sync-wait:pthread_cond_wait", "mux-line-out", "469"): ("known", "mq13-record-sites.json"),
            ("file-io:open", "mux-line-out", "469"): ("new", None),
            ("sync-wait:pthread_cond_wait", "mux-conn", "469"): ("new", None),
            ("sync-wait:pthread_cond_wait", "mux-line-out", "470"): ("new", None)})

    def test_a_same_named_file_is_never_the_known_one(self):
        known = self.known_list([{"location": "crates/cmux-tui-core/src/session/mod.rs:10:1", "kind": "sqlite",
                                  "thread": "surface-N-host"}])
        pair = {"kind": "file-io:pwrite", "thread": "surface-*-host", "count": 1, "total_ms": 2.0, "max_ms": 2.0}
        row = self.row("f (in cmux-tui) (mod.rs:10)", "cmux_tui_core", pairs=[pair])
        # Many mod.rs in the crate: atos names no single file, so the site is not marked known.
        (task,) = self.report.mq13_tasks([row], self.index, known)
        self.assertEqual((task["known"], task["known_from"]), ("unknown", None))
        self.assertIn("no single repo file", task["known_unknown_reason"])
        # Another mod.rs at the same line: new, not known.
        other = {"mod.rs": ["cmux-tui/crates/cmux-tui-core/src/mux/mod.rs"]}
        (task,) = self.report.mq13_tasks([row], other, known)
        self.assertEqual((task["known"], task["known_from"]), ("new", None))
        # The listed file itself, with the probe's surface-*-host pattern: known.
        listed = {"mod.rs": ["cmux-tui/crates/cmux-tui-core/src/session/mod.rs"]}
        (task,) = self.report.mq13_tasks([row], listed, known)
        self.assertEqual(task["known"], "known")

    def test_the_list_moves_to_the_measured_commit_or_marks_nothing(self):
        repo = tempfile.mkdtemp(prefix="blocking-probe-known-repo-")
        self.addCleanup(shutil.rmtree, repo, True)
        source = os.path.join(repo, "cmux-tui/crates/x/src/a.rs")
        os.makedirs(os.path.dirname(source))

        def commit(lines):
            with open(source, "w") as f:
                f.write("\n".join(lines) + "\n")
            for args in (["add", "-A"], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "c"]):
                subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True)
            return subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"], check=True, capture_output=True,
                                  text=True).stdout.strip()

        subprocess.run(["git", "init", "-q", repo], check=True, capture_output=True)
        lines = [f"line {n}" for n in range(1, 11)]
        old = commit(lines)
        lines[7] = "line 8 changed"
        new = commit(["added 1", "added 2", "added 3"] + lines)
        rows = [{"location": f"crates/x/src/a.rs:{line}:1", "kind": "fs", "thread": "mux-conn"} for line in (5, 8)]
        name, sites, reason = self.known_list(rows, old, new, repo)
        self.assertEqual(reason, "")
        # Line 5 is line 8 now; the old line 8 changed, so its site is filed as new.
        self.assertEqual(sites, {("cmux-tui/crates/x/src/a.rs", 8, "fs", "mux-conn")})
        _, sites, reason = self.known_list(rows, "0" * 40, new, repo)
        self.assertEqual(sites, frozenset())
        self.assertIn("cannot resolve", reason)
        _, _, reason = self.known_list(rows, old, "", repo)
        self.assertEqual(reason, "the sweep recorded no sha")
        row = self.row("f (in cmux-tui) (a.rs:8)", "x", pairs=[
            {"kind": "file-io:open", "thread": "mux-conn", "count": 1, "total_ms": 2.0, "max_ms": 2.0}])
        (task,) = self.report.mq13_tasks([row], {"a.rs": ["cmux-tui/crates/x/src/a.rs"]},
                                         (name, frozenset(), "the sweep recorded no sha"))
        self.assertEqual((task["known"], task["known_from"]), ("unknown", None))

    def test_moved_line_follows_git_hunks(self):
        moved = self.report.moved_line
        hunks = [(2, 0, 3), (5, 2, 1)]  # 3 lines added after line 2; lines 5-6 replaced by one line
        self.assertEqual([moved(hunks, line) for line in (1, 2, 3, 4, 5, 6, 7)], [1, 2, 6, 7, None, None, 9])

    def test_the_harness_hands_the_303_list_its_commit_and_the_sweep_to_the_report(self):
        with open(HARNESS) as f:
            harness = f.read()
        path = re.search(r'known_sites="([^"]+)"', harness).group(1)
        sha = re.search(r'known_sites_sha="([0-9a-f]{40})"', harness).group(1)
        self.assertTrue(os.path.isfile(os.path.join(ROOT, path)), path)
        with open(os.path.join(ROOT, os.path.dirname(path), "README.md")) as f:
            self.assertIn(f"({sha[:11]};", f.read())  # the README's "Head" commit
        self.assertIn('--known-sites-sha "$known_sites_sha"', harness)
        self.assertIn('--sweep-json "$out/sweep/every-action.json" --sweep-status "$status"', harness)
        name, sites, reason = self.report.known_sites(os.path.join(ROOT, path), sha, sha, ROOT)
        if "cannot resolve" in reason:
            self.skipTest(f"this clone lacks the list's commit {sha[:11]}")
        self.assertEqual(reason, "")
        self.assertIn(("cmux-tui/crates/cmux-tui-core/src/server/bounded_outbound.rs", 469, "condvar-wait",
                       "mux-line-out"), sites)


class DaemonSite(unittest.TestCase):
    """A daemon site is the cmux code that calls a cmux_threads blocking wrapper, not the wrapper."""

    def run_daemon(self, frames):
        work = tempfile.mkdtemp(prefix="blocking-probe-daemon-")
        self.addCleanup(shutil.rmtree, work, True)
        app = os.path.join(work, "cmux DEV.app")
        for relative in ("Contents/MacOS/cmux DEV", "Contents/Resources/bin/cmux-tui"):
            os.makedirs(os.path.dirname(os.path.join(app, relative)), exist_ok=True)
            open(os.path.join(app, relative), "w").close()
        dump = "#final\t1\n#threads\tmux-conn\nfile-io:open\tmux-conn\t1\t2000000\t2000000\t" \
               "libsystem_kernel.dylib|0x30|open;" + ";".join(frames) + ";\n"
        run = report_cli("--app", app, "--out", os.path.join(work, "out"), *write_dumps(work, [dump]))
        self.assertEqual(run.returncode, 0, run.stderr)
        with open(os.path.join(work, "out", "blocking-probe.json")) as f:
            return json.load(f)["sections"]["daemon_request"]

    def test_a_checked_wrapper_files_its_caller(self):
        (site,) = self.run_daemon([
            "cmux-tui|0x1000|_ZN3std2fs4File4open17h0123456789abcdefE",
            "cmux-tui|0x1100|_ZN12cmux_threads7checked2fs4read17h0123456789abcdefE",
            "cmux-tui|0x2000|_ZN13cmux_tui_core6server1x17h0123456789abcdefE",
            "cmux-tui|0x3000|_ZN12cmux_threads4work3run17h0123456789abcdefE"])
        self.assertEqual(site["site"], "_ZN13cmux_tui_core6server1x17h0123456789abcdefE")
        self.assertEqual(site["module"], "cmux_tui_core")

    def test_a_wait_with_only_wrapper_frames_stays_at_the_wrapper(self):
        (site,) = self.run_daemon(["cmux-tui|0x1100|_ZN12cmux_threads4sync5Mutex4lock17h0123456789abcdefE"])
        self.assertEqual(site["module"], "cmux_threads")

    def test_the_wrapper_pattern_names_only_the_blocking_modules(self):
        wrapper = load_report_module().BLOCKING_WRAPPER
        for name in ("cmux_threads::checked::fs::read", "cmux_threads::checked::sync::wait::h12",
                     "<cmux_threads::sync::Mutex<T>>::lock", "cmux_threads::lock_wait::wait",
                     "cmux_threads::blocking::scoped_blocking_call", "_ZN12cmux_threads7checked2fs4read17hE"):
            self.assertTrue(wrapper.search(name), name)
        for name in ("cmux_threads::work::run", "cmux_threads::blocking_kind", "cmux_tui_core::sync::x",
                     "cmux_threads::checkedx"):
            self.assertFalse(wrapper.search(name), name)


class Run2Sessions(FilingRun):
    """RUN-2 is defined on STRESS: a run without a complete STRESS session, or a failed sweep, never passes."""

    def test_a_light_only_sweep_never_passes_and_its_row_says_light(self):
        light = {"env": SWEEP_JSON["env"], "sessions": SWEEP_JSON["sessions"][:1]}
        filed, rows, _, _ = self.run_filing([QUIET_APP, QUIET_DAEMON], sweep=light, status=0)
        self.assertEqual(filed["run2"]["verdict"], "unproved")
        self.assertIn("no STRESS session (sessions: light)", filed["run2"]["incomplete"])
        self.assertIn("every action light |", rows[0])
        self.assertNotIn("STRESS |", rows[0])

    def test_a_failed_stress_session_or_sweep_never_passes(self):
        failed = dict(SWEEP_JSON, failed_sessions=[{"name": "stress", "error": "LaunchError()", "rows": 1}])
        filed, rows, _, _ = self.run_filing([QUIET_APP, QUIET_DAEMON], sweep=failed, status=3)
        self.assertEqual(filed["run2"]["verdict"], "unproved")
        self.assertIn("failed sessions: stress", filed["run2"]["incomplete"])
        self.assertIn("the sweep exited 3", filed["run2"]["incomplete"])
        filed, _, _, _ = self.run_filing([QUIET_APP, QUIET_DAEMON], status=3)
        self.assertEqual(filed["run2"]["incomplete"], ["the sweep exited 3"])

    def test_the_row_never_presents_a_mean_as_the_p99(self):
        filed, rows, _, stdout = self.run_filing([BUSY_APP, QUIET_DAEMON], status=0)
        self.assertIsNone(filed["run2"]["per_action_p99_ms"])
        self.assertNotIn("mean", rows[0])
        self.assertIn("per-action p99 not measured", rows[0])
        self.assertIn("per_action_p99=not_measured", stdout)


if __name__ == "__main__":
    unittest.main()
