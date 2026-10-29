"""Tests for scripts/perf-lab/stories/blocking_hangs.py (story blocking-hangs, task p12-perf-process-037).

Run: python3 -m unittest scripts/perf-lab/tests/test_blocking_hangs.py
"""

import importlib.util
import json
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
PERF_LAB = HERE.parent
REPO_ROOT = HERE.parents[2]
STORY_FILE = PERF_LAB / "stories.d" / "blocking-hangs.json"


def load(name, path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


bh = load("blocking_hangs_under_test", PERF_LAB / "stories" / "blocking_hangs.py")
writer = load("perf_result", PERF_LAB / "perf_result.py")
catalog = load("perf_lab_catalog", PERF_LAB / "catalog.py")


def site(location, count, context="main", kind="seam", total_ms=0.0, max_ms=0.0):
    return {"context": context, "kind": kind, "seam_kind": "none", "location": location, "count": count,
            "total_ms": total_ms, "max_ms": max_ms}


def blocking(sites=(), overflow=None, compiled_in=True):
    overflow = overflow or {}
    return {"compiled_in": compiled_in, "mode": "record", "pool_mode": "record",
            "overflow": sum(overflow.values()),
            "contexts": {c: {"sites": 0, "count": 0, "overflow": overflow.get(c, 0)} for c in ("main", "pool", "cpu-lane")},
            "sites": list(sites)}


def stall(sequence, duration_ms, kind="stall"):
    return {"sequence": sequence, "kind": kind, "duration_ms": duration_ms, "frames": [f"app work + {sequence}"]}


def thread_hang(sequence, role, scope="daemon.line"):
    return {"sequence": sequence, "kind": "hang", "duration_ms": 3.0, "scope": scope, "thread": role,
            "thread_kind": role, "frames": ["read + 4"]}


def hangs(count250=0, count=0, records=(), thread_hangs=(), thread_hang_count=None, installed=True, threshold_ms=250):
    reply = {"installed": installed, "threshold_ms": threshold_ms, "count": count, "count250": count250,
             "records": list(records)}
    if thread_hang_count is not None:
        reply.update(thread_hang_count=thread_hang_count, thread_hangs=list(thread_hangs))
    return reply


class FakeRpc:
    """The app socket: debug.blocking and debug.hangs answer from lists (the last one repeats). `None` in a list is a
    build without that method."""

    def __init__(self, blocking_replies, hangs_replies):
        self.blocking, self.hangs = list(blocking_replies), list(hangs_replies)
        self.calls = []

    @staticmethod
    def next(replies):
        reply = replies.pop(0) if len(replies) > 1 else replies[0]
        return reply if reply is not None else {"error": {"code": "method_not_found", "message": "Unknown method"}}

    def __call__(self, method, params=None, timeout=60):
        self.calls.append((method, params))
        assert not (params or {}).get("clear") and not (params or {}).get("reset"), "the story never clears"
        if method == "debug.blocking":
            return self.next(self.blocking)
        if method == "debug.hangs":
            return self.next(self.hangs)
        raise AssertionError(method)


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
               "storm_ops": {"move": 75}, "cef": {"valid": True, "problems": []}, "scenario_label": "stress-storm"}


def fake_trace(rpc):
    """A stand-in for trace.py: Recording runs build_stress then run_window; a stage's exception goes into the
    meta's errors and stops the run, as trace.py's Stages does."""
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

        def record(self):
            assert self.recorder == "none" and self.opts.hang_ms == 250 and self.opts.scenario == "stress-storm"
            with open(os.path.join(self.out, "host-env-full-4242.json"), "w") as f:
                json.dump({"ok": True, "reasons": []}, f)
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
    out = tempfile.mkdtemp(prefix="blocking-hangs-test-")
    test.addCleanup(lambda: __import__("shutil").rmtree(out, ignore_errors=True))
    module = fake_trace(rpc)
    saved_trace = sys.modules.get("cmux_next_trace")
    sys.modules["cmux_next_trace"] = module
    blobs = FakeBlobs()
    try:
        code = bh.main(["--app", "/tmp/cmux DEV t.app", "--out", out, *argv], blobs=blobs,
                       config_problem=config_problem)
    finally:
        if saved_trace is None:
            sys.modules.pop("cmux_next_trace", None)
        else:
            sys.modules["cmux_next_trace"] = saved_trace
    return code, out, blobs


def results_in(out):
    return [r for path in sorted(Path(out).glob("*.ndjson")) for r in writer.read_file(path)]


def summary_of(out):
    return json.loads((Path(out) / bh.SUMMARY).read_text())


