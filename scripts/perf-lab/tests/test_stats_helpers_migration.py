"""Bench migration p12-perf-process-069: the benches outside scripts/cmux-next use perf_stats and write result-v1.

browser_engine_bench.py, perf-10x-drag-daemon.py, frame-probe-tui.py and measure-frames.py had their own
percentile functions. They now load scripts/perf-lab/perf_import.py by file path, take perf_stats from it, and
write their raw samples as cmux-perf-result/v1 (perf_import.write_series, or BenchApp.record in measure-frames).
The old definitions are copied here only to record old against new on one fixed vector (p12-perf-process.md R8).

Run: python3 -m unittest scripts/perf-lab/tests/test_stats_helpers_migration.py
"""

import contextlib
import importlib.util
import io
import json
import os
import re
import statistics
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
PERF_LAB = os.path.join(ROOT, "scripts", "perf-lab")

FILES = {
    "browser_engine_bench": "scripts/perf/browser_engine_bench.py",
    "perf_10x_drag_daemon": "scripts/measure/perf-10x-drag-daemon.py",
    "frame_probe_tui": "scripts/frame-probe-tui.py",
    "measure_frames": "cmux-tui/scripts/measure-frames.py",
}
# Each bench's story (scripts/perf-lab/stories.d); frame-probe-tui is a manual probe with no story.
STORIES = {
    "perf_10x_drag_daemon": ["drag-daemon"],
    "measure_frames": ["tui-browser-frames"],
    "browser_engine_bench": ["browser-engine-webkit", "browser-engine-chromium"],
}

VECTOR = [3.1, 4.0, 4.2, 5.5, 6.0, 7.9, 8.3, 9.0, 12.4, 20.1]


def load(name, rel):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, os.path.join(ROOT, rel))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # before exec: a dataclass resolves its module through sys.modules
    spec.loader.exec_module(module)
    return module


queues = load("perf_lab_queues", "scripts/perf-lab/queues.py")
perf_import = load("perf_import", "scripts/perf-lab/perf_import.py")
perf_stats = perf_import.load("perf_stats")
perf_result = perf_import.load("perf_result")
bench_launch = perf_import.bench_launch()

BUILD = perf_result.Build(sha="a" * 40, config="bench", measure_version=2)
HOST = perf_result.Host("ab" * 32, "linux-test", "test chip", None, None, None)


def old_linear(values, p):
    """browser_engine_bench.stats' inner pct and frame-probe-tui's percentile (same definition)."""
    ordered = sorted(values)
    idx = (len(ordered) - 1) * p
    lo = int(idx)
    hi = min(lo + 1, len(ordered) - 1)
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (idx - lo)


def old_rounded_rank(values, p):
    """perf-10x-drag-daemon's pct and measure-frames' percentile (p as a fraction here)."""
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round((len(ordered) - 1) * p)))]


def story_metrics(story):
    with open(os.path.join(PERF_LAB, "stories.d", f"{story}.json")) as handle:
        doc = json.load(handle)
    return doc, [(re.compile(m["name"]), m["unit"], m["better"]) for m in doc["metrics"]]


class MigratedFilesTest(unittest.TestCase):
    def test_corrected_mq1_lists_none_of_the_files(self):
        hits = sorted(item.where for item in queues._private_stat_hits(ROOT) if item.key in FILES.values())
        self.assertEqual(hits, [])
        self.assertFalse(set(FILES.values()) & {item.key for item in queues.private_stats(ROOT)})

    def test_each_file_shares_the_perf_stats_module(self):
        for name, rel in FILES.items():
            with self.subTest(rel):
                self.assertIs(load(name, rel).perf_stats, perf_stats)

    def test_each_file_runs_help_under_isolated_python(self):
        for rel in FILES.values():
            with self.subTest(rel):
                argv = [sys.executable, "-I", os.path.join(ROOT, rel)]
                argv += ["run", "--help"] if rel.endswith("browser_engine_bench.py") else ["--help"]
                run = subprocess.run(argv, capture_output=True, text=True, cwd="/", timeout=60)
                self.assertEqual(run.returncode, 0, run.stderr)
                self.assertIn("usage:", run.stdout)

    def test_each_story_names_its_bench_and_an_owner(self):
        for name, stories in STORIES.items():
            for story in stories:
                with self.subTest(story):
                    doc, _ = story_metrics(story)
                    self.assertEqual(doc["command"][0], FILES[name])
                    self.assertTrue(doc["owner"])


