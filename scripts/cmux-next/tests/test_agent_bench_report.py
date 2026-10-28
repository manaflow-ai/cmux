#!/usr/bin/env python3
"""The agent and Home benches' statistics and result-v1 series (agent_bench_report.py, p12-perf-process-057): the
perf_stats percentiles against the private ones they replace, the report keys the benches kept, the names the lab
stories claim, the story and engine checks of the CLIs, and one run's series written through perf_result.

Runs on any host (Linux included): no app, no daemon, no fleet, no network.

    python3 -m unittest scripts/cmux-next/tests/test_agent_bench_report.py
"""

from __future__ import annotations

import importlib.util
import io
import json
import re
import statistics
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from contextlib import redirect_stderr
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
ROOT = HERE.parent.parent
STORIES = ROOT / "scripts/perf-lab/stories.d"
sys.path.insert(0, str(HERE))
import agent_bench_report as report  # noqa: E402
import bench_launch  # noqa: E402

pr = report.perf_result
BENCHES = ("acpmux-overhead-bench.py", "agent-engine-bench.py", "agent-stream-e2e.py", "home-perf.py")
VECTOR = [3.1, 4.0, 4.2, 5.5, 6.0, 7.9, 8.3, 9.0, 12.4, 20.1]
SHA = "a" * 40
HOST = pr.Host.from_dict(bench_launch.host_record("Apple M4", 16 * 2**30, "26.1", "25B78", 60))
BUILD = pr.Build(sha=SHA, config="bench", measure_version=bench_launch.PERF_LAB_MEASURE_VERSION)


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


acpmux_bench = load("acpmux_overhead_bench", HERE / "acpmux-overhead-bench.py")
stream_bench = load("agent_stream_e2e", HERE / "agent-stream-e2e.py")


