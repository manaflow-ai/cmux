#!/usr/bin/env python3
"""The vs-browsers T2 story (task 208): xbench's result-v1 per browser arm, and import_xbench's legacy points.

  python3 -m unittest scripts/perf-lab/tests/test_vs_browsers.py
"""
from __future__ import annotations

import functools
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

PERF_LAB = Path(__file__).resolve().parent.parent
ROOT = PERF_LAB.parent.parent


def load(name: str, path: Path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


import_xbench = load("perf_lab_import_xbench", PERF_LAB / "import_xbench.py")
xbench = import_xbench.xbench()
ingest = import_xbench.ingest
store = import_xbench.store
pr = import_xbench.perf_result
alerts = load("perf_lab_alerts", PERF_LAB / "alerts.py")
catalog = load("perf_lab_catalog", PERF_LAB / "catalog.py")

SHA = "3" * 40
POSITIONS = {SHA: ingest.CommitPosition(500, mainline=True)}
HOST = pr.Host(fingerprint="e" * 64, host_class=store.host_class(chip="Apple M6", memory_gb=16, display_hz=120),
               chip="Apple M6", macos="27.0", macos_build="26A425", display_hz=120)
BUILD = pr.Build(sha=SHA, config="bench", measure_version=2)
FEATURES = ({"perfPath.x": {"state": "on", "source": "default"}}, "fh1", "inactive")
VERSIONS = {"chrome": "155.0.8059.85"}
CHROME = "chrome-155.0.8059.85"


def sample(browser, round_no, row, value):
    return {"browser": browser, "round": round_no, "row": row, "value": value}


SAMPLES = [
    sample("cmux-chromium", 1, "launch-window", 300.0), sample("cmux-chromium", 1, "launch-window", 320.0),
    sample("chrome", 1, "launch-window", 600.0), sample("chrome", 1, "launch-window", 640.0),
    sample("cmux-chromium", 2, "launch-window", 330.0), sample("chrome", 2, "launch-window", 660.0),
    sample("cmux-chromium", 1, "memory-1", 200.0), sample("chrome", 1, "memory-1", 400.0),
    sample("cmux-chromium", 1, "power-idle-visible-gpu", 2.5),
    sample("cmux-chromium", 3, "tab-switch", 12.0),  # no Chrome sample in round 3: no ratio for it
    sample("chrome", 1, "idle-cpu-1", None),  # an unmeasured row
    sample("chrome", 1, "session-error", None),
]


class LabSeriesTests(unittest.TestCase):
    def series(self, browser):
        return {metric: (unit, better, values)
                for metric, unit, better, values in xbench.lab_series(SAMPLES, browser, VERSIONS)}

    def test_every_metric_names_its_browser_and_is_in_result_v1_units(self):
        cmux = self.series("cmux-chromium")
        self.assertEqual(cmux["xbench.cmux-chromium.launch-window"], ("ms", "lower", [300.0, 320.0, 330.0]))
        self.assertEqual(cmux["xbench.cmux-chromium.memory-1"], ("bytes", "lower", [200.0 * 1048576]))
        self.assertEqual(cmux["xbench.cmux-chromium.power-idle-visible-gpu"], ("percent", "lower", [0.25]))
        chrome = self.series("chrome")
        self.assertEqual(sorted(chrome), [f"xbench.{CHROME}.launch-window", f"xbench.{CHROME}.memory-1"])
        for unit, _better, _values in [*cmux.values(), *chrome.values()]:
            self.assertIn(unit, pr.UNITS)

    def test_a_cmux_arm_gets_its_per_round_ratio_to_chrome(self):
        cmux = self.series("cmux-chromium")
        unit, better, ratios = cmux[f"xbench.cmux-chromium.launch-window.vs-{CHROME}"]
        self.assertEqual((unit, better), ("ratio", "lower"))
        self.assertEqual(ratios, [310.0 / 620.0, 330.0 / 660.0])  # each round's median over Chrome's
        self.assertEqual(cmux[f"xbench.cmux-chromium.memory-1.vs-{CHROME}"][2], [0.5])
        self.assertNotIn(f"xbench.cmux-chromium.tab-switch.vs-{CHROME}", cmux)
        self.assertFalse([m for m in self.series("chrome") if ".vs-" in m], "the reference arm has no ratio")

    def test_a_vendor_arm_needs_a_version(self):
        with tempfile.TemporaryDirectory() as d:
            for name, version in (("Chrome.app", "155.0.8059.85"), ("Bare.app", None)):
                os.makedirs(os.path.join(d, name, "Contents"))
                with open(os.path.join(d, name, "Contents", "Info.plist"), "wb") as f:
                    xbench.plistlib.dump({"CFBundleShortVersionString": version} if version else {}, f)
            chrome, bare = os.path.join(d, "Chrome.app"), os.path.join(d, "Bare.app")
            self.assertEqual(xbench.vendor_versions({"cmux-chromium": bare, "chrome": chrome}), VERSIONS)
            with self.assertRaises(SystemExit) as ctx:
                xbench.vendor_versions({"chrome": bare})
            self.assertIn("names no version", str(ctx.exception))

    def test_every_row_unit_has_a_result_v1_unit(self):
        for row, (_label, unit, _main) in xbench.ROW_INFO.items():
            self.assertIn(xbench.RESULT_UNITS[unit][0], pr.UNITS, row)
        self.assertEqual(set(xbench.ENGINES) - xbench.CMUX - xbench.CHROMIUM, {"safari"})
        self.assertTrue(set(xbench.ENGINES.values()) <= set(pr.ENGINES))


class AppArgumentTests(unittest.TestCase):
    def test_a_bare_app_path_is_the_cmux_bundle(self):
        self.assertEqual(xbench.parse_apps(["/lab/cmux DEV t.app", "chrome=/c/Google Chrome.app"]),
                         {"cmux": "/lab/cmux DEV t.app", "chrome": "/c/Google Chrome.app"})
        self.assertEqual(xbench.parse_apps(["cmux=/n/cmux NEXT.app"]), {"cmux": "/n/cmux NEXT.app"})
        self.assertEqual(xbench.parse_apps(["/odd=name.app"]), {"cmux": "/odd=name.app"})

    def test_fetch_reads_fetch_browsers_lines_and_leaves_out_what_it_cannot_fetch(self):
        calls = []

        def run(argv, **kwargs):
            calls.append(argv)
            return SimpleNamespace(stdout="chrome=/cache/chrome/2026-10-26/Google Chrome.app\nnoise\n", returncode=0)

        self.assertEqual(xbench.fetch(["chrome", "helium"], run=run),
                         {"chrome": "/cache/chrome/2026-10-26/Google Chrome.app"})
        self.assertEqual(calls[0][-2:], ["chrome", "helium"])
        self.assertEqual(xbench.fetch([], run=run), {})
        self.assertEqual(len(calls), 1, "nothing to fetch runs nothing")

        def timeout(argv, **kwargs):
            raise subprocess.TimeoutExpired(argv, kwargs["timeout"])

        self.assertEqual(xbench.fetch(["chrome"], run=timeout), {})
        failed = SimpleNamespace(stdout="", returncode=1)
        self.assertEqual(xbench.fetch(["chrome"], run=lambda argv, **kw: failed), {})

    def test_the_lab_story_command_parses(self):
        story = json.loads((PERF_LAB / "stories.d" / "vs-browsers.json").read_text())
        argv = [*story["command"][1:], "--app", "/lab/cmux DEV t.app", "--tag", "t", "--out", "/tmp/o"]
        ran = []
        with mock.patch.object(xbench, "Run", lambda args: SimpleNamespace(main=lambda: ran.append(args))), \
                mock.patch.object(xbench.signal, "signal"):
            xbench.main(argv)
        args = ran[0]
        self.assertTrue(args.perf_lab)
        self.assertEqual((args.app, args.tag, args.fetch, args.browsers),
                         (["/lab/cmux DEV t.app"], "t", ["chrome"], "cmux-chromium,chrome"))
        self.assertEqual(story["id"], xbench.STORY)


class LabRecordTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.out = self.tmp.name
        self.perf_import = xbench.load_perf_import()

    def tearDown(self):
        self.tmp.cleanup()

    def record(self, environ=None):
        with mock.patch.object(self.perf_import, "measured_build", return_value=(BUILD, HOST)) as measured:
            lab = xbench.LabRecord("/lab/cmux.app", VERSIONS, environ={"PERF_LAB_CONFIG": "bench", **(environ or {})})
        measured.assert_called_once_with("/lab/cmux.app", "bench")
        return lab

    def test_each_arm_is_one_result_v1_run_with_its_engine(self):
        lab = self.record()
        lab.features = FEATURES
        paths = lab.write(self.out, SAMPLES, ["cmux-chromium", "chrome", "helium"])
        self.assertEqual(len(paths), 2, "an arm with no sample writes nothing")
        results = pr.read_dir(self.out)
        by_metric = {r.metric: r for r in results}
        cmux, chrome = by_metric["xbench.cmux-chromium.launch-window"], by_metric[f"xbench.{CHROME}.launch-window"]
        self.assertEqual({r.story for r in results}, {"vs-browsers"})
        self.assertEqual((cmux.engine, chrome.engine), ("chromium", "chromium"))
        self.assertNotEqual(cmux.run.id, chrome.run.id)
        self.assertEqual(cmux.run.started_at, chrome.run.started_at)
        self.assertEqual({r.build.sha for r in results}, {SHA}, "every arm is a point of the measured cmux commit")
        self.assertEqual(cmux.features_hash, "fh1")
        self.assertEqual((chrome.features, chrome.features_hash, chrome.safe_mode), ({}, None, None))
        self.assertEqual(by_metric[f"xbench.cmux-chromium.launch-window.vs-{CHROME}"].unit, "ratio")

    def test_series_are_keyed_by_browser_after_ingest(self):
        lab = self.record()
        lab.features = FEATURES
        lab.write(self.out, SAMPLES, ["cmux-chromium", "chrome"])
        with tempfile.TemporaryDirectory() as d:
            db = store.Store(Path(d) / "lab.sqlite3")
            db.migrate()
            report = ingest.ingest_paths(db, [self.out], commit_positions=POSITIONS.get, tier="T2")
            self.assertEqual(report.rejected, [])
            self.assertEqual(report.added_runs, 2)
            keys = {store.series_key(story="vs-browsers", metric=f"xbench.{b}.launch-window", engine="chromium",
                                     host_class=HOST.host_class, macos_major=27, build_config="bench")
                    for b in ("cmux-chromium", CHROME)}
            self.assertEqual(len(keys), 2)
            for key in keys:
                self.assertEqual(len(db.series_points(key)), 1)
            db.close()

    def test_a_chrome_update_starts_new_series_and_steps_no_judged_series(self):
        """Two nights a Chrome update apart, at the next cmux commit: Chrome's rows and the cmux ratios move to new
        series, so no series that holds both nights has a Chrome step in it."""
        later_sha = "4" * 40
        nights = [(SHA, VERSIONS, 1.0), (later_sha, {"chrome": "156.0.1.2"}, 2.0)]  # Chrome 156 is twice as slow
        with tempfile.TemporaryDirectory() as d:
            db = store.Store(Path(d) / "lab.sqlite3")
            db.migrate()
            for index, (sha, versions, slower) in enumerate(nights):
                out = Path(d) / f"night{index}"
                out.mkdir()
                build = pr.Build(sha=sha, config="bench", measure_version=2)
                with mock.patch.object(self.perf_import, "measured_build", return_value=(build, HOST)):
                    lab = xbench.LabRecord("/lab/cmux.app", versions, environ={"PERF_LAB_CONFIG": "bench"})
                lab.features = FEATURES
                samples = [{**s, "value": s["value"] * slower} if s["browser"] == "chrome" and s["value"] else s
                           for s in SAMPLES]
                lab.write(str(out), samples, ["cmux-chromium", "chrome"])
                positions = {SHA: ingest.CommitPosition(500, mainline=True),
                             later_sha: ingest.CommitPosition(501, mainline=True)}
                report = ingest.ingest_paths(db, [str(out)], commit_positions=positions.get, tier="T2")
                self.assertEqual(report.rejected, [])
            rows = db._db.execute("SELECT series_key, metric FROM series").fetchall()
            for key, metric in rows:
                points = alerts.judged_points(db.series_points(key))
                if metric.startswith("xbench.cmux-chromium.") and ".vs-" not in metric:
                    continue  # cmux's own rows did not change and hold both nights
                self.assertEqual(len(points), 1, f"{metric} holds two Chrome versions")
            metrics = {metric for _key, metric in rows}
            self.assertIn("xbench.chrome-156.0.1.2.launch-window", metrics)
            self.assertIn("xbench.cmux-chromium.launch-window.vs-chrome-156.0.1.2", metrics)
            db.close()
        # The reference arm's series are shown, never alerted: no sheriff subscription owns them.
        subscriptions = alerts.Subscriptions.load()
        for metric in metrics:
            if metric.startswith("xbench.chrome-"):
                series = alerts.SeriesInfo(0, "k", "vs-browsers", metric, "chromium", HOST.host_class, 27, "bench",
                                           "ms", "lower")
                self.assertIsNone(subscriptions.match(series), metric)

    def test_no_result_without_the_cmux_features_snapshot(self):
        lab = self.record()
        with self.assertRaises(SystemExit):
            lab.write(self.out, SAMPLES, ["cmux-chromium", "chrome"])
        self.assertEqual(os.listdir(self.out), [])

    def test_a_run_that_cannot_be_named_never_starts(self):
        launch = self.perf_import.bench_launch()
        with mock.patch.object(self.perf_import, "measured_build", side_effect=launch.RecordError("no sha")):
            with self.assertRaises(SystemExit) as ctx:
                xbench.LabRecord("/lab/cmux.app", VERSIONS, environ={})
        self.assertIn("no sha", str(ctx.exception))
        with self.assertRaises(SystemExit):
            xbench.LabRecord(None, VERSIONS, environ={})

    def test_first_cmux_launch_reads_features_and_writes_the_full_host_check(self):
        lab = self.record({"PERF_LAB_VDISPLAY_OUT": "/tmp/vd"})
        calls = []
        app = SimpleNamespace(call=lambda method, params, **kw: calls.append(method) or {
            "features": [{"name": "perfPath.x", "state": "on", "source": "default"}], "features_hash": "fh1",
            "safe_mode": "inactive"})
        browser = SimpleNamespace(app=app, instance=SimpleNamespace(pids=lambda: {42: "a", 7: "b"}))
        launch = self.perf_import.bench_launch()
        with mock.patch.object(launch, "lab_host_check", return_value={"ok": True}) as check:
            lab.launched(browser, self.out)
            lab.launched(browser, self.out)
        check.assert_called_once_with("/tmp/vd", [7, 42])
        self.assertEqual(calls, ["features.list"], "read once")
        self.assertEqual(lab.features, FEATURES)
        with open(os.path.join(self.out, f"{launch.LAB_CHECK_PREFIX}7.json")) as f:
            self.assertEqual(json.load(f), {"ok": True})

    def test_a_build_without_features_list_has_no_registry(self):
        app = SimpleNamespace(call=lambda *a, **kw: {"error": json.dumps({"code": "method_not_found"})})
        snapshot = self.perf_import.bench_launch().features_snapshot(xbench.features_reply(app))
        self.assertEqual(snapshot, ({}, None, None))
        app = SimpleNamespace(call=lambda *a, **kw: {"error": "features.list: [Errno 2] No such file"})
        self.assertIsNone(self.perf_import.bench_launch().features_snapshot(xbench.features_reply(app)))


class LabRunTests(unittest.TestCase):
    """xbench.Run in --perf-lab mode: fresh template profiles each run, and no run without every named arm."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.cmux = self.root / "cmux DEV t.app"
        self.cmux.mkdir()
        self.work = self.root / "work"
        patches = [mock.patch.object(xbench, "Helper"), mock.patch.object(xbench.pages, "BeaconServer")]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def tearDown(self):
        self.tmp.cleanup()

    def args(self, perf_lab=True, **changes):
        values = {"out": str(self.root / "out"), "work": str(self.work), "cache": str(self.root / "cache"),
                  "perf_lab": perf_lab, "app": [str(self.cmux)], "fetch": ["chrome"],
                  "browsers": "cmux-chromium,chrome",
                  "chrome_extension": [], "template_settle": 0.0, "cmux_ref": "", "tag": "t"}
        return SimpleNamespace(**{**values, **changes})

    def test_a_lab_run_never_clones_a_template_already_in_work(self):
        stale = self.work / "templates" / "chrome"
        stale.mkdir(parents=True)
        (stale / "Local State").write_text("an older build's profile")
        run = xbench.Run(self.args())
        self.assertNotEqual(Path(run.work), self.work)
        self.assertEqual(Path(run.work).parent, self.work)
        made = []
        run.make_template(SimpleNamespace(name="chrome", template=lambda path, settle: made.append(path)))
        self.assertEqual(made, [os.path.join(run.work, "templates", "chrome")], "the run made its own template")
        profile = run.profile(SimpleNamespace(name="chrome"), "launch1-0")
        self.assertFalse(os.path.exists(os.path.join(profile, "Local State")))
        with mock.patch.object(run, "measure"):
            run.main()
        self.assertFalse(os.path.exists(run.work), "the run's folder is gone after it")
        self.assertEqual(xbench.Run(self.args(perf_lab=False)).work, str(self.work), "a nightly run keeps --work")

    def test_a_template_that_fails_is_not_left_for_a_later_clone(self):
        run = xbench.Run(self.args())

        def broken(path, settle):
            Path(path, "half").write_text("x")
            raise RuntimeError("no DevTools port")

        with self.assertRaises(RuntimeError):
            run.make_template(SimpleNamespace(name="chrome", template=broken))
        self.assertFalse(os.path.exists(os.path.join(run.work, "templates", "chrome")))
        with mock.patch.object(run, "measure"):
            run.main()

    def test_a_lab_run_whose_chrome_fetch_fails_refuses_to_start(self):
        failed = mock.Mock(return_value=SimpleNamespace(stdout="fetch_browsers: chrome unavailable\n", returncode=1))
        timed_out = mock.Mock(side_effect=subprocess.TimeoutExpired(["fetch_browsers.py"], 3600))
        fetch = xbench.fetch
        for fetch_run in (failed, timed_out):
            run = xbench.Run(self.args())
            with mock.patch.object(xbench, "LabRecord") as record, \
                    mock.patch.object(xbench, "fetch", functools.partial(fetch, run=fetch_run)):
                with self.assertRaises(SystemExit) as ctx:
                    run.main()
            self.assertIn("no bundle for chrome", str(ctx.exception))
            record.assert_not_called()
            self.assertFalse(os.path.exists(run.work))
            self.assertFalse(os.path.exists(os.path.join(run.out, "meta.json")), "nothing measured")

    def test_a_lab_run_needs_the_reference_arm_and_a_nightly_run_skips_a_missing_arm(self):
        with mock.patch.object(xbench, "fetch", return_value={}):
            run = xbench.Run(self.args(browsers="cmux-chromium", fetch=[]))
            with self.assertRaises(SystemExit) as ctx:
                run.main()
            self.assertIn("no reference arm chrome", str(ctx.exception))
            self.assertEqual(xbench.Run(self.args(perf_lab=False)).arms(), {"cmux-chromium": str(self.cmux)})


class ImportXbenchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.db = store.Store(self.root / "lab.sqlite3")
        self.db.migrate()

    def tearDown(self):
        self.db.close()
        self.tmp.cleanup()

    def report(self, **changes):
        doc = {"date": "2026-10-20", "cmux_ref": SHA,
               "machine": {"host": "cmux20", "chip": "Apple M6", "ram_gb": 16, "macos": "27.0", "build": "26A425",
                           "displays": {"count": 1, "displays": [{"hz": 60.0}]}},
               "rows": {"launch-window": {"cmux-chromium": {"median": 310.0, "min": 300.0, "max": 400.0, "n": 6},
                                          "chrome": {"median": 620.0, "min": 600.0, "max": 700.0, "n": 6}},
                        "memory-1": {"chrome": {"median": 400.0, "n": 6}, "safari": {"median": None}},
                        "tab-switch-chromium-2-click": {"cmux-debug": {"median": 9.0, "p90": 12.0, "n": 5}}},
               "browsers": {"cmux-chromium": {"bundle": "/w/.build/perf-bench/cmux DEV perfbench.app",
                                              "version": "1.0.0"},
                            "chrome": {"bundle": "/c/apps/chrome/2026-10-20/Google Chrome.app",
                                       "version": "155.0.8059.85"},
                            "safari": {"bundle": "/Applications/Safari.app", "version": "27.0"}}}
        doc.update(changes)
        path = self.root / f"{doc.get('name', 'apple-m6-macos27')}.json"
        path.write_text(json.dumps(doc))
        return path

    def key(self, metric, engine="chromium", config="release"):
        return store.series_key(story="vs-browsers", metric=metric, engine=engine, host_class="xbench:apple-m6/16gb/60hz",
                                macos_major=27, build_config=config)

    def test_rows_become_legacy_points_under_the_lab_metric_names(self):
        report = import_xbench.import_xbench(self.db, [self.report()], commit_positions=POSITIONS.get)
        self.assertEqual(report.rejected, [])
        self.assertEqual(report.added_runs, 3)  # cmux-chromium, chrome, cmux-debug; safari measured nothing
        [cmux] = self.db.series_points(self.key("xbench.cmux-chromium.launch-window"))
        self.assertEqual((cmux.sha, cmux.commit_pos, cmux.samples), (SHA, 500, []))
        self.assertEqual({k: cmux.summary[k] for k in ("p50", "min", "max", "n")},
                         {"p50": 310.0, "min": 300.0, "max": 400.0, "n": 6})
        [memory] = self.db.series_points(self.key(f"xbench.{CHROME}.memory-1"))
        self.assertEqual(memory.summary["p50"], 400.0 * 1048576)
        [ratio] = self.db.series_points(self.key(f"xbench.cmux-chromium.launch-window.vs-{CHROME}"))
        self.assertEqual(ratio.summary["p50"], 0.5)
        [debug] = self.db.series_points(self.key("xbench.cmux-debug.tab-switch-chromium-2-click", "none", "debug"))
        self.assertEqual(debug.summary["p50"], 9.0)
        for point in (cmux, memory, ratio, debug):
            self.assertTrue(point.measure_version.startswith("legacy"))
            self.assertTrue(all(point.summary[flag] for flag in import_xbench.LEGACY_FLAGS))
        self.assertEqual(alerts.judged_points([cmux, memory, ratio, debug]), [])

    def test_an_arm_that_ran_the_nightly_binary_is_not_a_point_of_cmux_ref(self):
        nightly = {"bundle": "/c/apps/cmux-nightly/3946367535401/cmux NEXT.app",
                   "version": "1.0.0-nightly.3946367535401"}
        browsers = {"cmux-chromium": nightly, "chrome": {"bundle": "/c/Google Chrome.app", "version": "155.0.8059.85"}}
        report = import_xbench.import_xbench(self.db, [self.report(browsers=browsers)], commit_positions=POSITIONS.get)
        [refused] = report.rejected
        self.assertTrue(refused.source.endswith(" cmux-chromium"))
        self.assertIn("nightly-next binary 1.0.0-nightly.3946367535401", refused.reason)
        self.assertEqual(self.db.series_points(self.key("xbench.cmux-chromium.launch-window")), [])
        self.assertEqual(len(self.db.series_points(self.key(f"xbench.{CHROME}.launch-window"))), 1)

    def test_an_arm_the_browsers_block_does_not_name_is_refused(self):
        report = import_xbench.import_xbench(self.db, [self.report(browsers={})], commit_positions=POSITIONS.get)
        reasons = {r.source.rsplit(" ", 1)[1]: r.reason for r in report.rejected}
        self.assertEqual(sorted(reasons), ["chrome", "cmux-chromium"])
        self.assertIn("names no bundle", reasons["cmux-chromium"])
        self.assertIn("names no version", reasons["chrome"])
        self.assertEqual(report.added_runs, 1, "only the Debug matrix arm, a build of the checkout")

    def test_legacy_series_are_never_the_lab_bench_series(self):
        import_xbench.import_xbench(self.db, [self.report()], commit_positions=POSITIONS.get)
        lab_key = store.series_key(story="vs-browsers", metric="xbench.cmux-chromium.launch-window", engine="chromium",
                                   host_class=store.host_class(chip="Apple M6", memory_gb=16, display_hz=60),
                                   macos_major=27, build_config="bench")
        self.assertEqual(self.db.series_points(lab_key), [])

    def test_a_second_import_adds_nothing(self):
        path = self.report()
        import_xbench.import_xbench(self.db, [path], commit_positions=POSITIONS.get)
        again = import_xbench.import_xbench(self.db, [path], commit_positions=POSITIONS.get)
        self.assertEqual((again.added_runs, again.unchanged_runs, again.rejected), (0, 3, []))

    def test_bad_reports_are_rejected_with_a_reason(self):
        bad = [self.report(name="sha", cmux_ref="3330ea7"), self.report(name="date", date="yesterday"),
               self.report(name="host", machine={"host": "x"}), self.root / "missing.json"]
        unknown = self.report(name="unknown", rows={"launch-window": {"netscape": {"median": 1.0}}})
        report = import_xbench.import_xbench(self.db, [*bad, unknown], commit_positions=POSITIONS.get)
        reasons = {Path(r.source.split(" ")[0]).stem: r.reason for r in report.rejected}
        self.assertIn("not a full commit sha", reasons["sha"])
        self.assertIn("YYYY-MM-DD", reasons["date"])
        self.assertIn("display Hz", reasons["host"])
        self.assertIn("cannot read", reasons["missing"])
        self.assertIn("not an xbench browser", reasons["unknown"])
        self.assertEqual(report.added_runs, 0)
        off = import_xbench.import_xbench(self.db, [self.report()], commit_positions={}.get)
        self.assertIn("not in the lab's checkout", off.rejected[0].reason)

    def test_the_checked_in_baselines_import(self):
        files = import_xbench.baseline_files()
        self.assertEqual([p.name for p in files], ["apple-m4-pro-macos27.json", "apple-m6-macos27.json"])
        shas = {json.loads(p.read_text())["cmux_ref"] for p in files}
        positions = {sha: ingest.CommitPosition(1, mainline=True) for sha in shas}
        report = import_xbench.import_xbench(self.db, files, commit_positions=positions.get)
        # Both nights ran the nightly-next DMG as their cmux arms (browsers[cmux-*].bundle), not a build of cmux_ref.
        refused = sorted((Path(r.source.split(" ")[0]).stem, r.source.rsplit(" ", 1)[1]) for r in report.rejected)
        self.assertEqual(refused, [(p.stem, arm) for p in files
                                   for arm in ("cmux-chromium", "cmux-terminal", "cmux-webkit")])
        for rejection in report.rejected:
            self.assertIn("nightly-next binary 1.0.0-nightly.", rejection.reason)
        names = {row[0] for row in self.db._db.execute("SELECT metric FROM series")}
        self.assertFalse([n for n in names if n.startswith(("xbench.cmux-chromium.", "xbench.cmux-webkit."))])
        self.assertIn("xbench.chrome-155.0.8059.85.launch-window", names)
        self.assertGreater(report.added_results, 150)

    def test_lab_py_runs_the_command(self):
        lab = load("perf_lab_lab", PERF_LAB / "lab.py")
        self.assertIn("import-xbench", lab.discover())
        done = subprocess.run([sys.executable, "-I", str(PERF_LAB / "lab.py"), "import-xbench", "--help"],
                              capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 0, done.stderr)


class StoryTests(unittest.TestCase):
    def test_vs_browsers_is_a_clean_t2_story_bound_to_its_shards(self):
        loaded = catalog.load_catalog(ROOT)
        self.assertEqual([p for p in loaded.problems if "vs-browsers" in p], [])
        story = {s.id: s for s in loaded.stories}["vs-browsers"]
        self.assertEqual((story.tier, story.engine, story.config), ("T2", "chromium", "bench"))
        self.assertTrue(story.measurable())
        shard_map = (PERF_LAB / "shard_map.json").read_text()
        self.assertIn('"vs-browsers"', shard_map)

    def test_story_metric_patterns_cover_every_metric_the_arms_write(self):
        story = {s.id: s for s in catalog.load_catalog(ROOT).stories}["vs-browsers"]
        # The Home rows are the cmux-terminal arm's and the budget rows the cmux-budget arm's: neither runs here.
        samples = [sample(b, 1, row, 1.0) for b in ("cmux-chromium", "chrome")
                   for row in xbench.ROW_INFO if row not in xbench.budget.ROW_INFO and "home" not in row]
        for browser in ("cmux-chromium", "chrome"):
            for metric, unit, _better, _values in xbench.lab_series(samples, browser, VERSIONS):
                matched = [m for m in story.metrics if re.fullmatch(m.name, metric)]
                self.assertEqual(len(matched), 1, metric)
                self.assertEqual(matched[0].unit, unit, metric)


if __name__ == "__main__":
    unittest.main()
