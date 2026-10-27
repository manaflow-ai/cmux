#!/usr/bin/env python3
"""The switch benches' result-v1 series (p12-perf-process-052).

1. activation-perf.py: every phase's rows become activation.<phase>.<series> with every raw sample of a successful
   activation (total is round trip + drain, resyncs is a count, a row without a number or with an error reply is left
   out), the light phase in story activation (session light, engine none) and the heavy phases in activation-stress
   (session stress, engine chromium), written by a real BenchApp.record and stored by the real perf-lab ingest.
2. tab-switch-matrix.py: a scenario's switches of its own kind become tab_switch.<kind>.<count>[.<input>].<stage>
   and .content_frame; only a named story records, only the metrics it declares, under its one engine; a mixed-kind
   run ingests as one run.
3. tab-switch-stages.py: each warm kind's stages (cold left out, e2e = input + commit, the kind name made a metric
   part) and the confirms, all under the story's engine; the run ingests.
4. bench_tab_switch.py: a raw `debug.frames` stop reply splits into the report's summary and the recorded samples;
   each scenario's series becomes switch_repeat.<scenario>.<series>; the run ingests.
5. The four benches compute percentiles with perf_stats.pct and define no private one.
6. Every metric a bench writes in these tests fullmatches its story's patterns, and its engine and session are the
   story's.

Linux and macOS (off macOS, the benches that import bench_idle load with a stand-in for it: it loads libproc); no
app, no GUI session.

    python3 -m unittest scripts/cmux-next/tests/test_switch_bench_results.py
"""

from __future__ import annotations

import ast
import json
import os
import re
import shutil
import sys
import tempfile
import types
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
ROOT = HERE.parent.parent
PERF_LAB = ROOT / "scripts/perf-lab"
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import bench_launch as bl  # noqa: E402
from test_bench_launch import FEATURES, HOST, record_bundle, result_lines  # noqa: E402


def load_bench(name, file):
    """A bench module; off macOS with a stand-in for bench_idle (it loads libproc at import), removed again."""
    if sys.platform == "darwin":
        return bl.load_by_path(name, str(HERE / file))
    stub = types.ModuleType("bench_idle")
    stub.Client = stub.usage = stub.wait_for_socket = stub.classify = None
    had = sys.modules.get("bench_idle")
    sys.modules["bench_idle"] = stub
    try:
        return bl.load_by_path(name, str(HERE / file))
    finally:
        if had is None:
            del sys.modules["bench_idle"]
        else:
            sys.modules["bench_idle"] = had


activation = bl.load_by_path("activation_perf", str(HERE / "activation-perf.py"))
repeat = load_bench("bench_tab_switch", "bench_tab_switch.py")
matrix = load_bench("tab_switch_matrix", "tab-switch-matrix.py")
stages = bl.load_by_path("tab_switch_stages", str(HERE / "tab-switch-stages.py"))
perf_stats = bl.load_by_path("perf_stats", str(PERF_LAB / "perf_stats.py"))
ingest = bl.load_by_path("perf_lab_ingest", str(PERF_LAB / "ingest.py"))
BENCHES = ("tab-switch-matrix.py", "tab-switch-stages.py", "activation-perf.py", "bench_tab_switch.py")
SHA = "c" * 40


def story_file(story_id):
    return json.loads((PERF_LAB / "stories.d" / f"{story_id}.json").read_text())


class RecordingCase(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="switch-bench-")
        self.out = os.path.join(self.folder, "out")

    def tearDown(self):
        shutil.rmtree(self.folder, ignore_errors=True)

    def bench(self, tag):
        bench = bl.BenchApp(record_bundle(self.folder, tag, commit=SHA), out=self.out, teardown=False,
                            host=lambda: dict(HOST))
        bench.features = FEATURES  # what launch() read
        return bench

    def by_metric(self):
        return {line["metric"]: line for line in result_lines(self.out)}

    def ingest(self):
        """The out folder through the real perf-lab ingest: {run_uuid: (engine, session, {metric: samples})}."""
        db = ingest.store.Store(Path(self.folder) / "lab.sqlite3")
        db.migrate()
        try:
            report = ingest.ingest_paths(db, [self.out],
                                         commit_positions={SHA: ingest.CommitPosition(1, mainline=True)}.get)
            self.assertEqual([r.line() for r in report.rejected], [])
            runs = db._db.execute("SELECT run_uuid, engine, session FROM runs").fetchall()
            return {row["run_uuid"].split("/", 1)[1]: (row["engine"], row["session"], db.run_metrics(row["run_uuid"]))
                    for row in runs}
        finally:
            db.close()

    def assert_story_contract(self):
        """Every written line fullmatches its story's patterns and carries the story's engine and session."""
        for line in result_lines(self.out):
            story = story_file(line["story"])
            self.assertTrue(any(re.fullmatch(m["name"], line["metric"]) for m in story["metrics"]),
                            f"{line['story']} declares no {line['metric']}")
            self.assertEqual((line["engine"], line["session"]), (story["engine"], story["session"]), line["metric"])


