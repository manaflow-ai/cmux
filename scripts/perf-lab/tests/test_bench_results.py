#!/usr/bin/env python3
"""bench_results.py (result-v1 for benches with no app, p12-perf-process-219), the webviews writer that pipes to it
(webviews/scripts/perf-result.mjs), the chat-load daemon stage's series, and the webviews stories they write.

  python3 -m unittest scripts/perf-lab/tests/test_bench_results.py
"""
from __future__ import annotations

import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
LAB = HERE.parent
ROOT = LAB.parent.parent


def load(name: str, path: Path):
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    return sys.modules[name]


bench_results = load("perf_lab_bench_results_under_test", LAB / "bench_results.py")
perf_result = bench_results.perf_result
ingest = load("perf_lab_ingest", LAB / "ingest.py")
catalog = load("perf_lab_catalog_under_test", LAB / "catalog.py")
daemon_bench = load("chat_load_daemon_bench_under_test",
                    ROOT / "webviews" / "scripts" / "agent-pane" / "chat-load" / "daemon_bench.py")

SHA = "a" * 40
CPUINFO = "processor\t: 0\nvendor_id\t: GenuineIntel\nmodel name\t: Intel(R) Xeon(R) CPU @ 2.20GHz\n"
SPEC = {"story": "webviews", "engine": "none",
        "results": [{"metric": "web.diff_stream.wall", "unit": "ms", "better": "lower", "samples": [12.5, 11.0]},
                    {"metric": "web.settings.toggle.bool.settings_list_reads", "unit": "count", "better": "lower",
                     "samples": [1, 1, 2]}]}


def fixed_host(**overrides):
    args = {"read_text": lambda path: CPUINFO, "system": "Linux", "release": "6.8.0", "cpu_count": 8,
            "memory_bytes": 32 * 2 ** 30}
    args.update(overrides)
    return bench_results.local_host(**args)


def story_metrics(story_id: str) -> list[tuple[re.Pattern, str]]:
    doc = json.loads((LAB / "stories.d" / f"{story_id}.json").read_text(encoding="utf-8"))
    return [(re.compile(metric["name"]), metric["unit"]) for metric in doc["metrics"]]


def claimed(story_id: str, metric: str, unit: str) -> bool:
    return any(pattern.fullmatch(metric) and want == unit for pattern, want in story_metrics(story_id))


