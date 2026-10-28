#!/usr/bin/env python3
"""bench-startup.py (p08-startup-006, p12-perf-process-033): perf_stats percentiles, true cold (the purge right,
purge and their refusals), the after-reboot checks, the value marks of task 007 and 108, result-v1 series and the
lab stories that run them, --require-optimized, and --order chains, on fixtures.

Runs on any host (Linux included): no app, no fleet, no network. Launches are fakes; nothing is started.

    python3 scripts/cmux-next/tests/test_bench_startup.py
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
SPEC = importlib.util.spec_from_file_location("bench_startup", HERE / "bench-startup.py")
bs = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bs)
import bench_launch as bl  # noqa: E402

BASE = ["--app", "/tmp/cmux DEV t.app"]


def quiet(call, *args, **kwargs):
    """`(result or SystemExit code, stdout, stderr)` of a call, its output captured."""
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            result = call(*args, **kwargs)
        except SystemExit as exit_:
            result = exit_.code
    return result, out.getvalue(), err.getvalue()


def bundle(folder, tag, configuration=None, debug_dylib=False, marker=False, executable="cmux DEV"):
    """A `cmux DEV <tag>.app` as reload.sh stages it: `configuration` is its --config stamp (debug, release, bench,
    bench-checks); a Release product's executable is `cmux`."""
    app = os.path.join(folder, f"cmux DEV {tag}.app")
    os.makedirs(os.path.join(app, "Contents/MacOS"))
    info = {"CFBundleExecutable": executable}
    if configuration:
        info["CMUXBuildConfiguration"] = configuration
    with open(os.path.join(app, "Contents/Info.plist"), "wb") as out:
        plistlib.dump(info, out)
    with open(os.path.join(app, "Contents/MacOS", executable), "wb") as out:
        out.write(b"\xcf\xfa\xed\xfe" + b"\0" * 256 + (bl.BENCH_HOOKS_MARKER if marker else b"") + b"\0" * 16)
    if debug_dylib:
        open(os.path.join(app, "Contents/MacOS", f"{executable}.debug.dylib"), "wb").close()
    return app


class PercentileTests(unittest.TestCase):
    def test_percentiles_are_perf_stats_linear_interpolation(self):
        # p12-perf-process-033 moved from nearest rank to perf_stats.pct. Old -> new on these vectors:
        # 1..100: p95 95 -> 95.05, p99 99 -> 99.01; 100..119: p95 118 -> 118.05, p99 119 -> 118.81. p50 is unchanged.
        values = list(range(1, 101))
        self.assertEqual(bs.spread(values), {"p50": 50.5, "p95": 95.05, "p99": 99.01, "max": 100})
        self.assertEqual(bs.spread([7.0]), {"p50": 7.0, "p95": 7.0, "p99": 7.0, "max": 7.0})
        twenty = [float(v) for v in range(100, 120)]
        self.assertAlmostEqual(bs.spread(twenty)["p95"], 118.05)
        self.assertAlmostEqual(bs.spread(twenty)["p99"], 118.81)
        for vector in (values, twenty, [3.0, 1.0, 2.0]):
            self.assertEqual(bs.spread(vector)["p95"], bs.perf_stats.pct(vector, 0.95))

    def test_no_private_stat_function_is_left(self):
        source = (HERE / "bench-startup.py").read_text()
        self.assertNotRegex(source, r"def (pct|percentile|percentiles|p95|p99|quantile|med|median|stats)\(",
                            "MQ1: statistics come only from perf_stats")
        self.assertNotIn("import statistics", source)

    def test_table_rows_have_every_percentile_in_landing_order(self):
        runs = [{"main_start": 10, "first_window_frame_committed": 150 + i, "dfl.menu": 90} for i in range(20)]
        rows = bs.table(runs)
        self.assertEqual([row[1] for row in rows], ["main_start", "dfl.menu", "first_window_frame_committed"])
        _, _, values, gap, n = rows[2]
        self.assertEqual((values["p50"], values["max"], n), (159.5, 169, 20))
        self.assertAlmostEqual(values["p95"], 168.05)
        self.assertAlmostEqual(values["p99"], 168.81)
        self.assertEqual(gap, 159.5 - 90)

    def test_value_marks_never_make_a_row_and_a_non_number_is_left_out(self):
        self.assertTrue(set(bs.VALUE_MARKS).isdisjoint(mark for mark, _ in bs.MARKS))
        runs = [{"main_start": 10, bs.TEMPERATURE: "cold", bs.PAGEINS: 4100.0, bs.INTERRUPTED: True},
                {"main_start": "garbled"}]
        rows = bs.table(runs)
        self.assertEqual([(row[1], row[4]) for row in rows], [("main_start", 1)])

    def test_the_printed_header_and_cells_line_up(self):
        header = bs.spread_header()
        cells = bs.spread_cells(bs.spread([1.0, 2.0, 3.0]))
        self.assertEqual(header.split(), ["p50", "p95", "p99", "max"])
        self.assertEqual(len(header), len(cells))


class MainSpanTests(unittest.TestCase):
    """p08-startup 033: main() is a per-run span against its 10 ms budget, from the marks main() records in order."""

    def test_the_span_is_per_run_and_counts_runs_over_the_budget(self):
        runs = [{"main_start": 40.0 + i, "main.run": 40.0 + i + 4.0 + i} for i in range(10)]
        line = bs.main_span_summary(runs)
        self.assertIn("main_start -> main.run", line)
        self.assertIn("max 13.0", line)
        self.assertIn("n 10", line)
        self.assertTrue(line.endswith("3 over 10 ms"), line)

    def test_a_build_without_both_marks_prints_no_span(self):
        self.assertIsNone(bs.main_span_summary([{"main_start": 3.0}]))
        self.assertIsNone(bs.main_span_summary([{"main_start": 3.0, "main.run": "garbled"}]))

    def test_main_step_rows_are_in_main_order_between_its_first_and_last_mark(self):
        names = [mark for mark, _ in bs.MARKS]
        steps = names[names.index("main_start"):names.index("main.run") + 1]
        self.assertEqual(steps, ["main_start", "main.environment_frozen", "main.warmup_started", "main.app_environment",
                                 "main.launch_reads", "main.prestart", "main.delegate", "main.nsapp", "main.run"])


class MarkLineTests(unittest.TestCase):
    def test_times_values_and_names(self):
        self.assertEqual(bs.parse_mark_line(b"first_window_frame_committed 151.5"), ("first_window_frame_committed", 151.5))
        self.assertEqual(bs.parse_mark_line(b"launch.temperature cold"), ("launch.temperature", "cold"))
        self.assertEqual(bs.parse_mark_line(b"launch.interrupted true"), ("launch.interrupted", True))
        self.assertEqual(bs.parse_mark_line(b"launch.interrupted false"), ("launch.interrupted", False))
        self.assertEqual(bs.parse_mark_line(b"launch.pageins_first_frame 4100"), ("launch.pageins_first_frame", 4100.0))
        self.assertIsNone(bs.parse_mark_line(b"lonely"))
        self.assertIsNone(bs.parse_mark_line(b""))

    def test_the_pipe_reader_keeps_the_first_value_of_each_name(self):
        read_fd, write_fd = os.pipe()
        os.write(write_fd, b"main_start 3.0\nlaunch.temperature warm\nmain_start 9.0\nlaunch.int")
        os.write(write_fd, b"errupted true\n")
        os.close(write_fd)
        launch = bs.Launch.__new__(bs.Launch)
        launch.read_fd, launch.buffer, launch.marks = read_fd, b"", {}
        self.assertFalse(launch.wait_for("never", 2), "EOF ends the wait")
        os.close(read_fd)
        self.assertEqual(launch.marks, {"main_start": 3.0, "launch.temperature": "warm", "launch.interrupted": True})


