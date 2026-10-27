#!/usr/bin/env python3
"""scheduler.py and gen_shard_map.py: batches, tiers, shard owners, roles, one job per host and the hooks.

  python3 -m unittest scripts/perf-lab/tests/test_scheduler.py

A small simulation drives plan() the way labd does: a tick every minute, merges landing on the branch, builders
that finish a requested build after BUILD_MINUTES, and the controller's job-finished callback when a job's
seconds have passed.
"""
from __future__ import annotations

import argparse
import importlib.util
import io
import json
import random
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

LAB = Path(__file__).resolve().parent.parent
REPO_ROOT = LAB.parents[1]


def _load(name: str):
    module_name = f"perf_lab_{name}"
    if module_name in sys.modules:
        return sys.modules[module_name]
    spec = importlib.util.spec_from_file_location(module_name, LAB / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


scheduler = _load("scheduler")
gen = _load("gen_shard_map")

START = datetime(2026, 10, 26, 12, 0, tzinfo=timezone.utc)  # 12:00 UTC: lab day 2026-10-26 started at 09:00
M6 = "apple-m6/24gb/120hz"
BENCH = "apple-m2-pro/32gb/120hz"
BUILD_MINUTES = 5

STORIES = (
    scheduler.StorySpec("t0-key", "T0", 150, "bench"),
    scheduler.StorySpec("t0-switch", "T0", 120, "bench"),
    scheduler.StorySpec("t0-launch", "T0", 90, "bench"),
    scheduler.StorySpec("t0-idle", "T0", 60, "bench"),
    scheduler.StorySpec("t1-motion", "T1", 600, "bench"),
    scheduler.StorySpec("t1-sidebar", "T1", 300, "bench"),
    scheduler.StorySpec("t1-blocking", "T1", 300, "bench-checks"),
    scheduler.StorySpec("t2-soak", "T2", 1800, "bench"),
    scheduler.StorySpec("linux-diff", "linux", 900, "release"),
)
# The fixture lab: its bench class is an M2 Pro (BENCH), a host class of its own, so unlike the real cmux20-bench
# (gen_shard_map.LAYOUT) it runs T1 too.
LAYOUT = {**gen.LAYOUT, "cmux20-bench": {"shards": 1, "tiers": ("T1", "T2")}}
SHARD_MAP = scheduler.ShardMap.from_document(gen.generate(STORIES, LAYOUT))


def ACCEPT(plan):
    """labd's submit callback when the controller takes every job."""
    return scheduler.Rejected()


def lab_hosts(**changes):
    hosts = {
        "wf-a": scheduler.Host("wf-a", "waterfall", "m6", M6, shard=0),
        "wf-b": scheduler.Host("wf-b", "waterfall", "m6", M6, shard=1),
        "pp-a": scheduler.Host("pp-a", "pinpoint", "m6", M6),
        "pp-b": scheduler.Host("pp-b", "pinpoint", "m6", M6),
        "bench": scheduler.Host("bench", "waterfall", "cmux20-bench", BENCH, shard=0),
    }
    for name, fields in changes.items():
        hosts[name] = scheduler.replace(hosts[name], **fields)
    return list(hosts.values())


def sha(n: int) -> str:
    return f"{n:040x}"


class Sim:
    """labd around plan(): merges, builders, the controller's callbacks; records every job and its interval."""

    def __init__(self, *, hosts=None, merges_per_hour=0, stories=STORIES, shard_map=SHARD_MAP, extra_queue=(),
                 expected_build_seconds=BUILD_MINUTES * 60, state=None, **plan_inputs):
        self.state = state or scheduler.State()
        self.now = START
        self.hosts = hosts or lab_hosts()
        self.commits: list[str] = []
        self.merges_per_hour = merges_per_hour
        self.merged = 0
        self.stories = stories
        self.shard_map = shard_map
        self.ready: set[tuple[str, str]] = set()
        self.failed: set[tuple[str, str]] = set()
        self.building: dict[tuple[str, str], datetime] = {}
        self.extra_queue = set(extra_queue)
        self.expected = expected_build_seconds
        self.plan_inputs = plan_inputs
        self.jobs: list[tuple[scheduler.Job, datetime]] = []
        self.ends: dict[str, datetime] = {}
        self.plans: list = []

    def merge(self, count=1):
        for _ in range(count):
            self.merged += 1
            self.commits.append(sha(self.merged))

    def step(self, minutes=1, **inputs):
        for _ in range(minutes):
            self._tick(**inputs)
            self.now += timedelta(minutes=1)

    def _tick(self, **inputs):
        if self.merges_per_hour:
            minutes = int((self.now - START) / timedelta(minutes=1)) + 1  # merges landed by the end of this minute
            self.merge(max(0, minutes * self.merges_per_hour // 60 - self.merged))
        for pair, done in list(self.building.items()):
            if done <= self.now:
                self.ready.add(pair)
                del self.building[pair]
        for job_id, end in list(self.ends.items()):
            if end <= self.now:
                self.state = scheduler.finished(self.state, job_id)
                del self.ends[job_id]
        busy = {r.host for r in self.state.running}
        hosts = [scheduler.replace(h, busy=h.name in busy) for h in self.hosts]
        queued = frozenset(self.building) | frozenset(self.extra_queue)
        builds = scheduler.Builds(frozenset(self.ready), queued, self.expected, frozenset(self.failed))
        merged_inputs = {**self.plan_inputs, **inputs}
        result = scheduler.plan(self.state, self.now, hosts, builds, tuple(self.commits), stories=self.stories,
                                shard_map=self.shard_map, **merged_inputs)
        self.plans.append(result)
        for request in result.builds:
            self.building[(request.sha, request.config)] = self.now + timedelta(minutes=BUILD_MINUTES)
        for job in result.jobs:
            self.jobs.append((job, self.now))
            self.ends[job.id] = self.now + timedelta(seconds=job.seconds)
        self.state = result.state
        return result

    def t0_jobs(self):
        return [(j, at) for j, at in self.jobs if j.tier == "T0" and j.kind == "waterfall"]

    def t0_rounds(self):
        return sorted({j.round for j, _ in self.t0_jobs()}, key=lambda r: int(r.split("-")[1]))


class ShardMapTests(unittest.TestCase):
    def test_bin_packing_is_balanced_and_deterministic(self):
        bins, loads = gen.pack([("a", 150), ("b", 120), ("c", 90), ("d", 60)], 2)
        self.assertEqual(bins, [["a", "d"], ["b", "c"]])
        self.assertEqual(loads, [210, 210])
        self.assertEqual(gen.pack([("d", 60), ("c", 90), ("b", 120), ("a", 150)], 2), (bins, loads))

    def test_pinned_stories_keep_their_shard_and_new_ones_fill_the_least_loaded(self):
        # A fresh pack would put "e" (200) first on shard 0 and move the others; pinned, only "e" is placed.
        bins, loads = gen.pack([("a", 150), ("b", 120), ("c", 90), ("d", 60), ("e", 200)], 2,
                               pinned={"a": 0, "d": 0, "b": 1, "c": 1, "gone": 1})
        self.assertEqual(bins, [["a", "d", "e"], ["b", "c"]])
        self.assertEqual(loads, [410, 210])
        # A pinned index the layout no longer has is packed like a new story.
        self.assertEqual(gen.pack([("a", 150), ("b", 120)], 1, pinned={"a": 0, "b": 3}), ([["a", "b"]], [270]))

    def test_regenerating_after_a_new_story_moves_no_existing_story(self):
        current = gen.generate(STORIES, LAYOUT)
        grown = STORIES + (scheduler.StorySpec("t1-new", "T1", 5000, "bench"),
                           scheduler.StorySpec("t0-new", "T0", 30, "bench"))
        sticky = gen.generate(grown, LAYOUT, previous=current)
        before, after = gen.bindings(current), gen.bindings(sticky)
        for key, stories in before.items():
            for story_id, index in stories.items():
                self.assertEqual(after[key][story_id], index, (key, story_id))
        self.assertEqual({key: set(s) - set(before.get(key, {})) for key, s in after.items()
                          if set(s) - set(before.get(key, {}))},
                         {key: {"t1-new"} for key in after if key[1] == "T1"} | {("m6", "T0"): {"t0-new"}})
        # --repack is the fresh pack, the same as no previous map.
        self.assertEqual(gen.generate(grown, LAYOUT), gen.generate(grown, LAYOUT, previous=None))
        self.assertEqual(gen.bindings({"schema": "other"}), {})

    def test_the_checked_in_map_keeps_the_bindings_it_had_before_the_typing_stories(self):
        # p12-perf-process-050 added seven typing stories; a full repack would have moved seven T1 stories between
        # the two m6 minis (and so each of their series onto another host). The sticky map keeps them.
        shard_map = scheduler.ShardMap.load(LAB / "shard_map.json")
        for story_id in ("launch-cold-realistic", "omnibar", "tab-switch"):
            self.assertEqual(shard_map.owner("m6", "T1", story_id), 0, story_id)
        for story_id in ("launch-cold", "launch-warm-realistic", "memory-hidden", "new-surfaces-matrix"):
            self.assertEqual(shard_map.owner("m6", "T1", story_id), 1, story_id)

    def test_every_sharded_story_has_one_owner_per_class_of_its_tier(self):
        for story in STORIES:
            for lab_class, spec in LAYOUT.items():
                owners = [i for i, shard in enumerate(SHARD_MAP.shards(lab_class))
                          if story.id in shard.get(story.tier, ())]
                expected = 1 if story.tier in spec["tiers"] else 0
                self.assertEqual(len(owners), expected, (story.id, lab_class))

    def test_checked_in_shard_map_is_current(self):
        done = subprocess.run([sys.executable, "-I", str(LAB / "gen_shard_map.py"), "--check"],
                              capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)

    def test_a_shard_over_its_tier_interval_is_flagged(self):
        heavy = STORIES + tuple(scheduler.StorySpec(f"t1-heavy-{i}", "T1", 1800, "bench") for i in range(4))
        lines = gen.overloads(gen.generate(heavy, LAYOUT))
        self.assertEqual([line.split(":")[0] for line in lines], ["aws-m4pro/0", "cmux20-bench/0"])
        self.assertTrue(all("T1 takes 8400 s" in line for line in lines))
        self.assertEqual(gen.overloads(gen.generate(STORIES, LAYOUT)), [])
        with tempfile.TemporaryDirectory() as tmp:
            original = gen.catalog_stories
            gen.catalog_stories = lambda _root: heavy
            try:
                err = io.StringIO()
                gen.run("shard-map", argparse.Namespace(root=Path(tmp), check=True), io.StringIO(), err)
                self.assertIn("warning: aws-m4pro/0: T1 takes 8400 s", err.getvalue())  # gen.LAYOUT: bench runs no T1
            finally:
                gen.catalog_stories = original

    def test_check_fails_on_a_stale_map(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target = root / gen.SHARD_MAP_PATH
            target.parent.mkdir(parents=True)
            target.write_text("{}\n")
            original = gen.catalog_stories
            gen.catalog_stories = lambda _root: STORIES
            try:
                err = io.StringIO()
                code = gen.run("shard-map", argparse.Namespace(root=root, check=True), io.StringIO(), err)
                self.assertEqual(code, 1)
                self.assertIn("is stale", err.getvalue())
                self.assertEqual(gen.run("shard-map", argparse.Namespace(root=root, check=False),
                                         io.StringIO(), io.StringIO()), 0)
                self.assertEqual(gen.run("shard-map", argparse.Namespace(root=root, check=True),
                                         io.StringIO(), io.StringIO()), 0)
            finally:
                gen.catalog_stories = original


class BatchTests(unittest.TestCase):
    def test_100_merges_in_an_hour_make_6_t0_plans(self):
        sim = Sim(merges_per_hour=100)
        sim.state = scheduler.replace(sim.state, tier_at={"T1:m6/0": START, "T1:m6/1": START,
                                                          "T1:cmux20-bench/0": START})
        sim.step(60)
        self.assertEqual(sim.merged, 100)
        cuts = [p.cut for p in sim.plans if p.cut is not None]
        self.assertEqual(len(cuts), 6)
        self.assertEqual(len(sim.t0_rounds()), 6)
        measured = [b for b in sim.state.batches if b.status == scheduler.MEASURED]
        self.assertEqual([b.seq for b in measured], [1, 2, 3, 4, 5, 6])
        # Each batch starts right after the previous one ends: no commit is left out or counted twice.
        for before, after in zip(cuts, cuts[1:]):
            self.assertEqual(sim.commits.index(after.first), sim.commits.index(before.tip) + 1)
        self.assertEqual(sum(b.commits for b in cuts), sim.commits.index(cuts[-1].tip) + 1)

    def test_batch_tips_are_built_first(self):
        work = scheduler.PinpointWork("bisect-1", "bisect", M6, "t0-key", 600, builds=((sha(900), "bench"),))
        sim = Sim(pinpoint=[work])
        sim.merge(3)
        result = sim._tick()
        self.assertEqual([(b.sha, b.reason) for b in result.builds], [(sha(3), "batch-tip"), (sha(900), "bisect-1")])

    def test_newest_built_batch_folds_older_unbuilt_batches(self):
        sim = Sim()
        sim.merge(2)
        sim._tick()  # batch 1 cut, its build requested
        sim.building.clear()  # that build never finishes
        sim.now += timedelta(minutes=10)
        sim.merge(3)
        sim._tick()  # batch 2 cut
        sim.now += timedelta(minutes=BUILD_MINUTES)
        result = sim._tick()
        t0 = [j for j in result.jobs if j.tier == "T0"]
        self.assertTrue(t0)
        self.assertEqual({(j.first, j.sha) for j in t0}, {(sha(1), sha(5))})
        statuses = {b.seq: (b.status, b.measured_in) for b in result.state.batches}
        self.assertEqual(statuses, {1: ("folded", 2), 2: ("measured", 2)})

    def test_build_queue_of_3_measures_every_2nd_batch(self):
        sim = Sim(merges_per_hour=60, extra_queue={(sha(10_000 + i), "bench") for i in range(3)})
        sim.state = scheduler.replace(sim.state, tier_at={"T1:m6/0": START, "T1:m6/1": START,
                                                          "T1:cmux20-bench/0": START})
        sim.step(60)
        cuts = [p.cut for p in sim.plans if p.cut is not None]
        self.assertEqual([c.status for c in cuts], ["pending", "skipped"] * 3)
        self.assertTrue(all(p.mode == "every-2nd-batch" for p in sim.plans))
        batch_builds = [b for p in sim.plans for b in p.builds if b.reason == "batch-tip"]
        self.assertEqual(sorted(b.sha for b in batch_builds), sorted(c.tip for c in cuts if c.status == "pending"))
        self.assertEqual(len(sim.t0_rounds()), 3)
        # A skipped batch is measured inside the next one: its first commit starts that T0 range.
        self.assertEqual({j.first for j, _ in sim.t0_jobs()}, {cuts[0].first, cuts[1].first, cuts[3].first})

    def test_build_queue_of_2_measures_every_batch(self):
        sim = Sim(merges_per_hour=60, extra_queue={(sha(10_000 + i), "bench") for i in range(2)},
                  expected_build_seconds=0)
        sim.state = scheduler.replace(sim.state, tier_at={"T1:m6/0": START, "T1:m6/1": START,
                                                          "T1:cmux20-bench/0": START})
        sim.step(36)
        cutting = [p for p in sim.plans if p.cut is not None]
        cuts = [p.cut for p in cutting]
        self.assertEqual(len(cuts), 4)
        # At each cut the queue holds exactly EVERY_SECOND_QUEUE builds: not over it, so no batch is skipped.
        self.assertEqual([c.status for c in cuts], ["pending"] * 4)
        self.assertTrue(all(p.mode == "every-batch" for p in cutting))
        self.assertEqual(len(sim.t0_rounds()), len(cuts))


class RangeTests(unittest.TestCase):
    """Each shard's T0 ranges chain: every commit is in exactly one T0 job's [first, sha] on every T0 shard."""

    LONG_T1 = (
        scheduler.StorySpec("a0", "T0", 120, "bench"),
        scheduler.StorySpec("b0", "T0", 120, "bench"),
        scheduler.StorySpec("long", "T1", 1500, "bench"),  # longer than BATCH_INTERVAL: a T0 waits past a batch
        scheduler.StorySpec("short", "T1", 300, "bench"),
    )

    def assert_ranges_chain(self, sim, host):
        jobs = sorted((at, j) for j, at in sim.t0_jobs() if j.host == host)
        self.assertTrue(jobs, host)
        expected_first = sim.commits[0]
        for _, job in jobs:
            self.assertEqual(job.first, expected_first, (host, job.round))
            expected_first = sim.commits[sim.commits.index(job.sha) + 1] if job.sha != sim.commits[-1] else None
        return [j.round for _, j in jobs]

    def test_a_shard_that_misses_a_round_measures_its_commits_in_the_next(self):
        shard_map = scheduler.ShardMap.from_document(gen.generate(self.LONG_T1))
        sim = Sim(merges_per_hour=60, stories=self.LONG_T1, shard_map=shard_map)
        sim.step(3 * 60)
        rounds = {host: self.assert_ranges_chain(sim, host) for host in ("wf-a", "wf-b")}
        owner_of_long = {0: "wf-a", 1: "wf-b"}[shard_map.owner("m6", "T1", "long")]
        self.assertLess(len(rounds[owner_of_long]), len(sim.t0_rounds()), "the long T1 story made a T0 wait")

    def test_owner_busy_during_one_batch(self):
        sim = Sim()
        sim.state = scheduler.replace(sim.state, tier_at={"T1:m6/0": START, "T1:m6/1": START,
                                                          "T1:cmux20-bench/0": START},
                                      aa_day={h.name: scheduler.lab_day(START) for h in lab_hosts()})
        sim.merge(3)
        sim.step(10)  # batch 1 (commits 1-3) measured on both shards
        sim.merge(3)
        held = scheduler.Running("other-work", "wf-a", sim.now, 3600)
        sim.state = scheduler.replace(sim.state, running=(*sim.state.running, held))
        sim.step(10)  # batch 2 (commits 4-6) measured on wf-b only
        sim.merge(2)
        sim.step(10)  # batch 3 (commits 7-8) built while wf-a is still busy
        sim.state = scheduler.finished(sim.state, "other-work")
        sim.step(2)
        on_a = [(j.first, j.sha) for j, _ in sorted(sim.t0_jobs(), key=lambda pair: pair[1]) if j.host == "wf-a"]
        self.assertEqual(on_a, [(sha(1), sha(3)), (sha(4), sha(8))])  # not (07, 08): wf-a never measured 4-6
        on_b = [(j.first, j.sha) for j, _ in sorted(sim.t0_jobs(), key=lambda pair: pair[1]) if j.host == "wf-b"]
        self.assertEqual(on_b, [(sha(1), sha(3)), (sha(4), sha(6)), (sha(7), sha(8))])


class OwnershipTests(unittest.TestCase):
    def test_a_story_is_never_planned_on_a_non_owner(self):
        rng = random.Random(11)
        sim = Sim(merges_per_hour=40)
        for minute in range(8 * 60):
            if minute % 15 == 0:
                sim.hosts = [scheduler.replace(h, up=rng.random() > 0.3) for h in lab_hosts()]
            sim.step(1)
        owner_of = {}
        for lab_class in SHARD_MAP.classes:
            for index, shard in enumerate(SHARD_MAP.shards(lab_class)):
                for tier, ids in shard.items():
                    for story in ids:
                        owner_of[(lab_class, tier, story)] = index
        by_name = {h.name: h for h in lab_hosts()}
        waterfall_jobs = [j for j, _ in sim.jobs if j.kind == "waterfall"]
        self.assertTrue(any(j.tier == "T0" for j in waterfall_jobs))
        self.assertTrue(any(j.tier == "T1" for j in waterfall_jobs))
        for job in waterfall_jobs:
            host = by_name[job.host]
            for story in job.stories:
                self.assertEqual(owner_of[(host.lab_class, job.tier, story)], host.shard, (job, story))
        gaps = [g for p in sim.plans for g in p.gaps]
        self.assertTrue(gaps, "a down owner must leave a gap")

    def test_owner_down_is_a_gap_and_the_story_does_not_move(self):
        sim = Sim(hosts=lab_hosts(**{"wf-b": {"up": False}}))
        sim.merge()
        sim.step(BUILD_MINUTES + 1)
        t0 = [j for j, _ in sim.t0_jobs()]
        self.assertEqual({j.host for j in t0}, {"wf-a"})
        down_stories = set(SHARD_MAP.shards("m6")[1]["T0"])
        self.assertTrue(down_stories)
        gaps = {(g.tier, g.story, g.key) for p in sim.plans for g in p.gaps if g.tier == "T0"}
        self.assertEqual(gaps, {("T0", s, "m6/1") for s in down_stories})
        self.assertFalse(down_stories & {s for j in t0 for s in j.stories})

    def test_unknown_role_and_missing_shard_are_refused(self):
        with self.assertRaises(scheduler.SchedulerError):
            scheduler.Host("x", "builder", "m6", M6)
        with self.assertRaises(scheduler.SchedulerError):
            scheduler.Host("x", "waterfall", "m6", M6)


class HostTests(unittest.TestCase):
    def assert_one_job_per_host(self, sim):
        for result in sim.plans:
            hosts = [j.host for j in result.jobs]
            self.assertEqual(len(hosts), len(set(hosts)), result.jobs)
        intervals: dict[str, list[tuple[datetime, datetime]]] = {}
        for job, at in sim.jobs:
            intervals.setdefault(job.host, []).append((at, at + timedelta(seconds=job.seconds)))
        for host, spans in intervals.items():
            spans.sort()
            for (_, end), (start, _) in zip(spans, spans[1:]):
                self.assertLessEqual(end, start + timedelta(minutes=1), host)  # ticks are 1 minute apart

    def test_no_host_gets_two_jobs(self):
        bisects = [scheduler.PinpointWork(f"bisect-{i}", "bisect", M6, "t0-key", 900) for i in range(5)]
        sim = Sim(merges_per_hour=30, pinpoint=bisects, reference="ref-digest")
        sim.step(26 * 60)
        self.assertTrue(sim.jobs)
        self.assert_one_job_per_host(sim)

    def test_a_host_the_controller_reports_busy_gets_nothing(self):
        sim = Sim(hosts=lab_hosts(**{"wf-a": {"busy": True}}))
        sim.merge()
        sim.now += timedelta(minutes=BUILD_MINUTES)
        sim.ready.add((sha(1), "bench"))
        hosts = sim.hosts
        result = scheduler.plan(sim.state, sim.now, hosts, scheduler.Builds(frozenset(sim.ready)), (sha(1),),
                                stories=STORIES, shard_map=SHARD_MAP)
        self.assertNotIn("wf-a", {j.host for j in result.jobs})
        self.assertTrue(any(i.key == "m6/0" and i.tier == "T0" for i in result.state.queue))

    def test_lost_callback_frees_an_idle_host_after_its_deadline(self):
        state = scheduler.State(running=(scheduler.Running("old", "pp-a", START - timedelta(hours=2), 600),))
        result = scheduler.plan(state, START, lab_hosts(), scheduler.Builds(), (), stories=STORIES,
                                shard_map=SHARD_MAP, pinpoint=[scheduler.PinpointWork("b", "bisect", M6, "t0-key", 60)])
        self.assertEqual([j.host for j in result.jobs], ["pp-a"])
        self.assertTrue(any("no finish callback" in p for p in result.problems))


class PinpointTests(unittest.TestCase):
    def test_build_only_work_requests_its_build_and_never_starts_a_job(self):
        pair = (sha(900), "bench")
        work = scheduler.PinpointWork("bisect-b", "bisect", M6, "t0-key", 0, builds=(pair,), build_only=True)
        plan = lambda builds: scheduler.plan(scheduler.State(), START, lab_hosts(), builds, (), stories=STORIES,
                                             shard_map=SHARD_MAP, pinpoint=[work])
        waiting = plan(scheduler.Builds())
        self.assertEqual([(b.sha, b.reason) for b in waiting.builds], [(sha(900), "bisect-b")])
        self.assertEqual(waiting.jobs, ())
        built = plan(scheduler.Builds(ready=frozenset({pair})))
        self.assertEqual((built.jobs, built.builds), ((), ()))
        failed = plan(scheduler.Builds(failed=frozenset({pair})))
        self.assertEqual((failed.jobs, failed.builds, failed.problems), ((), (), ()))

    def test_five_bisects_delay_no_t0(self):
        quiet = {"tier_at": {"T1:m6/0": START, "T1:m6/1": START, "T1:cmux20-bench/0": START},
                 "aa_day": {h.name: scheduler.lab_day(START) for h in lab_hosts()}}
        base = Sim(merges_per_hour=50)
        base.state = scheduler.replace(base.state, **quiet)
        base.step(4 * 60)
        bisects = [scheduler.PinpointWork(f"bisect-{i}", "bisect", M6, "t0-key", 1200) for i in range(5)]
        loaded = Sim(merges_per_hour=50, pinpoint=bisects)
        loaded.state = scheduler.replace(loaded.state, **quiet)
        loaded.step(4 * 60)
        self.assertEqual([(j.id, at) for j, at in loaded.t0_jobs()], [(j.id, at) for j, at in base.t0_jobs()])
        ran = [j for j, _ in loaded.jobs if j.kind == "bisect"]
        self.assertTrue(ran)
        self.assertEqual({j.host for j in ran}, {"pp-a", "pp-b"})

    def test_bisect_borrows_an_idle_waterfall_host_when_t0_is_far(self):
        state = scheduler.State(seq=1, last_cut_tip=sha(1), last_cut_at=START, last_t0_sha=sha(1),
                                running=(scheduler.Running("x", "pp-a", START, 3600),
                                         scheduler.Running("y", "pp-b", START, 3600)),
                                tier_at={"T1:m6/0": START, "T1:m6/1": START, "T1:cmux20-bench/0": START},
                                tier_day={"T2:cmux20-bench/0": scheduler.lab_day(START)},
                                aa_day={h.name: scheduler.lab_day(START) for h in lab_hosts()})
        work = [scheduler.PinpointWork("bisect-9", "bisect", M6, "t0-key", 600)]
        builds = scheduler.Builds(frozenset({(sha(1), "bench")}), expected_seconds=20 * 60)
        result = scheduler.plan(state, START + timedelta(minutes=1), lab_hosts(), builds, (sha(1),),
                                stories=STORIES, shard_map=SHARD_MAP, pinpoint=work)
        self.assertEqual([(j.kind, j.host) for j in result.jobs], [("bisect", "wf-a")])
        # The next cut is 9 minutes away and the build estimate is unknown: T0 may start in under 10 minutes.
        near = scheduler.Builds(builds.ready, expected_seconds=0)
        result = scheduler.plan(state, START + timedelta(minutes=1), lab_hosts(), near, (sha(1),),
                                stories=STORIES, shard_map=SHARD_MAP, pinpoint=work)
        self.assertEqual(result.jobs, ())
        # A batch waiting for its build: T0 is due now, no borrow.
        result = scheduler.plan(state, START + timedelta(minutes=11), lab_hosts(), builds, (sha(1), sha(2)),
                                stories=STORIES, shard_map=SHARD_MAP, pinpoint=work)
        self.assertNotIn("bisect", {j.kind for j in result.jobs})

    def test_verify_prefers_the_bisect_host_and_waits_for_its_builds(self):
        work = scheduler.PinpointWork("verify-1", "verify", M6, "t0-key", 600, builds=((sha(7), "bench"),),
                                      prefer_host="pp-b")
        result = scheduler.plan(scheduler.State(), START, lab_hosts(), scheduler.Builds(), (), stories=STORIES,
                                shard_map=SHARD_MAP, pinpoint=[work])
        self.assertEqual(result.jobs, ())
        self.assertEqual([(b.sha, b.reason) for b in result.builds], [(sha(7), "verify-1")])
        result = scheduler.plan(scheduler.State(), START, lab_hosts(),
                                scheduler.Builds(frozenset({(sha(7), "bench")})), (), stories=STORIES,
                                shard_map=SHARD_MAP, pinpoint=[work])
        self.assertEqual([(j.kind, j.host) for j in result.jobs], [("verify", "pp-b")])

    def test_bisect_goes_before_verify(self):
        works = [scheduler.PinpointWork("v", "verify", M6, "t0-key", 60),
                 scheduler.PinpointWork("b1", "bisect", M6, "t0-key", 60),
                 scheduler.PinpointWork("b2", "bisect", M6, "t0-key", 60)]
        result = scheduler.plan(scheduler.State(), START, lab_hosts(), scheduler.Builds(), (), stories=STORIES,
                                shard_map=SHARD_MAP, pinpoint=works)
        self.assertEqual(sorted(j.id for j in result.jobs), ["b1", "b2"])


class TierTests(unittest.TestCase):
    def test_t1_every_2_hours_per_shard_one_story_per_job(self):
        sim = Sim(merges_per_hour=6)
        sim.step(5 * 60)
        t1 = [(j, at) for j, at in sim.jobs if j.tier == "T1"]
        self.assertTrue(all(len(j.stories) == 1 for j, _ in t1))
        rounds_on_a = sorted({(j.round, at.replace(minute=0)) for j, at in t1 if j.host == "wf-a"})
        starts = sorted({r for r, _ in rounds_on_a}, key=lambda r: int(r.split("-")[1]))
        self.assertEqual(len(starts), 3)  # rounds at about 0 h, 2 h and 4 h
        bench_stories = {s for j, _ in t1 if j.host == "bench" for s in j.stories}
        self.assertEqual(bench_stories, {"t1-motion", "t1-sidebar", "t1-blocking"})

    def test_t1_requests_the_bench_checks_build_it_needs(self):
        sim = Sim()
        sim.merge()
        sim.step(BUILD_MINUTES + 2)
        tier_builds = {(b.sha, b.config) for p in sim.plans for b in p.builds if b.reason == "tier"}
        self.assertIn((sha(1), "bench-checks"), tier_builds)

    def test_t0_goes_before_t1_on_a_waterfall_host(self):
        state = scheduler.State(seq=1, last_cut_tip=sha(1), last_cut_at=START, last_t0_sha=sha(1),
                                batches=(scheduler.Batch(1, sha(1), sha(1), 1, START, "measured", 1),),
                                tier_at={})
        builds = scheduler.Builds(frozenset({(sha(1), "bench"), (sha(1), "bench-checks"),
                                             (sha(2), "bench")}))
        result = scheduler.plan(state, START + timedelta(minutes=10), lab_hosts(), builds, (sha(1), sha(2)),
                                stories=STORIES, shard_map=SHARD_MAP)
        on_a = [j for j in result.jobs if j.host == "wf-a"]
        self.assertEqual([j.tier for j in on_a], ["T0"])
        self.assertTrue(any(i.tier == "T1" and i.key == "m6/0" for i in result.state.queue))

    def test_t2_and_aa_once_per_lab_day(self):
        sim = Sim(merges_per_hour=2, expected_build_seconds=20 * 60)
        sim.step(30 * 60)
        t2 = [j for j, _ in sim.jobs if j.tier == "T2"]
        self.assertEqual([(j.host, j.stories) for j in t2], [("bench", ("t2-soak",))] * 2)
        aa = [j for j, _ in sim.jobs if j.kind == "aa"]
        per_host = {}
        for job in aa:
            per_host.setdefault(job.host, []).append(job.round)
        self.assertEqual(set(per_host), {h.name for h in lab_hosts()})
        self.assertTrue(all(len(set(rounds)) == len(rounds) for rounds in per_host.values()))
        self.assertTrue(all(j.passes == 2 and set(j.stories) == {"t0-key", "t0-switch", "t0-launch", "t0-idle"}
                            for j in aa))

    def test_reference_follows_every_6th_t0_per_waterfall_host(self):
        sim = Sim(merges_per_hour=30, reference="sha256:frozen", expected_build_seconds=BUILD_MINUTES * 60)
        sim.state = scheduler.replace(sim.state, tier_at={"T1:m6/0": START, "T1:m6/1": START,
                                                          "T1:cmux20-bench/0": START})
        sim.step(110)
        t0_on_a = [j for j, _ in sim.t0_jobs() if j.host == "wf-a"]
        self.assertGreaterEqual(len(t0_on_a), 6)
        self.assertEqual([j.reference for j in t0_on_a][:6], [None] * 5 + ["sha256:frozen"])
        self.assertEqual(sim.state.t0_count["wf-a"], len(t0_on_a))
        sixth = t0_on_a[5]
        self.assertEqual(sixth.seconds, 2 * t0_on_a[0].seconds)
        without = Sim(merges_per_hour=30)
        without.step(110)
        self.assertFalse([j for j, _ in without.jobs if j.reference])


class HookTests(unittest.TestCase):
    def test_disabled_story_is_skipped(self):
        sim = Sim(skip=lambda story, host: (story, host.host_class) == ("t0-key", M6))  # an expectations entry
        sim.merge()
        sim.step(BUILD_MINUTES + 1)
        planned = {s for j, _ in sim.jobs if j.host != "bench" for s in j.stories}
        self.assertNotIn("t0-key", planned)
        self.assertIn("t0-switch", planned)
        owner = {0: "wf-a", 1: "wf-b"}[SHARD_MAP.owner("m6", "T0", "t0-key")]
        skipped = {(s.story, s.host) for p in sim.plans for s in p.skipped}
        self.assertIn(("t0-key", owner), skipped)

    def test_feature_arms_once_per_day(self):
        arms = [scheduler.FeatureArm("cefLayerHosting", ("t0-switch",))]
        sim = Sim(merges_per_hour=6, arms=arms)
        sim.step(26 * 60)
        pairs = [a for p in sim.plans for a in p.arms]
        self.assertEqual([a.value for a in pairs], ["on", "off", "on", "off"])
        self.assertEqual({a.feature for a in pairs}, {"cefLayerHosting"})
        self.assertNotIn("try", {j.kind for j, _ in sim.jobs})  # arms go to the try queue, never a lab host

    def test_unsharded_story_is_a_problem(self):
        extra = STORIES + (scheduler.StorySpec("t0-new", "T0", 30, "bench"),)
        result = scheduler.plan(scheduler.State(), START, lab_hosts(), scheduler.Builds(), (), stories=extra,
                                shard_map=SHARD_MAP)
        self.assertTrue(any("t0-new" in p for p in result.problems))


class LowerWorkTests(unittest.TestCase):
    """A/A and borrowing on waterfall hosts: no T0 lead limit where no T0 can come, a daily A/A slot everywhere."""

    def test_every_host_gets_its_aa_on_a_quiet_day_with_a_short_build_estimate(self):
        sim = Sim(expected_build_seconds=0)  # the CLI default: the build time is unknown
        sim.merge()
        sim.step(23 * 60)  # 12:00 to 11:00 the next day: one lab day, no merge after the first
        aa_hosts = {j.host for j, _ in sim.jobs if j.kind == "aa"}
        self.assertEqual(aa_hosts, {h.name for h in lab_hosts()})

    def test_a_host_without_a_t0_shard_borrows_without_a_t0_lead(self):
        state = scheduler.State(seq=1, last_cut_tip=sha(1), last_cut_at=START, last_t0_sha=sha(1),
                                batches=(scheduler.Batch(1, sha(1), sha(1), 1, START, "pending"),),
                                running=(scheduler.Running("x", "pp-a", START, 3600),
                                         scheduler.Running("y", "pp-b", START, 3600)))
        work = [scheduler.PinpointWork("bisect-bench", "bisect", BENCH, "t1-motion", 600)]
        result = scheduler.plan(state, START + timedelta(minutes=1), lab_hosts(), scheduler.Builds(), (sha(1),),
                                stories=STORIES, shard_map=SHARD_MAP, pinpoint=work)
        self.assertEqual([(j.kind, j.host) for j in result.jobs], [("bisect", "bench")])  # a T0 waits, not on bench

    def test_an_overloaded_t1_shard_still_runs_t2_and_its_daily_aa(self):
        heavy = STORIES + tuple(scheduler.StorySpec(f"t1-heavy-{i}", "T1", 1800, "bench") for i in range(4))
        shard_map = scheduler.ShardMap.from_document(gen.generate(heavy, LAYOUT))
        load = sum(s.seconds for s in heavy if s.tier == "T1")
        self.assertGreater(load, scheduler.T1_INTERVAL.total_seconds())  # bench holds all T1: 8400 s > 7200 s
        sim = Sim(merges_per_hour=6, stories=heavy, shard_map=shard_map)
        sim.step(44 * 60)  # to 08:00 UTC on 10-28: lab days 10-26 and 10-27
        on_bench = [(j, at) for j, at in sim.jobs if j.host == "bench"]
        days = {scheduler.lab_day(at) for j, at in on_bench if j.kind == "aa"}
        self.assertEqual(days, {"2026-10-26", "2026-10-27"})
        self.assertTrue(any(j.tier == "T2" for j, _ in on_bench))
        times = sorted({p.state.tier_at["T1:cmux20-bench/0"] for p in sim.plans
                        if "T1:cmux20-bench/0" in p.state.tier_at})
        self.assertGreaterEqual(len(times), 10)
        for before, after in zip(times, times[1:]):
            self.assertGreaterEqual(after - before, timedelta(seconds=scheduler.T1_HEADROOM * load))


class BuildFailureTests(unittest.TestCase):
    def state_with_a_waiting_batch(self):
        return scheduler.State(
            seq=2, last_cut_tip=sha(3), last_cut_at=START, last_t0_sha=sha(1),
            batches=(scheduler.Batch(1, sha(1), sha(1), 1, START - timedelta(minutes=10), "measured", 1),
                     scheduler.Batch(2, sha(2), sha(3), 2, START)),
            running=(scheduler.Running("x", "pp-a", START, 7200), scheduler.Running("y", "pp-b", START, 7200)),
            tier_at={"T1:m6/0": START, "T1:m6/1": START, "T1:cmux20-bench/0": START},
            tier_day={"T2:cmux20-bench/0": scheduler.lab_day(START)},
            aa_day={h.name: scheduler.lab_day(START) for h in lab_hosts()})

    def test_a_failed_tip_build_stops_holding_the_waterfall_hosts(self):
        work = [scheduler.PinpointWork("bisect-1", "bisect", M6, "t0-key", 600)]
        ready = frozenset({(sha(1), "bench"), (sha(1), "bench-checks")})
        waiting = scheduler.plan(self.state_with_a_waiting_batch(), START + timedelta(minutes=1), lab_hosts(),
                                 scheduler.Builds(ready, expected_seconds=20 * 60), (sha(1), sha(2), sha(3)),
                                 stories=STORIES, shard_map=SHARD_MAP, pinpoint=work)
        self.assertNotIn("bisect", {j.kind for j in waiting.jobs})  # the batch's T0 is due now
        builds = scheduler.Builds(ready, expected_seconds=20 * 60, failed=frozenset({(sha(3), "bench")}))
        result = scheduler.plan(self.state_with_a_waiting_batch(), START + timedelta(minutes=1), lab_hosts(), builds,
                                (sha(1), sha(2), sha(3)), stories=STORIES, shard_map=SHARD_MAP, pinpoint=work)
        self.assertEqual([(j.kind, j.host) for j in result.jobs], [("bisect", "wf-a")])
        self.assertEqual(result.state.batches[-1].status, "failed")
        self.assertTrue(any("batch 2" in p and "failed" in p for p in result.problems))
        self.assertNotIn((sha(3), "bench"), {(b.sha, b.config) for b in result.builds})
        # The next built batch covers the failed batch's commits.
        later = scheduler.replace(result.state, running=(), seq=3, last_cut_tip=sha(4),
                                  batches=(*result.state.batches, scheduler.Batch(3, sha(4), sha(4), 1, START)))
        t0 = scheduler.plan(later, START + timedelta(minutes=20), lab_hosts(),
                            scheduler.Builds(ready | {(sha(4), "bench")}, failed=builds.failed), (sha(4),),
                            stories=STORIES, shard_map=SHARD_MAP)
        self.assertEqual({(j.first, j.sha) for j in t0.jobs if j.tier == "T0"}, {(sha(2), sha(4))})

    def test_a_tip_build_that_never_comes_times_out_on_a_quiet_branch(self):
        state = self.state_with_a_waiting_batch()
        ready = frozenset({(sha(1), "bench")})
        work = [scheduler.PinpointWork("bisect-1", "bisect", M6, "t0-key", 600)]
        builds = scheduler.Builds(ready, expected_seconds=20 * 60)
        late = START + scheduler.BUILD_TIMEOUT + timedelta(minutes=1)
        result = scheduler.plan(state, late, lab_hosts(), builds, (sha(1), sha(2), sha(3)), stories=STORIES,
                                shard_map=SHARD_MAP, pinpoint=work)
        self.assertEqual(result.state.batches[-1].status, "failed")
        self.assertTrue(any("did not come" in p for p in result.problems))
        self.assertIn(("bisect", "wf-a"), {(j.kind, j.host) for j in result.jobs})
        # A build still in the builders' queue is waited for.
        queued = scheduler.replace(builds, queued=frozenset({(sha(3), "bench")}))
        result = scheduler.plan(state, late, lab_hosts(), queued, (sha(1), sha(2), sha(3)), stories=STORIES,
                                shard_map=SHARD_MAP, pinpoint=work)
        self.assertEqual(result.state.batches[-1].status, "pending")

    def test_a_failed_t1_build_is_a_gap_and_the_next_round_still_starts(self):
        sim = Sim()
        sim.merge()
        sim.step(BUILD_MINUTES + 1)
        pair = (sha(1), "bench-checks")
        self.assertIn(pair, sim.building)
        del sim.building[pair]  # the builders give up on it
        sim.failed.add(pair)
        sim.step(3 * 60)
        gaps = [g for p in sim.plans for g in p.gaps if g.story == "t1-blocking" and g.key.startswith("m6/")]
        self.assertTrue(gaps)
        self.assertIn("failed", gaps[0].reason)
        on_shard = {i.key for i in sim.state.queue if i.tier == "T1" and i.sha == sha(1)
                    and i.stories == ("t1-blocking",)}
        self.assertFalse(on_shard)  # not stuck in the queue
        t1_rounds = {j.round for j, _ in sim.jobs if j.tier == "T1" and j.host in ("wf-a", "wf-b")}
        self.assertGreaterEqual(len(t1_rounds), 2)  # the round after the gap was planned and ran


class PinpointOnceTests(unittest.TestCase):
    def test_finished_pinpoint_work_is_not_started_again(self):
        work = [scheduler.PinpointWork("bisect-1:step-3", "bisect", M6, "t0-key", 60)]
        first = scheduler.plan(scheduler.State(), START, lab_hosts(), scheduler.Builds(), (), stories=STORIES,
                               shard_map=SHARD_MAP, pinpoint=work)
        self.assertEqual([j.id for j in first.jobs], ["bisect-1:step-3"])
        done = scheduler.finished(first.state, "bisect-1:step-3")
        again = scheduler.plan(done, START + timedelta(minutes=2), lab_hosts(), scheduler.Builds(), (),
                               stories=STORIES, shard_map=SHARD_MAP, pinpoint=work)  # task 016 has not read it yet
        self.assertEqual(again.jobs, ())
        self.assertIn("bisect-1:step-3", again.state.dispatched)


class StateAndDriverTests(unittest.TestCase):
    def test_state_round_trips_through_json(self):
        sim = Sim(merges_per_hour=30, reference="r", arms=[scheduler.FeatureArm("f")])
        sim.step(150)
        document = json.loads(json.dumps(sim.state.to_document()))
        self.assertEqual(scheduler.State.from_document(document), sim.state)

    def test_driver_reads_ls_remote_and_fetches_only_on_a_new_tip(self):
        calls = {"ls": 0, "log": []}
        tips = iter([sha(1), sha(1), sha(3)])

        def ls_remote():
            calls["ls"] += 1
            return next(tips)

        def first_parent(anchor, tip):
            calls["log"].append((anchor, tip))
            return {sha(1): (sha(1),), sha(3): (sha(2), sha(3))}[tip]

        clock = iter([START, START + timedelta(minutes=1), START + timedelta(minutes=11)])
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "state.json"
            driver = scheduler.Driver(path, ls_remote=ls_remote, first_parent=first_parent, stories=STORIES,
                                      shard_map=SHARD_MAP, clock=lambda: next(clock))
            first = driver.tick(lab_hosts(), scheduler.Builds(), submit=ACCEPT)
            self.assertEqual(first.cut.tip, sha(1))
            driver.tick(lab_hosts(), scheduler.Builds(), submit=ACCEPT)
            third = driver.tick(lab_hosts(), scheduler.Builds(), submit=ACCEPT)
            self.assertEqual((third.cut.first, third.cut.tip), (sha(2), sha(3)))
            self.assertEqual(calls["ls"], 3)
            self.assertEqual(calls["log"], [(None, sha(1)), (sha(1), sha(3))])
            reloaded = scheduler.Driver(path, ls_remote=lambda: None, first_parent=first_parent, stories=STORIES,
                                        shard_map=SHARD_MAP)
            self.assertEqual(reloaded.state, driver.state)

    def test_driver_job_finished_frees_the_host(self):
        with tempfile.TemporaryDirectory() as tmp:
            driver = scheduler.Driver(Path(tmp) / "s.json", ls_remote=lambda: None, first_parent=lambda a, t: (),
                                      stories=STORIES, shard_map=SHARD_MAP, clock=lambda: START)
            work = [scheduler.PinpointWork("b", "bisect", M6, "t0-key", 60)]
            plan = driver.tick(lab_hosts(**{"pp-b": {"up": False}}), scheduler.Builds(), submit=ACCEPT,
                               pinpoint=work)
            self.assertEqual([j.host for j in plan.jobs], ["pp-a"])
            again = driver.tick(lab_hosts(**{"pp-b": {"up": False}}), scheduler.Builds(), submit=ACCEPT,
                                pinpoint=[scheduler.PinpointWork("c", "bisect", M6, "t0-key", 60)])
            self.assertEqual(again.jobs, ())
            driver.job_finished("b")
            freed = driver.tick(lab_hosts(**{"pp-b": {"up": False}}), scheduler.Builds(), submit=ACCEPT,
                                pinpoint=[scheduler.PinpointWork("c", "bisect", M6, "t0-key", 60)])
            self.assertEqual([j.host for j in freed.jobs], ["pp-a"])

    def test_a_job_the_controller_refuses_goes_back_to_the_queue(self):
        with tempfile.TemporaryDirectory() as tmp:
            clock = iter([START, START + timedelta(minutes=1)])
            driver = scheduler.Driver(Path(tmp) / "s.json", ls_remote=lambda: sha(1),
                                      first_parent=lambda a, t: (sha(1),), stories=STORIES, shard_map=SHARD_MAP,
                                      clock=lambda: next(clock))
            builds = scheduler.Builds(frozenset({(sha(1), "bench")}))
            work = [scheduler.PinpointWork("bisect-1", "bisect", M6, "t0-key", 60)]
            arms = [scheduler.FeatureArm("cefLayerHosting", ("t0-switch",))]

            def refuse(plan):
                return scheduler.Rejected(jobs=frozenset(j.id for j in plan.jobs), arms=frozenset({"cefLayerHosting"}))

            refused = driver.tick(lab_hosts(), builds, submit=refuse, pinpoint=work, arms=arms)
            t0 = [j for j in refused.jobs if j.tier == "T0"]
            self.assertEqual({j.host for j in t0}, {"wf-a", "wf-b"})
            self.assertIn("bisect-1", {j.id for j in refused.jobs})
            self.assertEqual(driver.state.running, ())
            self.assertEqual(driver.state.dispatched, ())
            self.assertEqual(driver.state.t0_count, {"wf-a": 0, "wf-b": 0})
            self.assertEqual({i.key for i in driver.state.queue if i.tier == "T0"}, {"m6/0", "m6/1"})
            again = driver.tick(lab_hosts(), builds, submit=ACCEPT, pinpoint=work, arms=arms)
            self.assertEqual({(j.round, j.host, j.first, j.sha) for j in again.jobs if j.tier == "T0"},
                             {(j.round, j.host, j.first, j.sha) for j in t0})
            self.assertIn("bisect-1", {j.id for j in again.jobs})
            self.assertEqual([a.value for a in again.arms], ["on", "off"])

    def test_a_crash_inside_submit_keeps_the_previous_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "s.json"
            driver = scheduler.Driver(path, ls_remote=lambda: sha(1), first_parent=lambda a, t: (sha(1),),
                                      stories=STORIES, shard_map=SHARD_MAP, clock=lambda: START)

            def crash(plan):
                raise OSError("controller unreachable")

            with self.assertRaises(OSError):
                driver.tick(lab_hosts(), scheduler.Builds(), submit=crash)
            self.assertFalse(path.exists())
            self.assertEqual(driver.state, scheduler.State())
            self.assertEqual(list(Path(tmp).iterdir()), [])

    def test_a_time_without_an_offset_is_refused(self):
        with self.assertRaises(scheduler.SchedulerError):
            scheduler.plan(scheduler.State(), START.replace(tzinfo=None), lab_hosts(), scheduler.Builds(), (),
                           stories=STORIES, shard_map=SHARD_MAP)
        document = scheduler.State(last_cut_at=START).to_document()
        document["last_cut_at"] = "2026-10-26T12:00:00"
        with self.assertRaisesRegex(scheduler.SchedulerError, "no UTC offset"):
            scheduler.State.from_document(document)
        self.assertEqual(scheduler.parse_time("2026-10-26T12:30Z"), START + timedelta(minutes=30))

    def test_schedule_command_refuses_a_naive_now_and_writes_the_state_whole(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            hosts = root / "hosts.json"
            hosts.write_text(json.dumps({"hosts": [
                {"name": "wf-a", "role": "waterfall", "class": "m6", "host_class": M6, "shard": 0}]}))
            builds = root / "builds.json"
            builds.write_text(json.dumps({"ready": [], "failed": [[sha(9), "bench"]]}))
            log = root / "log.txt"
            state = root / "state" / "scheduler.json"

            def schedule(now, commits):
                log.write_text("\n".join(commits) + "\n")
                return subprocess.run([sys.executable, "-I", str(LAB / "lab.py"), "schedule", "--state", str(state),
                                       "--hosts", str(hosts), "--builds", str(builds), "--branch-log", str(log),
                                       "--now", now, "--write"], capture_output=True, text=True)

            self.assertEqual(schedule("2026-10-26T12:00Z", [sha(1)]).returncode, 0)
            naive = schedule("2026-10-26T12:20", [sha(1), sha(2)])
            self.assertEqual(naive.returncode, 2)
            self.assertIn("no UTC offset", naive.stderr)
            self.assertNotIn("Traceback", naive.stderr)
            self.assertEqual(schedule("2026-10-26T12:20+00:00", [sha(1), sha(2)]).returncode, 0)
            self.assertEqual(sorted(p.name for p in state.parent.iterdir()), ["scheduler.json"])
            self.assertEqual(scheduler.State.from_document(json.loads(state.read_text())).last_cut_tip, sha(2))

    def test_git_seams(self):
        def fake(argv, **_):
            if "ls-remote" in argv:
                return subprocess.CompletedProcess(argv, 0, f"{sha(5)}\trefs/heads/perf/chrome-parity\n", "")
            if "merge-base" in argv:
                return subprocess.CompletedProcess(argv, 0, "", "")
            if "rev-list" in argv:
                self.assertIn(f"{sha(1)}..{sha(5)}", argv)
                return subprocess.CompletedProcess(argv, 0, f"{sha(2)}\n{sha(5)}\n", "")
            return subprocess.CompletedProcess(argv, 0, "", "")

        self.assertEqual(scheduler.git_ls_remote("origin", "perf/chrome-parity", run=fake), sha(5))
        read = scheduler.git_first_parent("origin", "perf/chrome-parity", run=fake)
        self.assertEqual(read(sha(1), sha(5)), (sha(2), sha(5)))

    def test_schedule_command_on_the_checkout(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            hosts = root / "hosts.json"
            hosts.write_text(json.dumps({"hosts": [
                {"name": "wf-a", "role": "waterfall", "class": "m6", "host_class": M6, "shard": 0},
                {"name": "wf-b", "role": "waterfall", "class": "m6", "host_class": M6, "shard": 1}]}))
            builds = root / "builds.json"
            builds.write_text(json.dumps({"ready": [[sha(1), "bench"]]}))
            log = root / "log.txt"
            log.write_text(sha(1) + "\n")
            state = root / "state.json"
            done = subprocess.run([sys.executable, "-I", str(LAB / "lab.py"), "schedule", "--state", str(state),
                                   "--hosts", str(hosts), "--builds", str(builds), "--branch-log", str(log),
                                   "--now", START.isoformat(), "--write"], capture_output=True, text=True)
            self.assertEqual(done.returncode, 0, done.stderr)
            output = json.loads(done.stdout)
            self.assertEqual(output["cut"], 1)
            # Each m6 shard that the checkout's shard map gives a T0 story runs a T0 job on its host.
            shards = json.loads((LAB / "shard_map.json").read_text())["classes"]["m6"]["shards"]
            t0_hosts = {("wf-a", "wf-b")[s["index"]] for s in shards if s["stories"].get("T0")}
            self.assertEqual({j["host"] for j in output["jobs"] if j["tier"] == "T0"}, t0_hosts)
            self.assertEqual(t0_hosts, {"wf-a", "wf-b"})
            self.assertTrue(state.is_file())


if __name__ == "__main__":
    unittest.main()
