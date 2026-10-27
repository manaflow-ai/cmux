#!/usr/bin/env python3
"""stories/swift_benches.py: the Swift in-process bench stories (task 217). Every bench file has a story, the runner's
context is the writer's, a line the Swift writer writes is valid result-v1, and `run` keeps only this run's results
whose metrics the story lists, with a fake lane instead of swift test.

  python3 -m unittest scripts/perf-lab/tests/test_swift_benches.py
"""
from __future__ import annotations

import argparse
import importlib.util
import io
import json
import re
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
LAB = HERE.parent
ROOT = LAB.parent.parent

_SPEC = importlib.util.spec_from_file_location("perf_lab_swift_benches_under_test", LAB / "stories" / "swift_benches.py")
sb = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = sb
_SPEC.loader.exec_module(sb)
perf_result = sb.perf_result

WRITER = ROOT / sb.WRITER
FACTS = {"chip": "Apple M4 Pro", "memory_bytes": 48 * 2 ** 30, "macos": "26.1", "macos_build": "25B78"}
FLEET = {"CMUX_CI_STEP_KEY": "step-1"}


def swift_record(context: dict, metric: str, unit: str, samples: list, better: str = "lower") -> str:
    """The line PerfResultWriter.record writes: the runner's context with the metric's own fields."""
    fields = dict(context, schema=perf_result.SCHEMA_ID, metric=metric, unit=unit, better=better, samples=samples,
                  target_ref=None)
    return json.dumps(fields, sort_keys=True) + "\n"


def story_doc(story_id: str = "swift-lane-item", env: tuple = ("CMUX_LANE_ITEM_BENCH=1",)) -> dict:
    command = [sb.SCRIPT, "run", "--story", story_id, "--filter", "LaneStatsBench"]
    for assignment in env:
        command += ["--env", assignment]
    return {"id": story_id, "tier": "builder", "description": "d", "command": command, "session": "light",
            "engine": "none", "config": "release",
            "metrics": [{"name": r"swift\.lane_item\.(clock_read|record|per_item)_ns", "unit": "ns", "better": "lower"}],
            "repeats": 1, "seconds": 900,
            "needs": [f"file:{sb.TESTS}/CmuxNextWakeupsTests/LaneStatsBench.swift", f"file:{sb.WRITER}"],
            "owner": "Performance Lead", "component": "Scheduler>Lanes"}


class WriterContractTests(unittest.TestCase):
    """The Swift writer and this runner agree on the context, the units and the file name."""

    def setUp(self) -> None:
        self.swift = WRITER.read_text(encoding="utf-8")

    def test_the_context_keys_are_the_writers(self) -> None:
        block = re.search(r"contextKeys: Set<String> = \[(.*?)\]", self.swift, re.S).group(1)
        swift_keys = set(re.findall(r'"([a-z_]+)"', block))
        self.assertEqual(swift_keys, set(perf_result.TOP_LEVEL_KEYS) - set(sb.METRIC_KEYS))
        self.assertIn(f'contextFileName = "{sb.CONTEXT_FILE}"', self.swift)
        self.assertIn(f'directoryVariable = "{sb.RESULT_DIR_VARIABLE}"', self.swift)
        self.assertIn(f'schema = "{perf_result.SCHEMA_ID}"', self.swift)

    def test_every_writer_unit_is_a_result_v1_unit(self) -> None:
        enum = re.search(r"public enum Unit: String, Sendable, CaseIterable \{(.*?)\n    \}", self.swift, re.S).group(1)
        raw = set(re.findall(r'= "([^"]+)"', enum))
        bare = {name for line in re.findall(r"case ([^\n]+)", enum) for name in re.split(r",\s*", line)
                if "=" not in name}
        self.assertEqual(raw | bare, set(perf_result.UNITS))

    def test_a_swift_line_is_valid_result_v1_and_round_trips(self) -> None:
        host = sb.builder_host.host_block(FACTS)
        build = perf_result.Build(sha="a" * 40, config=sb.CONFIG, measure_version=sb.MEASURE_VERSION)
        context = sb.context("swift-lane-item", perf_result.Run.start(), build, host)
        self.assertEqual(set(context), set(perf_result.TOP_LEVEL_KEYS) - set(sb.METRIC_KEYS))
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "swift-x.ndjson"
            path.write_text(swift_record(context, "swift.lane_item.record_ns", "ns", [3.5, 1, 2]))
            (result,) = perf_result.read_file(path)
        self.assertEqual(result.samples, [3.5, 1, 2])
        self.assertEqual(result.build.config, "release")
        self.assertEqual(result.story, "swift-lane-item")