class Blocking(unittest.TestCase):
    def test_build_without_detector_is_refused_not_zero(self):
        with self.assertRaises(bh.NoDetector) as caught:
            bh.parse_blocking(blocking(compiled_in=False))
        self.assertIn("bench-checks", str(caught.exception))
        with self.assertRaises(bh.NoDetector):
            bh.parse_blocking({"overflow": 0, "sites": []})  # no compiled_in at all

    def test_build_without_method_is_not_measurable(self):
        with self.assertRaises(bh.NotMeasurable):
            bh.parse_blocking({"error": {"code": "method_not_found"}})
        with self.assertRaises(bh.LegError):
            bh.parse_blocking({"error": "connection refused", "unreachable": True})

    def test_window_counts_sites_hit_in_the_window_only(self):
        before = bh.parse_blocking(blocking([site("A.swift:1", 3), site("B.swift:2", 1)]))
        after = bh.parse_blocking(blocking([site("A.swift:1", 3), site("B.swift:2", 4, total_ms=9.0),
                                            site("C.swift:3", 2), site("P.swift:4", 1, context="pool")]))
        window = bh.blocking_window(before, after)
        self.assertEqual([s["location"] for s in window["main"]["sites"]], ["B.swift:2", "C.swift:3"])
        self.assertEqual(window["main"]["sites"][0]["count"], 3)
        self.assertEqual(bh.site_count(window["main"]), (2, False))
        self.assertEqual(bh.site_count(window["pool"]), (1, False))
        self.assertEqual(bh.site_count(window["cpu-lane"]), (0, False))

    def test_overflow_makes_a_lower_bound_never_zero(self):
        before = bh.parse_blocking(blocking([], {"main": 2}))
        after = bh.parse_blocking(blocking([], {"main": 5}))
        self.assertEqual(bh.site_count(bh.blocking_window(before, after)["main"]), (1, True))

    def test_counts_going_back_are_refused(self):
        before = bh.parse_blocking(blocking([site("A.swift:1", 3)]))
        after = bh.parse_blocking(blocking([site("A.swift:1", 1)]))
        with self.assertRaises(bh.LegError):
            bh.blocking_window(before, after)

    def test_integral_float_counts_parse(self):
        reading = bh.parse_blocking(blocking([site("A.swift:1", 3.0)]))
        self.assertEqual(next(iter(reading.sites.values())).count, 3)


class Hangs(unittest.TestCase):
    def test_watchdog_not_running_is_a_leg_error(self):
        with self.assertRaises(bh.LegError):
            bh.parse_hangs(hangs(installed=False))

    def test_build_without_count250_is_not_measurable(self):
        reply = hangs()
        del reply["count250"]
        with self.assertRaises(bh.NotMeasurable):
            bh.parse_hangs(reply)

    def test_window_counts_main_hangs_and_thread_roles(self):
        before = bh.parse_hangs(hangs(count250=1, count=2, records=[stall(2, 300)],
                                      thread_hangs=[thread_hang(4, "lane")], thread_hang_count=4))
        after = bh.parse_hangs(hangs(count250=3, count=5, records=[stall(3, 260), stall(4, 1200), stall(5, 90, "busy"),
                                                                    stall(6, 120)],
                                     thread_hangs=[thread_hang(5, "lane"), thread_hang(6, "io"), thread_hang(7, "")],
                                     thread_hang_count=9))
        window = bh.hangs_window(before, after)
        self.assertEqual(window["over_250ms"], 2)
        self.assertEqual([r["sequence"] for r in window["stalls"]], [3, 4])
        self.assertEqual(window["roles"]["lane"], 1)
        self.assertEqual(window["roles"]["io"], 1)  # a record shows the role, so it is seen
        self.assertNotIn("renderer", window["roles"])  # no renderer thread is registered: unseen, not 0
        self.assertEqual(window["roles"]["unattributed"], 3)  # one with no kind, two the ring dropped

    def test_build_without_hang_watch_has_no_roles(self):
        window = bh.hangs_window(bh.parse_hangs(hangs()), bh.parse_hangs(hangs(count250=1)))
        self.assertIsNone(window["roles"])
        leg = bh.Leg("storm", "stress", "")
        metrics = bh.leg_metrics(leg, {"blocking": bh.blocking_window(bh.parse_blocking(blocking()),
                                                                      bh.parse_blocking(blocking())),
                                       "hangs": window})
        self.assertEqual(metrics["hangs.over_250ms.main"], 1)
        self.assertFalse([m for m in metrics if m.startswith("hang_watch.")])
        self.assertEqual(set(leg.unseen), {"hang_watch"})

    def test_cleared_counts_are_refused(self):
        with self.assertRaises(bh.LegError):
            bh.hangs_window(bh.parse_hangs(hangs(count250=4)), bh.parse_hangs(hangs(count250=0)))