def activation_rows(observers, round_trip, drain, resyncs, errors=None):
    return [{"observers_ms": o, "round_trip_ms": r, "drain_ms": d, "resyncs": c, "error": e}
            for o, r, d, c, e in zip(observers, round_trip, drain, resyncs, errors or [None] * len(observers))]


class ActivationTests(RecordingCase):
    def app(self, tag):
        app = activation.App(record_bundle(self.folder, tag, commit=SHA), self.out, 30)
        app.bench.teardown = None
        app.bench.read_host = lambda: dict(HOST)
        app.bench.features = FEATURES  # what launch() read
        return app

    def report(self):
        return {"light_rows": activation_rows([0.4, 0.6], [1.0, 2.0], [0.5, 0.25], [3, 4]),
                "heavy_app_only_rows": activation_rows([2.0, None], [5.0, 6.0], [1.0, 1.5], [40, None]),
                "rows": activation_rows([3.0, 4.5, 6.0], [7.0, 8.0, 9.0], [2.0, 2.5, 3.0], [10, 12, 64])}

    def test_every_phase_records_its_raw_samples_in_its_sessions_story(self):
        written = activation.record(self.app("act"), self.report())
        self.assertEqual(len(written), 15)
        self.assertFalse([m for m, path in written.items() if path.startswith("not recorded")], written)
        lines = self.by_metric()
        self.assertEqual(lines["activation.light.observers"]["samples"], [0.4, 0.6])
        self.assertEqual(lines["activation.light.total"]["samples"], [1.5, 2.25])
        self.assertEqual(lines["activation.heavy_app_only.observers"]["samples"], [2.0], "a row without a number is left out")
        self.assertEqual(lines["activation.heavy.resyncs"]["samples"], [10, 12, 64])
        self.assertEqual(lines["activation.heavy.resyncs"]["unit"], "count")
        self.assertEqual(lines["activation.heavy.drain"]["unit"], "ms")
        light = {(l["story"], l["session"], l["engine"]) for m, l in lines.items() if m.startswith("activation.light.")}
        heavy = {(l["story"], l["session"], l["engine"]) for m, l in lines.items() if not m.startswith("activation.light.")}
        self.assertEqual(light, {("activation", "light", "none")})
        self.assertEqual(heavy, {("activation-stress", "stress", "chromium")})
        self.assertEqual({line["better"] for line in lines.values()}, {"lower"})
        self.assert_story_contract()

    def test_one_run_ingests_as_one_store_run_per_story(self):
        activation.record(self.app("acting"), self.report())
        runs = self.ingest()
        self.assertEqual(sorted(runs), ["activation", "activation-stress"])
        self.assertEqual(runs["activation"][:2], ("none", "light"))
        self.assertEqual(runs["activation-stress"][:2], ("chromium", "stress"))
        self.assertEqual(len(runs["activation"][2]), 5)
        self.assertEqual(len(runs["activation-stress"][2]), 10)

    def test_a_failed_activation_is_left_out_of_every_series(self):
        rows = activation_rows([1.0, None, 3.0], [2.0, 900.0, 4.0], [0.5, 0.5, 0.5], [2, None, 3],
                               errors=[None, "no window", None])
        report = {"light_rows": rows}
        series = {metric: samples for metric, samples, *_ in activation.phase_series(report)}
        self.assertEqual(series["activation.light.round_trip"], [2.0, 4.0])
        self.assertEqual(series["activation.light.drain"], [0.5, 0.5])
        self.assertEqual(series["activation.light.total"], [2.5, 4.5])
        summary = activation.summarize(rows, {"count": 0})
        self.assertEqual((summary["cycles"], summary["failed"], summary["errors"]), (3, 1, ["no window"]))
        self.assertEqual(summary["round_trip_ms"]["max"], 4.0)

    def test_a_phase_not_measured_is_not_a_series(self):
        report = {"rows": activation_rows([1.0], [2.0], [3.0], [4]), "heavy_app_only_rows": []}
        metrics = [m for m, *_ in activation.phase_series(report)]
        self.assertFalse([m for m in metrics if m.startswith("activation.light.")])
        written = activation.record(self.app("act0"), report)
        self.assertEqual(written["activation.heavy_app_only.observers"], "not recorded: no samples")
        self.assertIn("activation.heavy.observers", self.by_metric())
        self.assertNotIn("activation.heavy_app_only.observers", self.by_metric())

    def test_phases_choose_the_sessions_run_measures(self):
        calls = []

        class Opts:
            cycles, phases = 2, "light"

        original = activation.cycles, activation.run_heavy
        activation.cycles = lambda app, count, **_: (calls.append("light") or activation_rows([1.0], [1.0], [1.0], [1]),
                                                     {"count": 0})
        activation.run_heavy = lambda app, opts, pid: calls.append("heavy") or {"rows": []}
        try:
            self.assertIn("light_rows", activation.run(None, Opts))
            self.assertEqual(calls, ["light"])
            Opts.phases = "heavy"
            self.assertNotIn("light_rows", activation.run(None, Opts))
            self.assertEqual(calls, ["light", "heavy"])
        finally:
            activation.cycles, activation.run_heavy = original
        self.assertEqual(activation.SESSION_PHASES, {"light": "light", "stress": "heavy"})

    def test_summary_adds_p99_from_perf_stats_and_keeps_its_keys(self):
        rows = activation_rows([float(v) for v in range(1, 21)], [1.0] * 20, [0.5] * 20, [2] * 20)
        summary = activation.summarize(rows, {"count": 0})
        self.assertEqual(summary["observers_ms"]["p95"], perf_stats.pct(range(1, 21), 0.95))
        self.assertEqual(summary["observers_ms"]["p99"], perf_stats.pct(range(1, 21), 0.99))
        self.assertEqual(set(summary["total_ms"]), {"p50", "p95", "p99"})
        self.assertEqual(set(summary["observers_ms"]), {"p50", "p95", "p99", "max"})

    def test_app_launches_through_bench_app_with_the_activation_env(self):
        app = activation.App(record_bundle(self.folder, "actapp", commit=SHA), self.out, 30)
        env = app.bench.environment()
        self.assertEqual(env["CMUX_NEXT_HANG_THRESHOLD_MS"], "30")
        self.assertEqual(env["CMUX_NEXT_TEST_WINDOW_SCREEN"], "last")
        self.assertEqual(env["CMUX_NEXT_TEST_WINDOW_FRAME"], "40,40,1440,900")
        self.assertEqual(env["CMUX_NEXT_NO_ACTIVATE"], "1")
        self.assertEqual(env["CMUX_NEXT_CONFIG_FILE"], app.config)
        self.assertEqual(json.load(open(app.config))["appearance"], {"backgroundOpacity": 1})
        self.assertEqual(app.bench.log_path, os.path.join(self.out, "app.log"))
        self.assertIsNone(app.process, "no process before launch()")
        self.assertEqual(app.socket, app.bench.socket)
        self.assertEqual(app.tag, "actapp")


