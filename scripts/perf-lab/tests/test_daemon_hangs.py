"""Tests for scripts/perf-lab/stories/daemon_hangs.py (story daemon-hangs, task p12-perf-process-232).

Run: python3 -m unittest scripts/perf-lab/tests/test_daemon_hangs.py
"""

import functools
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import types
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
PERF_LAB = HERE.parent
REPO_ROOT = HERE.parents[2]
STORY_FILE = PERF_LAB / "stories.d" / "daemon-hangs.json"


def load(name, path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


dh = load("daemon_hangs_under_test", PERF_LAB / "stories" / "daemon_hangs.py")
writer = load("perf_result", PERF_LAB / "perf_result.py")
catalog = load("perf_lab_catalog", PERF_LAB / "catalog.py")
bh = dh.blocking_hangs


def reading(over_250ms, records=()):
    return bh.DaemonReading(over_250ms, tuple(records))


def hang(sequence, span="mux-conn:workspace.create", duration_ms=300):
    return {"sequence": sequence, "span": span, "duration_ms": duration_ms}


STRESS_META = {"errors": [], "timed_out": [], "stress": {"workspaces": 40}, "storm_ops": {"move": 75},
               "scenario_label": "stress-storm"}


class FakeBench:
    """BenchApp's record contract: build, host and run filled in, one file per record() in `out`."""

    def __init__(self, out):
        self.out = out
        self.perf_session = "light"
        self.build_config = None
        self.run = writer.Run.start(run_id="run-1")

    def record(self, story, metric, unit, samples, better, engine, target_ref=None):
        if isinstance(target_ref, str):
            target_ref = writer.TargetRef(target=target_ref)
        result = writer.Result(
            story=story, metric=metric, unit=unit, better=better, samples=list(samples),
            build=writer.Build(sha="0123456789abcdef0123456789abcdef01234567", config=self.build_config,
                               measure_version=2),
            host=writer.Host(fingerprint="ab" * 32, host_class="apple-m4-pro/24gb/120hz", chip="Apple M4 Pro",
                             macos="26.0", macos_build="25A100", display_hz=120.0),
            engine=engine, session=self.perf_session, run=self.run, target_ref=target_ref)
        return writer.write_ndjson(self.out, [result], repo_root=REPO_ROOT)


class FakeProbe:
    """DaemonProbe's read(): the readings in order."""

    def __init__(self, readings):
        self.readings = list(readings)

    def read(self):
        return self.readings.pop(0)


class Story(unittest.TestCase):
    def setUp(self):
        self.out = tempfile.mkdtemp(prefix="daemon-hangs-test-")
        self.addCleanup(shutil.rmtree, self.out, True)

    def run_main(self, storm, argv=()):
        def runner(app, work, session, seconds):
            self.assertEqual((app, session, seconds), ("/tmp/cmux DEV t.app", "stress", 60))
            if storm.bench is True:
                storm.bench = FakeBench(work)
            return storm

        code = dh.main(["--app", "/tmp/cmux DEV t.app", "--out", self.out, *argv], environ={}, storm_runner=runner)
        with open(os.path.join(self.out, dh.SUMMARY), encoding="utf-8") as f:
            return code, json.load(f)

    def results(self):
        paths = sorted(Path(self.out).glob("*.ndjson"))
        return {r.metric: r for path in paths for r in writer.read_file(path)}

    def test_a_300ms_hang_in_the_window_is_one(self):
        storm = dh.Storm(before=reading(2, [hang(1), hang(2)]), after=reading(3, [hang(1), hang(2), hang(3)]),
                         meta=dict(STRESS_META), bench=True)
        code, summary = self.run_main(storm)
        self.assertEqual(code, dh.EXIT_OK, summary)
        results = self.results()
        self.assertEqual(results[dh.COUNT_METRIC].samples, [1])
        self.assertEqual(results[dh.COUNT_METRIC].target_ref.target, "hangs.daemon")
        self.assertEqual(results[dh.COUNT_METRIC].build.config, "bench")
        self.assertEqual(results[dh.COUNT_METRIC].session, "stress")
        self.assertEqual(results[dh.DURATION_METRIC].samples, [300])
        self.assertEqual(summary["window"]["records"], [hang(3)])
        self.assertEqual(len(list(Path(self.out).glob("*.ndjson"))), 1, "one result file")

    def test_a_quiet_window_stores_zero_and_no_duration(self):
        storm = dh.Storm(before=reading(0), after=reading(0), meta=dict(STRESS_META), bench=True)
        code, summary = self.run_main(storm)
        self.assertEqual(code, dh.EXIT_OK, summary)
        self.assertEqual({m: r.samples for m, r in self.results().items()}, {dh.COUNT_METRIC: [0]})

    def test_a_daemon_without_the_section_is_not_measurable(self):
        unseen = bh.DaemonReading(None, reason="no `hangs` section")
        storm = dh.Storm(before=unseen, after=unseen, meta=dict(STRESS_META), bench=True)
        code, summary = self.run_main(storm)
        self.assertEqual(code, dh.EXIT_NOT_MEASURABLE)
        self.assertIn("no `hangs` section", summary["reason"])
        self.assertEqual(self.results(), {}, "never stored as 0")

    def test_a_restarted_daemon_is_not_measurable(self):
        storm = dh.Storm(before=reading(5), after=reading(1), meta=dict(STRESS_META), bench=True)
        code, summary = self.run_main(storm)
        self.assertEqual(code, dh.EXIT_NOT_MEASURABLE, summary)
        self.assertEqual(self.results(), {})

    def test_a_window_that_was_not_the_storm_fails(self):
        meta = dict(STRESS_META, errors=[{"stage": "window", "error": "boom"}])
        storm = dh.Storm(before=reading(0), after=reading(0), meta=meta, bench=True)
        code, summary = self.run_main(storm)
        self.assertEqual(code, dh.EXIT_FAILED)
        self.assertIn("window: boom", summary["reason"])
        self.assertEqual(self.results(), {})

    def test_a_signal_passes_its_exit_through(self):
        storm = dh.Storm(meta=dict(STRESS_META), terminated=143)
        code, _summary = self.run_main(storm)
        self.assertEqual(code, 143)

    def test_an_unknown_session_is_usage(self):
        code = dh.main(["--app", "a", "--out", self.out, "nightly"], environ={}, storm_runner=None)
        self.assertEqual(code, dh.EXIT_USAGE)


class RunStorm(unittest.TestCase):
    """run_storm over a stand-in trace.py: the daemon is read right before and right after run_window."""

    def test_reads_around_the_window(self):
        order = []
        module = types.ModuleType("cmux_next_trace")

        class Stages:
            def __init__(self, meta):
                meta.setdefault("errors", [])

        class Recording:
            def __init__(self, opts, out, meta, stages, bundle, recorder):
                self.opts, self.meta, self.recorder = opts, meta, recorder
                self.rpc = object()
                self.app = types.SimpleNamespace(bench="bench")
                self.terminated = None

            def run_window(self):
                order.append("window")

            def record(self):
                assert self.recorder == "none" and self.opts.scenario == "light-storm"
                self.run_window()

        module.Stages, module.Recording = Stages, Recording

        class Probe:
            def __init__(self, rpc):
                self.readings = [reading(1), reading(2)]

            def read(self):
                order.append("read")
                return self.readings.pop(0)

        saved = sys.modules.get("cmux_next_trace")
        sys.modules["cmux_next_trace"] = module
        try:
            storm = dh.run_storm("/tmp/a.app", tempfile.gettempdir(), "light", 30, probe_for=Probe)
        finally:
            if saved is None:
                sys.modules.pop("cmux_next_trace", None)
            else:
                sys.modules["cmux_next_trace"] = saved
        self.assertEqual(order, ["read", "window", "read"])
        self.assertEqual((storm.before.over_250ms, storm.after.over_250ms, storm.bench), (1, 2, "bench"))
        self.assertIsNone(storm.terminated)


class Catalog(unittest.TestCase):
    def test_story_file_passes_the_lint_and_claims_the_daemon_target(self):
        loaded = catalog.load_catalog(REPO_ROOT)
        self.assertEqual([p for p in loaded.problems if "daemon-hangs" in p], [])
        self.assertIn("daemon-hangs", {s.id for s in loaded.stories})
        claims = catalog.claimed_checks(loaded)
        self.assertIn("daemon-hangs", claims[("hangs.daemon", "daemon\\.hangs_over_250ms")])

    def test_the_metric_names_match_the_story(self):
        doc = json.loads(STORY_FILE.read_text(encoding="utf-8"))
        import re
        names = [m["name"] for m in doc["metrics"]]
        for metric in (dh.COUNT_METRIC, dh.DURATION_METRIC):
            self.assertTrue(any(re.fullmatch(name, metric) for name in names), metric)
        self.assertEqual(doc["config"], dh.CONFIG)


if __name__ == "__main__":
    unittest.main()