class StoryRuns(unittest.TestCase):
    def test_storm_leg_stores_counts_with_targets_and_attachment(self):
        rpc = FakeRpc([blocking(), blocking([site("A.swift:1", 1)]),
                       blocking([site("A.swift:1", 2), site("Store.swift:9", 1)])],
                      [hangs(thread_hang_count=0), hangs(count250=1, count=1, records=[stall(1, 400)],
                                                         thread_hangs=[thread_hang(1, "lane")], thread_hang_count=1)])
        code, out, blobs = run_story(self, rpc)
        self.assertEqual(code, bh.EXIT_OK, summary_of(out))
        by_metric = {r.metric: r for r in results_in(out)}
        self.assertEqual(by_metric["main_blocking.sites"].samples, [2])
        self.assertEqual(by_metric["main_blocking.sites"].target_ref.target, "main-blocking-sites")
        self.assertEqual(by_metric["hangs.over_250ms.main"].samples, [1])
        self.assertEqual(by_metric["hangs.over_250ms.main"].target_ref.target, "hangs.app")
        self.assertFalse([m for m in by_metric if "daemon" in m])
        self.assertEqual(by_metric["hang_watch.past_deadline.lane"].samples, [1])
        self.assertNotIn("hang_watch.past_deadline.io", by_metric)
        self.assertEqual(summary_of(out)["legs"][0]["unseen"]["hang_watch.io"], bh.UNREGISTERED)
        for result in by_metric.values():
            self.assertEqual((result.unit, result.better, result.session, result.build.config),
                             ("count", "lower", "stress", "bench-checks"))
            self.assertEqual([a.kind for a in result.attachments], ["blocking-hangs"])
        (key, (data, _)), = blobs.objects.items()
        doc = json.loads(data)
        self.assertEqual(key, bh.attachment_key(next(iter(by_metric.values())).attachments[0].digest))
        self.assertEqual([s["location"] for s in doc["blocking"]["main"]["sites"]], ["A.swift:1", "Store.swift:9"])
        self.assertEqual(doc["hangs"]["main_stalls"][0]["frames"], ["app work + 1"])
        self.assertTrue((Path(out) / "storm-trace" / "host-env-full-4242.json").is_file())
        # Opening reads mark the newest record only; closing reads ask after the mark and skip over-budget records.
        hang_calls = [p for m, p in rpc.calls if m == "debug.hangs"]
        self.assertEqual(hang_calls[0]["limit"], 1)
        self.assertEqual((hang_calls[1]["after"], hang_calls[1]["thread_hangs_after"]), (0, 0))
        self.assertGreater(hang_calls[1]["over_budget_after"], 2 ** 48)
        # JSONValue.intValue (CmuxNextSettings/JSONValue.swift) reads abs >= 1e15 as nil, and nil means `after: 0`.
        self.assertLess(hang_calls[1]["over_budget_after"], 1e15)

    def test_build_without_detector_fails_before_the_stress_build_and_stores_nothing(self):
        rpc = FakeRpc([blocking(compiled_in=False)], [hangs()])
        code, out, blobs = run_story(self, rpc)
        self.assertEqual(code, bh.EXIT_FAILED)
        summary = summary_of(out)
        self.assertEqual(summary["refusal"]["kind"], "failed")
        self.assertIn("CMUX_BLOCKING_CHECKS", summary["refusal"]["reason"])
        self.assertEqual(results_in(out), [])
        self.assertEqual(blobs.objects, {})
        self.assertEqual([m for m, _ in rpc.calls], ["debug.blocking"])

    def test_stamped_bench_build_fails_without_a_launch(self):
        rpc = FakeRpc([blocking()], [hangs()])
        code, out, _ = run_story(self, rpc,
                                 config_problem=lambda app: "built with --config bench")
        self.assertEqual(code, bh.EXIT_FAILED)
        self.assertEqual(rpc.calls, [])
        self.assertIn("--config bench", summary_of(out)["refusal"]["reason"])

    def test_stamped_config_is_read_from_the_bundle(self):
        import plistlib
        app = Path(tempfile.mkdtemp(prefix="blocking-hangs-app-")) / "cmux DEV t.app"
        (app / "Contents").mkdir(parents=True)
        self.addCleanup(lambda: __import__("shutil").rmtree(app.parent, ignore_errors=True))
        for stamp, expected in (("bench", True), ("bench-checks", False), (None, False)):
            info = {"CFBundleIdentifier": "com.cmuxterm.app.next.debug.t"}
            if stamp:
                info["CMUXBuildConfiguration"] = stamp
            (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info))
            problem = bh.stamped_config_problem(str(app))
            self.assertEqual(problem is not None, expected, (stamp, problem))

    def test_build_without_debug_blocking_is_not_measurable(self):
        code, out, _ = run_story(self, FakeRpc([None], [hangs()]))
        self.assertEqual(code, bh.EXIT_NOT_MEASURABLE)
        self.assertEqual(summary_of(out)["refusal"]["kind"], "not-measurable")
        self.assertEqual(results_in(out), [])

    def test_missing_corpus_is_not_measured_and_the_storm_stands(self):
        rpc = FakeRpc([blocking()], [hangs(thread_hang_count=0)])
        saved = bh.ROOT
        bh.ROOT = tempfile.mkdtemp(prefix="blocking-hangs-root-")
        try:
            code, out, _ = run_story(self, rpc, argv=("--legs", "storm,corpus"))
        finally:
            bh.ROOT = saved
        self.assertEqual(code, bh.EXIT_OK)
        summary = summary_of(out)
        self.assertFalse(summary["corpus"]["measured"])
        self.assertIn("perf-corpus", summary["corpus"]["reason"])
        self.assertTrue(summary["legs"][0]["ok"])
        self.assertTrue(any(r.metric == "main_blocking.sites" for r in results_in(out)))


