"""Tests for scripts/perf-lab/stories/main_turn.py (story main-turn, task p12-perf-process-032).

Run: python3 -m unittest scripts/perf-lab/tests/test_main_turn.py
"""

import bisect
import contextlib
import hashlib
import importlib.util
import inspect
import json
import os
import random
import re
import sqlite3
import sys
import tempfile
import types
import unittest
from unittest import mock
from fractions import Fraction
from pathlib import Path

HERE = Path(__file__).resolve().parent
PERF_LAB = HERE.parent
REPO_ROOT = HERE.parents[2]
STORY_FILE = PERF_LAB / "stories.d" / "main-turn.json"


def load(name, path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


mt = load("main_turn_under_test", PERF_LAB / "stories" / "main_turn.py")
writer = load("perf_result", PERF_LAB / "perf_result.py")


def edges_us():
    """MainTurnHistogram.edgesNanos in microseconds: 50 us up by 1.2x, then 10 s."""
    edges, edge = [], 50_000.0
    while edge < 10_000_000_000:
        edges.append(round(edge) / 1000)
        edge *= 1.2
    edges.append(10_000_000.0)
    return edges


EDGES_US = edges_us()


def counts_of(samples_ms):
    counts = [0] * (len(EDGES_US) + 1)
    for value in samples_ms:
        counts[bisect.bisect_right(EDGES_US, value * 1000)] += 1
    return counts


def block(main_ms=(), input_ms=(), main_max=None, input_max=None):
    def one(samples, maximum):
        return {"count": len(samples), "buckets": counts_of(samples), "p50_ms": 0, "p95_ms": 0, "p99_ms": 0,
                "max_ms": maximum if maximum is not None else (max(samples) if samples else 0)}
    return {"edges_us": list(EDGES_US), "main_turn": one(list(main_ms), main_max),
            "input_queueing": one(list(input_ms), input_max)}


class FakeRpc:
    """debug.hangs answers from a list of turn_histogram blocks (None: a build without one)."""

    def __init__(self, blocks):
        self.blocks = list(blocks)
        self.calls = []

    def __call__(self, method, params=None, timeout=60):
        self.calls.append((method, params))
        assert method == "debug.hangs" and not (params or {}).get("clear")
        reply = {"installed": True, "records": []}
        current = self.blocks.pop(0) if len(self.blocks) > 1 else self.blocks[0]
        if current is not None:
            reply["turn_histogram"] = current
        return reply


class FakeBench:
    """BenchApp's record contract: build, host, features filled in, one file per record() in `out`."""

    def __init__(self, out, rpc):
        self.out, self.rpc = out, rpc
        self.perf_session = "light"
        self.build_config = None
        self.run = writer.Run.start(run_id="run-1")  # BenchApp keeps one run for every record()

    def record(self, story, metric, unit, samples, better, engine, target_ref=None):
        if isinstance(target_ref, str):
            target_ref = writer.TargetRef(target=target_ref)
        result = writer.Result(
            story=story, metric=metric, unit=unit, better=better, samples=list(samples),
            build=writer.Build(sha="0123456789abcdef0123456789abcdef01234567", config="bench", measure_version=2),
            host=writer.Host(fingerprint="ab" * 32, host_class="apple-m4-pro/24gb/120hz", chip="Apple M4 Pro", macos="26.0",
                             macos_build="25A100", display_hz=120.0),
            engine=engine, session=self.perf_session, run=self.run, target_ref=target_ref)
        return writer.write_ndjson(self.out, [result], repo_root=REPO_ROOT)


class FakeBlobs:
    """trace_quest's BlobStore put: the uploaded bytes by key."""

    def __init__(self):
        self.objects = {}

    def put(self, key, data, content_type):
        self.objects[key] = (bytes(data), content_type)


STRESS_META = {"stress": {"workspaces": 40, "busy_terminals": 8}, "storm_targets": {"workspaces": 39, "groups": 2},
               "storm_ops": {"move": 75, "task": 75, "group": 75, "pill": 75},
               "cef": {"valid": True, "problems": []}, "scenario_label": "stress-storm"}


def fake_trace(rpc, window_error=None, stage_errors=(), meta=None, record_error=None):
    """A stand-in for trace.py: Recording launches (BenchApp writes its host-env-full report into the recording's
    out), runs build_stress then run_window, each stage's exception recorded in meta as trace.py's Stages does,
    then stops. `meta` replaces STRESS_META's keys."""
    module = types.ModuleType("cmux_next_trace")

    class Stages:
        def __init__(self, meta):
            meta.setdefault("errors", [])
            meta.setdefault("timed_out", [])

    class Recording:
        def __init__(self, opts, out, meta, stages, bundle, recorder):
            self.opts, self.out, self.meta, self.recorder = opts, out, meta, recorder
            self.rpc = rpc
            self.app = types.SimpleNamespace(bench=FakeBench(out, rpc))
            self.terminated = None
            self.ran = []

        def build_stress(self):
            self.ran.append("stress-build")

        def run_window(self):
            self.ran.append("window")
            if window_error:
                raise window_error

        def record(self):
            assert self.recorder == "none" and self.opts.no_cef and self.opts.scenario == "stress-storm"
            with open(os.path.join(self.out, "host-env-full-4242.json"), "w") as f:
                json.dump({"ok": True, "reasons": []}, f)
            with open(os.path.join(self.out, "meta.json"), "w") as f:
                f.write("{}")
            if record_error:
                raise record_error
            for stage, step in (("stress-build", self.build_stress), ("window", self.run_window)):
                try:
                    step()
                except Exception as error:  # trace.py's Stages records a stage's failure and stops
                    self.meta["errors"].append({"stage": stage, "error": str(error)})
                    break
            self.meta["errors"] += list(stage_errors)
            self.meta.update({**STRESS_META, **(meta or {})})
            return 3 if self.meta["errors"] else 0

    module.Stages, module.Recording = Stages, Recording
    return module


def host_checks(run_dir):
    """run_story.host_check_reason's search (task 008): every host-env-full report anywhere under the run folder."""
    return sorted(Path(run_dir).glob(f"**/{mt.HOST_CHECK_GLOB}"))


class Percentiles(unittest.TestCase):
    def histogram(self, samples, maximum=None):
        return mt.parse_turn_histograms({"turn_histogram": block(samples, main_max=maximum)})["main_turn"]

    def test_close_turns_get_separate_intervals(self):
        low = mt.percentile_interval(self.histogram([3.6] * 100), Fraction(99, 100))
        high = mt.percentile_interval(self.histogram([4.4] * 100), Fraction(99, 100))
        self.assertLess(low[1], high[1])
        self.assertTrue(low[0] <= 3.6 <= low[1] and high[0] <= 4.4 <= high[1], (low, high))

    def test_interval_holds_true_percentile_within_a_bucket(self):
        rng = random.Random(32)
        samples = [rng.lognormvariate(0.3, 0.9) for _ in range(5000)]
        histogram = self.histogram(samples)
        ordered = sorted(samples)
        for quantile in (Fraction(50, 100), Fraction(95, 100), Fraction(99, 100)):
            true = ordered[-(-len(ordered) * quantile.numerator // quantile.denominator) - 1]
            low, high = mt.percentile_interval(histogram, quantile)
            self.assertTrue(low <= true <= high, (quantile, low, true, high))
            self.assertLessEqual(high, low * 1.2 * (1 + 1e-6))  # edges are whole nanoseconds

    def test_nearest_rank_is_exact(self):
        # 99 fast turns and 1 slow: p99 is the 99th turn, not the slow one (ceil(100 * 0.99) = 99).
        histogram = self.histogram([1.0] * 99 + [50.0])
        low, high = mt.percentile_interval(histogram, Fraction(99, 100))
        self.assertLess(high, 2.0)

    def test_high_edge_capped_by_max_and_overflow_uses_max(self):
        histogram = self.histogram([2.0] * 10, maximum=2.0)
        self.assertEqual(mt.percentile_interval(histogram, Fraction(99, 100))[1], 2.0)
        overflow = self.histogram([20_000.0] * 3)
        self.assertEqual(mt.percentile_interval(overflow, Fraction(99, 100)), (10_000.0, 20_000.0))

    def test_empty_histogram_has_no_interval(self):
        self.assertIsNone(mt.percentile_interval(self.histogram([]), Fraction(99, 100)))


class Parsing(unittest.TestCase):
    def test_build_without_turn_histogram_is_not_measurable(self):
        with self.assertRaises(mt.NotMeasurable) as caught:
            mt.parse_turn_histograms({"installed": True, "records": []})
        self.assertIn("turn_histogram", str(caught.exception))

    def test_failed_call_and_bad_shapes_are_leg_errors(self):
        with self.assertRaises(mt.LegError):
            mt.parse_turn_histograms({"error": "no socket", "unreachable": True})
        bad = block([1.0])
        bad["main_turn"]["buckets"] = bad["main_turn"]["buckets"][:-1]
        with self.assertRaises(mt.LegError):
            mt.parse_turn_histograms({"turn_histogram": bad})
        bad = block([1.0])
        bad["edges_us"] = list(reversed(bad["edges_us"]))
        with self.assertRaises(mt.LegError):
            mt.parse_turn_histograms({"turn_histogram": bad})

    def test_window_delta_subtracts_and_refuses_a_reset(self):
        before = mt.parse_turn_histograms({"turn_histogram": block([1.0] * 5)})["main_turn"]
        after = mt.parse_turn_histograms({"turn_histogram": block([1.0] * 5 + [3.0] * 7)})["main_turn"]
        self.assertEqual(mt.window_delta(before, after).count, 7)
        with self.assertRaises(mt.LegError):
            mt.window_delta(after, before)


class Window(unittest.TestCase):
    def test_reads_before_and_after_without_clearing(self):
        rpc = FakeRpc([block([1.0] * 4), block([1.0] * 4 + [2.0] * 6, [0.5] * 3)])
        window = mt.TurnWindow(rpc)
        with window:
            pass
        deltas = window.deltas()
        self.assertEqual((deltas["main_turn"].count, deltas["input_queueing"].count), (6, 3))
        self.assertEqual([c[0] for c in rpc.calls], ["debug.hangs", "debug.hangs"])

    def test_window_that_raised_has_no_after(self):
        window = mt.TurnWindow(FakeRpc([block([1.0])]))
        with self.assertRaises(RuntimeError):
            with window:
                raise RuntimeError("storm failed")
        with self.assertRaises(mt.LegError):
            window.deltas()


IDLE = block([0.2] * 50, [0.1] * 2)
STORM = block([0.2] * 50 + [1.0] * 900 + [3.0] * 95 + [9.0] * 5, [0.1] * 2 + [0.4] * 200)


class StormLeg(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.out = os.path.join(self.tmp.name, "out")
        self.work = os.path.join(self.tmp.name, "work")
        os.makedirs(self.out)
        os.makedirs(self.work)
        self.blobs = FakeBlobs()
        self.addCleanup(sys.modules.pop, "cmux_next_trace", None)

    def opts(self, **extra):
        values = dict(app=os.path.join(self.tmp.name, "cmux DEV t.app"), out=self.out, seconds=1, config=None,
                      legs={"storm"}, corpus="all")
        values.update(extra)
        return types.SimpleNamespace(**values)

    def run_storm(self, blocks, **trace_extra):
        rpc = FakeRpc(blocks)
        sys.modules["cmux_next_trace"] = fake_trace(rpc, **trace_extra)
        return mt.run_storm(self.opts(), self.work, writer, self.blobs)

    def test_storm_writes_result_v1_with_histogram_attachment(self):
        leg, signalled = self.run_storm([IDLE, IDLE, STORM])  # pre-check, window start, window end
        self.assertIsNone(signalled)
        self.assertTrue(leg.ok, leg.reason)
        results = writer.read_dir(self.out)
        by_metric = {r.metric: r for r in results}
        self.assertIn("main_turn.p99", by_metric)
        self.assertIn("input_queue.p99", by_metric)
        p99 = by_metric["main_turn.p99"]
        self.assertEqual(p99.target_ref.to_dict(), {"target": "main-turn"})
        self.assertEqual(p99.session, "stress")
        self.assertEqual(p99.story, "main-turn")
        low = by_metric["main_turn.p99.low"].samples[0]
        self.assertTrue(low <= 3.0 <= p99.samples[0], (low, p99.samples))
        self.assertIsNone(by_metric["input_queue.p99"].target_ref)
        digests = {a.digest for r in results for a in r.attachments}
        self.assertEqual(len(digests), 1)
        self.assertEqual({a.kind for r in results for a in r.attachments}, {"histogram"})
        digest = digests.pop()
        data, content_type = self.blobs.objects[mt.attachment_key(digest)]
        self.assertEqual((f"sha256:{hashlib.sha256(data).hexdigest()}", content_type), (digest, "application/json"))
        self.assertEqual(Path(self.out, "attachments", f"sha256-{digest[7:]}.json").read_bytes(), data)
        doc = json.loads(data)
        self.assertEqual(doc["window"]["main_turn"]["count"], 1000)
        self.assertEqual(doc["intervals_ms"]["main_turn.p99"], [low, p99.samples[0]])
        trace_dirs = list(Path(self.work).glob("main-turn-storm-*"))
        self.assertEqual(len(trace_dirs), 1)
        self.assertEqual(list(trace_dirs[0].glob("*.ndjson")), [], "staged results are removed")

    def test_launched_storm_leaves_its_host_check_under_out(self):
        # run_story.py rejects every result of a run folder with no host-env-full report (task 008).
        leg, _ = self.run_storm([IDLE, IDLE, STORM])
        self.assertTrue(leg.ok, leg.reason)
        found = host_checks(self.out)
        self.assertEqual([p.name for p in found], ["host-env-full-4242.json"])
        self.assertEqual(json.loads(found[0].read_text())["ok"], True)
        self.assertTrue(Path(self.out, "storm-trace", "meta.json").is_file())
        self.assertEqual(sorted(p.name for p in Path(self.out).glob("**/*.ndjson")),
                         [Path(leg.results).name], "only the leg's results are result files")

    def test_failed_storm_still_leaves_its_host_check(self):
        leg, _ = self.run_storm([IDLE], record_error=RuntimeError("trace.py crashed"))
        self.assertFalse(leg.ok)
        self.assertEqual(len(host_checks(self.out)), 1)

    def test_every_metric_matches_the_story(self):
        story = json.loads(STORY_FILE.read_text())
        patterns = [re.compile(m["name"]) for m in story["metrics"]]
        idle = block([0.2] * 5, [0.1])
        self.run_storm([idle, idle, block([0.2] * 5 + [1.0] * 50, [0.1, 0.3, 0.3])])
        names = [r.metric for r in writer.read_dir(self.out)]
        names += [f"corpus.agent-swarm.{n}" for n in names]
        for name in names:
            matched = [p.pattern for p in patterns if p.fullmatch(name)]
            self.assertEqual(len(matched), 1, (name, matched))

    def test_build_without_histogram_refuses_before_the_stress_build(self):
        sys.modules["cmux_next_trace"] = fake_trace(FakeRpc([None]))
        with self.assertRaises(mt.NotMeasurable):
            mt.run_storm(self.opts(), self.work, writer, self.blobs)
        self.assertEqual(writer.read_dir(self.out), [])

    def test_main_refuses_with_reason_and_exit_4(self):
        sys.modules["cmux_next_trace"] = fake_trace(FakeRpc([None]))
        code = mt.main(["--app", self.opts().app, "--tag", "t", "--out", self.out, "--legs", "storm"],
                       blobs=self.blobs)
        self.assertEqual(code, mt.EXIT_NOT_MEASURABLE)
        summary = json.loads(Path(self.out, "main-turn-summary.json").read_text())
        self.assertEqual(summary["refusal"]["kind"], "not-measurable")
        self.assertIn("turn_histogram", summary["refusal"]["reason"])
        self.assertEqual(writer.read_dir(self.out), [])

    def test_main_without_r2_launches_nothing_and_says_why(self):
        sys.modules["cmux_next_trace"] = fake_trace(FakeRpc([IDLE, IDLE, STORM]))
        with mock.patch.dict(os.environ, {"CMUX_PERF_LAB_R2_ACCOUNT_ID": ""}):
            code = mt.main(["--app", self.opts().app, "--tag", "t", "--out", self.out, "--legs", "storm"])
        self.assertEqual(code, mt.EXIT_FAILED)
        summary = json.loads(Path(self.out, "main-turn-summary.json").read_text())
        self.assertIn("R2 is not configured", summary["error"])
        self.assertEqual(writer.read_dir(self.out), [])
        self.assertEqual(host_checks(self.out), [], "no app was launched")

    def test_measured_stage_error_stores_nothing(self):
        idle = block([0.2] * 5)
        leg, _ = self.run_storm([idle, idle, block([0.2] * 5 + [1.0] * 5)],
                               stage_errors=[{"stage": "stress-build", "error": "only 12 workspaces"}])
        self.assertFalse(leg.ok)
        self.assertIn("only 12 workspaces", leg.reason)
        self.assertEqual(writer.read_dir(self.out), [])

    def test_a_window_that_is_not_the_stress_storm_stores_nothing(self):
        # trace.py only warns about these (build_stress's check=False, storm-setup, cef_validity).
        cases = {
            "not the STRESS shape: 3 busy terminals": {"stress": {"workspaces": 40, "shape_error": "3 busy terminals"}},
            "no target workspace": {"storm_targets": {"workspaces": 0, "groups": 0}},
            "sent no op": {"storm_ops": {}},
            "Chromium is not valid for a measurement: WebKit fallbacks": {
                "cef": {"valid": False, "problems": ["WebKit fallbacks"]}},
            "window was not key": {"scenario_label": "stress-storm-inactive"},
        }
        for reason, meta in cases.items():
            with self.subTest(reason):
                leg, _ = self.run_storm([IDLE, IDLE, STORM], meta=meta)
                self.assertFalse(leg.ok)
                self.assertIn(reason, leg.reason)
                self.assertEqual(writer.read_dir(self.out), [])

    def test_window_failure_stores_nothing(self):
        idle = block([0.2] * 5)
        leg, _ = self.run_storm([idle], window_error=RuntimeError("storm thread died"))
        self.assertFalse(leg.ok)
        self.assertEqual(writer.read_dir(self.out), [])

    def test_any_exception_is_the_legs_reason_and_main_still_writes_the_summary(self):
        sys.modules["cmux_next_trace"] = fake_trace(FakeRpc([IDLE, IDLE, STORM]))

        class RecordError(Exception):
            pass

        def failing_record(*_args, **_kwargs):
            raise RecordError("the app gave no features.list snapshot")

        with mock.patch.object(FakeBench, "record", failing_record):
            code = mt.main(["--app", self.opts().app, "--tag", "t", "--out", self.out, "--legs", "storm"],
                           blobs=self.blobs)
        self.assertEqual(code, mt.EXIT_FAILED)
        summary = json.loads(Path(self.out, "main-turn-summary.json").read_text())
        self.assertEqual(summary["legs"][0]["reason"], "RecordError: the app gave no features.list snapshot")
        self.assertEqual(writer.read_dir(self.out), [])

    def test_storm_options_keep_the_watchdog_sampler_out_of_the_measured_range(self):
        opts = mt.trace_options("/x/cmux DEV t.app", self.out, 30)
        self.assertGreaterEqual(opts.hang_ms, 50, "a lower CMUX_NEXT_HANG_THRESHOLD_MS samples (suspends) short turns")
        self.assertEqual(opts.hang_ms, mt.HANG_MS)
        self.assertEqual((opts.recorder, opts.no_cef, opts.system_trace), ("none", True, False))


class CorpusLegs(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = self.tmp.name
        self.out = os.path.join(self.root, "out")
        os.makedirs(self.out)
        self.blobs = FakeBlobs()
        self.opts = types.SimpleNamespace(app="/x/cmux DEV t.app", out=self.out, corpus="all", config=None)

    def manifest(self, story_id, tier="T1"):
        folder = os.path.join(self.root, "perf-corpus")
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, f"{story_id}.json"), "w") as f:
            json.dump({"id": story_id, "tier": tier}, f)

    def player(self, rpc, *, fail=None):
        def replay(manifest, *, app, out, window=None):
            bench_out = os.path.join(out, "bench")  # 3.8: the replay's BenchApp writes under `out`
            os.makedirs(bench_out)
            with open(os.path.join(bench_out, "host-env-full-77.json"), "w") as f:
                json.dump({"ok": True, "reasons": []}, f)
            if fail:
                raise fail
            bench = FakeBench(bench_out, rpc)
            with window(bench):
                pass

        return types.SimpleNamespace(replay=replay)

    def run_corpus(self, play, story_id="agent-swarm"):
        return mt.run_corpus(play, story_id, "m.json", self.opts, self.root, writer, self.blobs)

    def test_checkout_without_corpus_is_not_measured(self):
        legs, unmeasured = mt.corpus_legs(self.opts, self.root, writer, self.blobs, root=self.root)
        self.assertEqual(legs, [])
        self.assertIn("perf-corpus", unmeasured)

    def test_all_skips_t2_and_named_id_must_exist(self):
        self.manifest("agent-swarm")
        self.manifest("long-day-soak", tier="T2")
        self.assertEqual([i for i, _ in mt.corpus_manifests(self.root, "all")], ["agent-swarm"])
        with self.assertRaises(mt.LegError):
            mt.corpus_manifests(self.root, "dev-loop")

    def test_replay_hook_measures_the_window(self):
        rpc = FakeRpc([block([0.5] * 10), block([0.5] * 10 + [2.0] * 40)])
        leg = self.run_corpus(self.player(rpc))
        self.assertTrue(leg.ok, leg.reason)
        results = writer.read_dir(self.out)
        self.assertIn("corpus.agent-swarm.main_turn.p99", {r.metric for r in results})
        self.assertEqual({r.session for r in results}, {"corpus:agent-swarm"})
        self.assertTrue(all(r.target_ref is None for r in results))
        self.assertIn("input_queue: no input event", leg.notes[0])
        self.assertEqual([p.name for p in host_checks(self.out)], ["host-env-full-77.json"])

    def test_a_replay_that_raises_fails_its_leg_only(self):
        leg = self.run_corpus(self.player(FakeRpc([block([0.5])]), fail=OSError("WPR archive missing")))
        self.assertFalse(leg.ok)
        self.assertEqual(leg.reason, "OSError: WPR archive missing")
        self.assertEqual(len(host_checks(self.out)), 1, "the launched app's host check is kept")

    def test_player_without_hook_fails_the_leg(self):
        leg = self.run_corpus(types.SimpleNamespace())
        self.assertFalse(leg.ok)
        self.assertIn("replay", leg.reason)

    def test_replay_without_a_window_parameter_is_a_leg_error_not_a_type_error(self):
        def replay(manifest, *, app, out):
            raise AssertionError("never called without the hook")

        leg = self.run_corpus(types.SimpleNamespace(replay=replay))
        self.assertFalse(leg.ok)
        self.assertIn("window=", leg.reason)
        self.assertTrue(mt.takes_window(lambda manifest, **kwargs: None))

    def test_main_says_the_corpus_was_not_measured_and_exits_1(self):
        # A storm that passes, so only the missing corpus (no perf-corpus/ under root) fails the story.
        sys.modules["cmux_next_trace"] = fake_trace(FakeRpc([IDLE, IDLE, STORM]))
        self.addCleanup(sys.modules.pop, "cmux_next_trace", None)
        with mock.patch.object(mt.corpus_legs, "__defaults__", (self.root,)):
            code = mt.main(["--app", "/x/cmux DEV t.app", "--tag", "t", "--out", self.out], blobs=self.blobs)
        self.assertEqual(code, mt.EXIT_FAILED)
        summary = json.loads(Path(self.out, "main-turn-summary.json").read_text())
        self.assertTrue(summary["legs"][0]["ok"])
        self.assertEqual(summary["corpus"]["measured"], False)
        self.assertIn("perf-corpus", summary["corpus"]["reason"])


class Ingest(unittest.TestCase):
    def test_an_ingested_runs_histogram_attachment_resolves(self):
        ingest = load("perf_lab_ingest", PERF_LAB / "ingest.py")
        with tempfile.TemporaryDirectory() as tmp:
            out, work = os.path.join(tmp, "out"), os.path.join(tmp, "work")
            os.makedirs(out)
            os.makedirs(work)
            blobs = FakeBlobs()
            sys.modules["cmux_next_trace"] = fake_trace(FakeRpc([IDLE, IDLE, STORM]))
            self.addCleanup(sys.modules.pop, "cmux_next_trace", None)
            opts = types.SimpleNamespace(app=os.path.join(tmp, "cmux DEV t.app"), out=out, seconds=1, config=None)
            leg, _ = mt.run_storm(opts, work, writer, blobs)
            self.assertTrue(leg.ok, leg.reason)
            db = ingest.store.Store(Path(tmp, "lab.sqlite3"))
            self.addCleanup(db.close)
            db.migrate()
            sha = writer.read_dir(out)[0].build.sha
            report = ingest.ingest_paths(db, [out], commit_positions={sha: ingest.CommitPosition(1, mainline=True)}.get)
            self.assertEqual(report.rejected, [])
            with contextlib.closing(sqlite3.connect(Path(tmp, "lab.sqlite3"))) as read:
                rows = read.execute("SELECT attachments_json FROM runs").fetchall()
            attachments = [a for (text,) in rows for a in json.loads(text)]
            self.assertEqual([a["kind"] for a in attachments], ["histogram"])
            data, _ = blobs.objects[mt.attachment_key(attachments[0]["digest"])]
            self.assertEqual(f"sha256:{hashlib.sha256(data).hexdigest()}", attachments[0]["digest"])
            self.assertEqual(json.loads(data)["schema"], mt.ATTACHMENT_SCHEMA)


class RealTrace(unittest.TestCase):
    """The contract the storm leg takes from scripts/cmux-next/trace.py itself, not from the stand-in."""

    @classmethod
    def setUpClass(cls):
        mt.load_by_path("bench_launch", mt.BENCH_LAUNCH)
        cls.trace = mt.load_by_path("cmux_next_trace_real", mt.TRACE)
        cls.source = Path(mt.TRACE).read_text()

    def test_storm_recording_overrides_real_methods_with_the_real_constructor(self):
        recording = mt.storm_recording(self.trace)
        self.assertTrue(issubclass(recording, self.trace.Recording))
        for name in ("build_stress", "run_window", "record", "rpc"):
            self.assertTrue(name == "rpc" or callable(getattr(self.trace.Recording, name, None)), name)
        self.assertEqual(list(inspect.signature(self.trace.Recording.__init__).parameters),
                         ["self", "opts", "out", "meta", "stages", "bundle", "recorder"])
        self.assertEqual(list(inspect.signature(self.trace.Stages.__init__).parameters)[:2], ["self", "meta"])

    def test_trace_options_have_every_option_the_record_path_reads(self):
        read = set(re.findall(r"\bopts\.([a-z_]+)", self.source)) - {"verb", "dir", "self_test", "trace_processor"}
        given = set(vars(mt.trace_options("/x/cmux DEV t.app", "/tmp/o", 30)))
        self.assertEqual(read - given, set())

    def test_recorder_none_starts_no_recorder(self):
        compared = set(re.findall(r'self\.recorder == "([a-z]+)"', self.source))
        self.assertTrue(compared)
        self.assertNotIn("none", compared)
        self.assertLessEqual(compared, {"xctrace", "sample"})

    def test_story_meta_has_every_key_record_starts_with(self):
        source = inspect.getsource(self.trace.record)
        literal = source[source.index("meta = {"):source.index("recorder = opts.recorder")]
        started = set(re.findall(r'"([a-z_]+)":', literal))
        self.assertIn("warnings", started)
        meta = mt.storm_meta(mt.trace_options("/x/a.app", "/tmp/o", 30), "/x/a.app")
        self.assertEqual(started - set(meta), set())

    def test_meta_keys_and_stages_the_story_reads_exist(self):
        stages = set(re.findall(r'stages\.run\("([a-z-]+)"', self.source))
        self.assertLessEqual(set(mt.MEASURED_STAGES), stages)
        for key in ("storm_targets", "storm_ops", "cef", "scenario_label", "shape_error", "errors", "timed_out"):
            self.assertIn(f'"{key}"', self.source, key)
        self.assertIn('self.meta["stress"] = self.stress.build(', self.source)

    def test_host_check_glob_is_bench_launchs_prefix(self):
        prefix = getattr(sys.modules["bench_launch"], "LAB_CHECK_PREFIX", None)
        if prefix is not None:  # task 008's bench_launch
            self.assertEqual(mt.HOST_CHECK_GLOB, f"{prefix}*.json")


class StoryFile(unittest.TestCase):
    def test_story_claims_the_main_turn_target_and_runner_flags(self):
        story = json.loads(STORY_FILE.read_text())
        claimed = [m for m in story["metrics"] if m.get("target_ref") == {"target": "main-turn"}]
        self.assertEqual([m["name"] for m in claimed], ["main_turn\\.p99"])
        self.assertEqual(story["command"][0], "scripts/perf-lab/stories/main_turn.py")
        source = (PERF_LAB / "stories" / "main_turn.py").read_text()
        for flag in ("--app", "--tag", "--out"):
            self.assertIn(f'"{flag}"', source)

    def test_needs_name_what_only_task_031_builds_have(self):
        # debug.hangs predates task 031; the lab checks a `file:` need against the measured commit, so a build
        # without the histogram is not-measurable, never a failed try.
        story = json.loads(STORY_FILE.read_text())
        design = json.loads((REPO_ROOT / "plans/cmux-next/chrome-parity/design-result.json").read_text())
        task = next(t for t in design["programs"]["p12-perf-process"]["tasks"] if t["id"] == "p12-perf-process-031")
        files = [need[len("file:"):] for need in story["needs"] if need.startswith("file:")]
        self.assertTrue(files)
        self.assertTrue(any(path in task["files"] and path.endswith("MainTurnHistogram.swift") for path in files))


if __name__ == "__main__":
    unittest.main()