class CatalogTests(unittest.TestCase):
    def test_every_bench_file_has_a_story_that_writes_results(self) -> None:
        stories = sb.swift_stories()
        self.assertEqual(sb.coverage_problems(ROOT, stories), [])
        bench_files = sb.bench_files(ROOT)
        self.assertGreaterEqual(len(bench_files), 19)
        claimed = {path for story in stories for path in story.bench_files}
        self.assertLessEqual(set(bench_files) - claimed, set(sb.NOT_BENCHES))
        for path in sb.NOT_BENCHES:
            self.assertTrue((ROOT / path).is_file(), path)

    def test_every_swift_story_is_a_builder_release_story_with_an_owner(self) -> None:
        catalog = load_catalog()
        found = {story.id: story for story in catalog.load_catalog(ROOT).stories}
        for story in sb.swift_stories():
            with self.subTest(story=story.id):
                linted = found[story.id]
                self.assertEqual((linted.tier, linted.config, linted.engine, linted.session),
                                 ("builder", "release", "none", "light"))
                self.assertTrue(linted.owner)
                self.assertTrue(all(m.name.startswith(("swift\\.", "pane_bench\\.")) for m in linted.metrics))

    def test_the_catalog_lint_has_no_problem_with_the_swift_stories(self) -> None:
        problems = load_catalog().load_catalog(ROOT).problems
        self.assertEqual([p for p in problems if "swift" in p or "pane-bench" in p], [])

    def test_a_missing_bench_and_an_unclaimed_bench_are_problems(self) -> None:
        stories = sb.swift_stories()
        lane = next(story for story in stories if story.id == "swift-lane-item")
        gone = sb.SwiftStory(id="swift-gone", path=lane.path, filter="Gone", env=(),
                             bench_files=(f"{sb.TESTS}/CmuxNextWakeupsTests/GoneBench.swift",), metrics=lane.metrics)
        rest = [story for story in stories if story.id != "swift-lane-item"] + [gone]
        problems = sb.coverage_problems(ROOT, rest)
        self.assertTrue(any("GoneBench.swift does not exist" in p for p in problems), problems)
        self.assertTrue(any("LaneStatsBench.swift: a bench with no story" in p for p in problems), problems)

    def test_a_story_command_must_name_itself_one_filter_and_the_writer(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "swift-lane-item.json"
            doc = story_doc()
            doc["command"][3] = "swift-other"
            path.write_text(json.dumps(doc))
            with self.assertRaisesRegex(sb.StoryError, "own id"):
                sb.load_story(path)
            doc = story_doc()
            doc["needs"] = doc["needs"][:1]
            path.write_text(json.dumps(doc))
            with self.assertRaisesRegex(sb.StoryError, "PerfResultWriter"):
                sb.load_story(path)
            doc = story_doc(env=(f"{sb.RESULT_DIR_VARIABLE}=/tmp/x",))
            path.write_text(json.dumps(doc))
            with self.assertRaisesRegex(sb.StoryError, "runner owns it"):
                sb.load_story(path)


def load_catalog():
    if str(LAB) not in sys.path:
        sys.path.insert(0, str(LAB))
    spec = importlib.util.spec_from_file_location("perf_lab_catalog_under_swift_benches_test", LAB / "catalog.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class RunTests(unittest.TestCase):
    def setUp(self) -> None:
        self._dir = tempfile.TemporaryDirectory()
        self.work = Path(self._dir.name)
        self.stories = self.work / "stories.d"
        self.stories.mkdir()
        (self.stories / "swift-lane-item.json").write_text(json.dumps(story_doc()))
        self.out = self.work / "out"
        self.calls: list = []

    def tearDown(self) -> None:
        self._dir.cleanup()

    def args(self, **overrides) -> argparse.Namespace:
        values = dict(story="swift-lane-item", filter="LaneStatsBench", env=["CMUX_LANE_ITEM_BENCH=1"], out=self.out,
                      app=None, tag=None, session=None)
        values.update(overrides)
        return argparse.Namespace(**values)

    def run_story(self, lines=None, status: int = 0, environ=None, **overrides):
        """`run` with a fake lane that writes each (metric, unit, samples) as the Swift writer would."""

        def lane(command, env, cwd):
            self.calls.append((command, env, cwd))
            results = Path(env[sb.RESULT_DIR_VARIABLE])
            context = json.loads((results / sb.CONTEXT_FILE).read_text())
            for index, line in enumerate(lines(context) if lines else []):
                (results / f"swift-{index}.ndjson").write_text(line)
            return status

        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            code = sb.run(self.args(**overrides), FLEET if environ is None else environ, runner=lane,
                          host_facts=lambda: FACTS, hostname="aws-m4pro-7", stories_dir=self.stories, repo=ROOT)
        return code, stdout.getvalue(), stderr.getvalue()

    def test_the_lane_runs_the_bench_in_release_with_its_env_and_the_result_folder(self) -> None:
        code, _, err = self.run_story(lambda c: [swift_record(c, "swift.lane_item.record_ns", "ns", [2.5])])
        self.assertEqual(code, 0, err)
        ((command, env, cwd),) = self.calls
        self.assertEqual(command[1:], ["suite", sb.PACKAGE, "LaneStatsBench"])
        self.assertTrue(command[0].endswith(sb.LANE))
        self.assertEqual(env["CMUX_SWIFT_SUITE_CONFIGURATION"], "release")
        self.assertEqual(env["CMUX_LANE_ITEM_BENCH"], "1")
        self.assertEqual(env[sb.RESULT_DIR_VARIABLE], str(self.out.resolve() / sb.RESULTS_DIR))
        (result,) = perf_result.read_dir(self.out / sb.RESULTS_DIR)
        self.assertEqual((result.story, result.metric, result.samples), ("swift-lane-item", "swift.lane_item.record_ns",
                                                                         [2.5]))
        self.assertEqual(result.build.sha, sb.subprocess.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"],
                                                             capture_output=True, text=True).stdout.strip())
        self.assertIsNone(result.host.display_hz)

    def test_an_unlisted_metric_another_run_and_a_broken_file_are_rejected(self) -> None:
        def lines(context):
            other = dict(context, run={"id": "other", "started_at": context["run"]["started_at"]})
            return [swift_record(context, "swift.lane_item.record_ns", "ns", [1]),
                    swift_record(context, "swift.lane_item.unlisted_ns", "ns", [1]),
                    swift_record(context, "swift.lane_item.record_ns", "ms", [1]),
                    swift_record(other, "swift.lane_item.record_ns", "ns", [1]),
                    "{not json\n"]

        code, _, err = self.run_story(lines)
        self.assertEqual(code, 1)
        self.assertEqual(len(list((self.out / sb.RESULTS_DIR).glob("*.ndjson"))), 1)
        self.assertEqual(len(list((self.out / sb.REJECTED_DIR).glob("*.ndjson"))), 4)
        self.assertIn("matches no metric", err)
        self.assertIn("run differ", err)

    def test_a_metric_recorded_twice_in_the_run_is_rejected_as_ingest_would(self) -> None:
        def lines(context):
            return [swift_record(context, "swift.lane_item.record_ns", "ns", [1]),
                    swift_record(context, "swift.lane_item.record_ns", "ns", [2]),
                    swift_record(context, "swift.lane_item.per_item_ns", "ns", [3]),
                    swift_record(context, "swift.lane_item.clock_read_ns", "ns", [4])
                    + swift_record(context, "swift.lane_item.clock_read_ns", "ns", [5])]

        code, _, err = self.run_story(lines)
        self.assertEqual(code, 1)
        kept = perf_result.read_dir(self.out / sb.RESULTS_DIR)
        self.assertEqual([result.metric for result in kept], ["swift.lane_item.per_item_ns"])
        self.assertEqual(sorted(p.name for p in (self.out / sb.REJECTED_DIR).glob("*.ndjson")),
                         ["swift-0.ndjson", "swift-1.ndjson", "swift-3.ndjson"])
        self.assertIn("metric swift.lane_item.record_ns is recorded twice in this run (swift-0.ndjson, swift-1.ndjson)",
                      err)
        self.assertIn("metric swift.lane_item.clock_read_ns is recorded twice in this run (swift-3.ndjson)", err)

    def test_a_failed_suite_keeps_its_results_and_exits_one(self) -> None:
        code, _, _ = self.run_story(lambda c: [swift_record(c, "swift.lane_item.record_ns", "ns", [1])], status=1)
        self.assertEqual(code, 1)
        self.assertEqual(len(perf_result.read_dir(self.out / sb.RESULTS_DIR)), 1)

    def test_a_skipped_bench_writes_nothing_and_exits_two(self) -> None:
        code, _, err = self.run_story(None)
        self.assertEqual(code, 2)
        self.assertIn("CMUX_LANE_ITEM_BENCH", err)

    def test_off_the_fleet_or_on_a_lab_host_nothing_runs(self) -> None:
        code, _, err = self.run_story(None, environ={})
        self.assertEqual((code, self.calls), (2, []))
        self.assertIn("only on the build fleet", err)
        code, _, err = self.run_story(None, environ={**FLEET, "CMUX_CI_LABELS": "measure,perf-lab"})
        self.assertEqual((code, self.calls), (2, []))
        self.assertIn("perf-lab label", err)

    def test_arguments_that_differ_from_the_story_or_another_session_are_refused(self) -> None:
        code, _, err = self.run_story(None, filter="OtherBench")
        self.assertEqual((code, self.calls), (2, []))
        self.assertIn("differ", err)
        code, _, _ = self.run_story(None, session="stress")
        self.assertEqual((code, self.calls), (2, []))

    def test_the_runner_flags_parse_after_the_story_command(self) -> None:
        doc = story_doc()
        args = sb.parse_args(doc["command"][1:] + ["--app", "A.app", "--tag", "t", "--out", str(self.out)])
        self.assertEqual((args.story, args.filter, args.env, args.app), ("swift-lane-item", "LaneStatsBench",
                                                                         ["CMUX_LANE_ITEM_BENCH=1"], "A.app"))


if __name__ == "__main__":
    unittest.main()