class SharedLoaderTest(unittest.TestCase):
    """perf_import.load_by_path behaves as bench_launch.load_by_path: registered before exec, removed on failure."""

    def check_loader(self, loader):
        with tempfile.TemporaryDirectory() as folder:
            good = os.path.join(folder, "good.py")
            with open(good, "w") as handle:
                handle.write("import sys\nSEEN_DURING_EXEC = sys.modules.get(__name__) is not None\n")
            bad = os.path.join(folder, "bad.py")
            with open(bad, "w") as handle:
                handle.write("raise ValueError('boom')\n")
            name = f"p069_loader_{id(loader)}"
            try:
                module = loader(name, good)
                self.assertTrue(module.SEEN_DURING_EXEC)
                self.assertIs(loader(name, bad), module)  # once per process: the name is taken
                with self.assertRaises(ValueError):
                    loader(name + "_bad", bad)
                self.assertNotIn(name + "_bad", sys.modules)
            finally:
                sys.modules.pop(name, None)

    def test_perf_import_and_bench_launch_loaders_agree(self):
        self.check_loader(perf_import.load_by_path)
        self.check_loader(bench_launch.load_by_path)

    def test_missing_file_raises_import_error_naming_it(self):
        with self.assertRaises((ImportError, FileNotFoundError)):
            perf_import.load_by_path("p069_missing", os.path.join(PERF_LAB, "no_such_module.py"))
        self.assertNotIn("p069_missing", sys.modules)


class OldAgainstNewTest(unittest.TestCase):
    """Old and new values on VECTOR, as recorded in the commit message, through each file's own report code."""

    def test_browser_engine_bench_stats_keys_and_values_unchanged(self):
        bench = load("browser_engine_bench", FILES["browser_engine_bench"])
        got = bench.stats(VECTOR)
        self.assertEqual(list(got), ["n", "mean", "p50", "p95", "p99", "max"])
        self.assertEqual(got, {
            "n": 10,
            "mean": round(statistics.mean(VECTOR), 3),
            "p50": round(old_linear(VECTOR, 0.5), 3),
            "p95": round(old_linear(VECTOR, 0.95), 3),
            "p99": round(old_linear(VECTOR, 0.99), 3),
            "max": 20.1,
        })
        self.assertEqual((got["p50"], got["p95"], got["p99"]), (6.95, 16.635, 19.407))
        self.assertEqual(bench.stats([]), {})

    def test_frame_probe_summary_unchanged(self):
        probe = load("frame_probe_tui", FILES["frame_probe_tui"])
        frames = probe.FrameStats(hz=120.0, history_limit=100)
        now = 0
        frames.record_frame(now)
        for gap_ms in VECTOR:
            now += int(gap_ms * 1_000_000)
            frames.record_frame(now)
        summary = frames.summary()
        gaps = list(frames.gaps_ms)
        self.assertAlmostEqual(summary["p95_gap_ms"], old_linear(gaps, 0.95), places=9)
        self.assertAlmostEqual(summary["p99_gap_ms"], old_linear(gaps, 0.99), places=9)
        empty = probe.FrameStats(hz=120.0, history_limit=100).summary()
        self.assertEqual((empty["p95_gap_ms"], empty["p99_gap_ms"]), (0.0, 0.0))

    def test_drag_daemon_line_keeps_its_keys_and_adds_p99(self):
        # rtt_p50/p95 were a rounded rank: p50 6.0 -> 6.95 (round(4.5) is 4), p95 20.1 -> 16.635; p99 is new.
        drag = load("perf_10x_drag_daemon", FILES["perf_10x_drag_daemon"])
        times = [v / 1000 for v in VECTOR]  # seconds, as the bench times them
        line = drag.drag_line("set-split-ratio", times, 0.5, 1)
        self.assertEqual(line, "DRAG-DAEMON cmd=set-split-ratio n=10 rtt_p50_ms=6.950 rtt_p95_ms=16.635"
                               " rtt_p99_ms=19.407 rtt_max_ms=20.100 per_s=20.0 errors=1")
        self.assertEqual((old_rounded_rank(VECTOR, 0.5), old_rounded_rank(VECTOR, 0.95)), (6.0, 20.1))

    def test_measure_frames_lines_keep_their_keys_and_add_p99(self):
        # median was statistics.median (equal to pct 0.5); p95 was a rounded rank of percent 95: 20.1 -> 16.635.
        frames = load("measure_frames", FILES["measure_frames"])
        sizes = [int(v * 1000) for v in VECTOR]
        gaps = [v / 1000 for v in VECTOR]  # seconds, as the bench times them
        self.assertEqual(frames.frame_report_lines(sizes, gaps), [
            "frame_bytes: median=6950 p95=16635 p99=19407 max=20100",
            "inter_frame_gap_ms: median=7.0 p95=16.6 p99=19.4 max=20.1",
        ])
        self.assertEqual(statistics.median(VECTOR), 6.95)
        self.assertEqual(old_rounded_rank(VECTOR, 0.95), 20.1)
        self.assertEqual(frames.frame_report_lines([], []), [])


