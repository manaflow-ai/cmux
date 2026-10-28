#!/usr/bin/env python3
"""canary.py: the scratch history, its T0 lane and the three checks of done check 10.

  python3 -m unittest scripts/perf-lab/tests/test_canary.py
"""
from __future__ import annotations

import argparse
import contextlib
import importlib.util
import io
import json
import random
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import types
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

LAB = Path(__file__).resolve().parent.parent
ROOT = LAB.parents[1]


def _load(name: str, path: Path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


canary = _load("perf_lab_canary", LAB / "canary.py")
store = _load("perf_lab_store", LAB / "store.py")
scheduler = _load("perf_lab_scheduler", LAB / "scheduler.py")
lab = _load("perf_lab_lab", LAB / "lab.py")

T0 = datetime(2026, 10, 26, 12, 0, tzinfo=timezone.utc)
RUN_ID = "20261026T120000Z-0123456789ab"
BASE_POS = 1000


def _git(*args: str, cwd: Path) -> str:
    done = subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True, check=True)
    return done.stdout.strip()


class LayoutTests(unittest.TestCase):
    def test_default_layout_has_six_batches_on_each_side_of_the_injected_one(self):
        layout = canary.Layout()
        self.assertEqual((layout.batches, layout.batch_commits, layout.injected_batch), (13, 4, 6))
        self.assertEqual(layout.total, 52)
        self.assertEqual(canary.ALERT_WITHIN_BATCHES, 7)

    def test_injected_commit_is_never_a_batch_tip(self):
        with self.assertRaises(canary.CanaryError):
            canary.Layout(injected_offset=3)
        for seed in range(50):
            layout = canary.choose_layout(random.Random(seed))
            self.assertLess(layout.injected_offset, layout.batch_commits - 1)
        self.assertEqual(canary.choose_layout(random.Random(1), at=2).injected_index, 6 * 4 + 2)

    def test_seed_picks_the_same_commit(self):
        self.assertEqual(canary.choose_layout(random.Random(7)), canary.choose_layout(random.Random(7)))


class ScratchRefTests(unittest.TestCase):
    def test_refuses_every_ref_outside_the_canary_namespace(self):
        refused = ["refs/heads/feat-cmux-next", "refs/heads/perf/chrome-parity", "refs/heads/main",
                   "refs/heads/perf-lab/canary/feat-cmux-next", "refs/heads/perf-lab/canary/../../main",
                   f"refs/heads/perf-lab/canary/{RUN_ID}/x", f"refs/tags/perf-lab/canary/{RUN_ID}"]
        calls = []
        for ref in refused:
            with self.assertRaises(canary.CanaryError, msg=ref):
                canary.push_scratch(Path("."), "origin", "a" * 40, ref, git=lambda *a, cwd: calls.append(a) or "")
            with self.assertRaises(canary.CanaryError, msg=ref):
                canary.delete_scratch(Path("."), "origin", ref, git=lambda *a, cwd: calls.append(a) or "")
        self.assertEqual(calls, [])
        canary.delete_scratch(Path("."), "origin", canary.scratch_ref(RUN_ID),
                              git=lambda *a, cwd: calls.append(a) or "")
        self.assertEqual(calls, [("push", "--quiet", "origin", f":refs/heads/perf-lab/canary/{RUN_ID}")])
        with self.assertRaises(canary.CanaryError):
            canary.scratch_ref("feat-cmux-next")
        self.assertEqual(canary.scratch_ref(RUN_ID), f"refs/heads/perf-lab/canary/{RUN_ID}")

    def test_run_id_is_utc_stamp_and_tip(self):
        tip = "0123456789ab" + "c" * 28
        self.assertEqual(canary.run_id_for(T0, tip), RUN_ID)


class TurnOnTests(unittest.TestCase):
    def test_turns_the_shipped_feature_on_in_every_channel_and_keeps_the_rest(self):
        text = (ROOT / canary.FEATURE_FILE).read_text(encoding="utf-8")
        before, after = json.loads(text), json.loads(canary.turn_on(text))
        self.assertEqual(before["defaults"], {"dev": False, "nightly": False, "release": False})
        self.assertEqual(after["defaults"], {"dev": True, "nightly": True, "release": True})
        self.assertEqual({k: v for k, v in after.items() if k != "defaults"},
                         {k: v for k, v in before.items() if k != "defaults"})

    def test_refuses_another_feature(self):
        other = (ROOT / "schemas/features/features.d/perfLabKillProbe.json").read_text(encoding="utf-8")
        with self.assertRaises(canary.CanaryError):
            canary.turn_on(other)

    def test_the_real_generator_writes_the_flip(self):
        """The flip commit regenerates the Swift registry with the tree's own gen-features.py."""
        with tempfile.TemporaryDirectory() as temp:
            tree = Path(temp)
            for rel in ("schemas/features", "scripts/perf-lab/stories.d"):
                shutil.copytree(ROOT / rel, tree / rel)
            for rel in (canary.GENERATOR, "plans/cmux-next/OWNERS.md", "plans/cmux-next/perf-lead.md",
                        "Packages/macOS/CmuxNext/Package.swift", canary.GENERATED_SWIFT):
                (tree / rel).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / rel, tree / rel)
            path = tree / canary.FEATURE_FILE
            path.write_text(canary.turn_on(path.read_text(encoding="utf-8")), encoding="utf-8")
            canary.regenerate_registry(tree)
            swift = (tree / canary.GENERATED_SWIFT).read_text(encoding="utf-8")
        block = swift[swift.index("public static let perfLabCanary"):]
        block = block[:block.index(")\n\n")]
        self.assertIn("defaults: FeatureDefaults(dev: true, nightly: true, release: true)", block)