class RolesSeen(unittest.TestCase):
    def test_lane_only_registrations_write_no_other_role(self):
        before = bh.parse_hangs(hangs(thread_hang_count=0))
        after = bh.parse_hangs(hangs(thread_hangs=[thread_hang(1, "lane")], thread_hang_count=1))
        leg = bh.Leg("storm", "stress", "")
        empty = bh.blocking_window(bh.parse_blocking(blocking()), bh.parse_blocking(blocking()))
        metrics = bh.leg_metrics(leg, {"blocking": empty, "hangs": bh.hangs_window(before, after)})
        self.assertEqual({m: v for m, v in metrics.items() if m.startswith("hang_watch.")},
                         {"hang_watch.past_deadline.lane": 1})
        for role in ("main", "io", "renderer", "pool", "control"):
            self.assertEqual(leg.unseen[f"hang_watch.{role}"], bh.UNREGISTERED)
        self.assertFalse([m for m in metrics if m.startswith("hangs.over_250ms.") and m != "hangs.over_250ms.main"])


def corpus_checkout(test, ids):
    """A checkout root with perf-corpus/<id>.json (tier T1) and a player file; bh.ROOT points at it."""
    root = Path(tempfile.mkdtemp(prefix="blocking-hangs-root-"))
    test.addCleanup(lambda: __import__("shutil").rmtree(root, ignore_errors=True))
    (root / "perf-corpus").mkdir()
    for story_id in ids:
        (root / "perf-corpus" / f"{story_id}.json").write_text(json.dumps({"id": story_id, "tier": "T1"}))
    (root / "scripts" / "perf-lab" / "corpus").mkdir(parents=True)
    (root / "scripts" / "perf-lab" / "corpus" / "play.py").write_text("")
    saved = bh.ROOT
    bh.ROOT = str(root)
    test.addCleanup(lambda: setattr(bh, "ROOT", saved))
    return root


def fake_player(test, replay):
    """play.py as a module whose replay is `replay` (corpus_legs loads it by name, once)."""
    module = types.ModuleType("perf_lab_corpus_play")
    module.replay = replay
    saved = sys.modules.get("perf_lab_corpus_play")
    sys.modules["perf_lab_corpus_play"] = module
    test.addCleanup(lambda: sys.modules.__setitem__("perf_lab_corpus_play", saved) if saved is not None
                    else sys.modules.pop("perf_lab_corpus_play", None))


def corpus_rpc():
    """One replay's app: a site and a main hang in its window."""
    return FakeRpc([blocking(), blocking(), blocking([site("Replay.swift:7", 2)])],
                   [hangs(thread_hang_count=0), hangs(count250=1, count=1, records=[stall(1, 300)], thread_hang_count=0)])


