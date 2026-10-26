"""Tests for scripts/perf-lab/stories/main_turn.py (story main-turn, task p12-perf-process-032).

Run: python3 -m unittest scripts/perf-lab/tests/test_main_turn.py
"""

import bisect
import importlib.util
import json
import os
import random
import re
import sys
import tempfile
import types
import unittest
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

    def record(self, story, metric, unit, samples, better, engine, target_ref=None):
        if isinstance(target_ref, str):
            target_ref = writer.TargetRef(target=target_ref)
        result = writer.Result(
            story=story, metric=metric, unit=unit, better=better, samples=list(samples),
            build=writer.Build(sha="0123456789abcdef0123456789abcdef01234567", config="bench", measure_version=2),
            host=writer.Host(fingerprint="ab" * 32, host_class="mac-mini-m4pro", chip="Apple M4 Pro", macos="26.0",
                             macos_build="25A100", display_hz=120.0),
            engine=engine, session=self.perf_session, run=writer.Run.start(run_id="run-1"), target_ref=target_ref)
        return writer.write_ndjson(self.out, [result], repo_root=REPO_ROOT)


def fake_trace(rpc, bench_out, window_error=None, stage_errors=()):
    """A stand-in for trace.py: Recording runs build_stress then run_window, each stage's exception recorded in
    meta as trace.py's Stages does, then stops."""
    module = types.ModuleType("cmux_next_trace")

    class Stages:
        def __init__(self, meta):
            meta.setdefault("errors", [])
            meta.setdefault("timed_out", [])

    class Recording:
        def __init__(self, opts, out, meta, stages, bundle, recorder):
            self.opts, self.out, self.meta, self.recorder = opts, out, meta, recorder
            self.rpc = rpc
            self.app = types.SimpleNamespace(bench=FakeBench(bench_out, rpc))
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
            for stage, step in (("stress-build", self.build_stress), ("window", self.run_window)):
                try:
                    step()
                except Exception as error:  # trace.py's Stages records a stage's failure and stops
                    self.meta["errors"].append({"stage": stage, "error": str(error)})
                    break
            self.meta["errors"] += list(stage_errors)
            self.meta["scenario_label"] = "stress-storm"
            return 3 if self.meta["errors"] else 0

    module.Stages, module.Recording = Stages, Recording
    return module


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