def _make_repo(root: Path) -> tuple[Path, Path, str]:
    """A lab checkout with the canary's feature file, its remote (bare) and its feat-cmux-next tip."""
    remote, repo = root / "remote.git", root / "repo"
    _git("init", "--quiet", "--bare", str(remote), cwd=root)
    _git("init", "--quiet", "-b", "feat-cmux-next", str(repo), cwd=root)
    feature = repo / canary.FEATURE_FILE
    feature.parent.mkdir(parents=True)
    shutil.copy2(ROOT / canary.FEATURE_FILE, feature)
    generated = repo / canary.GENERATED_SWIFT
    generated.parent.mkdir(parents=True)
    generated.write_text("dev: false\n", encoding="utf-8")
    _git("add", "-A", cwd=repo)
    _git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet", "-m", "base", cwd=repo)
    _git("remote", "add", "origin", str(remote), cwd=repo)
    _git("push", "--quiet", "origin", "feat-cmux-next", cwd=repo)
    return repo, remote, _git("rev-parse", "HEAD", cwd=repo)


class BuildScratchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.repo, self.remote, self.tip = _make_repo(Path(self.temp.name))

    def tearDown(self):
        self.temp.cleanup()

    @staticmethod
    def regenerate(tree: Path) -> None:
        defaults = json.loads((tree / canary.FEATURE_FILE).read_text(encoding="utf-8"))["defaults"]
        (tree / canary.GENERATED_SWIFT).write_text(f"dev: {str(defaults['dev']).lower()}\n", encoding="utf-8")

    def test_one_flip_commit_inside_its_batch_and_empty_commits_around_it(self):
        layout = canary.Layout(injected_offset=1)
        scratch = canary.build_scratch(self.repo, self.tip, RUN_ID, layout, git=canary.git_runner(),
                                       regenerate=self.regenerate)
        self.assertEqual(len(scratch.batches), 13)
        commits = [sha for batch in scratch.batches for sha in batch.commits]
        self.assertEqual(len(commits), 52)
        self.assertEqual(scratch.injected, commits[6 * 4 + 1])
        self.assertNotIn(scratch.injected, [batch.tip for batch in scratch.batches])
        self.assertEqual(_git("rev-list", "--first-parent", "--reverse", f"{self.tip}..{commits[-1]}", cwd=self.repo)
                         .split(), commits)
        changed = {sha: _git("diff-tree", "--no-commit-id", "--name-only", "-r", sha, cwd=self.repo).split()
                   for sha in commits}
        self.assertEqual({sha for sha, files in changed.items() if files}, {scratch.injected})
        self.assertEqual(sorted(changed[scratch.injected]), sorted([canary.FEATURE_FILE, canary.GENERATED_SWIFT]))
        on = json.loads(_git("show", f"{scratch.injected}:{canary.FEATURE_FILE}", cwd=self.repo))
        off = json.loads(_git("show", f"{scratch.injected}^:{canary.FEATURE_FILE}", cwd=self.repo))
        self.assertEqual((on["defaults"]["dev"], off["defaults"]["dev"]), (True, False))
        self.assertEqual(_git("show", f"{commits[-1]}:{canary.GENERATED_SWIFT}", cwd=self.repo), "dev: true")
        self.assertEqual(len(_git("worktree", "list", "--porcelain", cwd=self.repo).split("\n\n")), 1)

        canary.push_scratch(self.repo, "origin", commits[-1], canary.scratch_ref(RUN_ID), git=canary.git_runner())
        heads = _git("for-each-ref", "--format=%(refname) %(objectname)", cwd=self.remote).splitlines()
        self.assertEqual(sorted(heads), sorted([f"refs/heads/feat-cmux-next {self.tip}",
                                                f"refs/heads/perf-lab/canary/{RUN_ID} {commits[-1]}"]))
        self.assertEqual(_git("rev-parse", f"refs/perf-lab/canary/{RUN_ID}", cwd=self.repo), commits[-1])

    def test_a_tip_without_the_feature_is_refused_and_leaves_no_worktree(self):
        _git("rm", "--quiet", canary.FEATURE_FILE, cwd=self.repo)
        _git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet", "-m", "drop", cwd=self.repo)
        tip = _git("rev-parse", "HEAD", cwd=self.repo)
        with self.assertRaises(canary.CanaryError):
            canary.build_scratch(self.repo, tip, RUN_ID, canary.Layout(), git=canary.git_runner(),
                                 regenerate=self.regenerate)
        self.assertEqual(len(_git("worktree", "list", "--porcelain", cwd=self.repo).split("\n\n")), 1)


def _record(injected_batch: int = 6) -> "canary.RunRecord":
    batches = []
    for index in range(13):
        first = f"{index:02d}" + "a" * 38
        tip = f"{index:02d}" + "f" * 38
        batches.append({"first": first, "tip": tip, "commits": [first, tip], "t0_at": None, "attempt": 0,
                        "attempt_at": None})
    return canary.RunRecord(RUN_ID, canary._stamp(T0), "origin", "b" * 40, "06" + "c" * 38, BASE_POS + 6 * 4 + 2,
                            injected_batch, ["terminal-key"], batches)