class ValueSummaryTests(unittest.TestCase):
    def test_a_build_without_value_marks_prints_nothing_extra(self):
        self.assertEqual(bs.value_summary([{"main_start": 1}]), [])
        self.assertEqual(bs.run_values({"main_start": 1}), [])

    def test_temperature_counts_against_the_asked_one(self):
        runs = [{bs.TEMPERATURE: "cold", bs.PAGEINS: 4000 + i, bs.MAIN_CPU: 50.0} for i in range(8)]
        runs += [{bs.TEMPERATURE: "warm", bs.PAGEINS: 300}, {bs.INTERRUPTED: True}]
        lines = bs.value_summary(runs, "cold")
        self.assertEqual(lines[0], "  launch.temperature: cold 8, warm 1 of 10 runs (1 without it); "
                                   "8 of 10 read cold as asked")
        self.assertEqual(lines[1], "  launch.pageins_run_loop_start: missing in all 10 runs")
        self.assertTrue(lines[2].startswith("  launch.pageins_first_frame: p50 4003  p95 4007  p99 4007  max 4007"),
                        lines[2])
        self.assertIn("n 9", lines[2])
        self.assertIn("main cpu", " ".join(bs.run_values(runs[0])))
        self.assertEqual(lines[-1], "  launch.interrupted: runs 10 (1 of 10)")

    def test_an_asked_temperature_with_no_marks_says_so(self):
        lines = bs.value_summary([{"main_start": 1}] * 3, "cold")
        self.assertIn("missing in all 3 runs", lines[0])
        self.assertEqual(lines[-1], "  launch.interrupted: none of 3 runs")

    def test_task_007_instant_temperature_marks_read_as_the_temperature(self):
        # 007 sends `launch.temperature.<name> <ms>` at run_loop_start and the page-in counts as values.
        runs = [{"main_start": 3.0, "launch.temperature.cold": 12.0, bs.PAGEINS_RUN_LOOP: 3900.0,
                 bs.PAGEINS: 4100.0} for _ in range(8)]
        runs += [{"launch.temperature.lukewarm": 11.0}, {"main_start": 3.0}]
        self.assertEqual(bs.run_temperature(runs[0]), "cold")
        self.assertIsNone(bs.run_temperature(runs[-1]))
        self.assertEqual(bs.run_temperature({bs.TEMPERATURE: "lukewarm", "launch.temperature.warm": 4.0}),
                         "lukewarm", "the value mark wins over the instant mark")
        lines = bs.value_summary(runs, "cold")
        self.assertEqual(lines[0], "  launch.temperature: cold 8, lukewarm 1 of 10 runs (1 without it); "
                                   "8 of 10 read cold as asked")
        self.assertTrue(lines[1].startswith("  launch.pageins_run_loop_start: p50 3900"), lines[1])
        self.assertEqual(bs.run_values(runs[0]), ["temperature cold", "page-ins at run loop 3900", "page-ins 4100"])
        self.assertNotEqual(bs.value_summary([{"launch.temperature.warm": 4.0}]), [],
                            "an instant temperature mark alone prints the summary")
        self.assertIsNotNone(bs.parse_order("main_start<launch.temperature.cold"), "the instant mark is a time")

    def test_temperatures_read_as_named_and_interrupted_rule(self):
        # Task 007 sends names. A number has no agreed meaning (007's signpost counts 0 as warm, Chrome's
        # StartupTemperature counts 0 as cold), so it is shown as it came, never turned into a name.
        self.assertEqual([bs.temperature_name(v) for v in ("COLD", "warm", "lukewarm", 0, 1.0, 2.5)],
                         ["cold", "warm", "lukewarm", "0", "1", "2.5"])
        self.assertEqual(bs.run_temperature({bs.TEMPERATURE: 0.0}), "0")
        self.assertEqual(bs.run_temperature({"launch.temperature.Warm": 3.0}), "warm")
        self.assertTrue(bs.interrupted({bs.INTERRUPTED: 0.0}), "a mark at 0 ms counts")
        self.assertFalse(bs.interrupted({bs.INTERRUPTED: False}))
        self.assertFalse(bs.interrupted({bs.INTERRUPTED: None}))
        self.assertFalse(bs.interrupted({}))
        self.assertEqual(bs.run_values({bs.TEMPERATURE: "cold", bs.PAGEINS: 4100.0, bs.INTERRUPTED: True}),
                         ["temperature cold", "page-ins 4100", "interrupted"])


    def test_first_frame_threads_print_with_the_runs_that_had_a_runtime_thread(self):
        """p08-startup-068: the threads right after the first frame, the runtime threads among them (target 0)."""
        clean = {bs.FIRST_FRAME_THREADS: 41.0, bs.FIRST_FRAME_RUNTIME_THREADS: 0.0, bs.FIRST_FRAME_GHOSTTY_THREADS: 4.0}
        runs = [dict(clean) for _ in range(3)] + [{**clean, bs.FIRST_FRAME_RUNTIME_THREADS: 2.0}]
        self.assertTrue(set(bs.THREAD_MARKS) <= set(bs.VALUE_MARKS), "counts, not times")
        self.assertEqual(bs.run_values(runs[0]), ["threads at first frame 41 (runtime 0, ghostty 4)"])
        self.assertEqual(bs.run_values({"main_start": 1}), [])
        lines = bs.first_frame_threads_summary(runs)
        self.assertEqual([line.split(":")[0].strip() for line in lines[:3]], list(bs.THREAD_MARKS))
        self.assertIn("p50 41", lines[0])
        self.assertIn("n 4", lines[0])
        self.assertEqual(lines[-1], "  runtime threads at first frame: runs 4 of 4 measured")
        self.assertEqual(bs.first_frame_threads_summary(runs[:3])[-1], "  runtime threads at first frame: none of 3 measured")
        self.assertEqual(bs.first_frame_threads_summary([{"main_start": 1}]), [], "an older build prints no thread line")
        self.assertEqual(bs.value_summary(runs)[-1], "  launch.interrupted: none of 4 runs", "the interrupted line stays last")
        self.assertNotIn(bs.FIRST_FRAME_THREADS, [row[1] for row in bs.table(runs)], "never a timed row")

    def test_action_catalog_main_wait_prints_zero_in_how_many_runs(self):
        """p08-startup-092: the acceptance count `action_catalog_main_wait_ms 0 in N of N`; a missing wait is not 0."""
        clean = {bs.ACTION_CATALOG_MAIN_WAIT: 0.0, bs.ACTION_CATALOG_MAIN_READ: 40.0}
        runs = [dict(clean) for _ in range(3)] + [{bs.ACTION_CATALOG_MAIN_WAIT: 1500.0, bs.ACTION_CATALOG_MAIN_READ: 1500.0},
                                                  {"main_start": 1}]
        self.assertTrue({bs.ACTION_CATALOG_MAIN_WAIT, bs.ACTION_CATALOG_MAIN_READ} <= set(bs.VALUE_MARKS), "not times")
        self.assertEqual(bs.run_values(runs[3]), ["action catalog wait 1.50 ms"])
        lines = bs.action_catalog_summary(runs)
        self.assertTrue(lines[0].startswith("  action_catalog_main_wait_ms: 0 in 3 of 5 runs; "), lines[0])
        self.assertTrue(lines[0].endswith("n 4 (1 without it)"), lines[0])
        self.assertIn("max 1.50", lines[0])
        self.assertTrue(lines[1].startswith("  action_catalog_main_read_ms: p50 0.04"), lines[1])
        self.assertEqual(bs.action_catalog_summary([{"main_start": 1}]), [], "an older build prints no catalog line")
        self.assertEqual(bs.value_summary(runs)[-1], "  launch.interrupted: none of 5 runs", "the interrupted line stays last")
        self.assertNotIn(bs.ACTION_CATALOG_MAIN_WAIT, [row[1] for row in bs.table(runs)], "never a timed row")

    def test_a_run_without_its_runtime_count_reads_missing_never_zero(self):
        """p08-startup-068: a quit before the census's later lines is a missing measurement, not the 0 target."""
        clean = {bs.FIRST_FRAME_THREADS: 41.0, bs.FIRST_FRAME_RUNTIME_THREADS: 0.0, bs.FIRST_FRAME_GHOSTTY_THREADS: 4.0}
        partial = {bs.FIRST_FRAME_THREADS: 40.0}
        runs = [dict(clean), partial, {"main_start": 1}]
        self.assertEqual(bs.run_values(partial), ["threads at first frame 40 (runtime missing, ghostty missing)"])
        lines = bs.first_frame_threads_summary(runs)
        self.assertEqual(lines[-2], "  runtime threads at first frame: none of 1 measured")
        self.assertEqual(lines[-1], f"  {bs.FIRST_FRAME_RUNTIME_THREADS}: missing in runs 2, 3 (2 of 3)")

    def test_sidebar_launch_rows_print_against_the_visible_rows(self):
        """p08-startup-064: the sidebar's row views built before startup_complete, against its visible rows."""
        runs = [{bs.SIDEBAR_ROWS_BUILT: 18.0, bs.SIDEBAR_ROWS_VISIBLE: 17.0} for _ in range(4)]
        runs += [{bs.SIDEBAR_ROWS_BUILT: 23.0, bs.SIDEBAR_ROWS_VISIBLE: 17.0}, {"main_start": 1}]
        self.assertTrue(set([bs.SIDEBAR_ROWS_BUILT, bs.SIDEBAR_ROWS_VISIBLE]) <= set(bs.VALUE_MARKS), "counts, not times")
        self.assertEqual(bs.run_values(runs[0]), ["sidebar rows built 18 for 17 visible"])
        self.assertEqual(bs.run_values(runs[-1]), [])
        lines = bs.value_summary(runs)
        line = next(line for line in lines if line.startswith(f"  {bs.SIDEBAR_ROWS_BUILT}:"))
        self.assertIn("p50 18", line)
        self.assertIn("n 5; visible p50 17; 1 of 5 over visible + 2", line)
        self.assertEqual(lines[-1], "  launch.interrupted: none of 6 runs", "the interrupted line stays last")
        self.assertEqual(bs.sidebar_rows_summary([{"main_start": 1}]), [], "an older build prints no sidebar line")
        self.assertNotIn(bs.SIDEBAR_ROWS_BUILT, [row[1] for row in bs.table(runs)], "never a timed row")