class ResultV1Test(unittest.TestCase):
    """Each bench's series are valid result-v1, and every metric is one its story claims with the same unit."""

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="p069-")

    def assert_claimed(self, story, series):
        _, claims = story_metrics(story)
        for item in series:
            with self.subTest(story=story, metric=item.metric):
                matched = [(unit, better) for pattern, unit, better in claims if pattern.fullmatch(item.metric)]
                self.assertEqual(matched, [(item.unit, item.better)])

    def write_and_read(self, story, engine, series, features=None):
        path = perf_import.write_series(self.dir, story, "light", engine, series, BUILD, HOST, features=features)
        return perf_result.read_file(path)

    def test_drag_daemon_series(self):
        drag = load("perf_10x_drag_daemon", FILES["perf_10x_drag_daemon"])
        series = []
        for name in drag.CASES:
            series += drag.drag_series(name, [v / 1000 for v in VECTOR], 0.5, 0)
        self.assert_claimed("drag-daemon", series)
        results = self.write_and_read("drag-daemon", "none", series)
        rtt = {r.metric: r.samples for r in results}["drag_daemon.set-split-ratio.rtt"]
        self.assertEqual([round(v, 9) for v in rtt], VECTOR)  # raw ms samples, not a summary
        self.assertEqual(len({r.run.id for r in results}), 1)

    def test_measure_frames_series(self):
        frames = load("measure_frames", FILES["measure_frames"])
        series = frames.frame_series(59.5, [100, 200], [v / 1000 for v in VECTOR], None)
        self.assert_claimed("tui-browser-frames", [s for s in series if s.samples])
        results = self.write_and_read("tui-browser-frames", frames.ENGINE, series)
        self.assertEqual(sorted(r.metric for r in results), [
            "tui_browser_frames.fps", "tui_browser_frames.frame_bytes", "tui_browser_frames.inter_frame_gap"])

    def test_frame_probe_series(self):
        probe = load("frame_probe_tui", FILES["frame_probe_tui"])
        stats = probe.FrameStats(hz=120.0, history_limit=2)
        notify = probe.NotifyState(completed=3, failed=1, max_ms=42.0)
        series = probe.probe_series(stats, list(VECTOR), notify)
        results = self.write_and_read(probe.STORY, "none", series)
        by_metric = {r.metric: r.samples for r in results}
        self.assertEqual(by_metric["frame_probe_tui.gap"], VECTOR)  # every gap, not the --history window
        self.assertEqual(by_metric["frame_probe_tui.notify_max"], [42.0])
        no_burst = {s.metric for s in probe.probe_series(stats, [1.0], None)}
        self.assertNotIn("frame_probe_tui.notify_max", no_burst)

    def test_frame_probe_result_dir_needs_headless_and_app(self):
        probe = load("frame_probe_tui", FILES["frame_probe_tui"])
        for argv in (["--result-dir", self.dir], ["--result-dir", self.dir, "--headless", "1"]):
            with self.subTest(argv), self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
                probe.parse_args(argv)

    def test_browser_engine_series_per_arm(self):
        bench = load("browser_engine_bench", FILES["browser_engine_bench"])
        for engine in ("webkit", "chromium"):
            with self.subTest(engine):
                report = {
                    "launch": {"idle": {"app_footprint_bytes": 1000}, "idle_cpu_percent": {"app": 1.0, engine: 0.5}},
                    "engines": {engine: {"first_page_load_ms": 30.0, "memory_per_tab_bytes": {"total": 4096},
                                         "cpu_percent_one_visible": {"app": 2.0, engine: 3.0}}},
                }
                raw = {"launch": [500.0, 510.0], "key_no_browser": list(VECTOR), f"{engine}.loads": [30.0, 10.0, 11.0],
                       f"{engine}.opens": [1.0, 2.0, 3.0], f"{engine}.keys": list(VECTOR)}
                series = bench.run_series(report, raw, engine)
                self.assert_claimed(bench.STORIES[engine], series)
                features = ({"perf.example": {"state": "on", "source": "default"}}, "f" * 8, "off")
                results = self.write_and_read(bench.STORIES[engine], engine, series, features=features)
                by_metric = {r.metric: r for r in results}
                self.assertEqual(by_metric[f"browser_engine.{engine}.warm_page_load"].samples, [10.0, 11.0])
                self.assertEqual(by_metric[f"browser_engine.{engine}.cpu_one_visible"].samples, [5.0])
                self.assertEqual(by_metric["browser_engine.idle.cpu"].samples, [1.5])
                self.assertEqual(by_metric["browser_engine.launch.socket_ready"].features_hash, "f" * 8)

    def test_browser_engine_failed_arm_writes_only_what_it_measured(self):
        bench = load("browser_engine_bench", FILES["browser_engine_bench"])
        series = bench.run_series({"launch": {}, "engines": {"webkit": {"error": "boom"}}},
                                  {"launch": [500.0]}, "webkit")
        results = self.write_and_read("browser-engine-webkit", "webkit", series)
        self.assertEqual([r.metric for r in results], ["browser_engine.launch.socket_ready"])

    def test_browser_engine_out_is_a_report_file_or_a_folder(self):
        bench = load("browser_engine_bench", FILES["browser_engine_bench"])
        self.assertEqual(bench.out_paths(None, "t"), (None, None))
        report, results = bench.out_paths("/x/run.json", "t")
        self.assertEqual((str(report), results), ("/x/run.json", None))
        report, results = bench.out_paths("/x/run", "t")
        self.assertEqual((str(report), str(results)), ("/x/run/browser-engine-t.json", "/x/run"))


if __name__ == "__main__":
    unittest.main()