def _story(story_id: str, tier: str, *metrics: str):
    """A catalog.Story's fields key_frame_stories reads."""
    return types.SimpleNamespace(id=story_id, tier=tier, metrics=tuple(types.SimpleNamespace(name=m) for m in metrics))


STORIES = (scheduler.StorySpec("terminal-key", "T0", 60, "bench"), scheduler.StorySpec("switch", "T0", 40, "bench"),
           scheduler.StorySpec("cold-launch", "T1", 300, "bench"))
SHARDS = scheduler.ShardMap.from_document({"classes": {"m6": {"tiers": ["T0", "T1"], "shards": [
    {"index": 0, "stories": {"T0": ["terminal-key"], "T1": ["cold-launch"]}},
    {"index": 1, "stories": {"T0": ["switch"]}}]}}})
HOSTS = [scheduler.Host("cmux15", "waterfall", "m6", "apple-m6/16gb/120hz", shard=0),
         scheduler.Host("cmux16", "waterfall", "m6", "apple-m6/16gb/120hz", shard=1),
         scheduler.Host("cmux17", "pinpoint", "m6", "apple-m6/16gb/120hz")]


class KeyFrameStoryTests(unittest.TestCase):
    def test_the_catalog_on_this_branch_has_the_terminal_key_frame_t0_story(self):
        """p12-perf-process-050 put terminal key->frame light in T0 (typing-terminal), so the 2 ms key-down spin
        moves a T0 series."""
        catalog = _load("perf_lab_catalog", LAB / "catalog.py")
        found = canary.key_frame_stories(catalog.load_catalog(ROOT).stories,
                                         scheduler.ShardMap.load(LAB / "shard_map.json"))
        self.assertIn("typing-terminal", found)

    def test_the_spin_is_on_the_path_of_the_t0_story_keys(self):
        """typing-terminal types with debug.key into a window that is never key (BenchApp sets CMUX_NEXT_NO_ACTIVATE),
        which skips CmuxApplication's dispatch and so its keyDownInterceptor. The spin is composed into
        AppServices.routeKeyDown, which the interceptor and debug.key both call; a debug.key that called the router
        directly would type past the spin and no canary run could alert."""
        app = ROOT / "Packages/macOS/CmuxNext/Sources/CmuxNextApp"
        services = (app / "AppServices.swift").read_text()
        self.assertRegex(services, r"lazy var routeKeyDown[^\n]*= PerfLabCanaryKeyDown\(")
        self.assertRegex(services, r"keyDownInterceptor = \{[^\n]*\n[^\n]*\n[^\n]*routeKeyDown\(event, window\)")
        debug_key = (app / "Focus/DebugKey.swift").read_text()
        self.assertIn("services.routeKeyDown(event, window)", debug_key)
        self.assertNotIn("keyRouter.interceptKeyDown(", debug_key)
        typing_terminal = json.loads((LAB / "stories.d/typing-terminal.json").read_text())
        self.assertEqual(Path(typing_terminal["command"][0]).name, "typing-frame-bench.py")

    def test_only_sharded_t0_stories_with_a_key_to_frame_metric_count(self):
        stories = [_story("terminal-key", "T0", r"terminal\.light\.key_to_frame"),
                   _story("switch", "T0", r"switch\.ms"),
                   _story("cold-launch", "T1", r"omnibar\.(idle|load)\.key_to_frame"),
                   _story("omnibar-key", "T0", r"omnibar\.(idle|load)\.key_to_frame")]  # not in the shard map
        self.assertEqual(canary.key_frame_stories(stories, SHARDS), ("terminal-key",))
        with self.assertRaises(canary.CanaryError):
            canary.key_frame_stories(stories[1:], SHARDS)

    def test_run_refuses_before_building_or_pushing_anything(self):
        with tempfile.TemporaryDirectory() as temp:
            parser = argparse.ArgumentParser()
            canary.add_arguments("canary", parser)
            args = parser.parse_args(["--run", "--data-dir", temp, "--tip", "a" * 40])
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                self.assertEqual(canary.run("canary", args, out=io.StringIO()), 2)
            # The catalog has a T0 key-to-frame story, so the refusal is the missing labd of the empty data dir.
            self.assertIn("labd does not run on", err.getvalue())
            self.assertEqual(list(Path(temp).iterdir()), [])