class ViewsBuiltTests(unittest.TestCase):
    """p08-startup-065: `launch.views_built` (the pane views made before startup_complete) is a value, sent before
    startup_complete: printed per run and as a spread, never a time row or an --order term."""

    def test_a_run_with_views_built_prints_the_value_and_never_a_row(self):
        run = {"main_start": 3.0, bs.VIEWS_BUILT: 2.0, "startup_complete.launchPhaseSettled": 900.0,
               bs.STARTUP_COMPLETE: 900.0}
        self.assertEqual(bs.run_values(run), ["views built 2", "startup complete launchPhaseSettled"])
        self.assertNotIn(bs.VIEWS_BUILT, [row[1] for row in bs.table([run])])
        self.assertIn("  launch.views_built: p50 2  p95 2  p99 2  max 2  n 1 (== the visible panes)",
                      bs.value_summary([run]))
        with self.assertRaises(ValueError):
            bs.parse_order(f"main_start<{bs.VIEWS_BUILT}")

    def test_a_build_without_it_prints_no_line_for_it(self):
        lines = bs.value_summary([{"startup_complete.launchPhaseSettled": 900.0}])
        self.assertFalse([line for line in lines if bs.VIEWS_BUILT in line], lines)

    def test_a_startup_complete_wait_reads_it_from_before_the_completion(self):
        read_fd, write_fd = os.pipe()
        os.write(write_fd, b"launch.views_built 2\nstartup_complete.launchPhaseSettled 900.0\nstartup_complete 900.0\n")
        launch = bs.Launch.__new__(bs.Launch)
        launch.read_fd, launch.buffer, launch.marks = read_fd, b"", {}
        self.assertTrue(launch.wait_for(bs.STARTUP_COMPLETE, 2))
        os.close(write_fd)
        os.close(read_fd)
        self.assertEqual(launch.marks[bs.VIEWS_BUILT], 2.0)


class CompletionReasonTests(unittest.TestCase):
    """p08-startup-012: `startup_complete.<reason>` comes before `startup_complete`; the bench counts reasons."""

    def test_the_reason_reads_from_its_instant_mark(self):
        run = {"main_start": 3.0, "startup_complete.launchPhaseSettled": 900.0, bs.STARTUP_COMPLETE: 900.0}
        self.assertEqual(bs.completion_reason(run), "launchPhaseSettled")
        self.assertIsNone(bs.completion_reason({"main_start": 3.0, bs.STARTUP_COMPLETE: 900.0}))
        self.assertEqual(bs.run_values(run), ["startup complete launchPhaseSettled"])
        self.assertIn(bs.STARTUP_COMPLETE, [mark for mark, _ in bs.MARKS], "startup_complete is a timed row")

    def test_the_summary_counts_reasons_and_the_failsafe(self):
        runs = [{"startup_complete.launchPhaseSettled": 900.0} for _ in range(8)]
        runs += [{"startup_complete.failsafe": 10000.0}, {"main_start": 3.0}]
        lines = bs.value_summary(runs)
        self.assertIn("  startup_complete: launchPhaseSettled 8, failsafe 1 of 10 runs (1 without it); "
                      "1 of 10 by the failsafe", lines)
        self.assertEqual(lines[-1], "  launch.interrupted: none of 10 runs", "the interrupted line stays last")

    def test_a_build_without_the_scheduler_says_so_only_when_other_values_print(self):
        self.assertEqual(bs.value_summary([{"main_start": 1}]), [])
        lines = bs.value_summary([{"main_start": 1}] * 2, "warm")
        self.assertIn("  startup_complete: missing in all 2 runs (no --startup-complete, or the build has no "
                      "scheduler)", lines)