def switch(kind, input_ms, apply_ms, commit_ms):
    return {"kind": kind, "input_ms": input_ms, "apply_ms": apply_ms, "commit_ms": commit_ms,
            "e2e_ms": round(input_ms + commit_ms, 3)}


def matrix_result(kind, count, content=None):
    """A scenario() result: the switches also hold the workspace's first terminal (another kind)."""
    part = {"switches": [switch(kind, 1.0, 2.0, 3.0), switch("terminal", 9.0, 9.0, 9.0), switch(kind, 1.5, 2.5, 3.5)]}
    result = {"kind": kind, "count": count, "ctrl_tab": dict(part), "cmd_shift_bracket": dict(part)}
    if content:
        result["ctrl_tab"]["content_frame_ms"] = {"samples": content}
    return result


class MatrixTests(RecordingCase):
    def test_series_are_the_scenarios_own_kind_per_input_and_stage(self):
        series = dict(matrix.scenario_series(matrix_result("webkit", 10, content=[12.0, 14.0])))
        self.assertEqual(sorted(series), [
            "tab_switch.webkit.10.apply", "tab_switch.webkit.10.cmd_shift_bracket.apply",
            "tab_switch.webkit.10.cmd_shift_bracket.commit", "tab_switch.webkit.10.cmd_shift_bracket.e2e",
            "tab_switch.webkit.10.commit", "tab_switch.webkit.10.content_frame", "tab_switch.webkit.10.e2e"])
        self.assertEqual(series["tab_switch.webkit.10.e2e"], [4.0, 5.0], "the first terminal's switches are left out")
        self.assertEqual(series["tab_switch.webkit.10.cmd_shift_bracket.apply"], [2.0, 2.5])
        self.assertEqual(series["tab_switch.webkit.10.content_frame"], [12.0, 14.0])

    def test_a_story_records_only_what_it_declares_under_its_engine(self):
        story = matrix.Story.load("tab-switch")
        bench = self.bench("mx")
        webkit = matrix.record_scenario(matrix_result("webkit", 10, content=[12.0]), bench, story)
        terminal = matrix.record_scenario(matrix_result("terminal", 10), bench, story)
        chromium = matrix.record_scenario(matrix_result("chromium", 10, content=[9.0]), bench, story)
        self.assertFalse([m for m, path in webkit.items() if path.startswith("not recorded")], webkit)
        for written in (terminal, chromium):
            self.assertTrue(written)
            self.assertEqual(set(written.values()), {"not recorded: story tab-switch declares no such metric"})
        lines = self.by_metric()
        self.assertEqual(len(lines), 7)
        self.assertEqual({(l["story"], l["engine"]) for l in lines.values()}, {("tab-switch", "webkit")})
        self.assert_story_contract()
        runs = self.ingest()
        self.assertEqual(sorted(runs), ["tab-switch"])
        self.assertEqual(runs["tab-switch"][0], "webkit")

    def test_no_story_records_nothing(self):
        self.assertEqual(matrix.record_scenario(matrix_result("webkit", 10), self.bench("mx0"), None), {})
        self.assertFalse(os.path.isdir(self.out) and os.listdir(self.out))

    def test_configure_reads_the_story_and_defaults_to_none(self):
        app = record_bundle(self.folder, "mxcfg", commit=SHA)
        matrix.configure(["--tag", "mxcfg", "--app", app])
        self.assertIsNone(matrix.STORY)
        self.assertTrue(os.path.isfile(matrix.CONFIG))
        matrix.configure(["--tag", "mxcfg", "--app", app, "--story", "tab-switch"])
        self.assertEqual((matrix.STORY.id, matrix.STORY.engine), ("tab-switch", "webkit"))
        with self.assertRaises(SystemExit):
            matrix.configure(["--tag", "mxcfg", "--app", app, "--story", "no-such-story"])

    def test_the_tab_switch_story_names_itself(self):
        command = story_file("tab-switch")["command"]
        self.assertEqual(command[command.index("--story") + 1], "tab-switch")

    def test_stat_reports_p99_from_perf_stats(self):
        values = [3.1, 4.7, 5.0, 5.2, 6.8, 7.4, 8.0, 9.9, 12.5, 30.2]
        self.assertEqual(matrix.stat(values), {"p50": 7.1, "p90": 14.27, "p95": 22.235, "p99": 28.607, "max": 30.2})