# The private statistics the four benches had before the migration (R8: old and new on one fixed vector).
def old_acpmux_pct(xs, q):  # acpmux-overhead-bench.py pct
    xs = sorted(xs)
    k = (len(xs) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return round(xs[lo] + (xs[hi] - xs[lo]) * (k - lo), 1)


def old_engine_median(values):  # agent-engine-bench.py median
    return round(statistics.median([v for v in values if v is not None]), 1)


def old_stream_median(values):  # agent-stream-e2e.py median
    return round(statistics.median(values), 2)


def old_home_key_dispatch(trips):  # home-perf.py typing()
    trips = sorted(trips)
    return {"count": len(trips), "p50": round(statistics.median(trips), 2),
            "p95": round(trips[int(len(trips) * 0.95) - 1], 2), "max": round(trips[-1], 2)}


def story_metrics(story_id):
    doc = json.loads((STORIES / f"{story_id}.json").read_text())
    return doc, [(re.compile(m["name"]), m["unit"]) for m in doc["metrics"]]


class StoryMatch(unittest.TestCase):
    def assert_claimed(self, story_id, entries):
        """Every series is in `story_id` and its metric full-matches exactly one of the story's metrics, unit too."""
        _, metrics = story_metrics(story_id)
        self.assertTrue(entries)
        for entry in entries:
            self.assertEqual(entry.story, story_id)
            claims = [unit for pattern, unit in metrics if pattern.fullmatch(entry.metric)]
            self.assertEqual(len(claims), 1, f"{entry.metric}: {len(claims)} story metrics claim it")
            self.assertEqual(claims[0], entry.unit, entry.metric)
            self.assertTrue(entry.samples, entry.metric)


class PercentileMigrationTests(unittest.TestCase):
    """Old and new values on VECTOR (the commit message lists them)."""

    def test_acpmux_pct_was_already_linear_interpolation(self):
        for q in (0.5, 0.95):
            self.assertEqual(report.pct(VECTOR, q, 1), old_acpmux_pct(VECTOR, q))
        self.assertEqual((report.pct(VECTOR, 0.5, 1), report.pct(VECTOR, 0.95, 1), report.pct(VECTOR, 0.99, 1)),
                         (7.0, 16.6, 19.4))

    def test_medians_equal_statistics_median(self):
        self.assertEqual(report.median(VECTOR + [None]), old_engine_median(VECTOR + [None]))
        self.assertEqual(report.median(VECTOR, 2), old_stream_median(VECTOR))
        self.assertEqual(report.median([]), None)

    def test_home_key_dispatch_moves_from_a_floor_rank_to_linear_interpolation(self):
        old, new = old_home_key_dispatch(VECTOR), report.key_dispatch(VECTOR)
        self.assertEqual((old["p50"], old["p95"], old["max"]), (6.95, 12.4, 20.1))
        self.assertEqual((new["p50"], new["p95"], new["p99"], new["max"]), (6.95, 16.63, 19.41, 20.1))
        self.assertEqual(set(old) | {"p99"}, set(new), "the old keys stay; p99 is new")
        self.assertEqual(report.key_dispatch([]), {"count": 0, "p50": None, "p95": None, "p99": None, "max": None})


class AcpmuxTests(StoryMatch):
    def run_rows(self, base):
        return {m: base + i for i, m in enumerate(report.ACPMUX_TIMES)} | {"requests": 2, "request_bytes": 4096,
                                                                            "request_kb": 4.0, "request_ktok": 1.0}

    def test_side_summaries_keep_their_keys_and_add_p99(self):
        rows = {"raw": [self.run_rows(v) for v in VECTOR], "acpmux": [self.run_rows(v + 1) for v in VECTOR]}
        summary = acpmux_bench.side_summaries(rows)
        self.assertEqual(set(summary), {"raw", "acpmux", "delta_p50"})
        self.assertEqual(summary["raw"]["ready"], {"p50": 7.0, "p95": 16.6, "p99": 19.4, "n": 10})
        self.assertEqual(summary["delta_p50"]["end"], 1.0)
        empty = acpmux_bench.side_summaries({"raw": [], "acpmux": []})
        self.assertEqual(empty["raw"]["first"], {"p50": None, "p95": None, "p99": None, "n": 0})
        self.assertIsNone(empty["delta_p50"]["first"])

    def test_series_names_overhead_and_missed_runs(self):
        pairs = [{"raw": self.run_rows(10), "acpmux": self.run_rows(13)}, {"raw": None, "acpmux": self.run_rows(14)}]
        entries = report.acpmux_series("claude", pairs, {"raw": 1, "acpmux": 0})
        self.assert_claimed("acpmux-overhead", entries)
        by = {e.metric: e.samples for e in entries}
        self.assertEqual(by["acpmux_overhead.claude.overhead.end"], [3], "only the run where both sides worked")
        self.assertEqual(by["acpmux_overhead.claude.raw.end.missed_runs"], [1])
        self.assertEqual(by["acpmux_overhead.claude.acpmux.end"], [15, 16])
        self.assertEqual(by["acpmux_overhead.claude.raw.errors"], [1])
        self.assertEqual(by["acpmux_overhead.claude.acpmux.request_bytes"], [4096, 4096])

    def test_record_writes_valid_result_v1_named_by_the_bundle(self):
        out = tempfile.mkdtemp(prefix="acpmux-record-")
        args = acpmux_bench.parse_args(["--app", "/nonexistent/cmux DEV t.app", "--out", out])
        self.assertTrue(args.acpmux.endswith("cmux DEV t.app/Contents/Resources/bin/acpmux"))
        paired = {"codex": ([{"raw": self.run_rows(5), "acpmux": self.run_rows(6)}], {"raw": 0, "acpmux": 0})}
        path = acpmux_bench.record(args, paired, (BUILD, HOST))
        results = pr.read_dir(out)
        self.assertEqual(str(Path(path).parent), out)
        self.assertEqual({r.engine for r in results}, {"none"})
        self.assertEqual({r.build.sha for r in results}, {SHA})
        self.assertIn("acpmux_overhead.codex.overhead.ready", {r.metric for r in results})

    def test_record_says_why_when_nothing_can_be_written(self):
        args = acpmux_bench.parse_args(["--app", "/nonexistent/x.app", "--out", tempfile.mkdtemp()])
        with redirect_stderr(io.StringIO()):
            self.assertTrue(acpmux_bench.record(args, {}, (BUILD, HOST)).startswith("not recorded: "))

    def test_an_unnamed_build_or_host_fails_before_any_harness_runs(self):
        args = acpmux_bench.parse_args(["--app", "/nonexistent/x.app", "--out", tempfile.mkdtemp()])

        def unnamed(app, stated):
            raise bench_launch.RecordError("no build sha")

        def no_executable(app, stated):
            raise SystemExit("bench-launch: no executable in x.app/Contents/MacOS")
        for measure in (unnamed, no_executable):
            with redirect_stderr(io.StringIO()) as err, self.assertRaises(SystemExit) as done:
                acpmux_bench.measure_first(args, measure)
            self.assertEqual(done.exception.code, 2)
            self.assertIn("cannot record result-v1", err.getvalue())
        # main measures first: a bundle result-v1 cannot name never starts the daemon or a harness.
        with unittest.mock.patch.object(acpmux_bench, "Daemon") as daemon, \
                unittest.mock.patch.dict("os.environ", {"CMUX_CI_SHA": ""}), \
                redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as done:
            acpmux_bench.main(["--app", "/nonexistent/x.app", "--out", tempfile.mkdtemp()])
        self.assertEqual(done.exception.code, 2)
        daemon.assert_not_called()

    def test_a_run_that_records_nothing_exits_non_zero_after_its_reports(self):
        out = tempfile.mkdtemp(prefix="acpmux-fail-")
        report_path = str(Path(out) / "report.json")
        with unittest.mock.patch.object(acpmux_bench, "Daemon"), \
                unittest.mock.patch.object(acpmux_bench, "measure_first", return_value=(BUILD, HOST)), \
                unittest.mock.patch.object(acpmux_bench, "record", return_value="not recorded: boom"), \
                redirect_stderr(io.StringIO()), unittest.mock.patch("builtins.print"), \
                self.assertRaises(SystemExit) as done:
            acpmux_bench.main(["--app", "/nonexistent/x.app", "--out", out, "--harness", "claude", "-n", "0",
                               "--warmup", "0", "--json", report_path])
        self.assertNotIn(done.exception.code, (0, None))
        self.assertEqual(json.loads(Path(report_path).read_text())["_meta"]["result_v1"], "not recorded: boom")

    def test_out_needs_the_bundle(self):
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            acpmux_bench.parse_args(["--acpmux", "/bin/true", "--out", "/tmp"])
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            acpmux_bench.parse_args([])


class AgentEngineTests(StoryMatch):
    def result(self):
        chat = {"content_ms": 120.0, "interactive_ms": 180.0, "engine": "cef"}
        return {"first_chat": chat, "more_chats": [dict(chat, content_ms=v) for v in VECTOR[:3]] + [
                    {"content_ms": 50.0, "interactive_ms": 70.0, "engine": "webkit:agentChat"}, {"error": "boom"}],
                "session": {"composer_ms": 90.0},
                "typing": {"to_frame_samples_ms": [4.1, 6.5], "to_paint_samples_ms": [9.9, 12.3]},
                "flings": [{"dropped_frames": 2, "frames_ms": [8.3, 8.4]}, {"dropped_frames": 0, "frames_ms": [8.2]}],
                "baseline": {"total_footprint_bytes": 100}, "one_chat": {"total_footprint_bytes": 150},
                "chats_10": {"total_footprint_bytes": 400}}

    def test_series_are_claimed_by_each_engine_story(self):
        for engine, story in report.AGENT_ENGINE_STORIES.items():
            self.assert_claimed(story, report.agent_engine_series(engine, self.result(), 10))

    def test_series_values(self):
        by = {e.metric: e.samples for e in report.agent_engine_series("chromium", self.result(), 10)}
        self.assertEqual(by["agent_engine.next_content"], [3.1, 4.0, 4.2])
        self.assertEqual(by["agent_engine.next_content.missed_runs"], [2])
        self.assertEqual(by["agent_engine.fling.frame_interval"], [8.3, 8.4, 8.2])
        self.assertEqual(by["agent_engine.fling.dropped_frames"], [2, 0])
        self.assertEqual(by["agent_engine.memory.chats_10.footprint"], [400])
        self.assertEqual(by["agent_engine.typing.to_frame"], [4.1, 6.5])
        self.assertEqual(by["agent_engine.typing.to_paint"], [9.9, 12.3])
        self.assertEqual(by["agent_engine.engine_fallback"], [1], "the WebKit chat of a Chromium run")
        self.assertEqual(by["agent_engine.next_interactive"], [180.0] * 3, "its 70 ms is WebKit's, not Chromium's")

    def test_a_chat_in_another_engine_never_enters_the_series(self):
        by = {e.metric: e.samples for e in report.agent_engine_series("chromium", self.result(), 10)}
        self.assertNotIn(50.0, by["agent_engine.next_content"])
        self.assertEqual(by["agent_engine.next_content.missed_runs"], [2], "the WebKit chat and the failed one")

    def test_a_first_chat_in_another_engine_records_no_session_work(self):
        """The session, typing, flings and memory run in the first chat's page: a mode whose page showed in the other
        engine measured that engine, so none of it is a sample of the story's."""
        webkit = {e.metric: e.samples for e in report.agent_engine_series("webkit", self.result(), 10)}
        self.assertEqual(webkit["agent_engine.engine_fallback"], [4])
        self.assertEqual(webkit["agent_engine.next_content"], [50.0])
        self.assertNotIn("agent_engine.first_content", webkit)
        self.assertEqual(webkit["agent_engine.first_content.missed_runs"], [1])
        self.assertEqual(webkit["agent_engine.session_composer.missed_runs"], [1])
        self.assertEqual(webkit["agent_engine.fling.dropped_frames.missed_runs"], [2])
        for gone in ("agent_engine.session_composer", "agent_engine.fling.frame_interval",
                     "agent_engine.fling.dropped_frames", "agent_engine.typing.to_frame",
                     "agent_engine.memory.baseline.footprint", "agent_engine.memory.chats_10.footprint"):
            self.assertNotIn(gone, webkit)
        unread = dict(self.result(), first_chat={"content_ms": 120.0, "interactive_ms": 180.0, "engine": None})
        by = {e.metric: e.samples for e in report.agent_engine_series("chromium", unread, 10)}
        self.assertNotIn("agent_engine.first_content", by, "an unread engine is not the story's")
        self.assertNotIn("agent_engine.fling.frame_interval", by)

    def test_summary_keeps_its_keys(self):
        result = self.result()
        summary = report.agent_engine_summary_stats(result["first_chat"], result["more_chats"])
        self.assertEqual(summary, {"first_content_ms": 120.0, "first_interactive_ms": 180.0,
                                   "next_content_ms_median": 4.1, "next_interactive_ms_median": 180.0},
                         "the report's medians cover every chat, as before; its engines_seen names the fallback")

    def test_frame_samples_and_engines(self):
        reply = {"samples": [{"interval_ms": 8.3, "layout_ms": 1.0}, {"interval_ms": None}, "x"], "frames": 2}
        self.assertEqual(report.frame_samples(reply), [8.3])
        self.assertEqual(report.frame_samples(reply, "layout_ms"), [1.0])
        self.assertEqual(report.frame_samples({"error": "no page"}), [])
        self.assertEqual([report.page_engine(n) for n in ("cef", "webkit:agentChat", "gone", None)],
                         ["chromium", "webkit", None, None])
        typing = {"keys": 2, "samples": [{"to_frame_ms": 4.1, "to_paint_ms": 9.9}, {"to_frame_ms": 6.5}]}
        self.assertEqual(report.frame_samples(typing, "to_paint_ms"), [9.9])

    def test_run_frames_takes_only_the_frames_of_a_run_that_worked(self):
        ring = {"frames": 3, "samples": [{"interval_ms": 8.3}, {"interval_ms": 8.4}, {"interval_ms": 8.2}]}
        self.assertEqual(report.run_frames({"frames": 4, "p95_ms": 9.0}, ring), ring)
        # A fling or stream that failed before it reset the ring: the ring still holds the last run's frames.
        self.assertEqual(report.frame_samples(report.run_frames({"error": "no transcript"}, ring)), [])
        # A socket timeout: the page still runs, so the ring is partial or another run's.
        self.assertEqual(report.run_frames({"error": "timed out", "unreachable": True}, ring), {})
        self.assertEqual(report.run_frames({"frames": 400}, ring), {}, "the reply counted other frames")
        self.assertEqual(report.run_frames({"frames": 4}, {"error": "no page"}), {})
        self.assertEqual(report.run_frames({"running": False, "frames": 0}, {"frames": 0, "samples": []}), {})

    def run_cli(self, *args):
        return subprocess.run([sys.executable, "-I", str(HERE / "agent-engine-bench.py"),
                               "--app", "/nonexistent/cmux DEV t.app", *args],
                              capture_output=True, text=True, timeout=60, cwd="/")

    def test_cli_refuses_a_story_of_two_modes_or_another_engine_before_it_launches(self):
        two = self.run_cli("--modes", "webkit,chromium", "--story", "agent-engine")
        self.assertEqual(two.returncode, 2, two.stderr)
        self.assertIn("one mode", two.stderr)
        other = self.run_cli("--modes", "webkit", "--story", "agent-engine")
        self.assertEqual(other.returncode, 2, other.stderr)
        self.assertIn("engine 'chromium'", other.stderr)


class AgentStreamTests(StoryMatch):
    def runs(self):
        reply = {"frames": 400, "p95_ms": 9.0, "p99_ms": 12.0, "dropped_frames": 1, "detached_frames": 0,
                 "growing_frames": 30, "growth_px": {"p95": 18.0}, "layout_ms": {"p95_ms": 1.5}}
        return [{"reply": reply, "interval_ms": [8.3, 8.4], "layout_ms": [1.0, 1.1], "react_ms": [0.5]},
                {"reply": {"error": "no transcript"}, "interval_ms": [], "layout_ms": [], "react_ms": []}]

    def test_series_are_claimed_by_each_engine_story(self):
        for engine, story in report.AGENT_STREAM_STORIES.items():
            self.assert_claimed(story, report.stream_series(engine, self.runs(), "cef"))

    def test_series_values(self):
        by = {e.metric: e.samples for e in report.stream_series("chromium", self.runs(), "cef")}
        self.assertEqual(by["agent_stream.frame_interval"], [8.3, 8.4])
        self.assertEqual(by["agent_stream.dropped_frames"], [1])
        self.assertEqual(by["agent_stream.dropped_frames.missed_runs"], [1])
        self.assertEqual(by["agent_stream.engine_fallback"], [0])

    def test_a_tab_in_another_or_an_unread_engine_records_no_frame(self):
        """A WebKit tab of a chromium story (CEF missing), or an engine read that failed: its frames are not the
        story's engine's, so only engine_fallback and the missed runs record."""
        for engine, shown in (("webkit", "cef"), ("chromium", "webkit:agentChat"), ("chromium", None)):
            by = {e.metric: e.samples for e in report.stream_series(engine, self.runs(), shown)}
            self.assertEqual(by["agent_stream.engine_fallback"], [1], (engine, shown))
            for key in ("frame_interval", "layout", "react", "dropped_frames", "detached_frames", "growing_frames"):
                self.assertNotIn(f"agent_stream.{key}", by, (engine, shown))
            self.assertEqual(by["agent_stream.dropped_frames.missed_runs"], [2], (engine, shown))

    def test_table_keeps_its_columns_and_adds_p99(self):
        old = [("nominal_ms",), ("frames",), ("p95_ms",), ("max_ms",), ("dropped_frames",), ("detached_frames",),
               ("growing_frames",), ("growth_px", "p95"), ("growth_px", "max"), ("layout_ms", "p95_ms"),
               ("react_ms", "p95_ms"), ("other_ms", "p95_ms"), ("deltas",)]
        self.assertEqual([c for c in report.STREAM_COLUMNS if c != ("p99_ms",)], old)
        replies = [r["reply"] for r in self.runs()]
        self.assertEqual(report.stream_median(replies, "growth_px", "p95"), 18.0)
        self.assertEqual(report.stream_median(replies, "deltas"), None)

    def test_parse_refuses_what_it_cannot_record(self):
        def refused(*argv):
            with redirect_stderr(io.StringIO()) as err, self.assertRaises(SystemExit):
                stream_bench.parse(["--app", "/x.app", *argv])
            return err.getvalue()
        self.assertIn("variant", refused("--story", "agent-stream", "--engine", "chromium", "--variant", "a=/d"))
        self.assertIn("--engine", refused("--story", "agent-stream"))
        self.assertIn("engine 'chromium'", refused("--story", "agent-stream", "--engine", "webkit"))
        self.assertIn("name=directory", refused("--variant", "nodir"))
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            stream_bench.parse([])
        opts = stream_bench.parse(["--app", "/x.app", "--story", "agent-stream-webkit", "--engine", "webkit"])
        self.assertEqual((opts.story, opts.engine, opts.session), ("agent-stream-webkit", "webkit", "light"))

    def test_a_variant_page_gets_its_own_builds_shared_library(self):
        """A variant pane that imports cmux-page://cmux.shared/ loads it from its own build's pages/_shared."""
        with tempfile.TemporaryDirectory() as tmp:
            build = Path(tmp) / "after"
            pane, shared = build / "agent-pane", build / "pages" / "_shared"
            pane.mkdir(parents=True)
            (pane / "index.html").write_text('<script type="module" src="cmux-page://cmux.shared/react-A1.js"></script>')
            old = Path(tmp) / "before"
            old.mkdir()
            (old / "index.html").write_text('<script type="module" src="pane.js"></script>')
            with redirect_stderr(io.StringIO()) as err, self.assertRaises(SystemExit):
                stream_bench.parse(["--app", "/x.app", "--variant", f"after={pane}"])
            self.assertIn("--variant-shared after=", err.getvalue())
            shared.mkdir(parents=True)
            opts = stream_bench.parse(["--app", "/x.app", "--variant", f"after={pane}", "--variant", f"before={old}"])
            self.assertEqual(opts.shared, {"after": str(shared), "before": None})
            given = Path(tmp) / "elsewhere"
            opts = stream_bench.parse(["--app", "/x.app", "--variant", f"after={pane}", "--variant-shared", f"after={given}"])
            self.assertEqual(opts.shared, {"after": str(given)})
            with redirect_stderr(io.StringIO()) as err, self.assertRaises(SystemExit):
                stream_bench.parse(["--app", "/x.app", "--variant", f"after={pane}", "--variant-shared", f"x={given}"])
            self.assertIn("names no --variant", err.getvalue())


class HomeTests(StoryMatch):
    def test_split_raw_frames_keeps_the_report_keys(self):
        answer = {"frames": 2, "p50_ms": 8.3, "p95_ms": 8.4, "intervals_ms": [8.3, 8.4], "main_ms": [1.0, 2.0],
                  "view_layouts_per_frame": [0, 1], "window_layouts_per_frame": [0, 0], "render_armed": False}
        stats, raw = report.split_raw_frames(answer)
        self.assertEqual(stats, {"frames": 2, "p50_ms": 8.3, "p95_ms": 8.4, "render_armed": False})
        self.assertEqual(sorted(raw), ["intervals_ms", "main_ms", "view_layouts_per_frame", "window_layouts_per_frame"])
        self.assertEqual(report.split_raw_frames(None), ({}, {}))

    def test_series_are_claimed_by_the_story(self):
        raw = {stage: {"intervals_ms": [8.3, 16.7], "main_ms": [2.0, 3.0]} for stage in report.HOME_FRAME_STAGES}
        results = {"memory_launch": {"rss_mb": 300.0, "footprint_mb": 250.5}, "memory_open": {"rss_mb": None},
                   "memory_end": {"rss_mb": 310.0, "footprint_mb": 260.0}}
        entries = report.home_series(raw, VECTOR, results)
        self.assert_claimed("home-perf", entries)
        by = {e.metric: e.samples for e in entries}
        self.assertEqual(by["home_perf.memory.launch.footprint"], [round(250.5 * 1024 * 1024)])
        self.assertNotIn("home_perf.memory.open.rss", by)
        self.assertEqual(by["home_perf.typing.key_dispatch"], VECTOR)


class RecordTests(unittest.TestCase):
    def test_any_written(self):
        self.assertTrue(report.any_written({"a/m": "/out/m.ndjson", "a/n": "not recorded: no sha"}))
        self.assertFalse(report.any_written({"a/m": "not recorded: no sha"}))
        self.assertFalse(report.any_written({}))
        self.assertFalse(report.any_written(None))

    def test_record_all_reports_each_series(self):
        class Bench:
            perf_session = None

            def __init__(self):
                self.calls = []

            def record(self, story, metric, unit, samples, better, engine):
                if metric.endswith("bad"):
                    raise bench_launch.RecordError("no features")
                self.calls.append((story, metric, unit, samples, better, engine, self.perf_session))
                return f"/out/{metric}.ndjson"

        bench = Bench()
        entries = [report.Series("home-perf", "m.good", "ms", [1.0]), report.Series("home-perf", "m.bad", "ms", [2.0])]
        with redirect_stderr(io.StringIO()), unittest.mock.patch("builtins.print"):
            written = report.record_all(bench, entries, engine="none")
        self.assertEqual(written["home-perf/m.good"], "/out/m.good.ndjson")
        self.assertEqual(written["home-perf/m.bad"], "not recorded: no features")
        self.assertEqual(bench.calls, [("home-perf", "m.good", "ms", [1.0], "lower", "none", "light")])

    def test_write_all_round_trips(self):
        out = tempfile.mkdtemp(prefix="agent-write-")
        entries = report.home_series({"scroll": {"intervals_ms": [8.3]}}, [1.5], {})
        report.write_all(out, entries, BUILD, HOST, root=ROOT)
        self.assertEqual(sorted(r.metric for r in pr.read_dir(out)), sorted(e.metric for e in entries))


class QueueTests(unittest.TestCase):
    def test_the_benches_left_the_bench_migration_queue(self):
        done = subprocess.run([sys.executable, "-I", str(ROOT / "scripts/perf-lab/queues.py"), "bench-migration",
                               "--files"], capture_output=True, text=True, timeout=120, cwd=ROOT)
        self.assertEqual(done.returncode, 0, done.stderr)
        listed = set(done.stdout.split())
        self.assertEqual(sorted(f"scripts/cmux-next/{b}" for b in BENCHES if f"scripts/cmux-next/{b}" in listed), [])
        self.assertNotIn("scripts/cmux-next/agent_bench_report.py", listed)

    def test_each_bench_imports_under_isolated_mode(self):
        for bench in BENCHES:
            done = subprocess.run([sys.executable, "-I", str(HERE / bench), "--help"], capture_output=True, text=True,
                                  timeout=60, cwd="/")
            self.assertEqual(done.returncode, 0, f"{bench}: {done.stderr[-800:]}")


if __name__ == "__main__":
    unittest.main()