class PurgeTests(unittest.TestCase):
    def test_a_refused_purge_is_named_and_stops_the_run(self):
        def refused(argv, **_):
            self.assertEqual(argv, ["sudo", "-n", "/usr/sbin/purge"], "sudo -n: never a prompt; the sudoers command")
            return subprocess.CompletedProcess(argv, 1, "", "sudo: a password is required\n")
        code, _, err = quiet(bs.purge, refused)
        self.assertEqual(code, 2)
        self.assertIn("cold run refused", err)
        self.assertIn("a password is required", err)

    def test_a_missing_sudo_is_a_refusal_too(self):
        def missing(argv, **_):
            raise FileNotFoundError(2, "No such file", "sudo")
        code, _, err = quiet(bs.purge, missing)
        self.assertEqual(code, 2)
        self.assertIn("cannot run `sudo -n /usr/sbin/purge`", err)

    def test_a_granted_purge_returns(self):
        ok = quiet(bs.purge, lambda argv, **_: subprocess.CompletedProcess(argv, 0, "", ""))
        self.assertEqual(ok[0], None)


class FakeLaunch:
    events = []

    def __init__(self, tag, scratch, extra_env=None):
        FakeLaunch.events.append("launch")
        self.marks = {}

    def wait_for(self, mark, timeout, any_of=False):
        self.marks = {"first_terminal_frame": 300.0, "agent_pane.handshake_end": 320.0, bs.TEMPERATURE: "cold"}
        return True

    def quit(self):
        FakeLaunch.events.append("quit")


class Unreached(FakeLaunch):
    """A launch that never drew: its first content never came before the timeout."""

    def wait_for(self, mark, timeout, any_of=False):
        return False


class OneRunTests(unittest.TestCase):
    def setUp(self):
        self.saved = {name: getattr(bs, name) for name in ("Launch", "app_pids", "tag_pids", "stop", "owner_pids",
                                                           "reset_state")}
        FakeLaunch.events = []
        bs.reset_state = lambda tag: None
        bs.Launch = FakeLaunch
        bs.app_pids = lambda tag: []
        bs.tag_pids = lambda tag: []
        bs.owner_pids = lambda session: []
        bs.stop = lambda pids, timeout=10: FakeLaunch.events.append("stop")

    def tearDown(self):
        for name, value in self.saved.items():
            setattr(bs, name, value)

    def purge(self):
        FakeLaunch.events.append("purge")

    def test_cold_temperature_purges_last_before_the_measured_launch(self):
        marks = bs.one_run("t", "cold", 5, purge_cold=True, purge_cache=self.purge)
        self.assertEqual(FakeLaunch.events, ["stop", "purge", "launch", "quit"])
        self.assertEqual(marks[bs.TEMPERATURE], "cold")

    def test_cold_mode_without_purge_still_only_stops_the_daemon(self):
        bs.one_run("t", "cold", 5, purge_cache=self.purge)
        self.assertNotIn("purge", FakeLaunch.events, "--mode cold keeps its meaning: daemon stopped, no purge")

    def test_a_refusal_stops_before_any_launch(self):
        def refuse():
            raise bs.Refused("cold run refused: test")
        code, _, err = quiet(bs.one_run, "t", "cold", 5, purge_cold=True, purge_cache=refuse)
        self.assertEqual(code, 2)
        self.assertNotIn("launch", FakeLaunch.events)
        self.assertIn("cold run refused", err)

    def test_startup_complete_waits_for_the_mark_after_the_first_content(self):
        waited = []

        class CompletingLaunch(FakeLaunch):
            def wait_for(self, mark, timeout, any_of=False):
                waited.append((mark, timeout))
                return super().wait_for(mark, timeout, any_of)

        bs.Launch = CompletingLaunch
        bs.tag_pids = lambda tag: [41]
        saved = bs.WAIT_STARTUP_COMPLETE
        try:
            bs.one_run("t", "warm", 5)
            self.assertEqual(waited, [(["first_terminal_frame", "agent_pane.handshake_end"], 5),
                                      (list(bs.THREAD_MARKS), bs.THREAD_MARKS_WAIT_S)],
                             "off by default: the run ends at the first content and its first frame's thread counts")
            waited.clear()
            bs.WAIT_STARTUP_COMPLETE = True
            bs.one_run("t", "warm", 5)
        finally:
            bs.WAIT_STARTUP_COMPLETE = saved
        self.assertEqual(waited[1][0], bs.STARTUP_COMPLETE)
        self.assertLessEqual(waited[1][1], 5, "within what is left of the run's one timeout")

    def test_order_marks_keep_the_launch_past_the_first_content(self):
        # The launch-order marks come from afterStartup posts, after the first content.
        waited = []

        class OrderedLaunch(FakeLaunch):
            def wait_for(self, mark, timeout, any_of=False):
                waited.append((list(mark) if isinstance(mark, list) else mark, timeout, any_of))
                return super().wait_for(mark, timeout, any_of)

        bs.Launch = OrderedLaunch
        bs.tag_pids = lambda tag: [41]
        saved = list(bs.ORDER_MARKS)
        try:
            bs.ORDER_MARKS[:] = ["launch.non_paint_services",
                                 "launch.agent_page_warmup|launch.agent_page_warmup_not_needed|launch.agent_page_warmup_chromium"]
            bs.one_run("t", "warm", 5)
        finally:
            bs.ORDER_MARKS[:] = saved
        self.assertEqual([(marks, any_of) for marks, _, any_of in waited[-2:]],
                         [(["launch.non_paint_services"], True),
                          (["launch.agent_page_warmup", "launch.agent_page_warmup_not_needed",
                            "launch.agent_page_warmup_chromium"], True)],
                         "one wait per term, for any one of its marks")
        self.assertLessEqual(waited[-1][1], 5, "within what is left of the run's one timeout")

    def test_purge_never_runs_before_a_warm_launch(self):
        bs.tag_pids = lambda tag: [41]  # the daemon runs: no priming launch
        bs.one_run("t", "warm", 5, purge_cold=True, purge_cache=self.purge)
        self.assertEqual(FakeLaunch.events, ["launch", "quit"])

    def test_before_quit_runs_in_the_measured_app_before_it_quits(self):
        bs.one_run("t", "cold", 5, purge_cold=True, purge_cache=self.purge,
                   before_quit=lambda tag: FakeLaunch.events.append(f"features {tag}"))
        self.assertEqual(FakeLaunch.events, ["stop", "purge", "launch", "features t", "quit"])

    def test_before_quit_runs_in_a_launch_that_never_drew(self):
        bs.Launch = Unreached
        quiet(bs.one_run, "t", "cold", 5, before_quit=lambda tag: FakeLaunch.events.append("features"))
        self.assertEqual(FakeLaunch.events, ["stop", "launch", "features", "quit"],
                         "a hung launch still names its features, so its missing_runs record")

    def test_hung_launches_still_record_their_missing_runs(self):
        bs.Launch = Unreached
        recorder = bs.Recorder("/tmp/out", "empty", bench_app=FakeBenchApp, rpc=lambda *a, **k: {
            "features": [], "features_hash": "h", "safe_mode": "off"})
        saved = dict(bs.APPS)
        bs.APPS["t"] = "/tmp/cmux DEV t.app"
        try:
            runs = [quiet(bs.one_run, "t", "cold", 5, "empty", before_quit=recorder.read_features)[0]
                    for _ in range(3)]
            code, out, _ = quiet(bs.write_results, recorder, {"t": {"cold": runs}})
        finally:
            bs.APPS.clear()
            bs.APPS.update(saved)
        self.assertIsNone(code, out)
        records = {r[1]: r[3] for r in FakeBenchApp.made[-1].records}
        self.assertEqual(records["launch.cold.first_content.missing_runs"], [3])
        self.assertEqual(records["launch.cold.first_window_frame_committed.missing_runs"], [3])
        self.assertNotIn("launch.cold.first_content", records, "no samples, no series")


class RequireOptimizedTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="bench-startup-test-")
        self.saved = dict(bs.APPS), dict(bs.TAGGED), bs.DERIVED
        bs.DERIVED = os.path.join(self.folder, "DerivedData")

    def tearDown(self):
        for live, saved in zip((bs.APPS, bs.TAGGED), self.saved):
            live.clear()
            live.update(saved)
        bs.DERIVED = self.saved[2]

    def check(self, tag, **kwargs):
        bs.APPS[tag] = bundle(self.folder, tag, **kwargs)
        return quiet(bs.require_optimized, [tag])

    def tagged(self, tag, config, age, **kwargs):
        """A reload.sh --tag build in the tag's DerivedData product folder (Debug or Release), `age` seconds old."""
        folder = os.path.join(bs.DERIVED, f"cmux-{tag}/Build/Products", config)
        os.makedirs(folder, exist_ok=True)
        app = bundle(folder, tag, **kwargs)
        stamp = os.path.getmtime(os.path.join(app, "Contents/Info.plist")) - age
        os.utime(os.path.join(app, "Contents/Info.plist"), (stamp, stamp))
        return app

    # The stamps reload.sh writes (`--config` names), on the bundles each builds.
    def test_release_and_bench_stamps_pass(self):
        code, out, _ = self.check("rel", configuration="release")
        self.assertEqual(code, None)
        self.assertIn("a Release build; Info.plist CMUXBuildConfiguration=release", out)
        code, out, _ = self.check("bench", configuration="bench", marker=True)
        self.assertEqual(code, None)
        self.assertIn("a bench build", out)

    def test_debug_and_bench_checks_stamps_are_refused_before_any_launch(self):
        code, out, err = self.check("dbg", configuration="debug", debug_dylib=True)
        self.assertEqual(code, 2)
        self.assertIn("Debug build", out)
        self.assertIn("--require-optimized: tag dbg", err)
        code, _, err = self.check("checks", configuration="bench-checks", marker=True)
        self.assertEqual(code, 2)
        self.assertIn("blocking detector costs time on every checked call", err)

    def test_a_stamp_the_bundle_contradicts_is_refused(self):
        code, _, err = self.check("liar", configuration="release", marker=True)
        self.assertEqual(code, 2)
        self.assertIn("CMUXBuildConfiguration='release', but", err)
        self.assertIn("bench-hooks bundle", err)
        code, _, err = self.check("debug-says-bench", configuration="bench", debug_dylib=True)
        self.assertEqual(code, 2)
        self.assertIn("debug bundle", err)

    def test_unstamped_bundles_read_from_the_executable(self):
        self.assertEqual(self.check("plain")[0], None, "no .debug.dylib, no marker: a Release build")
        self.assertEqual(self.check("plain-debug", debug_dylib=True)[0], 2)
        code, _, err = self.check("plain-bench", marker=True)
        self.assertEqual(code, 2, "an unstamped bench-hooks bundle can be bench or bench-checks")
        self.assertIn("bench-hooks build with no CMUXBuildConfiguration", err)

    def test_a_tag_finds_its_bench_build_under_products_release(self):
        # reload.sh --tag t --config bench stages `cmux DEV t.app` (executable `cmux`) under Products/Release;
        # a later Debug rebuild of the tag lands under Products/Debug and is newer.
        bench = self.tagged("t", "Release", 60, configuration="bench", marker=True, executable="cmux")
        debug = self.tagged("t", "Debug", 0, configuration="debug", debug_dylib=True)
        code, out, _ = quiet(bs.require_optimized, ["t"])
        self.assertEqual(code, None, out)
        self.assertEqual(bs.app_binary("t"), os.path.join(bench, "Contents/MacOS/cmux"))
        bs.TAGGED.clear()
        self.assertEqual(bs.app_binary("t"), os.path.join(debug, "Contents/MacOS/cmux DEV"),
                         "without --require-optimized the newest build runs")
        pattern = bs.re.compile(bs.bundle_root("t"))
        self.assertTrue(pattern.search(bench) and pattern.search(debug), "both product folders are the tag's")

    def test_after_reboot_reads_no_executable_before_the_launch(self):
        def scan(*_):
            raise AssertionError("the executable was read before the first launch since the boot")

        bench = self.tagged("t", "Release", 60, configuration="bench", marker=True, executable="cmux")
        self.tagged("t", "Debug", 0, configuration="debug", debug_dylib=True)
        saved = bs.build_config, bl.bundle_kind, bs.bundle_kind
        bs.build_config = bl.bundle_kind = bs.bundle_kind = scan
        try:
            code, out, _ = quiet(bs.require_optimized, ["t"], bs.stamp_evidence)
            self.assertEqual(code, None, out)
            self.assertEqual(bs.app_path("t"), bench, "the stamp alone finds the tag's bench build")
            for tag, kwargs in (("plain", {}), ("dbg", {"configuration": "release", "debug_dylib": True}),
                                ("checks", {"configuration": "bench-checks", "marker": True})):
                bs.APPS[tag] = bundle(self.folder, tag, **kwargs)
                self.assertEqual(quiet(bs.require_optimized, [tag], bs.stamp_evidence)[0], 2, tag)
        finally:
            bs.build_config, bl.bundle_kind, bs.bundle_kind = saved
        code, _, err = self.check("liar", configuration="release", marker=True)
        self.assertEqual(code, 2, "after the launch, the executable check still refuses a stamp it contradicts")

    def test_a_tag_with_only_a_debug_build_is_refused_with_the_bench_command(self):
        self.tagged("only", "Debug", 0, configuration="debug", debug_dylib=True)
        code, _, err = quiet(bs.require_optimized, ["only"])
        self.assertEqual(code, 2)
        self.assertIn("`reload.sh --tag only --config bench`, which lands in Build/Products/Release", err)
        code, _, err = quiet(bs.app_binary, "missing")
        self.assertIn("no tagged app for missing", str(code))


