#!/usr/bin/env python3
"""xbench vs-browsers as a perf-lab story (p12-perf-process-208): `xbench.py story`, stories.d/vs-browsers.json and
import_xbench.py.

  python3 -m unittest scripts/perf-lab/tests/test_xbench_story.py
"""
from __future__ import annotations

import ast
import importlib.util
import json
import os
import plistlib
import re
import sqlite3
import sys
import tempfile
import types
import unittest
from pathlib import Path

PERF_LAB = Path(__file__).resolve().parent.parent
ROOT = PERF_LAB.parent.parent
PERF_BENCH = ROOT / "scripts" / "perf-bench"
BASELINES = sorted((PERF_BENCH / "baseline").glob("*.json"))
STORY_FILE = PERF_LAB / "stories.d" / "vs-browsers.json"


def load(name: str, path: Path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


# xbench's counters need macOS's libproc; the story's result writing does not.
sys.modules.setdefault("procs", types.SimpleNamespace())
xbench = load("xbench", PERF_BENCH / "xbench.py")
import_xbench = load("perf_lab_import_xbench", PERF_LAB / "import_xbench.py")
bench_launch = xbench.bench_launch
pr = xbench.perf_result
store = import_xbench.store

SHA = "0123456789abcdef0123456789abcdef01234567"
FEATURES = ({"perfPath.x": {"state": "on", "source": "default"}}, "fh1", "off")


def host():
    return bench_launch.host_record("Apple M6", 16 * 2**30, "27.0", "26A425", 120)


def samples():
    """Two rounds of the cmux Chromium arm and Chrome, as Run.record writes them, with one unmeasured cell."""
    out = []
    for round_no in (1, 2):
        for browser, launch, memory in (("cmux-chromium", 310.0 + round_no, 930.0), ("chrome", 620.0, 390.0)):
            out += [{"browser": browser, "round": round_no, "row": "launch-window", "value": launch},
                    {"browser": browser, "round": round_no, "row": "memory-1", "value": memory},
                    {"browser": browser, "round": round_no, "row": "idle-cpu-20", "value": 1.5},
                    {"browser": browser, "round": round_no, "row": "idle-wakeups-20", "value": 38.0},
                    {"browser": browser, "round": round_no, "row": "power-idle-hidden", "value": 0.5}]
    out.append({"browser": "chrome", "round": 2, "row": "tab-switch", "value": None, "note": "no visibilitychange"})
    out.append({"browser": "cmux-chromium", "round": 1, "row": "session-error", "value": None, "note": "x"})
    return out


def fake_app(folder: str, *, marker: bool = True, commit: str | None = SHA) -> str:
    app = os.path.join(folder, "cmux NEXT.app")
    os.makedirs(os.path.join(app, "Contents/MacOS"))
    info = {"CFBundleExecutable": "cmux NEXT"}
    if commit:
        info["CMUXCommit"] = commit
    with open(os.path.join(app, "Contents/Info.plist"), "wb") as handle:
        plistlib.dump(info, handle)
    with open(os.path.join(app, "Contents/MacOS/cmux NEXT"), "wb") as handle:
        handle.write(b"\0binary " + (bench_launch.BENCH_HOOKS_MARKER if marker else b"") + b"\0")
    return app


class StoryResultsTests(unittest.TestCase):
    def results(self, rows=None):
        return xbench.story_results(rows or samples(), browsers=["cmux-chromium", "chrome"], story="vs-browsers",
                                    engine="chromium", session="light",
                                    build=pr.Build(sha=SHA, config="bench", measure_version=1),
                                    host=pr.Host.from_dict(host()), run=pr.Run(id="run1",
                                                                               started_at="2026-10-26T01:00:00.0Z"),
                                    features=FEATURES)

    def test_one_result_per_row_and_browser_with_chrome_as_the_reference(self):
        by_metric = {r.metric: r for r in self.results()}
        self.assertEqual(sorted(by_metric), sorted(f"{row}.{arm}" for row in (
            "launch-window", "memory-1", "idle-cpu-20", "idle-wakeups-20", "power-idle-hidden")
            for arm in ("cmux-chromium", "chrome_ref")))
        self.assertEqual(by_metric["launch-window.cmux-chromium"].samples, [311.0, 312.0])
        self.assertEqual(by_metric["launch-window.chrome_ref"].samples, [620.0, 620.0])

    def test_units_are_result_v1_units(self):
        by_metric = {r.metric: r for r in self.results()}
        self.assertEqual(by_metric["memory-1.chrome_ref"].unit, "bytes")
        self.assertEqual(by_metric["memory-1.chrome_ref"].samples, [390.0 * 2**20] * 2)
        self.assertEqual(by_metric["idle-cpu-20.cmux-chromium"].unit, "percent")
        self.assertEqual(by_metric["idle-wakeups-20.cmux-chromium"].unit, "per_s")
        self.assertEqual(by_metric["power-idle-hidden.cmux-chromium"].unit, "mW")

    def test_every_result_is_valid_result_v1_of_the_story(self):
        for result in self.results():
            result.validate(repo_root=ROOT)
            self.assertEqual((result.story, result.engine, result.session, result.better),
                             ("vs-browsers", "chromium", "light", "lower"))
            self.assertEqual(result.features_hash, "fh1")

    def test_series_are_keyed_by_browser(self):
        """The lab store's series key of each result: one series per row and browser, same story and host."""
        keys = {}
        for result in self.results():
            keys[result.metric] = store.series_key(story=result.story, metric=result.metric, engine=result.engine,
                                                   host_class=result.host.host_class, macos_major=27,
                                                   build_config=result.build.config)
        self.assertEqual(len(set(keys.values())), len(keys))
        self.assertNotEqual(keys["launch-window.cmux-chromium"], keys["launch-window.chrome_ref"])

    def test_budget_and_unknown_rows_are_not_story_results(self):
        rows = [{"browser": "cmux-chromium", "round": 1, "row": "budget-idle-cpu", "value": 1.0},
                {"browser": "cmux-chromium", "round": 1, "row": "no-such-row", "value": 1.0},
                {"browser": "helium", "round": 1, "row": "memory-1", "value": 1.0},
                {"browser": "cmux-chromium", "round": 1, "row": "memory-1", "value": 1.0}]
        self.assertEqual([r.metric for r in self.results(rows)], ["memory-1.cmux-chromium"])


class StoryBrowsersTests(unittest.TestCase):
    def test_one_engine_and_one_cmux_arm(self):
        self.assertEqual(xbench.story_browsers("cmux-chromium,chrome,helium", "chromium"),
                         ["cmux-chromium", "chrome", "helium"])
        self.assertEqual(xbench.story_browsers("cmux-webkit,safari", "webkit"), ["cmux-webkit", "safari"])
        for names, engine in (("cmux-chromium,safari", "chromium"), ("chrome", "chromium"),
                              ("cmux-chromium,cmux-webkit", "chromium"), ("cmux-budget,chrome", "chromium"),
                              ("cmux-chromium,chrome,chrome", "chromium"), ("cmux-chromium,netscape", "chromium")):
            with self.subTest(names=names), self.assertRaises(xbench.StoryError):
                xbench.story_browsers(names, engine)

    def test_every_lab_browser_is_an_xbench_browser(self):
        self.assertLessEqual(set(xbench.lab_series.BROWSER_ENGINES), set(xbench.LABELS))
        self.assertNotIn(xbench.budget.NAME, xbench.lab_series.BROWSER_ENGINES)


class StoryMainTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.out = os.path.join(self.tmp.name, "results")
        self.calls = {}

    def measure(self, features=FEATURES, rows=None):
        def run(run_args, env):
            self.calls["run_args"], self.calls["env"] = run_args, env
            return (samples() if rows is None else rows), features
        return run

    def fetch(self, names):
        self.calls["fetched"] = names
        return {name: f"/vendor/{name}.app" for name in names}

    def main(self, *extra, app=None, measure=None, environ=None):
        argv = ["--app", app or fake_app(self.tmp.name), "--out", self.out, "--story", "vs-browsers",
                "--engine", "chromium", "--config", "bench", "--session", "light",
                "--work", os.path.join(self.tmp.name, "work"), *extra]
        return xbench.story_main(argv, read_host=host, fetch=self.fetch, measure=measure or self.measure(),
                                 environ={"CMUX_FEATURES_SAFE_MODE": "off"} if environ is None else environ)

    def test_writes_result_v1_for_the_prebuilt_app(self):
        self.assertEqual(self.main(), 0)
        results = pr.read_dir(self.out)
        self.assertEqual(len(results), 10)
        self.assertEqual({r.build.sha for r in results}, {SHA})
        self.assertEqual({r.build.config for r in results}, {"bench"})
        self.assertEqual({r.build.measure_version for r in results}, {xbench.XBENCH_MEASURE_VERSION})
        self.assertEqual({r.run.id for r in results}, {results[0].run.id})
        self.assertEqual({r.host.host_class for r in results}, {"apple-m6/16gb/120hz"})

    def test_measures_the_app_at_app_and_fetches_only_vendor_browsers(self):
        app = fake_app(self.tmp.name)
        self.assertEqual(self.main("--browser-app", "cmux=/elsewhere.app", app=app), 0)
        run_args = self.calls["run_args"]
        self.assertEqual(self.calls["fetched"], ["chrome"])
        self.assertIn(f"cmux={app}", run_args.app)
        self.assertNotIn("cmux=/elsewhere.app", run_args.app)
        self.assertEqual((run_args.browsers, run_args.cmux_ref), ("cmux-chromium,chrome", SHA))

    def test_a_given_browser_app_is_not_fetched(self):
        self.assertEqual(self.main("--browser-app", "chrome=/Applications/Google Chrome.app"), 0)
        self.assertEqual(self.calls["fetched"], [])
        self.assertIn("chrome=/Applications/Google Chrome.app", self.calls["run_args"].app)

    def test_cmux_arms_get_the_bench_env_and_the_runner_safe_mode(self):
        self.assertEqual(self.main(), 0)
        env = self.calls["env"]
        self.assertEqual(env["CMUX_FEATURES_SAFE_MODE"], "off")
        for name, value in bench_launch.bench_env.fixed_env().items():
            self.assertEqual(env[name], value)

    def test_no_features_snapshot_writes_nothing(self):
        self.assertEqual(self.main(measure=self.measure(features=None)), 1)
        self.assertFalse(os.path.exists(self.out) and os.listdir(self.out))

    def test_nothing_measured_writes_nothing(self):
        self.assertEqual(self.main(measure=self.measure(rows=[])), 1)
        self.assertFalse(os.path.exists(self.out) and os.listdir(self.out))

    def test_a_release_bundle_is_not_a_bench_config(self):
        self.assertEqual(self.main(app=fake_app(self.tmp.name, marker=False)), 1)
        self.assertNotIn("run_args", self.calls)

    def test_an_app_without_a_commit_is_refused(self):
        self.assertEqual(self.main(app=fake_app(self.tmp.name, commit=None), environ={}), 1)
        self.assertNotIn("run_args", self.calls)

    def test_the_runner_sha_names_an_unstamped_build(self):
        self.assertEqual(self.main(app=fake_app(self.tmp.name, commit=None), environ={"CMUX_CI_SHA": SHA}), 0)
        self.assertEqual({r.build.sha for r in pr.read_dir(self.out)}, {SHA})


class StoryFileTests(unittest.TestCase):
    def setUp(self):
        self.story = json.loads(STORY_FILE.read_text(encoding="utf-8"))

    def test_story_shape(self):
        self.assertEqual(self.story["id"], STORY_FILE.stem)
        self.assertEqual((self.story["tier"], self.story["engine"], self.story["config"], self.story["session"]),
                         ("T2", "chromium", "bench", "light"))
        self.assertTrue((ROOT / self.story["command"][0]).is_file())
        self.assertEqual(self.story["command"][1], "story")
        for placeholder in ("{app}", "{out}", "{story}", "{engine}", "{config}", "{session}"):
            self.assertIn(placeholder, self.story["command"])

    def test_metric_patterns_match_every_result_the_story_writes(self):
        browsers = self.story["command"][self.story["command"].index("--browsers") + 1]
        self.assertEqual(xbench.story_browsers(browsers, self.story["engine"]), ["cmux-chromium", "chrome"])
        rows = [{"browser": b, "round": 1, "row": row, "value": 1.0}
                for row, unit in xbench.ROWS_BY_ID.items() for b in ("cmux-chromium", "chrome")]
        results = xbench.story_results(rows, browsers=["cmux-chromium", "chrome"], story="vs-browsers",
                                       engine="chromium", session="light",
                                       build=pr.Build(sha=SHA, config="bench", measure_version=1),
                                       host=pr.Host.from_dict(host()),
                                       run=pr.Run(id="r", started_at="2026-10-26T01:00:00.0Z"), features=FEATURES)
        chromium_rows = {r.metric for r in results} - {
            f"{row}.{arm}" for row in ("power-home-idle", "idle-cpu-home", "idle-wakeups-home")
            for arm in ("cmux-chromium", "chrome_ref")}  # cmux-terminal's rows: never measured for these arms
        for metric in sorted(chromium_rows):
            unit = next(r.unit for r in results if r.metric == metric)
            matching = [m for m in self.story["metrics"] if re.fullmatch(m["name"], metric)]
            with self.subTest(metric=metric):
                self.assertEqual(len(matching), 1)
                self.assertEqual(matching[0]["unit"], unit)

    def test_no_copied_threshold(self):
        def numbers(node, where="$"):
            if isinstance(node, bool):
                return
            if isinstance(node, (int, float)):
                yield where
            elif isinstance(node, dict):
                for key, value in node.items():
                    yield from numbers(value, f"{where}.{key}")
            elif isinstance(node, list):
                for index, value in enumerate(node):
                    yield from numbers(value, f"{where}[{index}]")
        self.assertEqual(sorted(numbers(self.story)), ["$.repeats", "$.seconds"])


class ImportXbenchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.db_path = Path(self.tmp.name) / "lab.sqlite3"
        self.db = store.Store(self.db_path)
        self.addCleanup(self.db.close)
        self.db.migrate()
        self.shas = {json.loads(p.read_text()).get("cmux_ref") for p in BASELINES}

    def positions(self, sha):
        return 100 if sha in self.shas else None

    def import_all(self):
        return import_xbench.import_files(self.db, BASELINES, commit_positions=self.positions)

    def series(self):
        with sqlite3.connect(self.db_path) as db:
            return db.execute("SELECT story, metric, engine, host_class, build_config, unit, series_key "
                              "FROM series").fetchall()

    def test_baselines_become_legacy_series_keyed_by_browser(self):
        report = self.import_all()
        self.assertGreater(report.added_results, 0)
        series = self.series()
        self.assertEqual({s[0] for s in series}, {import_xbench.LEGACY_STORY})
        by = {(s[1], s[3]): s for s in series}
        m6 = "apple-m6/16gb/60hz"
        cmux, chrome = by[("launch-window.cmux-chromium", m6)], by[("launch-window.chrome_ref", m6)]
        self.assertNotEqual(cmux[6], chrome[6])
        self.assertEqual((cmux[2], cmux[4], cmux[5]), ("chromium", "release", "ms"))
        self.assertEqual(by[("power-video.safari", m6)][2], "webkit")
        self.assertEqual(by[("idle-cpu-home.cmux-terminal", m6)][2], "none")
        self.assertEqual(by[("memory-1.cmux-chromium", m6)][5], "bytes")
        self.assertIn(("launch-window.cmux-chromium", "apple-m4-pro/48gb/60hz"), by)
        debug = by[("tab-switch-chromium-2-ctrl_tab.cmux-debug", m6)]
        self.assertEqual((debug[2], debug[4]), ("chromium", "debug"))
        self.assertEqual(by[("tab-switch-markdown-2-ctrl_tab.cmux-debug", m6)][2], "none")

    def test_points_are_the_median_and_flagged_legacy(self):
        self.import_all()
        key = next(s[6] for s in self.series() if s[1] == "memory-1.chrome_ref" and s[3].startswith("apple-m6"))
        (point,) = self.db.series_points(key)
        self.assertEqual(point.samples, [388.8 * 2**20])
        self.assertTrue(point.summary["legacy_stat"] and point.summary["legacy_median_only"])
        self.assertEqual((point.summary["min"], point.summary["max"], point.summary["n"]),
                         (379.2 * 2**20, 416.5 * 2**20, 3))
        self.assertEqual(point.measure_version, import_xbench.LEGACY_MEASURE_VERSION)

    def test_a_second_import_adds_nothing(self):
        first = self.import_all()
        with sqlite3.connect(self.db_path) as db:
            before = db.execute("SELECT COUNT(*) FROM results").fetchone()[0]
        second = self.import_all()
        with sqlite3.connect(self.db_path) as db:
            after = db.execute("SELECT COUNT(*) FROM results").fetchone()[0]
        self.assertEqual((second.added_runs, second.added_results), (0, 0))
        self.assertEqual(second.unchanged_runs, first.added_runs)
        self.assertEqual(before, after)

    def test_every_baseline_imports_and_the_tab_switch_report_is_skipped(self):
        """The tab-switch-matrix report's rows are already the cmux-debug cells of the results file of its run."""
        report = self.import_all()
        self.assertEqual(report.rejected, [])
        self.assertEqual([Path(s.source).name for s in report.skipped], ["tab-switch-apple-m6-macos27.json"])

    def test_a_file_that_is_no_results_document_is_rejected(self):
        path = Path(self.tmp.name) / "other.json"
        path.write_text(json.dumps({"date": "2026-10-20"}))
        report = import_xbench.import_files(self.db, [path], commit_positions=self.positions)
        self.assertEqual([r.reason for r in report.rejected], ["not an xbench results document (no rows object)"])

    def test_a_commit_the_checkout_lacks_is_rejected(self):
        report = import_xbench.import_files(self.db, BASELINES[:1], commit_positions=lambda sha: None)
        self.assertEqual(report.added_runs, 0)
        self.assertIn("not in the lab's checkout", report.rejected[0].reason)

    def test_a_bad_cell_is_rejected_alone(self):
        doc = json.loads(BASELINES[0].read_text())
        doc["rows"]["memory-1"]["cmux-budget"] = {"median": 1.0}
        doc["rows"]["no-such-row"] = {"chrome": {"median": 1.0}}
        doc["rows"]["memory-10"]["chrome"] = {"median": None}
        path = Path(self.tmp.name) / BASELINES[0].name
        path.write_text(json.dumps(doc))
        report = import_xbench.import_files(self.db, [path], commit_positions=self.positions)
        self.assertEqual({r.source.rsplit(" ", 1)[1] for r in report.rejected},
                         {"memory-1|cmux-budget", "memory-10|chrome", "no-such-row|chrome"})
        self.assertGreater(report.added_results, 0)

    def test_row_units_come_from_xbench_and_budget(self):
        units = import_xbench.row_units()
        self.assertEqual(units["memory-1"], "MB")
        self.assertEqual(units["budget-idle-disk-writes"], "KB/s")
        self.assertEqual({row: unit for row, unit in units.items() if row in xbench.ROW_INFO},
                         {row: info[1] for row, info in xbench.ROW_INFO.items()})
        self.assertLessEqual(set(units.values()), set(import_xbench.lab_series.RESULT_UNITS))

    def test_cli_stores_the_baselines(self):
        """`import_xbench.py --db DB FILE` (and `lab.py import-xbench`, which calls the same add_arguments and run)."""
        real = import_xbench.git_commit_positions
        import_xbench.git_commit_positions = lambda repo: self.positions
        self.addCleanup(setattr, import_xbench, "git_commit_positions", real)
        argv = ["--db", str(self.db_path), str(BASELINES[0])]
        self.assertEqual(import_xbench.main(argv), 0)
        self.assertEqual(import_xbench.main(argv), 0)
        self.assertEqual(import_xbench.main(["--db", str(self.db_path), str(PERF_BENCH / "missing.json")]), 1)
        self.assertEqual(import_xbench.main(["--db", "", str(BASELINES[0])]), 2)

    def test_lab_py_can_list_the_command_without_importing_it(self):
        tree = ast.parse((PERF_LAB / "import_xbench.py").read_text(encoding="utf-8"))
        literal = next(node.value for node in tree.body if isinstance(node, ast.Assign)
                       and any(isinstance(t, ast.Name) and t.id == "LAB_COMMANDS" for t in node.targets))
        self.assertEqual(list(ast.literal_eval(literal)), ["import-xbench"])


if __name__ == "__main__":
    unittest.main()