class AdvanceTests(unittest.TestCase):
    def setUp(self):
        self.record = _record()
        self.tips = {b["tip"] for b in self.record.batches}

    def test_asks_one_round_per_batch_once_built_at_most_every_batch_interval(self):
        now = T0
        self.assertEqual(canary.advance(self.record, now, set(), set()), [])
        self.assertIsNone(self.record.batches[0]["t0_at"])
        self.assertEqual(len(canary.advance(self.record, now, self.tips, set())), 1)
        self.assertEqual(self.record.batches[0]["attempt"], 1)
        self.assertEqual(canary.advance(self.record, now + scheduler.BATCH_INTERVAL - timedelta(seconds=1), self.tips,
                                        set()), [])
        for step in range(1, 30):
            canary.advance(self.record, now + step * scheduler.BATCH_INTERVAL, self.tips,
                           {(b["tip"], "terminal-key") for b in self.record.batches})
        self.assertTrue(all(b["t0_at"] for b in self.record.batches))
        asked = [canary._time(b["t0_at"]) for b in self.record.batches]
        self.assertTrue(all(later - earlier >= scheduler.BATCH_INTERVAL for earlier, later in zip(asked, asked[1:])))

    def test_a_round_with_no_result_is_asked_again_under_a_new_attempt(self):
        canary.advance(self.record, T0, self.tips, set())
        first = canary.round_id(self.record, 0, 1)
        later = T0 + canary.ROUND_RETRY
        lines = canary.advance(self.record, later, self.tips, set())
        self.assertEqual(self.record.batches[0]["attempt"], 2)
        self.assertIn("attempt 2", lines[0])
        self.assertEqual(self.record.batches[0]["t0_at"], canary._stamp(T0), "the cadence counts the first ask")
        rounds = canary.LaneDocument.of(self.record, Path("/lane"), set()).lane.rounds
        self.assertEqual([r.id for r in rounds][:1], [canary.round_id(self.record, 0, 2)])
        self.assertNotEqual(rounds[0].id, first)
        measured = {(self.record.batches[0]["tip"], "terminal-key")}
        canary.advance(self.record, later + canary.ROUND_RETRY, self.tips, measured)
        self.assertEqual(self.record.batches[0]["attempt"], 2, "a measured round is never asked again")


