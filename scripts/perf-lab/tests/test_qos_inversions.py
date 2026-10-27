"""Tests for scripts/perf-lab/stories/qos_inversions.py (story qos-inversions, task p12-perf-process-230).

Run: python3 -m unittest scripts/perf-lab/tests/test_qos_inversions.py
"""

import importlib.util
import json
import os
import re
import shutil
import sys
import tempfile
import types
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
PERF_LAB = HERE.parent
REPO_ROOT = HERE.parents[2]
STORY_FILE = PERF_LAB / "stories.d" / "qos-inversions.json"


def load(name, path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


qi = load("qos_inversions_under_test", PERF_LAB / "stories" / "qos_inversions.py")
bh = qi.bh
writer = load("perf_result", PERF_LAB / "perf_result.py")
catalog = load("perf_lab_catalog", PERF_LAB / "catalog.py")


def site(location, count, waiter="user-interactive", target="utility"):
    return {"location": location, "waiter": waiter, "target": target, "count": count}


def blocking(sites=(), overflow=0, compiled_in=True, with_inversions=True):
    """A debug.blocking report (BlockingControl.swift) with its `inversions` block."""
    reply = {"compiled_in": compiled_in, "mode": "record", "pool_mode": "record", "overflow": 0, "contexts": {},
             "sites": []}
    if with_inversions:
        reply["inversions"] = {"count": sum(s["count"] for s in sites), "overflow": overflow, "sites": list(sites)}
    return reply


class FakeRpc:
    """The app socket: debug.blocking answers from a list (the last one repeats); `None` is a build without it."""

    def __init__(self, replies):
        self.replies, self.calls = list(replies), []

    def __call__(self, method, params=None, timeout=60):
        self.calls.append((method, params))
        assert method == "debug.blocking", method
        assert not (params or {}).get("reset"), "the story never resets"
        reply = self.replies.pop(0) if len(self.replies) > 1 else self.replies[0]
        return reply if reply is not None else {"error": {"code": "method_not_found", "message": "Unknown method"}}


class FakeBench:
    """BenchApp's record contract: build, host, features filled in, one file per record() in `out`."""

    def __init__(self, out, rpc):
        self.out, self.rpc = out, rpc
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


class FakeBlobs:
    def __init__(self):
        self.objects = {}

    def put(self, key, data, content_type):
        self.objects[key] = (bytes(data), content_type)


STRESS_META = {"stress": {"workspaces": 40}, "storm_targets": {"workspaces": 39, "groups": 2},
               "storm_ops": {"move": 75}, "scenario_label": "stress-storm"}


def fake_trace(rpc):
    """trace.py's Recording: build_stress then run_window; a stage's exception goes into the meta's errors."""
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

        def build_stress(self):
            pass

        def run_window(self):
            pass

        def record(self):
            assert self.recorder == "none" and self.opts.scenario == "stress-storm"
            for stage, step in (("stress-build", self.build_stress), ("window", self.run_window)):
                try:
                    step()
                except Exception as error:  # noqa: BLE001 - trace.py's Stages records a stage's failure
                    self.meta["errors"].append({"stage": stage, "error": str(error)})
                    break
            self.meta.update(STRESS_META)
            return 3 if self.meta["errors"] else 0

    module.Stages, module.Recording = Stages, Recording
    return module


def run_story(test, rpc, argv=("--legs", "storm"), config_problem=lambda app: None):
    """main() over the fakes; returns (exit, out folder, blobs)."""
    out = tempfile.mkdtemp(prefix="qos-inversions-test-")
    test.addCleanup(lambda: shutil.rmtree(out, ignore_errors=True))
    saved = sys.modules.get("cmux_next_trace")
    sys.modules["cmux_next_trace"] = fake_trace(rpc)
    blobs = FakeBlobs()
    try:
        code = qi.main(["--app", "/tmp/cmux DEV t.app", "--out", out, *argv], blobs=blobs,
                       config_problem=config_problem)
    finally:
        if saved is None:
            sys.modules.pop("cmux_next_trace", None)
        else:
            sys.modules["cmux_next_trace"] = saved
    return code, out, blobs


def results_in(out):
    return [r for path in sorted(Path(out).glob("*.ndjson")) for r in writer.read_file(path)]


def summary_of(out):
    return json.loads((Path(out) / qi.SUMMARY).read_text())


class Readings(unittest.TestCase):
    def test_build_without_detector_is_refused_not_zero(self):
        with self.assertRaises(bh.NoDetector):
            qi.parse_inversions(blocking(compiled_in=False))

    def test_build_without_the_inversions_report_is_not_measurable(self):
        with self.assertRaises(bh.NotMeasurable) as caught:
            qi.parse_inversions(blocking(with_inversions=False))
        self.assertIn("230", str(caught.exception))
        with self.assertRaises(bh.NotMeasurable):
            qi.parse_inversions({"error": {"code": "method_not_found"}})

    def test_window_counts_inversions_in_the_window_only(self):
        before = qi.parse_inversions(blocking([site("A.swift:1", 3), site("B.swift:2", 1)]))
        after = qi.parse_inversions(blocking([site("A.swift:1", 3), site("B.swift:2", 4),
                                              site("C.swift:3", 1, waiter="user-initiated", target="background")]))
        window = qi.inversions_window(before, after)
        self.assertEqual(window["count"], 4)
        self.assertEqual([(s["location"], s["count"]) for s in window["sites"]], [("B.swift:2", 3), ("C.swift:3", 1)])
        self.assertEqual((window["sites"][1]["waiter"], window["sites"][1]["target"]), ("user-initiated", "background"))

    def test_overflow_counts_so_a_full_table_never_reads_zero(self):
        window = qi.inversions_window(qi.parse_inversions(blocking(overflow=2)), qi.parse_inversions(blocking(overflow=5)))
        self.assertEqual((window["count"], window["overflow"], window["sites"]), (3, 3, []))

    def test_counts_going_back_are_refused(self):
        with self.assertRaises(bh.LegError):
            qi.inversions_window(qi.parse_inversions(blocking([site("A.swift:1", 3)])),
                                 qi.parse_inversions(blocking([site("A.swift:1", 1)])))
        with self.assertRaises(bh.LegError):
            qi.inversions_window(qi.parse_inversions(blocking(overflow=3)), qi.parse_inversions(blocking(overflow=1)))


class StoryRuns(unittest.TestCase):
    def test_storm_leg_stores_zero_with_the_target_and_attachment(self):
        rpc = FakeRpc([blocking([site("Old.swift:1", 2)])])
        code, out, blobs = run_story(self, rpc)
        self.assertEqual(code, bh.EXIT_OK, summary_of(out))
        result, = results_in(out)
        self.assertEqual((result.metric, result.samples, result.target_ref.target), ("qos.inversions", [0], "qos.inversions"))
        self.assertEqual((result.unit, result.better, result.session, result.build.config),
                         ("count", "lower", "stress", "bench-checks"))
        self.assertEqual([a.kind for a in result.attachments], ["qos-inversions"])
        (key, (data, _)), = blobs.objects.items()
        self.assertEqual(key, bh.attachment_key(result.attachments[0].digest))
        self.assertEqual(json.loads(data)["inversions"]["sites"], [])
        self.assertEqual([m for m, _ in rpc.calls], ["debug.blocking"] * 3)  # check, open, close

    def test_storm_leg_counts_an_inversion_in_its_window(self):
        rpc = FakeRpc([blocking(), blocking(), blocking([site("Store.swift:9", 2)], overflow=1)])
        code, out, blobs = run_story(self, rpc)
        self.assertEqual(code, bh.EXIT_OK, summary_of(out))
        result, = results_in(out)
        self.assertEqual(result.samples, [3])
        (_, (data, _)), = blobs.objects.items()
        self.assertEqual(json.loads(data)["inversions"]["sites"], [site("Store.swift:9", 2)])
        self.assertEqual(summary_of(out)["legs"][0]["sites"], [site("Store.swift:9", 2)])

    def test_build_without_detector_fails_before_the_stress_build_and_stores_nothing(self):
        rpc = FakeRpc([blocking(compiled_in=False)])
        code, out, blobs = run_story(self, rpc)
        self.assertEqual(code, bh.EXIT_FAILED)
        self.assertIn("CMUX_BLOCKING_CHECKS", summary_of(out)["refusal"]["reason"])
        self.assertEqual((results_in(out), blobs.objects), ([], {}))
        self.assertEqual(len(rpc.calls), 1)

    def test_build_without_the_report_is_not_measurable(self):
        for reply in (blocking(with_inversions=False), None):
            code, out, _ = run_story(self, FakeRpc([reply]))
            self.assertEqual(code, bh.EXIT_NOT_MEASURABLE)
            self.assertEqual(summary_of(out)["refusal"]["kind"], "not-measurable")
            self.assertEqual(results_in(out), [])

    def test_stamped_bench_build_fails_without_a_launch(self):
        rpc = FakeRpc([blocking()])
        code, out, _ = run_story(self, rpc, config_problem=lambda app: "built with --config bench")
        self.assertEqual(code, bh.EXIT_FAILED)
        self.assertEqual(rpc.calls, [])


class CorpusLegs(unittest.TestCase):
    def corpus_checkout(self, ids):
        root = Path(tempfile.mkdtemp(prefix="qos-inversions-root-"))
        self.addCleanup(lambda: shutil.rmtree(root, ignore_errors=True))
        (root / "perf-corpus").mkdir()
        for story_id in ids:
            (root / "perf-corpus" / f"{story_id}.json").write_text(json.dumps({"id": story_id, "tier": "T1"}))
        (root / "scripts" / "perf-lab" / "corpus").mkdir(parents=True)
        (root / "scripts" / "perf-lab" / "corpus" / "play.py").write_text("")
        saved = bh.ROOT
        bh.ROOT = str(root)
        self.addCleanup(lambda: setattr(bh, "ROOT", saved))

    def fake_player(self, replay):
        module = types.ModuleType("perf_lab_corpus_play")
        module.replay = replay
        saved = sys.modules.get("perf_lab_corpus_play")
        sys.modules["perf_lab_corpus_play"] = module
        self.addCleanup(lambda: sys.modules.__setitem__("perf_lab_corpus_play", saved) if saved is not None
                        else sys.modules.pop("perf_lab_corpus_play", None))

    def test_replay_with_the_window_hook_writes_a_corpus_result(self):
        self.corpus_checkout(["chat-burst"])

        def replay(manifest, *, app, out, window=None):
            with window(FakeBench(out, FakeRpc([blocking(), blocking(), blocking([site("Replay.swift:7", 1)])]))):
                pass

        self.fake_player(replay)
        code, out, _ = run_story(self, None, argv=("--legs", "corpus"))
        self.assertEqual(code, bh.EXIT_OK, summary_of(out))
        result, = results_in(out)
        self.assertEqual((result.metric, result.samples, result.target_ref), ("corpus.chat-burst.qos.inversions", [1], None))
        self.assertEqual(result.session, "corpus:chat-burst")

    def test_missing_corpus_is_not_measured_and_the_storm_stands(self):
        saved = bh.ROOT
        bh.ROOT = tempfile.mkdtemp(prefix="qos-inversions-root-")
        self.addCleanup(lambda: setattr(bh, "ROOT", saved))
        code, out, _ = run_story(self, FakeRpc([blocking()]), argv=("--legs", "storm,corpus"))
        self.assertEqual(code, bh.EXIT_OK)
        summary = summary_of(out)
        self.assertFalse(summary["corpus"]["measured"])
        self.assertEqual([r.metric for r in results_in(out)], ["qos.inversions"])


class Catalog(unittest.TestCase):
    def test_story_file_passes_the_lint_and_claims_the_target(self):
        doc = json.loads(STORY_FILE.read_text())
        self.assertEqual((doc["id"], doc["config"], doc["command"][0]),
                         ("qos-inversions", "bench-checks", "scripts/perf-lab/stories/qos_inversions.py"))
        loaded = catalog.load_catalog(REPO_ROOT)
        self.assertEqual([p for p in loaded.problems if "qos-inversions" in p], [])
        self.assertIn("qos-inversions", catalog.claimed_checks(loaded)[("qos.inversions", "qos\\.inversions")])

    def test_every_written_metric_name_matches_a_story_metric(self):
        patterns = [re.compile(m["name"]) for m in json.loads(STORY_FILE.read_text())["metrics"]]
        for name in ("qos.inversions", "corpus.chat-burst.qos.inversions"):
            self.assertTrue(any(p.fullmatch(name) for p in patterns), name)


if __name__ == "__main__":
    unittest.main()
