#!/usr/bin/env python3
"""The sidebar document and drag benches' result-v1 series (sidebar_drag_bench_report.py, p12-perf-process-055): the
names the lab stories claim, the perf_stats percentiles against the private ones they replace, the drag checks'
work percentiles and threshold, each story's command through its bench's own parser, and one run's series through
perf_result and perf-lab ingest.

Runs on any host (Linux included): no app, no daemon, no fleet, no network.

    python3 -m unittest scripts/cmux-next/tests/test_sidebar_drag_bench_report.py
"""

from __future__ import annotations

import importlib.util
import io
import json
import re
import statistics
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
PERF_LAB = HERE.parent / "perf-lab"
STORIES = PERF_LAB / "stories.d"
sys.path.insert(0, str(HERE))
import bench_launch  # noqa: E402
import sidebar_drag_bench_report as report  # noqa: E402
import sidebar_v2_motion_checks as checks  # noqa: E402


def load(name: str, path: Path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


ingest = load("perf_lab_ingest", PERF_LAB / "ingest.py")
pr = report.perf_result
store = ingest.store

VECTOR = [3.1, 4.0, 4.2, 5.5, 6.0, 7.9, 8.3, 9.0, 12.4, 20.1]
SHA = "b" * 40
CHIP = "Apple M4 Pro"
HOST = pr.Host(fingerprint="e" * 64, host_class=store.host_class(chip=CHIP, memory_gb=24, display_hz=120), chip=CHIP,
               macos="26.1", macos_build="25B78", display_hz=120)
BUILD = pr.Build(sha=SHA, config="bench", measure_version=2)
SCENARIOS = report.DRAG_SCENARIOS


# The private percentiles the benches had before the migration (R8: old and new on one fixed vector).
def old_doc_p95(values):  # sidebar-doc-bench.py report()
    ordered = sorted(values)
    return ordered[max(0, int(len(ordered) * 0.95) - 1)]


def old_work_p95(values):  # sidebar_v2_motion_checks.analyse drag_work_p95_ms
    work = sorted(values)
    return work[int(len(work) * 0.95)] if work else 0


def frames(work, step=0.0, n=12):
    """A drag recording for analyse(): a card lifted over `workspace(a)` for the first frames, dropped where it
    started, and a neighbour row `workspace(b)` that moves `step` pt per frame. `work` is each frame's drag update."""
    out = []
    for i in range(n):
        lifted = i < n - 4
        out.append({"t": i / 120, "lift": [0, 0, 100, 20] if lifted else None,
                    "work_ms": work[i] if i < len(work) else 0,
                    "views": {"workspace(a)": [0, 0, 100, 20, 0 if lifted else 1],
                              "workspace(b)": [0, 40 + step * i, 100, 20]}})
    return out


def story(story_id):
    return json.loads((STORIES / f"{story_id}.json").read_text())


def claimed(doc, series):
    """The story metric that full-matches the series' name with its unit, or None."""
    return next((m for m in doc["metrics"] if re.fullmatch(m["name"], series.metric) and m["unit"] == series.unit),
                None)


def drag_result(ok=True, recorded=True):
    return {"ok": ok, "recorded": recorded, "max_step_pt": 2.1, "jump_count": 0 if ok else 3,
            "frame_gaps_over_1_5x": 1}


class PercentileTests(unittest.TestCase):
    def test_fixed_vector_old_private_percentiles_and_the_perf_stats_ones(self):
        self.assertEqual(old_doc_p95(VECTOR), 12.4)
        self.assertEqual(statistics.median(VECTOR), 6.95)
        self.assertEqual(old_work_p95(VECTOR), 20.1)
        new = {q: report.pct(VECTOR, q) for q in (.5, .95, .99)}
        self.assertEqual(new, {.5: 6.95, .95: 16.63, .99: 19.41})

    def test_doc_report_line_has_median_p95_p99_and_n(self):
        self.assertEqual(report.distribution_line("workspace.place", VECTOR),
                         "workspace.place: median 6.95 ms, p95 16.63 ms, p99 19.41 ms, n=10")

    def test_analyse_takes_work_percentiles_and_cadence_from_perf_stats(self):
        result = checks.analyse(frames(VECTOR), {"workspace(a)"}, dropped_key="workspace(a)")
        self.assertEqual((result["drag_work_p95_ms"], result["drag_work_p99_ms"]), (16.63, 19.41))
        self.assertEqual(result["cadence_ms"], round(1000 / 120, 2))
        self.assertEqual(checks.drag_work(frames(VECTOR)), VECTOR, "frames with no drag update are left out")

    def test_work_check_is_the_named_threshold(self):
        calm = checks.analyse(frames([1.0] * 8), {"workspace(a)"}, dropped_key="workspace(a)")
        self.assertTrue(calm["recorded"])
        self.assertTrue(calm["ok"], calm)
        heavy = checks.analyse(frames([checks.WORK_P95_MS + 1] * 8), {"workspace(a)"}, dropped_key="workspace(a)")
        self.assertFalse(heavy["ok"])
        jumpy = checks.analyse(frames([1.0] * 8, step=checks.JUMP_PT + 1), {"workspace(a)"}, dropped_key="workspace(a)")
        self.assertFalse(jumpy["ok"])
        self.assertGreater(jumpy["jump_count"], 0)


class SeriesTests(unittest.TestCase):
    def test_doc_series_one_per_timed_request(self):
        series = report.doc_series({"workspace.create": [1.0, 2.0], "workspace.place": [3.0],
                                    "workspace_group.update": [0.5], "sidebar.move": []}, "doc")
        self.assertEqual({s.metric: s.samples for s in series},
                         {"sidebar_doc.doc.workspace_create": [1.0, 2.0], "sidebar_doc.doc.workspace_place": [3.0],
                          "sidebar_doc.doc.workspace_group_update": [0.5]})
        self.assertEqual({(s.story, s.unit, s.engine, s.session) for s in series},
                         {("sidebar-doc", "ms", "none", "light")})

    def test_drag_series_of_a_recorded_and_an_unrecorded_scenario(self):
        series = {s.metric: s for s in report.drag_series("1-row-into-pinned", drag_result(), VECTOR)}
        self.assertEqual(series["sidebar_drag.light.1-row-into-pinned.work"].samples, VECTOR)
        self.assertEqual(series["sidebar_drag.light.1-row-into-pinned.max_step"].samples, [2.1])
        self.assertEqual(series["sidebar_drag.light.1-row-into-pinned.failed"].samples, [0])
        empty = report.drag_series("2-tile-into-list", drag_result(ok=False, recorded=False), [])
        self.assertEqual([(s.metric, s.samples) for s in empty], [("sidebar_drag.light.2-tile-into-list.failed", [1])])

    def test_drag_session_and_story_follow_stress(self):
        self.assertEqual((report.drag_session(0), report.drag_session(1000)), ("light", "stress"))
        self.assertEqual((report.drag_story("light"), report.drag_story("stress")), ("sidebar-drag", "sidebar-drag-stress"))
        stress = report.drag_series("4-autoscroll-across", drag_result(), [1.0], session="stress")
        self.assertEqual({s.story for s in stress}, {"sidebar-drag-stress"})

    def test_drag_live_counts_ffi_calls_off_contract_and_failed_steps(self):
        steps = [("a", "PASS"), ("b", "FAIL"), ("c", "SKIP"), ("d", "FAIL")]
        series = {s.metric: s.samples for s in report.drag_live_series(steps, [2, 2, 3])}
        self.assertEqual(series, {"sidebar_drag_live.ffi_calls_off_contract": [0, 0, 1], "sidebar_drag_live.failed_steps": [2]})
        self.assertEqual([s.metric for s in report.drag_live_series([], [])], ["sidebar_drag_live.failed_steps"])

    def test_drag_live_fewer_ffi_calls_read_as_worse_not_better(self):
        """A lost drop (1 call) or an unmirrored drag (0) is as far from the contract as an extra call: lower is
        better holds on either side of two."""
        off = {calls: report.drag_live_series([], [calls])[0].samples for calls in (0, 1, 2, 3)}
        self.assertEqual(off, {0: [2], 1: [1], 2: [0], 3: [1]})

    def test_drag_run_of_a_stopped_harness_shows_failed_proofs(self):
        """fail_harness stopped the run after scenario 1: the run says harness failed and each wanted scenario
        that ran no check is failed, not missing."""
        checks = {"1-row-into-pinned": drag_result(), "harness": {"ok": False, "error": "no window"}}
        series = {s.metric: s.samples for s in report.drag_run_series(checks, {"1-row-into-pinned": [1.0]}, {"1", "2", "5"})}
        self.assertEqual(series["sidebar_drag.light.harness.failed"], [1])
        self.assertEqual(series["sidebar_drag.light.1-row-into-pinned.failed"], [0])
        self.assertEqual(series["sidebar_drag.light.2-tile-into-list.failed"], [1])
        self.assertEqual(series["sidebar_drag.light.5-refusal-springs-back.failed"], [1])
        self.assertNotIn("sidebar_drag.light.3-group-into-pinned.failed", series, "not wanted: not written")
        self.assertEqual(report.missing_scenarios(checks, {"1", "2", "5"}), ["2-tile-into-list", "5-refusal-springs-back"])

    def test_drag_run_of_a_clean_run_has_harness_failed_zero(self):
        checks = {name: drag_result() for name in SCENARIOS}
        series = {s.metric: s.samples for s in report.drag_run_series(checks, {}, set("12345"), session="stress")}
        self.assertEqual(series["sidebar_drag.stress.harness.failed"], [0])
        self.assertEqual({m: v for m, v in series.items() if m.endswith(".failed") and "harness" not in m},
                         {f"sidebar_drag.stress.{name}.failed": [0] for name in SCENARIOS})
        self.assertEqual(report.missing_scenarios(checks, set("12345")), [])

    def test_drag_scenario_names_are_the_record_script_ones(self):
        source = (HERE / "sidebar-v2-drag-record.py").read_text()
        self.assertEqual(tuple(re.findall(r'record\("([0-9]-[a-z-]+)"', source)), SCENARIOS)


class StoryTests(unittest.TestCase):
    def check_claimed(self, story_id, series):
        doc = story(story_id)
        mine = [s for s in series if s.story == story_id]
        self.assertTrue(mine, f"no series for {story_id}")
        for s in mine:
            self.assertEqual((s.engine, s.session), (doc["engine"], doc["session"]), s.metric)
            self.assertIsNotNone(claimed(doc, s), f"{story_id} claims no metric {s.metric} ({s.unit})")

    def test_every_series_a_story_runs_is_claimed_by_it(self):
        times = {request: [1.0] for request in report.DOC_REQUESTS}
        self.check_claimed("sidebar-doc", report.doc_series(times, "doc"))
        for session in ("light", "stress"):
            series = [entry for i, name in enumerate(SCENARIOS)
                      for entry in report.drag_series(name, drag_result(ok=i != 1, recorded=i != 2), [1.0], session)]
            self.check_claimed(report.drag_story(session), series)
            stopped = report.drag_run_series({"harness": {"ok": False}}, {}, set("12345"), session)
            self.check_claimed(report.drag_story(session), stopped)
        self.check_claimed("sidebar-drag-live", report.drag_live_series([("a", "FAIL")], [2]))

    def test_needs_name_every_debug_method_the_script_calls(self):
        """The lab admits a build only with every method the story's script calls (catalog.py `needs`); the
        teardown's debug.quit is BenchApp's. sidebar-drag skips sidebar_wheel (stress only) and window_snapshot
        (--setup-only)."""
        conditional = {"sidebar-drag": {"debug.sidebar_wheel", "debug.window_snapshot"},
                       "sidebar-drag-stress": {"debug.window_snapshot"}, "sidebar-drag-live": {"debug.quit"}}
        for story_id, script in (("sidebar-drag", "sidebar-v2-drag-record.py"),
                                 ("sidebar-drag-stress", "sidebar-v2-drag-record.py"),
                                 ("sidebar-drag-live", "sidebar-v2-drag-live.py")):
            called = set(re.findall(r'rpc\("(debug\.[a-z_]+)"', (HERE / script).read_text()))
            needs = {n.split(":", 1)[1] for n in story(story_id)["needs"] if n.startswith("debug:")}
            self.assertEqual(called - conditional[story_id] - needs, set(), story_id)

    RUNNER = ["--app", "/x/cmux DEV t.app", "--tag", "t", "--out", "/x/out"]  # what the story runner adds

    def parsed(self, story_id, script):
        """The story's command, plus the runner's flags, through its bench's own parser."""
        command = story(story_id)["command"]
        self.assertEqual(command[0], f"scripts/cmux-next/{script}")
        bench = load(f"bench_{script.replace('-', '_')[:-3]}_055", HERE / script)
        return bench.parse(command[1:] + self.RUNNER)

    def test_story_commands_parse_with_their_bench_and_say_what_the_story_does(self):
        doc = self.parsed("sidebar-doc", "sidebar-doc-bench.py")
        self.assertEqual((doc.count, doc.samples, doc.subscriber, doc.out), (2000, 40, "doc", "/x/out"))
        self.assertEqual(str(doc.binary), str(Path("/x/cmux DEV t.app").resolve() / "Contents/Resources/bin/cmux-tui"),
                         "--app names the daemon")
        light = self.parsed("sidebar-drag", "sidebar-v2-drag-record.py")
        self.assertEqual((light.app, light.out, light.stress, light.real_pointer), ("/x/cmux DEV t.app", "/x/out", 0, False))
        self.assertEqual(report.drag_story(report.drag_session(light.stress)), "sidebar-drag")
        stress = self.parsed("sidebar-drag-stress", "sidebar-v2-drag-record.py")
        self.assertEqual(report.drag_story(report.drag_session(stress.stress)), "sidebar-drag-stress")
        live = self.parsed("sidebar-drag-live", "sidebar-v2-drag-live.py")
        self.assertEqual((live.app, live.only, live.story), ("/x/cmux DEV t.app", None, "sidebar-drag-live"))

    def test_doc_bench_refuses_out_without_app_and_no_daemon(self):
        bench = load("bench_sidebar_doc_bench_055", HERE / "sidebar-doc-bench.py")
        self.assertIsNone(bench.parse(["--binary", "/bin/cmux-tui"]).out)
        for argv in ([], ["--binary", "/bin/cmux-tui", "--out", "/x/out"]):
            with self.assertRaises(SystemExit), redirect_stderr(io.StringIO()):
                bench.parse(argv)

    def test_the_catalog_lints_the_new_stories_clean(self):
        catalog = load("perf_lab_catalog", PERF_LAB / "catalog.py").load_catalog()
        ids = {s.id for s in catalog.stories}
        self.assertLessEqual({"sidebar-doc", "sidebar-drag", "sidebar-drag-stress", "sidebar-drag-live"}, ids)
        self.assertEqual([p for p in catalog.problems if "sidebar-d" in p], [])


class RecordTests(unittest.TestCase):
    def ingest(self, tmp, folder):
        db = store.Store(Path(tmp) / "lab.sqlite3")
        db.migrate()
        self.addCleanup(db.close)
        got = ingest.ingest_paths(db, [folder], commit_positions={SHA: ingest.CommitPosition(1, mainline=True)}.get)
        return db, got

    def test_doc_series_write_all_round_trips_and_ingests(self):
        series = report.doc_series({"workspace.create": [1.5, 2.5], "sidebar.move": [0.7]}, "doc")
        run = pr.Run(id="sbdoc1", started_at="2026-10-26T12:00:00.000000Z")
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "results"
            report.write_all(out, series, BUILD, HOST, run=run, root=HERE.parent.parent)
            back = pr.read_dir(out)
            self.assertEqual(sorted(r.metric for r in back), ["sidebar_doc.doc.sidebar_move", "sidebar_doc.doc.workspace_create"])
            db, got = self.ingest(tmp, out)
            self.assertEqual(got.rejected, [])
            self.assertEqual(db.run_metrics("sbdoc1/sidebar-doc")["sidebar_doc.doc.workspace_create"], [1.5, 2.5])

    def test_drag_series_record_through_bench_app_and_ingest(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "results"
            bundle = Path(tmp) / "cmux DEV sb055.app"
            bundle.mkdir()
            app = bench_launch.BenchApp(str(bundle), out=str(out), teardown=False)
            app.features, app._build, app._host = ({}, None, None), BUILD, HOST
            series = (report.drag_series("1-row-into-pinned", drag_result(), [1.0, 1.4])
                      + report.drag_series("5-refusal-springs-back", drag_result(ok=False), [2.0]))
            written = report.record_all(app, series)
            self.assertFalse([v for v in written.values() if v.startswith("not recorded")], written)
            db, got = self.ingest(tmp, out)
            self.assertEqual(got.rejected, [])
            metrics = db.run_metrics(f"{app.run.id}/sidebar-drag")
            self.assertEqual(metrics["sidebar_drag.light.1-row-into-pinned.work"], [1.0, 1.4])
            self.assertEqual(metrics["sidebar_drag.light.5-refusal-springs-back.failed"], [1])


class BenchSourceTests(unittest.TestCase):
    """The four files keep no private percentile, launch the app only through BenchApp and print p99 next to every
    p95 (MQ1, MQ2, MQ3)."""

    FILES = ("sidebar-doc-bench.py", "sidebar-v2-drag-record.py", "sidebar_v2_motion_checks.py",
             "sidebar-v2-drag-live.py")

    def test_no_private_stats_no_self_launch_and_p99(self):
        queues = load("perf_lab_queues", PERF_LAB / "queues.py")
        root = str(HERE.parent.parent)
        keys = {f"scripts/cmux-next/{name}" for name in self.FILES}
        for name, run in (("MQ1", queues.private_stats), ("MQ2", queues.self_launch), ("MQ3", queues.p95_without_p99)):
            self.assertEqual([i.key for i in run(root) if i.key in keys], [], name)

    def test_the_gui_scripts_never_open_the_app_themselves(self):
        for name in ("sidebar-v2-drag-record.py", "sidebar-v2-drag-live.py"):
            source = (HERE / name).read_text()
            self.assertNotIn('"open", "-n"', source, name)
            self.assertNotIn("NX_APP_STOP", source, name)
            self.assertIn("BenchApp(", source, name)


if __name__ == "__main__":
    unittest.main()