class LocalHostTest(unittest.TestCase):
    def test_block_has_no_display_and_a_series_class_that_is_not_the_mac_form(self):
        host = fixed_host()
        self.assertEqual(host.chip, "Intel(R) Xeon(R) CPU @ 2.20GHz")
        self.assertEqual(host.host_class, "linux:intel-r-xeon-r-cpu-2-20ghz:8cpu:32gb")
        self.assertIsNone(host.macos)
        self.assertIsNone(host.display_hz)
        self.assertIsNone(ingest.MAC_CLASS.match(host.host_class))
        stored = ingest._store_host(host, "linux-lab")
        self.assertEqual(stored.host_class, host.host_class)

    def test_a_kernel_update_is_a_new_fingerprint_in_the_same_class(self):
        before, after = fixed_host(), fixed_host(release="6.9.1")
        self.assertNotEqual(before.fingerprint, after.fingerprint)
        self.assertEqual(before.host_class, after.host_class)
        self.assertEqual(before.fingerprint, fixed_host().fingerprint)

    def test_an_unreadable_chip_or_memory_refuses_instead_of_a_zero_series(self):
        with self.assertRaisesRegex(bench_results.BenchResultsError, "memory"):
            fixed_host(memory_bytes=0)
        unreadable = fixed_host(read_text=lambda path: (_ for _ in ()).throw(OSError("no /proc")))
        self.assertTrue(unreadable.chip)  # the platform's own name stands in

    def test_the_runner_host_file_wins_over_the_local_block(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "host.json"
            path.write_text(json.dumps(fixed_host(cpu_count=64).to_dict()), encoding="utf-8")
            host = bench_results.lab_host({"PERF_LAB_HOST_FILE": str(path)}, host=lambda: self.fail("local read"))
            self.assertEqual(host.host_class, "linux:intel-r-xeon-r-cpu-2-20ghz:64cpu:32gb")
            path.write_text("{}", encoding="utf-8")
            with self.assertRaisesRegex(bench_results.BenchResultsError, "not a host block"):
                bench_results.lab_host({"PERF_LAB_HOST_FILE": str(path)})


class BuildAndRunTest(unittest.TestCase):
    def test_build_reads_the_runner_variables_else_head_as_release(self):
        build = bench_results.lab_build({}, head=lambda: SHA)
        self.assertEqual((build.sha, build.config, build.measure_version), (SHA, "release", 1))
        build = bench_results.lab_build({"PERF_LAB_SHA": "b" * 40, "PERF_LAB_CONFIG": "bench",
                                         "PERF_LAB_MEASURE_VERSION": "2"}, head=lambda: self.fail("git read"))
        self.assertEqual((build.sha, build.config, build.measure_version), ("b" * 40, "bench", 2))
        with self.assertRaisesRegex(bench_results.BenchResultsError, "not an integer"):
            bench_results.lab_build({"PERF_LAB_MEASURE_VERSION": "two"}, head=lambda: SHA)

    def test_the_story_run_spans_processes_and_needs_both_variables(self):
        environ = {"PERF_LAB_RUN_ID": "abc123", "PERF_LAB_RUN_STARTED_AT": "2026-10-27T10:00:00Z"}
        own = {"id": "own", "started_at": "2026-10-27T09:00:00.000Z"}
        self.assertEqual(bench_results.lab_run(environ, own).to_dict(),
                         {"id": "abc123", "started_at": "2026-10-27T10:00:00Z"})
        self.assertEqual(bench_results.lab_run({}, own).to_dict(), own)
        self.assertTrue(bench_results.lab_run({}).id)
        with self.assertRaisesRegex(bench_results.BenchResultsError, "both"):
            bench_results.lab_run({"PERF_LAB_RUN_ID": "abc123"})


class RecordTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.out = Path(self.tmp.name) / "out"
        self.build = perf_result.Build(sha=SHA, config="release", measure_version=1)

    def record(self, spec=SPEC, **environ):
        return bench_results.record(spec, {"PERF_RESULT_DIR": str(self.out), **environ}, build=self.build,
                                    host=fixed_host())

    def test_unset_result_dir_writes_nothing(self):
        self.assertIsNone(bench_results.record(SPEC, {}, build=self.build, host=fixed_host()))
        self.assertFalse(self.out.exists())

    def test_writes_valid_result_v1_that_reads_back(self):
        path = self.record(PERF_LAB_SESSION="stress")
        results = perf_result.read_dir(self.out)
        self.assertEqual(path.parent, self.out)
        self.assertEqual([r.metric for r in results], ["web.diff_stream.wall", "web.settings.toggle.bool.settings_list_reads"])
        first = results[0]
        self.assertEqual((first.story, first.engine, first.session, first.samples), ("webviews", "none", "stress", [12.5, 11.0]))
        self.assertEqual(first.features, {})
        self.assertIsNone(first.safe_mode)
        self.assertEqual(results[0].run, results[1].run)

    def test_the_lab_story_replaces_the_bench_default(self):
        self.record(PERF_LAB_STORY="webviews-chromium")
        self.assertEqual({r.story for r in perf_result.read_dir(self.out)}, {"webviews-chromium"})

    def test_an_invalid_spec_or_result_writes_nothing(self):
        for spec, message in (({**SPEC, "results": []}, "empty"),
                              ({**SPEC, "extra": 1}, "unknown"),
                              ({**SPEC, "results": [{"metric": "web.x", "unit": "ms", "samples": [1]}]}, "exactly")):
            with self.subTest(message=message), self.assertRaisesRegex(bench_results.BenchResultsError, message):
                self.record(spec)
        with self.assertRaisesRegex(perf_result.ResultError, "unit"):
            self.record({**SPEC, "results": [{"metric": "web.x", "unit": "frames", "better": "lower", "samples": [1]}]})
        self.assertFalse(self.out.exists() and any(self.out.iterdir()))

    def test_cli_prints_the_path_and_exits_2_on_a_bad_spec(self):
        out = io.StringIO()
        environ = {"PERF_RESULT_DIR": str(self.out), "PERF_LAB_SHA": SHA}
        self.assertEqual(bench_results.main([], io.StringIO(json.dumps(SPEC)), out, environ), 0)
        self.assertTrue(Path(out.getvalue().strip()).is_file())
        self.assertEqual(bench_results.main([], io.StringIO("{"), io.StringIO(), environ), 2)
        unset = io.StringIO()
        self.assertEqual(bench_results.main([], io.StringIO(json.dumps(SPEC)), unset, {}), 0)
        self.assertEqual(unset.getvalue(), "")


@unittest.skipIf(shutil.which("node") is None, "node is not installed")
class WebviewsWriterTest(unittest.TestCase):
    """webviews/scripts/perf-result.mjs under node, as the .mjs benches run it (bun loads the same file)."""

    SCRIPT = """
import { perfSeries, recordPerfResults } from %s;
const path = recordPerfResults({
  story: "webviews",
  engine: "none",
  series: [perfSeries("web.diff_stream.wall", "ms", [3.5, null, 4]), perfSeries("web.diff_stream.app_render", "ms", [])],
});
process.stdout.write(JSON.stringify({ path: path ?? null }));
"""

    def run_node(self, environ):
        writer = ROOT / "webviews" / "scripts" / "perf-result.mjs"
        done = subprocess.run(["node", "--input-type=module", "-e", self.SCRIPT % json.dumps(writer.as_uri())],
                              capture_output=True, text=True, timeout=60, env=environ)
        self.assertEqual(done.returncode, 0, done.stderr)
        return json.loads(done.stdout)["path"]

    def test_writes_through_perf_result_and_skips_empty_series(self):
        with tempfile.TemporaryDirectory() as tmp:
            environ = {**os.environ, "PERF_RESULT_DIR": tmp, "PERF_LAB_SHA": SHA}
            for name in ("PERF_LAB_STORY", "PERF_LAB_RUN_ID", "PERF_LAB_RUN_STARTED_AT", "PERF_LAB_HOST_FILE"):
                environ.pop(name, None)
            path = self.run_node(environ)
            self.assertEqual(Path(path).parent, Path(tmp))
            [result] = perf_result.read_dir(tmp)
            self.assertEqual((result.metric, result.samples, result.build.sha), ("web.diff_stream.wall", [3.5, 4], SHA))

    def test_unset_result_dir_records_nothing(self):
        environ = {k: v for k, v in os.environ.items() if k != "PERF_RESULT_DIR"}
        self.assertIsNone(self.run_node(environ))


class ChatLoadDaemonTest(unittest.TestCase):
    RESULT = {"sessions": [
        {"turns": 100, "open_bytes": 4096, "scroll_to_first": {"pages": 0, "bytes": 0, "records": 0, "wall_ms": 0}},
        {"turns": 1000, "open_bytes": 131072,
         "scroll_to_first": {"pages": 3, "bytes": 700000, "records": 900, "unique": True, "wall_ms": 40.5,
                             "cpu_ms": 30.0, "read_mb": 0.7, "peak_extra_mb": 2.5}}],
        "rss_mb": 48.0}
    RUNS = {100: [{"wall_ms": 5.0, "cpu_ms": 4.0, "read_mb": 0.01, "peak_extra_mb": 0.5}] * 3,
            1000: [{"wall_ms": 9.0, "cpu_ms": 7.0, "read_mb": 0.2, "peak_extra_mb": 1.0}] * 3}

    def test_every_series_is_one_the_daemon_story_claims(self):
        series = daemon_bench.perf_series(self.RUNS, self.RESULT)
        names = {entry["metric"] for entry in series}
        self.assertIn("web.chat_load.daemon.t1000.scroll.pages", names)
        self.assertNotIn("web.chat_load.daemon.t100.scroll.wall", names)  # nothing to page back through
        self.assertEqual(next(e for e in series if e["metric"] == "web.chat_load.daemon.t100.open.read")["samples"],
                         [10000.0] * 3)
        for entry in series:
            with self.subTest(metric=entry["metric"]):
                self.assertTrue(claimed("webviews-chat-load-daemon", entry["metric"], entry["unit"]))

    def test_records_only_with_a_result_dir(self):
        series = daemon_bench.perf_series(self.RUNS, self.RESULT)
        self.assertIsNone(daemon_bench.record_perf_results(series, {}))
        with tempfile.TemporaryDirectory() as tmp:
            path = daemon_bench.record_perf_results(series, {"PERF_RESULT_DIR": tmp, "PERF_LAB_SHA": SHA})
            results = perf_result.read_dir(tmp)
            self.assertEqual(Path(path).parent, Path(tmp))
            self.assertEqual({r.story for r in results}, {"webviews-chat-load-daemon"})
            self.assertEqual(len(results), len(series))


class StoriesTest(unittest.TestCase):
    WEB_STORIES = ("webviews", "webviews-chromium", "webviews-chat-load-daemon", "webviews-chat-load",
                   "webviews-chat-load-webkit", "webviews-switch-intent", "webviews-switch-intent-webkit")

    def test_the_webviews_stories_lint_clean_and_only_the_two_runnable_ones_are_measurable(self):
        loaded = catalog.load_catalog(ROOT)
        stories = {story.id: story for story in loaded.stories}
        problems = [p for p in loaded.problems if any(f"/{s}.json" in p for s in self.WEB_STORIES)]
        self.assertEqual(problems, [])
        self.assertEqual({s for s in self.WEB_STORIES if stories[s].measurable()}, {"webviews", "webviews-chromium"})
        for story_id in self.WEB_STORIES:
            self.assertEqual(stories[story_id].tier, "linux")
            self.assertTrue(all(m.name.startswith("web\\.") for m in stories[story_id].metrics))

    def test_the_story_command_takes_the_runner_flags(self):
        script = (ROOT / "webviews" / "scripts" / "perf-lab-story.sh").read_text(encoding="utf-8")
        for flag in ("--app", "--tag", "--out", "PERF_RESULT_DIR", "perf_result"):
            self.assertIn(flag, script)
        done = subprocess.run(["bash", str(ROOT / "webviews" / "scripts" / "perf-lab-story.sh"), "--engine", "webkit",
                               "--out", tempfile.gettempdir()], capture_output=True, text=True, timeout=30)
        self.assertEqual(done.returncode, 2)
        self.assertIn("none or chromium", done.stderr)

    def test_the_bench_metric_names_are_claimed_by_their_story(self):
        """The names the TypeScript and node benches build, as literal examples of each template."""
        examples = {
            "webviews": [("web.diff_stream.first_batch", "ms"), ("web.settings.open.general.first_frame", "ms"),
                         ("web.settings.set.fontSize.wall", "ms"),
                         ("web.settings.section.switch.hoverClick.shown_incomplete", "count"),
                         ("web.settings.search.keystroke.components_rendered", "count"),
                         ("web.settings.open.theme.no_first_frame", "count"),
                         ("web.ordered_rows.turn_view", "ms"), ("web.icon_picker.symbol_keystroke", "ms"),
                         ("web.icon_picker.configure", "ms")],
            "webviews-chromium": [("web.chat_open.loaded_cached.draw", "ms"),
                                  ("web.chat_open.quiet_cold.draw_frames", "count"),
                                  ("web.chat_open.loaded_cold.never_drawn", "count"),
                                  ("web.diff_paint.huge.first_highlight", "ms")],
            "webviews-chat-load": [("web.chat_load.open.t10000.first_paint", "ms"),
                                   ("web.chat_load.switch.t100.heap", "bytes"),
                                   ("web.chat_load.mock.default.utf16_in", "count"),
                                   ("web.chat_load.mock.t1000.scroll.wall", "ms"),
                                   ("web.chat_load.switch.t1000.timed_out", "count")],
            "webviews-chat-load-webkit": [("web.chat_load.open.t100.interactive", "ms"),
                                          ("web.chat_load.mock.default.timed_out", "count")],
            "webviews-switch-intent": [("web.switch_intent.codex.repeat.paint", "ms"),
                                       ("web.switch_intent.claude_sr.first.reply", "ms"),
                                       ("web.switch_intent.claude_sr.first.timed_out", "count")],
            "webviews-switch-intent-webkit": [("web.switch_intent.codex.first.ready", "ms")],
        }
        for story_id, metrics in examples.items():
            for metric, unit in metrics:
                with self.subTest(story=story_id, metric=metric):
                    self.assertTrue(re.fullmatch(perf_result.NAME_PATTERN, metric))
                    self.assertTrue(claimed(story_id, metric, unit))


if __name__ == "__main__":
    unittest.main()