class StormLeg(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.out = os.path.join(self.tmp.name, "out")
        self.staging = os.path.join(self.tmp.name, "trace")
        os.makedirs(self.out)
        os.makedirs(self.staging)
        self.addCleanup(sys.modules.pop, "cmux_next_trace", None)

    def opts(self, **extra):
        values = dict(app=os.path.join(self.tmp.name, "cmux DEV t.app"), out=self.out, seconds=1, config=None,
                      legs={"storm"}, corpus="all")
        values.update(extra)
        return types.SimpleNamespace(**values)

    def run_storm(self, blocks, **trace_extra):
        rpc = FakeRpc(blocks)
        sys.modules["cmux_next_trace"] = fake_trace(rpc, self.staging, **trace_extra)
        return mt.run_storm(self.opts(), self.tmp.name, writer)

    def test_storm_writes_result_v1_with_histogram_attachment(self):
        idle = block([0.2] * 50, [0.1] * 2)
        storm = block([0.2] * 50 + [1.0] * 900 + [3.0] * 95 + [9.0] * 5, [0.1] * 2 + [0.4] * 200)
        leg, signalled = self.run_storm([idle, idle, storm])  # pre-check, window start, window end
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
        blob = Path(self.out, "attachments", f"sha256-{digests.pop()[7:]}.json")
        doc = json.loads(blob.read_text())
        self.assertEqual(doc["window"]["main_turn"]["count"], 1000)
        self.assertEqual(doc["intervals_ms"]["main_turn.p99"], [low, p99.samples[0]])
        self.assertEqual(list(Path(self.staging).glob("*.ndjson")), [], "staged results are removed")

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
        rpc = FakeRpc([None])
        sys.modules["cmux_next_trace"] = fake_trace(rpc, self.staging)
        with self.assertRaises(mt.NotMeasurable):
            mt.run_storm(self.opts(), self.tmp.name, writer)
        self.assertEqual(writer.read_dir(self.out), [])

    def test_main_refuses_with_reason_and_exit_4(self):
        sys.modules["cmux_next_trace"] = fake_trace(FakeRpc([None]), self.staging)
        code = mt.main(["--app", self.opts().app, "--tag", "t", "--out", self.out, "--legs", "storm"])
        self.assertEqual(code, mt.EXIT_NOT_MEASURABLE)
        summary = json.loads(Path(self.out, "main-turn-summary.json").read_text())
        self.assertEqual(summary["refusal"]["kind"], "not-measurable")
        self.assertIn("turn_histogram", summary["refusal"]["reason"])
        self.assertEqual(writer.read_dir(self.out), [])

    def test_measured_stage_error_stores_nothing(self):
        idle = block([0.2] * 5)
        leg, _ = self.run_storm([idle, idle, block([0.2] * 5 + [1.0] * 5)],
                               stage_errors=[{"stage": "stress-build", "error": "only 12 workspaces"}])
        self.assertFalse(leg.ok)
        self.assertIn("only 12 workspaces", leg.reason)
        self.assertEqual(writer.read_dir(self.out), [])

    def test_window_failure_stores_nothing(self):
        idle = block([0.2] * 5)
        leg, _ = self.run_storm([idle], window_error=RuntimeError("storm thread died"))
        self.assertFalse(leg.ok)
        self.assertEqual(writer.read_dir(self.out), [])


class CorpusLegs(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = self.tmp.name
        self.out = os.path.join(self.root, "out")
        os.makedirs(self.out)
        self.opts = types.SimpleNamespace(app="/x/cmux DEV t.app", out=self.out, corpus="all", config=None)

    def manifest(self, story_id, tier="T1"):
        folder = os.path.join(self.root, "perf-corpus")
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, f"{story_id}.json"), "w") as f:
            json.dump({"id": story_id, "tier": tier}, f)

    def test_checkout_without_corpus_has_no_legs(self):
        legs, notes = mt.corpus_legs(self.opts, self.root, writer, root=self.root)
        self.assertEqual(legs, [])
        self.assertIn("perf-corpus", notes[0])

    def test_all_skips_t2_and_named_id_must_exist(self):
        self.manifest("agent-swarm")
        self.manifest("long-day-soak", tier="T2")
        self.assertEqual([i for i, _ in mt.corpus_manifests(self.root, "all")], ["agent-swarm"])
        with self.assertRaises(mt.LegError):
            mt.corpus_manifests(self.root, "dev-loop")

    def test_replay_hook_measures_the_window(self):
        rpc = FakeRpc([block([0.5] * 10), block([0.5] * 10 + [2.0] * 40)])
        staging = os.path.join(self.root, "staging")
        os.makedirs(staging)

        def replay(manifest, app, out, window):
            bench = FakeBench(staging, rpc)
            with window(bench):
                pass
            return bench

        leg = mt.run_corpus(types.SimpleNamespace(replay=replay), "agent-swarm", "m.json", self.opts, self.root,
                            writer)
        self.assertTrue(leg.ok, leg.reason)
        results = writer.read_dir(self.out)
        self.assertIn("corpus.agent-swarm.main_turn.p99", {r.metric for r in results})
        self.assertEqual({r.session for r in results}, {"corpus:agent-swarm"})
        self.assertTrue(all(r.target_ref is None for r in results))
        self.assertIn("input_queue: no input event", leg.notes[0])

    def test_player_without_hook_fails_the_leg(self):
        leg = mt.run_corpus(types.SimpleNamespace(), "agent-swarm", "m.json", self.opts, self.root, writer)
        self.assertFalse(leg.ok)
        self.assertIn("replay", leg.reason)


class StoryFile(unittest.TestCase):
    def test_story_claims_the_main_turn_target_and_runner_flags(self):
        story = json.loads(STORY_FILE.read_text())
        claimed = [m for m in story["metrics"] if m.get("target_ref") == {"target": "main-turn"}]
        self.assertEqual([m["name"] for m in claimed], ["main_turn\\.p99"])
        self.assertEqual(story["command"][0], "scripts/perf-lab/stories/main_turn.py")
        source = (PERF_LAB / "stories" / "main_turn.py").read_text()
        for flag in ("--app", "--tag", "--out"):
            self.assertIn(f'"{flag}"', source)


if __name__ == "__main__":
    unittest.main()