class OrderTests(unittest.TestCase):
    RESULTS = {"t": {"warm": [
        {"launch_picture_shown": 40, "first_window_frame_committed": 150, "launch.non_paint_services": 160},
        {"launch_picture_shown": 40, "first_window_frame_committed": 150, "launch.non_paint_services": 140},
        {"launch_picture_shown": 160, "first_window_frame_committed": 150},
    ]}}

    def test_a_pair_keeps_its_meaning(self):
        out = bs.check_orders(self.RESULTS, ["first_window_frame_committed<launch.non_paint_services"])
        self.assertEqual(out, ["t warm run 2: launch.non_paint_services at 140 ms, before first_window_frame_committed at 150 ms",
                               "t warm run 3: launch.non_paint_services missing"])

    def test_a_chain_checks_each_neighbor_pair(self):
        out = bs.check_orders(self.RESULTS, ["launch_picture_shown<first_window_frame_committed<launch.non_paint_services"])
        self.assertEqual(len(out), 3, out)
        self.assertIn("t warm run 3: first_window_frame_committed at 150 ms, before launch_picture_shown at 160 ms", out)

    def test_a_term_with_alternatives_takes_the_mark_that_arrived(self):
        # The agent page warm-up marks whether it made its page, was not
        # needed (an agent page started WebKit) or made none because agent pages open in Chromium.
        term = "launch.agent_page_warmup|launch.agent_page_warmup_not_needed|launch.agent_page_warmup_chromium"
        order = "first_window_frame_committed<" + term
        results = {"t": {"warm": [
            {"first_window_frame_committed": 150, "launch.agent_page_warmup": 400},
            {"first_window_frame_committed": 150, "launch.agent_page_warmup_not_needed": 400},
            {"first_window_frame_committed": 150, "launch.agent_page_warmup_chromium": 400},
            {"first_window_frame_committed": 150, "launch.agent_page_warmup_not_needed": 120},
            {"first_window_frame_committed": 150},
        ]}}
        self.assertEqual(bs.check_orders(results, [order]), [
            f"t warm run 4: {term} at 120 ms, before first_window_frame_committed at 150 ms",
            f"t warm run 5: {term} missing",
        ])
        self.assertIn(order, bs.LAUNCH_ORDER, "the budget-mode check accepts any of the three marks")

    def test_the_chromium_warmup_skip_is_its_own_mark(self):
        # A launch whose agent pages open in Chromium must not read like one where a
        # restored WebKit agent page started WebKit first.
        names = [name for name, _ in bs.MARKS]
        for mark in ("launch.agent_page_warmup", "launch.agent_page_warmup_not_needed",
                     "launch.agent_page_warmup_chromium"):
            self.assertEqual(names.count(mark), 1, mark)

    def test_bad_orders_are_usage_errors(self):
        for order in ("first_window_frame_committed", "a<", "<b", "main_start<launch.temperature",
                      "a<b|", "a<b|launch.temperature"):
            code, _, err = quiet(bs.parse_args, BASE + ["--order", order])
            self.assertEqual(code, 2, order)
            self.assertIn("--order", err)

    def test_budgets_ignore_value_marks_in_runs(self):
        results = {"t": {"cold": [{"first_window_frame_committed": 290, bs.TEMPERATURE: "cold"}] * 3}}
        self.assertEqual(bs.check_budgets(results, ["first_window_frame_committed=300"]), [])
        self.assertEqual(bs.check_budgets(results, ["first_window_frame_committed=280"]),
                         ["t cold: first_window_frame_committed median 290 ms > 280 ms"])


class ArgsTests(unittest.TestCase):
    def test_no_new_flag_changes_the_defaults(self):
        args = bs.parse_args(BASE)
        self.assertEqual((args.temperature, args.require_optimized, args.mode, args.runs, args.order),
                         (None, False, None, 5, []))
        self.assertEqual((args.purge, args.purge_cold, args.after_reboot, args.out), (False, False, False, None))

    def test_cold_temperature_needs_cold_mode_only(self):
        self.assertEqual(bs.parse_args(BASE + ["--mode", "cold", "--temperature", "cold"]).temperature, "cold")
        for modes in ([], ["--mode", "warm"], ["--mode", "cold", "--mode", "warm"]):
            code, _, err = quiet(bs.parse_args, BASE + modes + ["--temperature", "cold"])
            self.assertEqual(code, 2, modes)
            self.assertIn("--temperature cold needs --mode cold", err)

    def test_a_tag_or_app_is_required(self):
        self.assertEqual(quiet(bs.parse_args, [])[0], 2)


class PurgeRightTests(unittest.TestCase):
    """Acceptance (p12-perf-process-033): without purge rights the cold story refuses with a reason before any
    launch, and never reports warm as cold."""

    def test_a_missing_right_refuses_with_sudos_reason(self):
        def refused(argv, **_):
            self.assertEqual(argv, ["sudo", "-n", "-l", "/usr/sbin/purge"], "-l lists the right and runs nothing")
            return subprocess.CompletedProcess(argv, 1, "", "sudo: a password is required\n")
        code, _, err = quiet(bs.check_purge_right, refused)
        self.assertEqual(code, 2)
        self.assertIn("may not run /usr/sbin/purge without a password (sudo: a password is required)", err)
        self.assertIn("--grant-privileged", err)
        self.assertIn("--after-reboot", err)

    def test_a_silent_refusal_names_the_exit_status(self):
        code, _, err = quiet(bs.check_purge_right, lambda argv, **_: subprocess.CompletedProcess(argv, 1, "", ""))
        self.assertEqual(code, 2)
        self.assertIn("(exit 1)", err)

    def test_no_sudo_is_a_refusal(self):
        def missing(argv, **_):
            raise FileNotFoundError(2, "No such file", "sudo")
        self.assertEqual(quiet(bs.check_purge_right, missing)[0], 2)

    def test_a_granted_right_returns(self):
        def granted(argv, **_):
            return subprocess.CompletedProcess(argv, 0, "/usr/sbin/purge\n", "")
        self.assertEqual(quiet(bs.check_purge_right, granted)[0], None)


class AfterRebootTests(unittest.TestCase):
    BOOT = "{ sec = 1000000, usec = 52 } Mon Oct 26 03:00:00 2026\n"

    def setUp(self):
        self.saved = bs.tag_pids, bs.seeded_focus
        bs.tag_pids = lambda tag: []
        bs.seeded_focus = lambda tag: None

    def tearDown(self):
        bs.tag_pids, bs.seeded_focus = self.saved

    def check(self, uptime, profile="empty", boot=None):
        def sysctl(argv, **_):
            self.assertEqual(argv, ["/usr/sbin/sysctl", "-n", "kern.boottime"])
            return subprocess.CompletedProcess(argv, 0, self.BOOT if boot is None else boot, "")
        return quiet(bs.check_after_reboot, ["t"], profile, sysctl, lambda: 1000000 + uptime)

    def test_a_fresh_boot_passes(self):
        self.assertEqual(self.check(120)[0], None)

    def test_a_long_uptime_refuses(self):
        code, _, err = self.check(bs.AFTER_REBOOT_MAX_UPTIME_S + 1)
        self.assertEqual(code, 2)
        self.assertIn("after-reboot run refused: the Mac has been up", err)

    def test_an_unreadable_boot_time_refuses(self):
        code, _, err = self.check(10, boot="")
        self.assertEqual(code, 2)
        self.assertIn("kern.boottime is unreadable", err)

    def test_a_tag_that_already_ran_refuses(self):
        bs.tag_pids = lambda tag: [41]
        code, _, err = self.check(10)
        self.assertEqual(code, 2)
        self.assertIn("tag t already ran since the boot", err)

    def test_an_unseeded_realistic_profile_refuses(self):
        code, _, err = self.check(10, profile="realistic")
        self.assertEqual(code, 2)
        self.assertIn("seed it with one --profile realistic run before the reboot", err)
        bs.seeded_focus = lambda tag: bs.seed_layout()
        self.assertEqual(self.check(10, profile="realistic")[0], None)


