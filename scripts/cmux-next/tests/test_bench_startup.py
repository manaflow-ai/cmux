#!/usr/bin/env python3
"""bench-startup.py (p08-startup-006): percentiles, true cold (purge and its refusal), the value marks of task 007
and 108, --require-optimized, and --order chains, on fixtures.

Runs on any host (Linux included): no app, no fleet, no network. Launches are fakes; nothing is started.

    python3 scripts/cmux-next/tests/test_bench_startup.py
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import plistlib
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
    def test_nearest_rank_percentiles(self):
        values = list(range(1, 101))
        self.assertEqual(bs.spread(values), {"p50": 50.5, "p95": 95, "p99": 99, "max": 100})
        self.assertEqual(bs.spread([7.0]), {"p50": 7.0, "p95": 7.0, "p99": 7.0, "max": 7.0})
        # 20 runs: p95 is the 19th value, p99 the 20th (the max), as a nearest rank reads.
        twenty = [float(v) for v in range(100, 120)]
        self.assertEqual((bs.spread(twenty)["p95"], bs.spread(twenty)["p99"]), (118.0, 119.0))

    def test_table_rows_have_every_percentile_in_landing_order(self):
        runs = [{"main_start": 10, "first_window_frame_committed": 150 + i, "dfl.menu": 90} for i in range(20)]
        rows = bs.table(runs)
        self.assertEqual([row[1] for row in rows], ["main_start", "dfl.menu", "first_window_frame_committed"])
        _, _, values, gap, n = rows[2]
        self.assertEqual((values["p50"], values["p95"], values["p99"], values["max"], n), (159.5, 168, 169, 169, 20))
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
            self.assertEqual(argv, ["sudo", "-n", "purge"], "sudo -n: never a prompt")
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
        self.assertIn("cannot run `sudo -n purge`", err)

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


class OneRunTests(unittest.TestCase):
    def setUp(self):
        self.saved = {name: getattr(bs, name) for name in ("Launch", "app_pids", "tag_pids", "stop", "owner_pids")}
        FakeLaunch.events = []
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
        marks = bs.one_run("t", "cold", 5, temperature="cold", purge_cache=self.purge)
        self.assertEqual(FakeLaunch.events, ["stop", "purge", "launch", "quit"])
        self.assertEqual(marks[bs.TEMPERATURE], "cold")

    def test_cold_mode_without_temperature_still_only_stops_the_daemon(self):
        bs.one_run("t", "cold", 5, purge_cache=self.purge)
        self.assertNotIn("purge", FakeLaunch.events, "--mode cold keeps its meaning: daemon stopped, no purge")

    def test_a_refusal_stops_before_any_launch(self):
        def refuse():
            raise bs.Refused("cold run refused: test")
        code, _, err = quiet(bs.one_run, "t", "cold", 5, temperature="cold", purge_cache=refuse)
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
            self.assertEqual([mark for mark, _ in waited], [["first_terminal_frame", "agent_pane.handshake_end"]],
                             "off by default: the run ends at the first content")
            waited.clear()
            bs.WAIT_STARTUP_COMPLETE = True
            bs.one_run("t", "warm", 5)
        finally:
            bs.WAIT_STARTUP_COMPLETE = saved
        self.assertEqual(waited[1][0], bs.STARTUP_COMPLETE)
        self.assertLessEqual(waited[1][1], 5, "within what is left of the run's one timeout")

    def test_warm_temperature_purges_nothing(self):
        bs.tag_pids = lambda tag: [41]  # the daemon runs: no priming launch
        bs.one_run("t", "warm", 5, temperature="warm", purge_cache=self.purge)
        self.assertEqual(FakeLaunch.events, ["launch", "quit"])


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

    def test_bad_orders_are_usage_errors(self):
        for order in ("first_window_frame_committed", "a<", "<b", "main_start<launch.temperature"):
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

    def test_cold_temperature_needs_cold_mode_only(self):
        self.assertEqual(bs.parse_args(BASE + ["--mode", "cold", "--temperature", "cold"]).temperature, "cold")
        for modes in ([], ["--mode", "warm"], ["--mode", "cold", "--mode", "warm"]):
            code, _, err = quiet(bs.parse_args, BASE + modes + ["--temperature", "cold"])
            self.assertEqual(code, 2, modes)
            self.assertIn("--temperature cold needs --mode cold", err)

    def test_a_tag_or_app_is_required(self):
        self.assertEqual(quiet(bs.parse_args, [])[0], 2)


if __name__ == "__main__":
    unittest.main()