class CorpusLegs(unittest.TestCase):
    def test_replay_with_the_window_hook_writes_corpus_results(self):
        corpus_checkout(self, ["chat-burst"])
        played = []

        def replay(manifest, *, app, out, window=None):
            bench = FakeBench(out, corpus_rpc())
            with window(bench):
                played.append(manifest)
            with open(os.path.join(out, "host-env-full-99.json"), "w") as f:
                json.dump({"ok": True}, f)

        fake_player(self, replay)
        code, out, blobs = run_story(self, None, argv=("--legs", "corpus"))
        self.assertEqual(code, bh.EXIT_OK, summary_of(out))
        self.assertEqual(len(played), 1)
        by_metric = {r.metric: r for r in results_in(out)}
        self.assertEqual(by_metric["corpus.chat-burst.main_blocking.sites"].samples, [1])
        self.assertEqual(by_metric["corpus.chat-burst.hangs.over_250ms.main"].samples, [1])
        for result in by_metric.values():
            self.assertTrue(result.metric.startswith("corpus.chat-burst."))
            self.assertIsNone(result.target_ref)  # only the storm leg claims targets
            self.assertEqual(result.session, "corpus:chat-burst")
            self.assertEqual([a.kind for a in result.attachments], ["blocking-hangs"])
        (_, (data, _)), = blobs.objects.items()
        self.assertEqual(json.loads(data)["leg"], "corpus:chat-burst")
        self.assertTrue((Path(out) / "corpus-chat-burst" / "host-env-full-99.json").is_file())
        summary = summary_of(out)
        self.assertTrue(summary["corpus"]["measured"])
        self.assertEqual([leg["name"] for leg in summary["legs"]], ["corpus:chat-burst"])

    def test_replay_without_the_hook_fails_its_leg_with_a_reason(self):
        corpus_checkout(self, ["chat-burst"])
        fake_player(self, lambda manifest, *, app, out: None)
        code, out, _ = run_story(self, None, argv=("--legs", "corpus"))
        self.assertEqual(code, bh.EXIT_FAILED)
        leg, = summary_of(out)["legs"]
        self.assertFalse(leg["ok"])
        self.assertIn("window", leg["reason"])
        self.assertEqual(results_in(out), [])

    def test_a_failed_launch_fails_only_its_leg(self):
        corpus_checkout(self, ["agent-swarm", "dev-loop"])
        launch_error = bh.launch_error()

        def replay(manifest, *, app, out, window=None):
            if manifest.endswith("agent-swarm.json"):
                raise launch_error("no-gui-session", {"detail": "no GUI session", "log_tail": ""})
            with window(FakeBench(out, corpus_rpc())):
                pass

        fake_player(self, replay)
        code, out, _ = run_story(self, None, argv=("--legs", "corpus"))
        self.assertEqual(code, bh.EXIT_FAILED)
        summary = summary_of(out)
        self.assertEqual(summary["exit"], bh.EXIT_FAILED)
        swarm, dev = summary["legs"]
        self.assertFalse(swarm["ok"])
        self.assertIn("no-gui-session", swarm["reason"])
        self.assertTrue(dev["ok"], dev)
        self.assertTrue(any(r.metric.startswith("corpus.dev-loop.") for r in results_in(out)))
        self.assertFalse(any(r.metric.startswith("corpus.agent-swarm.") for r in results_in(out)))


class Catalog(unittest.TestCase):
    def test_story_file_passes_the_lint_and_claims_both_targets(self):
        doc = json.loads(STORY_FILE.read_text())
        self.assertEqual((doc["id"], doc["config"], doc["command"][0]),
                         ("blocking-hangs", "bench-checks", "scripts/perf-lab/stories/blocking_hangs.py"))
        claimed = {m["target_ref"]["target"] for m in doc["metrics"] if "target" in m.get("target_ref", {})}
        self.assertEqual(claimed, {"main-blocking-sites", "hangs.app"})
        loaded = catalog.load_catalog(REPO_ROOT)
        self.assertEqual([p for p in loaded.problems if "blocking-hangs" in p], [])
        self.assertIn("blocking-hangs", {s.id for s in loaded.stories})
        claims = catalog.claimed_checks(loaded)
        self.assertIn("blocking-hangs", claims[("main-blocking-sites", "main_blocking\\.sites")])
        self.assertIn("blocking-hangs", claims[("hangs.app", "hangs\\.over_250ms\\.[a-z_]+")])

    def test_every_written_metric_name_matches_a_story_metric(self):
        import re
        patterns = [re.compile(m["name"]) for m in json.loads(STORY_FILE.read_text())["metrics"]]
        names = ["main_blocking.sites", "blocking.sites.pool", "blocking.sites.cpu_lane", "hangs.over_250ms.main",
                 *[f"hang_watch.past_deadline.{r}" for r in (*bh.THREAD_ROLES, "unattributed")]]
        for name in names + [f"corpus.chat-burst.{n}" for n in names]:
            self.assertTrue(any(p.fullmatch(name) for p in patterns), name)


if __name__ == "__main__":
    unittest.main()