class ResultSeriesTests(unittest.TestCase):
    def test_every_result_mark_and_its_missing_runs(self):
        runs = [{"first_window_frame_committed": 140.0 + i, "first_terminal_frame": 300.0 + i,
                 "did_finish_launching_end": 90.0} for i in range(4)] + [{"first_window_frame_committed": 150.0}]
        series = {metric: (unit, samples) for metric, unit, samples in bs.result_series("warm", runs, "realistic")}
        self.assertEqual(series["launch.warm.first_window_frame_committed"],
                         ("ms", [140.0, 141.0, 142.0, 143.0, 150.0]))
        self.assertEqual(series["launch.warm.first_terminal_frame"], ("ms", [300.0, 301.0, 302.0, 303.0]))
        self.assertEqual(series["launch.warm.first_terminal_frame.missing_runs"], ("count", [1]))
        self.assertEqual(series["launch.warm.sidebar_rows_shown.missing_runs"], ("count", [5]))
        self.assertNotIn("launch.warm.sidebar_rows_shown", series, "no samples, no series")
        self.assertNotIn("launch.warm.not_cold_runs", series)

    def test_a_run_the_build_called_warm_is_never_a_cold_sample(self):
        runs = [{"first_window_frame_committed": 280.0, bs.TEMPERATURE: "cold"},
                {"first_window_frame_committed": 120.0, bs.TEMPERATURE: "warm"},
                {"first_window_frame_committed": 125.0, "launch.temperature.lukewarm": 4.0},
                {"first_window_frame_committed": 290.0},
                {"first_window_frame_committed": 295.0, bs.TEMPERATURE: 0.0}]
        series = {metric: samples for metric, _, samples in bs.result_series("cold", runs, "empty")}
        self.assertEqual(series["launch.cold.first_window_frame_committed"], [280.0, 290.0, 295.0],
                         "a named non-cold run is left out; no name, or a number, keeps the run")
        self.assertEqual(series["launch.cold.not_cold_runs"], [2])
        self.assertEqual(series["launch.cold.first_window_frame_committed.missing_runs"], [0])

    def test_an_empty_profile_launch_that_ends_on_the_agent_page(self):
        runs = [{"first_window_frame_committed": 140.0, bs.AGENT_MARK: 310.0 + i} for i in range(3)]
        runs.append({"first_window_frame_committed": 150.0, bs.FINAL_MARK: 290.0, bs.AGENT_MARK: 330.0})
        series = {metric: samples for metric, _, samples in bs.result_series("cold", runs, "empty")}
        self.assertEqual(series["launch.cold.first_content"], [310.0, 311.0, 312.0, 290.0],
                         "the first content that drew, the agent page or a terminal")
        self.assertEqual(series["launch.cold.first_content.missing_runs"], [0])
        self.assertFalse([m for m in series if m.startswith("launch.cold.first_terminal_frame")],
                         "no series an empty profile's first launch could never fill")

    def test_stories_and_targets(self):
        self.assertEqual(bs.default_story("cold", "empty"), "launch-cold")
        self.assertEqual(bs.default_story("warm", "realistic"), "launch-warm-realistic")
        self.assertEqual(bs.default_story("cold", "empty", after_reboot=True), "launch-after-reboot")
        self.assertEqual(bs.target_of("cold", "launch.cold.first_window_frame_committed", "empty"), "launch.cold")
        self.assertEqual(bs.target_of("warm", "launch.warm.first_window_frame_committed", "empty"), "launch.warm")
        self.assertIsNone(bs.target_of("cold", "launch.cold.first_window_frame_committed", "realistic"))
        self.assertIsNone(bs.target_of("cold", "launch.cold.first_terminal_frame", "empty"))
        self.assertIsNone(bs.target_of("restart", "launch.restart.first_window_frame_committed", "empty"))


class FakeBenchApp:
    made = []

    def __init__(self, app, out=None, teardown=True, perf_session="light", build_config=None, run=None):
        self.app, self.out, self.teardown, self.run = app, out, teardown, run
        self.features = None
        self.records = []
        FakeBenchApp.made.append(self)

    def record(self, story, metric, unit, samples, better, engine, target_ref=None):
        if self.features is None:
            raise bl.RecordError("bench-launch: t has no features.list snapshot")
        self.records.append((story, metric, unit, list(samples), better, engine, target_ref))
        return os.path.join(self.out, f"{metric}.ndjson")


class RecorderTests(unittest.TestCase):
    def setUp(self):
        self.saved = dict(bs.APPS)
        bs.APPS["t"] = "/tmp/cmux DEV t.app"
        FakeBenchApp.made = []
        self.calls = []

    def tearDown(self):
        bs.APPS.clear()
        bs.APPS.update(self.saved)

    def rpc(self, path, method, params=None, timeout=60):
        self.calls.append((path, method))
        if len(self.calls) == 1:
            return {"error": "connection refused", "unreachable": True}
        return {"features": [{"name": "launch.instant", "state": "on", "source": "default"}],
                "features_hash": "abc", "safe_mode": "off"}

    def recorder(self, profile="empty", **kwargs):
        return bs.Recorder("/tmp/out", profile, bench_app=FakeBenchApp, rpc=self.rpc, **kwargs)

    def test_features_come_from_the_measured_app_once(self):
        recorder = self.recorder()
        recorder.read_features("t")
        recorder.read_features("t")
        self.assertEqual([method for _, method in self.calls], ["features.list", "features.list"],
                         "the next socket after an unreachable one, then never again")
        self.assertEqual(FakeBenchApp.made[0].features[0], {"launch.instant": {"state": "on", "source": "default"}})
        self.assertFalse(FakeBenchApp.made[0].teardown, "bench-startup stops its own processes")

    def test_records_name_the_story_target_and_engine(self):
        recorder = self.recorder()
        recorder.read_features("t")
        written = recorder.record("t", "cold", [{"first_window_frame_committed": 250.0, "first_terminal_frame": 400.0}])
        app = FakeBenchApp.made[0]
        frame = next(r for r in app.records if r[1] == "launch.cold.first_window_frame_committed")
        self.assertEqual(frame, ("launch-cold", "launch.cold.first_window_frame_committed", "ms", [250.0], "lower",
                                 "none", "launch.cold"))
        self.assertTrue(all(r[0] == "launch-cold" for r in app.records))
        self.assertTrue(written["launch.cold.first_content"].endswith(".ndjson"))
        self.assertIs(app.run, recorder.run, "every result of the invocation names one run")

    def test_a_story_override_and_the_realistic_profile(self):
        recorder = self.recorder(profile="realistic")
        recorder.read_features("t")
        recorder.record("t", "warm", [{"first_window_frame_committed": 100.0}])
        self.assertTrue(all(r[0] == "launch-warm-realistic" and r[6] is None for r in FakeBenchApp.made[0].records))
        recorder = self.recorder(story="my-story")
        recorder.read_features("t")
        recorder.record("t", "warm", [{"first_window_frame_committed": 100.0}])
        self.assertTrue(all(r[0] == "my-story" for r in FakeBenchApp.made[-1].records))

    def test_no_features_writes_nothing_and_says_why(self):
        written = self.recorder().record("t", "warm", [{"first_window_frame_committed": 100.0}])
        self.assertTrue(all(outcome.startswith("not recorded: bench-launch: t has no features.list snapshot")
                            for outcome in written.values()))
        self.assertEqual(FakeBenchApp.made[0].records, [])
        code, out, err = quiet(bs.write_results, self.recorder(),
                               {"t": {"warm": [{"first_window_frame_committed": 1.0}]}})
        self.assertEqual(code, 2)
        self.assertIn("no result-v1 written to /tmp/out", err)
        self.assertIn("result-v1 t launch.warm.first_window_frame_committed: not recorded", out)

    def test_the_real_bench_app_writes_valid_result_v1(self):
        folder = tempfile.mkdtemp(prefix="bench-startup-result-")
        bs.APPS["t"] = bundle(folder, "t", configuration="bench", marker=True)
        host = {"fingerprint": "0" * 64, "class": "apple-m4-16gb-120hz", "chip": "Apple M4", "macos": "26.0",
                "macos_build": "25A100", "display_hz": 120}

        def bench_app(path, **kwargs):
            return bl.BenchApp(path, host=lambda: host, **kwargs)

        saved = os.environ.get("CMUX_CI_SHA")
        os.environ["CMUX_CI_SHA"] = "a" * 40
        try:
            recorder = bs.Recorder(os.path.join(folder, "out"), "empty", bench_app=bench_app, rpc=self.rpc)
            recorder.read_features("t")
            written = recorder.record("t", "cold", [{"first_window_frame_committed": 250.0, bs.TEMPERATURE: "cold"}])
        finally:
            if saved is None:
                os.environ.pop("CMUX_CI_SHA")
            else:
                os.environ["CMUX_CI_SHA"] = saved
        self.assertFalse([o for o in written.values() if o.startswith("not recorded")], written)
        results = {r.metric: r for r in bs.perf_result.read_dir(os.path.join(folder, "out"))}
        frame = results["launch.cold.first_window_frame_committed"]
        self.assertEqual((frame.story, frame.samples, frame.build.config, frame.target_ref.target),
                         ("launch-cold", [250.0], "bench", "launch.cold"))
        self.assertEqual(results["launch.cold.not_cold_runs"].samples, [0])