class LaneDocumentTests(unittest.TestCase):
    def test_round_trips_and_lists_only_unmeasured_rounds(self):
        record = _record()
        for index in range(3):
            canary.advance(record, T0 + index * scheduler.BATCH_INTERVAL, {b["tip"] for b in record.batches}, set())
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp) / RUN_ID
            record.save(directory)
            measured = {(record.batches[0]["tip"], "terminal-key")}
            document = canary.LaneDocument.of(record, directory, measured)
            canary._write_json(directory / canary.LANE_FILE, document.to_document())
            [read] = canary.lane_documents(Path(temp))
        self.assertEqual(read, document)
        self.assertEqual(read.lane.name, f"canary/{RUN_ID}")
        self.assertEqual(read.mainline, f"refs/perf-lab/canary/{RUN_ID}")
        self.assertEqual(read.store, directory / canary.DB_NAME)
        self.assertEqual([r.sha for r in read.lane.rounds], [b["tip"] for b in record.batches[1:3]])
        self.assertEqual(read.lane.builds, tuple(b["tip"] for b in record.batches))
        self.assertEqual(read.commits, {sha for b in record.batches for sha in b["commits"]})

    def test_a_finished_or_broken_lane_is_skipped(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            finished = _record()
            finished.save(root / RUN_ID)
            broken = canary.RunRecord(**{**_record().__dict__, "run_id": "20261019T120000Z-0123456789ab"})
            broken.save(root / broken.run_id)
            (root / broken.run_id / canary.LANE_FILE).write_text('{"schema": "cmux-perf-lab-lane/v1", "name": "x"}')
            with contextlib.redirect_stderr(io.StringIO()) as err:
                self.assertEqual(canary.lane_documents(root), [])
            self.assertIn("skipped", err.getvalue())


class SchedulerLaneTests(unittest.TestCase):
    """The lane in labd's real scheduler (scheduler.plan): owners, one job per host, the waterfall first."""

    def lane(self, record, measured=frozenset()):
        return canary.LaneDocument.of(record, Path("/lane"), set(measured)).lane

    def plan(self, lane, *, hosts=HOSTS, ready=None, state=None, log=()):
        builds = scheduler.Builds(ready=frozenset(ready if ready is not None else
                                                  {(sha, "bench") for sha in lane.builds}))
        return scheduler.plan(state or scheduler.State(), T0, hosts, builds, log, stories=STORIES, shard_map=SHARDS,
                              lanes=[lane])

    def asked(self):
        record = _record()
        canary.advance(record, T0, {b["tip"] for b in record.batches}, set())
        return record

    def test_a_round_runs_only_the_key_frame_story_on_its_owner(self):
        record = self.asked()
        result = self.plan(self.lane(record))
        self.assertEqual([(j.id, j.host, j.stories, j.sha, j.first, j.tier, j.kind, j.lane, j.reference)
                          for j in result.jobs],
                         [(f"canary:{RUN_ID}:T0-1.1:m6.0", "cmux15", ("terminal-key",), record.batches[0]["tip"],
                           record.batches[0]["first"], "T0", "waterfall", f"canary/{RUN_ID}", None)])
        self.assertEqual(result.state.queue, (), "a lane round is never a waterfall queue item")
        self.assertEqual(result.state.t0_count, {}, "nor counts toward the reference cadence")
        again = self.plan(self.lane(record), state=result.state)
        self.assertEqual(again.jobs, (), "a lane job id starts once")

    def test_a_busy_or_down_owner_gets_no_lane_job(self):
        record = self.asked()
        for change in ({"busy": True}, {"up": False}):
            hosts = [scheduler.replace(HOSTS[0], **change), *HOSTS[1:]]
            self.assertEqual(self.plan(self.lane(record), hosts=hosts).jobs, (), change)

    def test_the_waterfall_t0_goes_first(self):
        record = self.asked()
        branch = ("e" * 40,)
        ready = {(sha, "bench") for sha in (*self.lane(record).builds, *branch)}
        state = scheduler.plan(scheduler.State(), T0 - scheduler.BATCH_INTERVAL, HOSTS, scheduler.Builds(), branch,
                               stories=STORIES, shard_map=SHARDS).state
        result = self.plan(self.lane(record), ready=ready, state=state, log=branch)
        on_owner = [j for j in result.jobs if j.host == "cmux15"]
        self.assertEqual([(j.round, j.lane) for j in on_owner], [("T0-1", None)])

    def test_builds_wait_and_are_requested_ahead(self):
        record = self.asked()
        result = self.plan(self.lane(record), ready=set())
        self.assertEqual(result.jobs, ())
        self.assertEqual([(b.sha, b.config, b.reason) for b in result.builds],
                         [(b["tip"], "bench", f"lane:canary/{RUN_ID}") for b in record.batches])

    def test_a_refused_lane_job_and_a_refused_build_are_asked_for_again(self):
        record = self.asked()
        lane = self.lane(record)
        with tempfile.TemporaryDirectory() as temp:
            driver = scheduler.Driver(Path(temp) / "scheduler.json", ls_remote=lambda: None,
                                      first_parent=lambda anchor, tip: None, stories=STORIES, shard_map=SHARDS,
                                      clock=lambda: T0)
            job_id = f"canary:{RUN_ID}:T0-1.1:m6.0"
            ready = scheduler.Builds(ready=frozenset({(record.batches[0]["tip"], "bench")}))
            refused_build = (record.batches[1]["tip"], "bench")
            first = driver.tick(HOSTS, ready, lanes=[lane],
                                submit=lambda plan: scheduler.Rejected(jobs=frozenset({job_id}),
                                                                       builds=frozenset({refused_build})))
            self.assertEqual([j.id for j in first.jobs], [job_id])
            second = driver.tick(HOSTS, ready, lanes=[lane], submit=lambda plan: scheduler.Rejected())
            self.assertEqual([j.id for j in second.jobs], [job_id])
            self.assertEqual([(b.sha, b.config) for b in second.builds], [refused_build])


class LaneStore:
    """A lane store with T0 points at the batch tips and the alert, bisect and verify rows a run produces."""

    HOST = store.Host("cmux15", "Apple M6", 16, 120, "fp")

    def __init__(self, path: Path, record) -> None:
        self.path, self.record = path, record
        self.db = store.Store(path)
        self.db.migrate()

    def close(self) -> None:
        self.db.close()

    def point(self, batch: int, at: datetime, value: float) -> None:
        tip = self.record.batches[batch]["tip"]
        run = store.Run(f"run-{batch}", "waterfall", "m1", "terminal-key", "none", 26, "26A1", "h", "off", at,
                        tier="T0")
        self.db.insert_run(run, build=store.Build(tip, "bench", BASE_POS + batch * 4 + 3), host=self.HOST,
                           metrics=[store.Metric("key_to_frame_ms", "ms", "lower", [value] * 5)])

    def alert(self, at: datetime, start: int, end: int) -> int:
        def write():
            raw = self.db._db
            group = raw.execute("INSERT INTO alert_groups (state, start_pos, end_pos, created_at, updated_at) "
                                "VALUES ('new', ?, ?, ?, ?)", (start, end, canary._stamp(at), canary._stamp(at))).lastrowid
            series = raw.execute("SELECT id FROM series LIMIT 1").fetchone()[0]
            raw.execute("INSERT INTO alerts (series_id, group_id, rule, start_pos, end_pos, median_before, median_after,"
                        " is_improvement, created_at) VALUES (?, ?, 'edivisive', ?, ?, 8, 10, 0, ?)",
                        (series, group, start, end, canary._stamp(at)))
            return group

        return self.db._write(write)

    def job(self, kind: str, group: int, at: datetime, result: dict, head: str | None = None) -> None:
        self.db._write(lambda: self.db._db.execute(
            "INSERT INTO jobs (kind, state, story, head_sha, alert_group_id, result_json, created_at, updated_at) "
            "VALUES (?, 'done', 'terminal-key', ?, ?, ?, ?, ?)",
            (kind, head, group, json.dumps(result), canary._stamp(at), canary._stamp(at))))

    def judge(self, now: datetime):
        db = sqlite3.connect(self.path)
        try:
            return canary.judge(db, self.record, now)
        finally:
            db.close()


def _bisect(*commits: str) -> dict:
    return {"outcome": "culprits", "culprits": [{"commits": list(commits)}]}


def _verified(state: str = "verified", strict: str = "different") -> dict:
    return {"state": state, "strict": strict, "p_value": 0.001, "median_shift": 2.0, "reason": "r"}


class JudgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.record = _record()
        self.lane = LaneStore(Path(self.temp.name) / "lab.sqlite3", self.record)
        for batch in range(13):
            self.lane.point(batch, T0 + batch * scheduler.BATCH_INTERVAL, 8.0 if batch < 6 else 10.0)
        self.alerted = T0 + 12 * scheduler.BATCH_INTERVAL + timedelta(minutes=1)
        self.injected_pos = self.record.injected_pos

    def tearDown(self):
        self.lane.close()
        self.temp.cleanup()

    def test_full_pass(self):
        group = self.lane.alert(self.alerted, BASE_POS + 5 * 4 + 4, BASE_POS + 6 * 4 + 3)
        self.lane.job("bisect", group, self.alerted + timedelta(hours=2), _bisect(self.record.injected))
        self.lane.job("verify", group, self.alerted + timedelta(hours=3), _verified(), head=self.record.injected)
        verdict = self.lane.judge(self.alerted + timedelta(hours=4))
        self.assertEqual(verdict.to_dict()["state"], canary.PASS, verdict)
        self.assertIn("after 7 T0 batches", verdict.alert.detail)

    def test_no_alert_is_pending_until_seven_batches_are_measured(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        lane = LaneStore(Path(temp.name) / "lab.sqlite3", self.record)
        self.addCleanup(lane.close)
        for batch in range(12):
            lane.point(batch, T0 + batch * scheduler.BATCH_INTERVAL, 8.0)
        self.assertEqual(lane.judge(T0 + timedelta(hours=2)).state, canary.PENDING)
        lane.point(12, T0 + 12 * scheduler.BATCH_INTERVAL, 8.0)
        verdict = lane.judge(T0 + timedelta(hours=3))
        self.assertEqual((verdict.state, verdict.alert.state), (canary.FAIL, canary.FAIL))

    def test_an_alert_after_more_than_seven_batches_fails(self):
        self.record.injected_pos = BASE_POS + 5 * 4 + 2  # in batch 6: 8 batch tips at or after it
        self.lane.alert(self.alerted, BASE_POS + 4 * 4 + 4, BASE_POS + 6 * 4 + 3)
        alert = self.lane.judge(self.alerted).alert
        self.assertEqual(alert.state, canary.FAIL)
        self.assertIn("after 8 T0 batches", alert.detail)

    def test_an_alert_whose_range_misses_the_injected_commit_does_not_count(self):
        self.lane.alert(self.alerted, BASE_POS + 7 * 4 + 4, BASE_POS + 8 * 4 + 3)
        self.assertEqual(self.lane.judge(self.alerted).alert.state, canary.FAIL)

    def test_a_bisect_to_another_commit_fails(self):
        group = self.lane.alert(self.alerted, BASE_POS + 5 * 4 + 4, BASE_POS + 6 * 4 + 3)
        self.lane.job("bisect", group, self.alerted + timedelta(hours=1), _bisect("06" + "a" * 38))
        bisect = self.lane.judge(self.alerted + timedelta(hours=1)).bisect
        self.assertEqual(bisect.state, canary.FAIL)
        self.assertIn("06aaaaaaaaaa", bisect.detail)

    def test_a_range_culprit_is_not_exact(self):
        group = self.lane.alert(self.alerted, BASE_POS + 5 * 4 + 4, BASE_POS + 6 * 4 + 3)
        self.lane.job("bisect", group, self.alerted, _bisect(self.record.injected, "06" + "f" * 38))
        self.assertEqual(self.lane.judge(self.alerted).bisect.state, canary.FAIL)

    def test_a_bisect_later_than_three_hours_fails(self):
        group = self.lane.alert(self.alerted, BASE_POS + 5 * 4 + 4, BASE_POS + 6 * 4 + 3)
        self.assertEqual(self.lane.judge(self.alerted + timedelta(hours=2)).bisect.state, canary.PENDING)
        self.assertEqual(self.lane.judge(self.alerted + timedelta(hours=3, seconds=1)).bisect.state, canary.FAIL)
        self.lane.job("bisect", group, self.alerted + timedelta(hours=3, minutes=1), _bisect(self.record.injected))
        self.assertEqual(self.lane.judge(self.alerted + timedelta(hours=4)).bisect.state, canary.FAIL)

    def test_verification_needs_the_strict_rule(self):
        group = self.lane.alert(self.alerted, BASE_POS + 5 * 4 + 4, BASE_POS + 6 * 4 + 3)
        self.lane.job("bisect", group, self.alerted, _bisect(self.record.injected))
        self.assertEqual(self.lane.judge(self.alerted).verify.state, canary.PENDING)
        self.lane.job("verify", group, self.alerted, _verified("unverified", "unknown"), head=self.record.injected)
        verdict = self.lane.judge(self.alerted)
        self.assertEqual((verdict.verify.state, verdict.state), (canary.FAIL, canary.FAIL))

    def test_a_verification_of_another_commit_does_not_count(self):
        group = self.lane.alert(self.alerted, BASE_POS + 5 * 4 + 4, BASE_POS + 6 * 4 + 3)
        self.lane.job("verify", group, self.alerted, _verified(), head="06" + "f" * 38)
        self.assertEqual(self.lane.judge(self.alerted).verify.state, canary.PENDING)

    def test_a_run_that_never_measures_times_out_after_a_day(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        lane = LaneStore(Path(temp.name) / "lab.sqlite3", self.record)
        self.addCleanup(lane.close)
        for batch in range(8):  # two T0 batches after the injected commit, then no build comes
            lane.point(batch, T0 + batch * scheduler.BATCH_INTERVAL, 8.0)
        self.assertEqual(lane.judge(T0 + canary.RUN_LIMIT).state, canary.PENDING)
        verdict = lane.judge(T0 + canary.RUN_LIMIT + timedelta(seconds=1))
        self.assertEqual((verdict.alert.state, verdict.state), (canary.FAIL, canary.FAIL))
        self.assertIn("timed out", verdict.alert.detail)


class LastTests(unittest.TestCase):
    def test_last_judges_the_newest_runs_and_passes_only_when_all_pass(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            older = canary.RunRecord(**{**_record().__dict__, "run_id": "20261019T120000Z-0123456789ab"})
            newer = _record()
            for record in (older, newer):
                record.save(root / record.run_id)
            lane = LaneStore(root / newer.run_id / canary.DB_NAME, newer)
            try:
                for batch in range(13):
                    lane.point(batch, T0 + batch * scheduler.BATCH_INTERVAL, 8.0 if batch < 6 else 10.0)
                alerted = T0 + timedelta(hours=2, minutes=1)
                group = lane.alert(alerted, BASE_POS + 5 * 4 + 4, BASE_POS + 6 * 4 + 3)
                lane.job("bisect", group, alerted + timedelta(hours=1), _bisect(newer.injected))
                lane.job("verify", group, alerted + timedelta(hours=2), _verified(), head=newer.injected)
            finally:
                lane.close()
            now = T0 + timedelta(hours=5)
            out = io.StringIO()
            self.assertEqual(canary.report_last(root, 1, now, as_json=False, out=out), 0)
            self.assertIn("1/1 canary runs passed", out.getvalue())
            out = io.StringIO()
            self.assertEqual(canary.report_last(root, 2, now, as_json=True, out=out), 1)
            document = json.loads(out.getvalue())
            self.assertEqual([r["state"] for r in document["runs"]], [canary.PASS, canary.PENDING])
            self.assertEqual(canary.report_last(root, 3, now, as_json=False, out=io.StringIO()), 1)


class CommandTests(unittest.TestCase):
    def test_lab_lists_the_canary_command(self):
        self.assertIn("canary", lab.discover(LAB))

    def test_last_with_no_runs_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            parser = argparse.ArgumentParser()
            canary.add_arguments("canary", parser)
            args = parser.parse_args(["--last", "3", "--data-dir", temp])
            out = io.StringIO()
            self.assertEqual(canary.run("canary", args, out=out), 1)
            self.assertIn("0/3 canary runs passed", out.getvalue())


class RealSubmitPathTests(unittest.TestCase):
    def test_labd_hands_the_lane_job_to_its_submit_program_and_hands_a_refused_one_on_again(self):
        """labd's PlanLoop, the real Driver and command_submitter with a submit program, the lane read from disk."""
        labd = _load("perf_lab_labd", LAB / "labd.py")
        record = _record()
        canary.advance(record, T0, {b["tip"] for b in record.batches}, set())
        job_id = f"canary:{RUN_ID}:T0-1.1:m6.0"
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "canary"
            directory = root / RUN_ID
            record.save(directory)
            canary._write_json(directory / canary.LANE_FILE,
                               canary.LaneDocument.of(record, directory, set()).to_document())
            program = Path(temp) / "submit"
            program.write_text(f"#!/bin/sh\nn=$(cat '{temp}/count' 2>/dev/null || echo 0); n=$((n + 1))\n"
                               f"echo $n > '{temp}/count'\ncat > '{temp}/plan-'$n.json\n"
                               f"if [ $n = 1 ]; then printf '{{\"jobs\": [\"{job_id}\"]}}'; fi\n")
            program.chmod(0o755)
            driver = scheduler.Driver(Path(temp) / "scheduler.json", ls_remote=lambda: None,
                                      first_parent=lambda anchor, tip: None, stories=STORIES, shard_map=SHARDS,
                                      clock=lambda: T0)
            ready = scheduler.Builds(ready=frozenset((b["tip"], "bench") for b in record.batches))
            loop = labd.PlanLoop(driver, hosts=lambda: HOSTS, builds=lambda: ready,
                                 submit=labd.command_submitter(program, scheduler.Rejected),
                                 lanes=lambda: canary.lane_documents(root))
            loop.step()
            loop.step()
            plans = [json.loads((Path(temp) / f"plan-{n}.json").read_text()) for n in (1, 2)]
            third = loop.step()
        for plan in plans:
            self.assertEqual([(j["id"], j["host"], j["lane"], j["stories"]) for j in plan["jobs"]],
                             [(job_id, "cmux15", f"canary/{RUN_ID}", ["terminal-key"])])
        self.assertEqual(third["jobs"], 0, "accepted on the second plan: it is running")


class DriveTests(unittest.TestCase):
    """start_run and drive end to end on a temp git repo. labd's real scheduler plans the lane from lane.json, a
    fake lab host measures each job (KEY_MS before the injected commit, KEY_MS + 2 from it on), the real
    alerts.detect must find the step within 7 T0 batches, and a fake --pinpoint-command names the culprit."""

    STORY = "terminal-key-to-frame-light"  # subscriptions.json target-key-frame watches this series
    SPECS = (scheduler.StorySpec(STORY, "T0", 60, "bench"),)
    SHARD_MAP = scheduler.ShardMap.from_document({"classes": {"m6": {"tiers": ["T0"], "shards": [
        {"index": 0, "stories": {"T0": [STORY]}}]}}})
    KEY_MS = 8.0

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.repo, self.remote, self.tip = _make_repo(self.root)
        self.data = self.root / "data" / "canary"
        self.now = datetime.now(timezone.utc).replace(microsecond=0) - timedelta(days=2)
        self.state = scheduler.State()
        self.jobs: list = []
        self.crash_at: int | None = None
        self.sleeps = 0
        self.pinpoint_failed = False
        self.logs: list[str] = []

    def tearDown(self):
        self.temp.cleanup()

    def services(self) -> "canary.Services":
        return canary.Services(
            git=canary.git_runner(), clock=lambda: self.now, sleep=self.sleep,
            builds=lambda: types.SimpleNamespace(ready=Everything()),
            detect=lambda path: canary.lane_detect(path, clock=lambda: self.now), pinpoint=self.pinpoint,
            log=self.logs.append, regenerate=BuildScratchTests.regenerate)

    def sleep(self, seconds: float) -> None:
        """labd and its lab host between two polls: plan the lanes, run each job at once, store its points."""
        self.sleeps += 1
        if self.sleeps == self.crash_at:
            raise Crash()
        self.now += scheduler.BATCH_INTERVAL
        for document in canary.lane_documents(self.data):
            builds = scheduler.Builds(ready=frozenset((sha, "bench") for sha in document.lane.builds))
            host = scheduler.Host("cmux15", "waterfall", "m6", "apple-m6/16gb/120hz", shard=0)
            result = scheduler.plan(self.state, self.now, [host], builds, (), stories=self.SPECS,
                                    shard_map=self.SHARD_MAP, lanes=[document.lane])
            self.state = result.state
            for job in result.jobs:
                self.jobs.append(job.id)
                self.state = scheduler.finished(self.state, job.id)
                self.measure(document, job)

    def measure(self, document, job) -> None:
        position = int(_git("rev-list", "--count", "--first-parent", job.sha, "--", cwd=self.repo))
        injected = canary.RunRecord.load(document.store.parent).injected_pos
        value = self.KEY_MS + (2.0 if position >= injected else 0.0)
        db = store.Store(document.store, clock=lambda: self.now)
        try:
            db.insert_run(store.Run(job.id, "waterfall", "m1", self.STORY, "none", 26, "26A1", "h", "off", self.now,
                                    tier="T0"),
                          build=store.Build(job.sha, "bench", position), host=LaneStore.HOST,
                          metrics=[store.Metric("key_to_frame_ms", "ms", "lower",
                                                [value + 0.01 * (i % 3) for i in range(10)])])
        finally:
            db.close()

    def pinpoint(self, path: Path) -> None:
        """--pinpoint-command: fails once (a transient error), then bisects and verifies each new alert group."""
        if not self.pinpoint_failed:
            self.pinpoint_failed = True
            raise canary.CanaryError("pinpoint executor is restarting")
        record = canary.RunRecord.load(path.parent)
        db = sqlite3.connect(path)
        try:
            for (group,) in db.execute("SELECT id FROM alert_groups WHERE id NOT IN "
                                       "(SELECT alert_group_id FROM jobs WHERE alert_group_id IS NOT NULL)").fetchall():
                at = canary._stamp(self.now)
                for kind, result, head in (("bisect", _bisect(record.injected), None),
                                           ("verify", _verified(), record.injected)):
                    db.execute("INSERT INTO jobs (kind, state, story, head_sha, alert_group_id, result_json, "
                               "created_at, updated_at) VALUES (?, 'done', ?, ?, ?, ?, ?, ?)",
                               (kind, self.STORY, head, group, json.dumps(result), at, at))
            db.commit()
        finally:
            db.close()

    def start(self) -> Path:
        return canary.start_run(self.data, self.repo, "origin", self.tip, canary.Layout(injected_offset=1),
                                [self.STORY], self.services())

    def assert_passed(self, directory: Path, verdict) -> None:
        self.assertEqual(verdict.state, canary.PASS, verdict)
        measured = int(re.search(r"after (\d+) T0 batches", verdict.alert.detail).group(1))
        self.assertLessEqual(measured, canary.ALERT_WITHIN_BATCHES)
        self.assertFalse((directory / canary.LANE_FILE).exists(), "labd stops planning a finished lane")
        record = canary.RunRecord.load(directory)
        self.assertEqual(record.verdict["state"], canary.PASS)
        heads = _git("for-each-ref", "--format=%(refname)", "refs/heads", cwd=self.remote).split()
        self.assertEqual(heads, ["refs/heads/feat-cmux-next"], "the scratch branch is deleted from the remote")
        self.assertEqual(_git("rev-parse", record.mainline, cwd=self.repo), record.batches[-1]["tip"])
        self.assertTrue(any("pinpoint executor is restarting" in line for line in self.logs))

    def test_a_run_alerts_bisects_and_verifies_the_injected_commit(self):
        directory = self.start()
        verdict = canary.drive(directory, self.repo, {"bench"}, self.services())
        self.assert_passed(directory, verdict)
        self.assertEqual(len(self.jobs), len(set(self.jobs)), "every lane job started once")

    def test_a_resumed_run_goes_on_where_it_stopped(self):
        directory = self.start()
        self.crash_at = 5
        with self.assertRaises(Crash):
            canary.drive(directory, self.repo, {"bench"}, self.services())
        asked = sum(1 for b in canary.RunRecord.load(directory).batches if b["t0_at"])
        self.assertEqual(asked, 5)
        self.crash_at = None
        verdict = canary.drive(directory, self.repo, {"bench"}, self.services())
        self.assert_passed(directory, verdict)
        record = canary.RunRecord.load(directory)
        self.assertEqual({b["attempt"] for b in record.batches if b["t0_at"]}, {1}, "no round was asked twice")
        self.assertEqual(len(self.jobs), len(set(self.jobs)))


class Crash(Exception):
    """The canary process dies between two polls."""


class Everything:
    def __contains__(self, item) -> bool:
        return True


if __name__ == "__main__":
    unittest.main()