def stages_part(confirms):
    return {"switches": [switch("terminal", 1.0, 2.0, 3.0), switch("chromium", 2.0, 4.0, 6.0), switch("cold", 50, 60, 70),
                         {"kind": "browser page", "input_ms": 1.0, "apply_ms": 1.0}, switch("chromium", 1.0, 3.0, 5.0)],
            "confirms_ms": confirms}


class StagesTests(RecordingCase):
    def test_series_per_warm_kind_and_the_confirms(self):
        series = dict(stages.input_series("ctrl_tab", stages_part([4.0, 5.0])))
        self.assertEqual(sorted(series), [
            "tab_switch_stages.ctrl_tab.browser_page.apply", "tab_switch_stages.ctrl_tab.browser_page.commit",
            "tab_switch_stages.ctrl_tab.browser_page.e2e", "tab_switch_stages.ctrl_tab.chromium.apply",
            "tab_switch_stages.ctrl_tab.chromium.commit", "tab_switch_stages.ctrl_tab.chromium.e2e",
            "tab_switch_stages.ctrl_tab.confirm", "tab_switch_stages.ctrl_tab.terminal.apply",
            "tab_switch_stages.ctrl_tab.terminal.commit", "tab_switch_stages.ctrl_tab.terminal.e2e"])
        self.assertEqual(series["tab_switch_stages.ctrl_tab.chromium.e2e"], [8.0, 6.0], "input + commit")
        self.assertEqual(series["tab_switch_stages.ctrl_tab.chromium.apply"], [4.0, 3.0])
        self.assertEqual(series["tab_switch_stages.ctrl_tab.browser_page.e2e"], [], "no commit, no e2e")
        self.assertEqual(series["tab_switch_stages.ctrl_tab.confirm"], [4.0, 5.0])

    def test_every_series_records_in_the_story_under_one_engine_and_ingests(self):
        report = {"keys_forward": stages_part([4.0]), "keys_back": stages_part([]), "clicks": stages_part([3.0])}
        written = stages.record(self.bench("stg"), report)
        self.assertEqual(written["tab_switch_stages.ctrl_shift_tab.confirm"], "not recorded: no samples")
        lines = self.by_metric()
        self.assertIn("tab_switch_stages.click.terminal.e2e", lines)
        self.assertEqual({(l["story"], l["engine"]) for l in lines.values()},
                         {(stages.STORY, story_file(stages.STORY)["engine"])})
        self.assert_story_contract()
        runs = self.ingest()
        self.assertEqual(sorted(runs), ["tab-switch-stages"])
        self.assertEqual(len(runs["tab-switch-stages"][2]), len(lines))