class StoryCommandTests(unittest.TestCase):
    """Each launch story's command is a valid bench-startup command once the runner adds --app and --out, and the
    result-v1 metrics it writes are the ones the story lists."""

    STORIES = HERE.parent / "perf-lab" / "stories.d"

    def stories(self):
        # bench-startup's stories; launch-connect is launch-connect-journey.py's (test_launch_journey_results).
        found = [story for story in (json.loads(path.read_text()) for path in sorted(self.STORIES.glob("launch*.json")))
                 if story["command"][0] == "scripts/cmux-next/bench-startup.py"]
        self.assertLessEqual({"launch-cold", "launch-cold-realistic", "launch-warm", "launch-warm-realistic",
                              "launch-after-reboot"}, {story["id"] for story in found})
        return found

    def test_every_launch_story_runs_and_lists_its_metrics(self):
        for story in self.stories():
            with self.subTest(story=story["id"]):
                self.assertEqual(story["command"][0], "scripts/cmux-next/bench-startup.py")
                args = bs.parse_args(story["command"][1:] + BASE + ["--out", "/tmp/out"])
                patterns = [m["name"] for m in story["metrics"]]
                saved, root = bs.CORPUS, "launch"
                self.addCleanup(setattr, bs, "CORPUS", saved)
                if args.corpus:  # a corpus launch story (launch-restore-*): its series are under corpus.<id>
                    bs.CORPUS = bs.corpus_module().load(args.corpus)
                    root = bs.CORPUS.metric_root
                    self.assertEqual(story["session"], bs.CORPUS.session)
                for mode in args.mode:
                    self.assertEqual(bs.default_story(mode, args.profile, args.after_reboot), story["id"])
                    written = [metric for metric, _, _ in bs.result_series(mode, [{}], args.profile, root)]
                    written += [f"{root}.{mode}.{mark}" for mark in bs.result_marks(args.profile)]
                    for metric in written:
                        self.assertTrue(any(re.fullmatch(p, metric) for p in patterns), metric)
                    for pattern in patterns:
                        self.assertTrue(any(re.fullmatch(pattern, metric) for metric in written), pattern)

    def test_cold_stories_purge_or_follow_a_reboot(self):
        for story in self.stories():
            args = bs.parse_args(story["command"][1:] + BASE)
            if "cold" in args.mode:
                with self.subTest(story=story["id"]):
                    self.assertTrue(args.purge_cold or args.after_reboot)
                    self.assertEqual("privilege:purge" in story["needs"], args.purge_cold)
                    self.assertEqual(story["tier"], "T2" if args.after_reboot else "T1")


class ResultArgsTests(unittest.TestCase):
    def test_purge_runs_only_before_cold_launches(self):
        args = bs.parse_args(BASE + ["--purge"])
        self.assertTrue(args.purge_cold)
        self.assertEqual(args.mode, None, "--purge keeps cold and warm; only the cold launches purge")
        self.assertTrue(bs.parse_args(BASE + ["--mode", "cold", "--temperature", "cold"]).purge_cold)

    def test_an_unpurged_cold_result_is_refused(self):
        for argv in (["--profile", "empty", "--out", "o"], ["--profile", "empty", "--mode", "cold", "--out", "o"]):
            code, _, err = quiet(bs.parse_args, BASE + argv)
            self.assertEqual(code, 2, argv)
            self.assertIn("result-v1 never reports it as cold", err)
        self.assertTrue(bs.parse_args(BASE + ["--profile", "empty", "--mode", "warm", "--out", "o"]).out)
        self.assertTrue(bs.parse_args(BASE + ["--profile", "empty", "--purge", "--out", "o"]).out)

    def test_a_result_names_its_profile(self):
        code, _, err = quiet(bs.parse_args, BASE + ["--mode", "warm", "--out", "o"])
        self.assertEqual(code, 2)
        self.assertIn("--out needs --profile", err)

    def test_a_realistic_after_reboot_result_names_its_story(self):
        argv = BASE + ["--after-reboot", "--profile", "realistic", "--out", "o"]
        code, _, err = quiet(bs.parse_args, argv)
        self.assertEqual(code, 2)
        self.assertIn("launch-after-reboot is the empty profile's series", err)
        self.assertEqual(bs.parse_args(argv + ["--story", "my-reboot"]).story, "my-reboot")
        self.assertTrue(bs.parse_args(BASE + ["--after-reboot", "--profile", "empty", "--out", "o"]).out)

    def test_after_reboot_is_one_cold_run_without_purge(self):
        args = bs.parse_args(BASE + ["--after-reboot"])
        self.assertEqual((args.mode, args.runs, args.purge_cold), (["cold"], 1, False))
        for extra in (["--mode", "warm"], ["--runs", "3"], ["--purge"], ["--temperature", "cold"]):
            code, _, err = quiet(bs.parse_args, BASE + ["--after-reboot"] + extra)
            self.assertEqual(code, 2, extra)
            self.assertIn("--after-reboot", err)


if __name__ == "__main__":
    unittest.main()