class RepeatTests(RecordingCase):
    def test_raw_frames_split_into_the_summary_and_the_samples(self):
        reply = {"p50_ms": 8.3, "p99_ms": 16.7, "missed": 1, "intervals_ms": [8.3, 8.4, 16.7], "main_ms": [1.0, 2.0],
                 "view_layouts_per_frame": [0, 1], "window_layouts_per_frame": [0, 0], "render_draws_per_frame": [1]}
        summary, raw = repeat.split_raw_frames(reply)
        self.assertEqual(summary, {"p50_ms": 8.3, "p99_ms": 16.7, "missed": 1})
        self.assertEqual(raw, {"intervals_ms": [8.3, 8.4, 16.7], "main_ms": [1.0, 2.0]})
        self.assertEqual(repeat.split_raw_frames({"p50_ms": 1.0})[1], {"intervals_ms": [], "main_ms": []})

    def test_each_scenario_records_its_series(self):
        samples = {"tab-repeat": {"frame_interval": [8.3, 8.4], "main_busy": [1.5, 2.5], "stalls": [0]},
                   "workspace-repeat": {"frame_interval": [], "main_busy": [3.0], "stalls": [2]}}
        written = repeat.record(self.bench("rep"), "tab-switch-repeat", samples)
        self.assertEqual(written["switch_repeat.workspace-repeat.frame_interval"], "not recorded: no samples")
        lines = self.by_metric()
        self.assertEqual(sorted(lines), ["switch_repeat.tab-repeat.frame_interval", "switch_repeat.tab-repeat.main_busy",
                                         "switch_repeat.tab-repeat.stalls", "switch_repeat.workspace-repeat.main_busy",
                                         "switch_repeat.workspace-repeat.stalls"])
        self.assertEqual(lines["switch_repeat.tab-repeat.frame_interval"]["samples"], [8.3, 8.4])
        self.assertEqual(lines["switch_repeat.workspace-repeat.stalls"]["unit"], "count")
        self.assert_story_contract()
        self.assertEqual(sorted(self.ingest()), ["tab-switch-repeat"])


class SharedStatsTests(unittest.TestCase):
    def test_no_bench_defines_a_private_percentile(self):
        for name in BENCHES:
            tree = ast.parse((HERE / name).read_text())
            private = [node.name for node in ast.walk(tree) if isinstance(node, ast.FunctionDef)
                       and re.fullmatch(r"_*(pct|percentiles?|quantiles?|p\d{2,3}|med|median)", node.name)]
            self.assertEqual(private, [], name)

    def test_the_benches_take_pct_from_perf_stats(self):
        for module in (matrix, stages, activation):
            self.assertIs(module.pct, module.perf_stats.pct, module.__name__)
            self.assertTrue(module.perf_stats.__file__.endswith("scripts/perf-lab/perf_stats.py"), module.__name__)

    def test_shared_pct_on_the_commit_vector(self):
        """The values the commit message quotes for the old nearest-rank pct and perf_stats.pct."""
        vector = [3.1, 4.7, 5.0, 5.2, 6.8, 7.4, 8.0, 9.9, 12.5, 30.2]
        got = {q: round(perf_stats.pct(vector, q), 3) for q in (0.5, 0.9, 0.95, 0.99)}
        self.assertEqual(got, {0.5: 7.1, 0.9: 14.27, 0.95: 22.235, 0.99: 28.607})


class StoryTests(unittest.TestCase):
    def test_switch_stories_have_their_owner_and_command(self):
        for story_id in ("tab-switch-stages", "activation", "activation-stress", "tab-switch-repeat"):
            self.assertEqual(story_file(story_id)["owner"], "PL-switch")
        self.assertEqual(story_file("activation")["command"][-2:], ["--phases", "light"])
        self.assertEqual(story_file("activation-stress")["command"][-2:], ["--phases", "heavy"])
        for phase, (story_id, session, engine) in activation.PHASES.items():
            self.assertEqual((story_file(story_id)["session"], story_file(story_id)["engine"]), (session, engine), phase)


if __name__ == "__main__":
    unittest.main()
