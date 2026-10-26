#!/usr/bin/env python3
"""pinpoint_exec.py: the Pinpoint executor against a fake controller, a real lab store and a real build ledger.

  python3 -m unittest scripts/perf-lab/tests/test_pinpoint_exec.py
"""
from __future__ import annotations

import importlib.util
import json
import random
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

LAB = Path(__file__).resolve().parent.parent


def _load(name: str, path: Path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


store = _load("perf_lab_store", LAB / "store.py")
builds = _load("perf_lab_builds", LAB / "builds.py")
pinpoint = _load("perf_lab_pinpoint", LAB / "pinpoint.py")
exe = _load("perf_lab_pinpoint_exec", LAB / "pinpoint_exec.py")

NOW = datetime(2026, 10, 25, 12, 0, tzinfo=timezone.utc)
STORY = "terminal.key-frame.light"
METRIC = "key_to_frame_ms"
M6 = store.Host("cmux15", "apple-m6", 16, 120, "fp-m6")
CLASS = M6.host_class
OTHER_CLASS = "apple-m4-pro/48gb/120hz"
SHAS = [f"{i:02x}" * 20 for i in range(17)]  # first-parent commits, oldest first; position = index
TIPS = (0, 4, 8, 12, 16)  # the waterfall measured these batch tips
CULPRIT = 10
BEFORE, AFTER = 10.0, 15.0


class Crash(Exception):
    """labd dies right after the controller took a request."""


class World:
    """A fake controller: builders write the ledger, story jobs write runs into the store as labd's ingest would."""

    def __init__(self, root: Path, *, unbuildable=(), silent=(), refuse_first_story=False) -> None:
        self.ledger = builds.BuildLedger(root / "ledger", clock=lambda: NOW)
        self.lab = store.Store(root / "lab.sqlite", clock=lambda: NOW)
        self.unbuildable = {SHAS[i] for i in unbuildable}
        self.silent = {SHAS[i] for i in silent}  # builder jobs that end without recording anything
        self.refuse_first_story = refuse_first_story
        self.host_list = [exe.LabHost("cmux17", exe.PINPOINT, CLASS)]
        self.by_key: dict[str, str] = {}
        self.jobs: dict[str, dict] = {}
        self.build_requests: list[exe.BuildRequest] = []
        self.story_requests: list[exe.StoryRequest] = []
        self.crash_on_story: int | None = None
        self.clock = NOW

    # Controller
    def hosts(self):
        return list(self.host_list)

    def find(self, key):
        return self.by_key.get(key)

    def _new(self, key, **job):
        if key in self.by_key:
            raise AssertionError(f"request {key} sent twice")
        controller_id = f"c{len(self.jobs) + 1}"
        self.by_key[key] = controller_id
        self.jobs[controller_id] = {"finished": False, "exit": None, **job}
        return controller_id

    def submit_build(self, request):
        self.build_requests.append(request)
        return self._new(request.key, kind="build", request=request)

    def submit_story(self, request):
        busy = [j for j in self.jobs.values()
                if j["kind"] == "story" and not j["finished"] and j["request"].host == request.host]
        if busy:
            raise AssertionError(f"{request.host} got a second story job")
        self.story_requests.append(request)
        controller_id = self._new(request.key, kind="story", request=request)
        if self.crash_on_story == len(self.story_requests):
            raise Crash()
        return controller_id

    def status(self, controller_id):
        job = self.jobs[controller_id]
        return exe.ControllerJob(job["finished"], job["exit"])

    # The world moves on: every outstanding job ends.
    def run_all(self) -> None:
        for controller_id, job in self.jobs.items():
            if job["finished"]:
                continue
            job["finished"] = True
            request = job["request"]
            if job["kind"] == "build":
                job["exit"] = 0
                if request.sha in self.silent:
                    continue
                if request.sha in self.unbuildable:
                    record = builds.BuildRecord(request.sha, request.config, "failed", 30,
                                                reason="x.swift:1: error: no")
                else:
                    record = builds.BuildRecord(request.sha, request.config, "ok", 30, digest="d" * 64,
                                                app="cmux DEV perf-lab.app")
                self.ledger.record(record)
                continue
            if self.refuse_first_story and len([j for j in self.jobs.values() if j["kind"] == "story"]) == 1:
                job["exit"] = 3  # env-invalid: nothing stored
                continue
            job["exit"] = 0
            for repeat in range(request.repeats):
                self.clock += timedelta(seconds=1)
                self.lab.insert_run(
                    run(f"{controller_id}-{repeat}", "bisect", self.clock, job_id=request.lab_job_id),
                    build=store.Build(request.sha, request.config, SHAS.index(request.sha)),
                    host=store.Host(request.host, "apple-m6", 16, 120, "fp-m6"),
                    metrics=[metric(samples(request.sha, f"{controller_id}-{repeat}"))])


def samples(sha: str, seed: str) -> list[float]:
    rng = random.Random(f"{sha}:{seed}")
    base = AFTER if SHAS.index(sha) >= CULPRIT else BEFORE
    return [base + rng.gauss(0, 0.3) for _ in range(5)]


def run(uuid: str, kind: str, started: datetime, job_id: int | None = None) -> store.Run:
    return store.Run(run_uuid=uuid, kind=kind, measure_version="1", story=STORY, engine="native", macos_major=26,
                     macos_build="25A1", features_hash="f", safe_mode="off", started_at=started, job_id=job_id)


def metric(values: list[float]) -> store.Metric:
    return store.Metric(METRIC, "ms", "lower", values)


def seed_lab(world: World, *, group_state: str = "new") -> int:
    """Waterfall points at the batch tips, their builds in the ledger, and one alert group over the whole range."""
    for index in TIPS:
        world.lab.insert_run(run(f"wf-{index}", "waterfall", NOW + timedelta(minutes=index)),
                             build=store.Build(SHAS[index], "bench", index), host=M6,
                             metrics=[metric(samples(SHAS[index], "wf"))])
        world.ledger.record(builds.BuildRecord(SHAS[index], "bench", "ok", 30, digest="e" * 64,
                                               app="cmux DEV perf-lab.app"))
    db = world.lab._db
    stamp = NOW.isoformat()
    group_id = db.execute(
        "INSERT INTO alert_groups (state, start_pos, end_pos, created_at, updated_at) VALUES (?, 1, 16, ?, ?)",
        (group_state, stamp, stamp)).lastrowid
    series_id = db.execute("SELECT id FROM series").fetchone()[0]
    db.execute(
        """INSERT INTO alerts (series_id, group_id, rule, start_pos, end_pos, median_before, median_after,
                               is_improvement, created_at) VALUES (?, ?, 'edivisive', 1, 16, ?, ?, 0, ?)""",
        (series_id, group_id, BEFORE, AFTER, stamp))
    return group_id


def first_parent(good: str, bad: str):
    return SHAS[SHAS.index(good) + 1:SHAS.index(bad) + 1]


class Fixture(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def world(self, **options) -> World:
        world = World(self.root, **options)
        world.lab.migrate()
        return world

    def executor(self, world: World, **options) -> exe.Executor:
        return exe.Executor(self.root / "lab.sqlite", self.root / "state", controller=world, ledger=world.ledger,
                            first_parent=first_parent, clock=lambda: NOW, **options)

    def drive(self, world: World, executor: exe.Executor, rounds: int = 200) -> list[exe.TickReport]:
        reports = []
        for _ in range(rounds):
            reports.append(executor.tick())
            if self.bisect_row(world)["state"] == "done":
                return reports
            world.run_all()
        self.fail("the bisect did not finish")

    def bisect_row(self, world: World):
        return world.lab._db.execute(
            "SELECT * FROM jobs WHERE kind = 'bisect' AND alert_group_id IS NOT NULL").fetchone()

    def result(self, world: World) -> dict:
        return json.loads(self.bisect_row(world)["result_json"])

    def group(self, world: World, group_id: int):
        return world.lab._db.execute("SELECT * FROM alert_groups WHERE id = ?", (group_id,)).fetchone()

    def history(self, world: World, group_id: int) -> list[tuple[str, str]]:
        return [(r["from_state"], r["to_state"]) for r in world.lab._db.execute(
            "SELECT * FROM sheriff_history WHERE group_id = ? ORDER BY id", (group_id,))]


class StartTests(Fixture):
    def test_new_group_starts_one_bisect_with_the_alert_delta(self) -> None:
        world = self.world()
        group_id = seed_lab(world)
        executor = self.executor(world)
        self.assertEqual(len(executor.start_bisects()), 1)
        self.assertEqual(executor.start_bisects(), [])
        row = self.bisect_row(world)
        job = json.loads(row["params_json"])["job"]
        self.assertEqual(job["magnitude"], AFTER - BEFORE)
        self.assertEqual((job["story"], job["metric"], job["host_class"], job["config"]),
                         (STORY, METRIC, CLASS, "bench"))
        self.assertEqual((job["good"]["sha"], job["bad"]["sha"]), (SHAS[0], SHAS[16]))
        self.assertEqual([c["sha"] for c in job["commits"]], SHAS)
        self.assertEqual([i for i, c in enumerate(job["commits"]) if c["batch_tip"]], list(TIPS))
        self.assertEqual([i for i, c in enumerate(job["commits"]) if c["stored_build"]], list(TIPS))
        self.assertEqual(self.group(world, group_id)["state"], "bisecting")
        self.assertEqual(self.history(world, group_id), [("new", "triaged"), ("triaged", "bisecting")])

    def test_closed_or_drifted_groups_are_not_bisected(self) -> None:
        for state in ("lab-drift", "invalid", "culprit", "accepted"):
            with self.subTest(state=state):
                self.tearDown()
                self.setUp()
                world = self.world()
                seed_lab(world, group_state=state)
                self.assertEqual(self.executor(world).start_bisects(), [])
                self.assertIsNone(self.bisect_row(world))

    def test_unknown_range_waits(self) -> None:
        world = self.world()
        seed_lab(world)
        executor = exe.Executor(self.root / "lab.sqlite", self.root / "state", controller=world, ledger=world.ledger,
                                first_parent=lambda good, bad: None, clock=lambda: NOW)
        report = executor.tick()
        self.assertEqual(report.started, [])
        self.assertIn("not known yet", report.problems[0])


class BisectTests(Fixture):
    def test_finds_the_culprit_and_marks_the_group_unverified(self) -> None:
        world = self.world()
        group_id = seed_lab(world)
        self.drive(world, self.executor(world))
        result = self.result(world)
        self.assertEqual(result["outcome"], pinpoint.CULPRITS)
        self.assertEqual([c["change"]["sha"] for c in result["culprits"]], [SHAS[CULPRIT]])
        group = self.group(world, group_id)
        self.assertEqual((group["state"], group["culprit_sha"], group["culprit_verified"]),
                         ("culprit", SHAS[CULPRIT], 0))
        self.assertEqual(self.history(world, group_id)[-1], ("bisecting", "culprit"))
        # Batch tips had builds; inside the culprit batch only the midpoint 10, then 9 (8 vs 10 DIFFERENT), were built.
        self.assertEqual(sorted(SHAS.index(r.sha) for r in world.build_requests), [9, 10])
        for request in world.story_requests:
            self.assertEqual((request.story, request.config, request.digest[:7]), (STORY, "bench", "sha256:"))

    def test_build_failure_is_unbuildable(self) -> None:
        world = self.world(unbuildable=(9,))
        seed_lab(world)
        self.drive(world, self.executor(world))
        result = self.result(world)
        self.assertIn([SHAS[9], pinpoint.UNBUILDABLE], result["skipped"])
        self.assertEqual(len([r for r in world.build_requests if r.sha == SHAS[9]]), 1)  # recorded once, never retried
        culprit = result["culprits"][0]
        self.assertEqual(culprit["change"]["sha"], SHAS[CULPRIT])
        self.assertEqual(culprit["commits"], [SHAS[9], SHAS[10]])  # the step is in (8, 10] across the skipped commit
        self.assertNotIn(SHAS[9], {r.sha for r in world.story_requests})

    def test_builder_that_records_nothing_is_asked_again_then_unbuildable(self) -> None:
        world = self.world(silent=(9,))
        seed_lab(world)
        self.drive(world, self.executor(world))
        self.assertEqual(len([r for r in world.build_requests if r.sha == SHAS[9]]), exe.BUILD_RETRIES + 1)
        self.assertIn([SHAS[9], pinpoint.UNBUILDABLE], self.result(world)["skipped"])

    def test_refused_story_job_runs_again(self) -> None:
        world = self.world(refuse_first_story=True)
        seed_lab(world)
        reports = self.drive(world, self.executor(world))
        self.assertEqual(self.result(world)["outcome"], pinpoint.CULPRITS)
        self.assertTrue(any("exited 3" in p for r in reports for p in r.problems))
        first, again = world.story_requests[0], world.story_requests[1]
        self.assertEqual((first.sha, first.repeats), (again.sha, again.repeats))
        self.assertNotEqual(first.key, again.key)

    def test_no_step_goes_back_to_triaged(self) -> None:
        global CULPRIT
        world = self.world()
        old, CULPRIT = CULPRIT, 99  # every commit measures BEFORE
        try:
            group_id = seed_lab(world)
            self.drive(world, self.executor(world))
        finally:
            CULPRIT = old
        self.assertEqual(self.result(world)["outcome"], pinpoint.NO_CULPRIT)
        self.assertEqual(self.group(world, group_id)["state"], "triaged")
        self.assertEqual(self.history(world, group_id)[-1], ("bisecting", "triaged"))


class RestartTests(Fixture):
    def baseline(self) -> tuple[dict, int, int]:
        world = self.world()
        seed_lab(world)
        self.drive(world, self.executor(world))
        return self.result(world), len(world.build_requests), len(world.story_requests)

    def test_restart_resumes_without_resubmitting(self) -> None:
        expected = self.baseline()
        self.tearDown()
        self.setUp()
        world = self.world()
        seed_lab(world)
        for executor_round in range(100):  # a new labd process every tick
            executor = self.executor(world)
            executor.tick()
            executor.tick()  # a second tick with no news sends nothing
            executor.close()
            if self.bisect_row(world)["state"] == "done":
                break
            world.run_all()
        self.assertEqual((self.result(world), len(world.build_requests), len(world.story_requests)), expected)

    def test_crash_after_the_controller_took_the_request(self) -> None:
        world = self.world()
        seed_lab(world)
        world.crash_on_story = 3
        executor = self.executor(world)
        with self.assertRaises(Crash):
            for _ in range(50):
                executor.tick()
                world.run_all()
        executor.close()
        sent = len(world.story_requests)
        executor = self.executor(world)
        executor.tick()  # adopts the request by its key instead of sending it again (World refuses a repeat key)
        self.assertEqual(len(world.story_requests), sent)
        row = world.lab._db.execute("SELECT controller_job_id FROM jobs WHERE id = ?",
                                    (world.story_requests[-1].lab_job_id,)).fetchone()
        self.assertEqual(row["controller_job_id"], world.by_key[world.story_requests[-1].key])
        self.drive(world, executor)
        self.assertEqual(self.result(world)["outcome"], pinpoint.CULPRITS)

    def test_a_journal_that_does_not_replay_is_refused(self) -> None:
        world = self.world()
        seed_lab(world)
        executor = self.executor(world)
        executor.tick()
        path = next((self.root / "state").glob("bisect-*.json"))
        document = json.loads(path.read_text())
        document["events"][0]["actions"] = []
        path.write_text(json.dumps(document))
        sent = len(world.story_requests)
        report = self.executor(world).tick()
        self.assertIn("cannot resume", report.problems[0])
        self.assertEqual(len(world.story_requests), sent)
        self.assertEqual(json.loads(path.read_text()), document)  # left as it was for the operator


class HostTests(Fixture):
    def test_never_another_class_or_a_waterfall_host_that_is_not_idle(self) -> None:
        world = self.world()
        seed_lab(world)
        world.host_list = [
            exe.LabHost("cmux17", exe.PINPOINT, CLASS),
            exe.LabHost("cmux20-bench", exe.PINPOINT, OTHER_CLASS),
            exe.LabHost("aws-m4pro-5", exe.WATERFALL, OTHER_CLASS, next_t0_at=NOW + timedelta(hours=5)),
            exe.LabHost("cmux15", exe.WATERFALL, CLASS, busy=True, next_t0_at=NOW + timedelta(hours=5)),
            exe.LabHost("cmux16", exe.WATERFALL, CLASS, next_t0_at=NOW + timedelta(minutes=5)),
            exe.LabHost("cmux18", exe.PINPOINT, CLASS, up=False),
        ]
        self.drive(world, self.executor(world, repeat_seconds=lambda story: 10.0))
        self.assertEqual({r.host for r in world.story_requests}, {"cmux17"})
        self.assertEqual(self.result(world)["outcome"], pinpoint.CULPRITS)

    def test_borrows_an_idle_waterfall_host_far_from_its_t0(self) -> None:
        world = self.world()
        seed_lab(world)
        world.host_list = [exe.LabHost("cmux16", exe.WATERFALL, CLASS, next_t0_at=NOW + timedelta(hours=1))]
        self.drive(world, self.executor(world, repeat_seconds=lambda story: 10.0))
        self.assertEqual({r.host for r in world.story_requests}, {"cmux16"})

    def test_waits_with_no_host_of_its_class(self) -> None:
        world = self.world()
        seed_lab(world)
        world.host_list = [exe.LabHost("cmux20-bench", exe.PINPOINT, OTHER_CLASS)]
        executor = self.executor(world)
        for _ in range(5):
            executor.tick()
            world.run_all()
        self.assertEqual(world.story_requests, [])
        self.assertEqual(self.bisect_row(world)["state"], "running")

    def test_pick_host(self) -> None:
        idle = exe.LabHost("w", exe.WATERFALL, CLASS, next_t0_at=NOW + timedelta(minutes=30))
        own = exe.LabHost("p", exe.PINPOINT, CLASS)
        other = exe.LabHost("x", exe.PINPOINT, OTHER_CLASS)
        pick = exe.pick_host
        self.assertEqual(pick([idle, own, other], CLASS, now=NOW, seconds=60, taken=set()), own)
        self.assertEqual(pick([idle, other], CLASS, now=NOW, seconds=60, taken=set()), idle)
        self.assertIsNone(pick([idle, other], CLASS, now=NOW, seconds=None, taken=set()))  # unknown length
        self.assertIsNone(pick([idle], CLASS, now=NOW, seconds=31 * 60, taken=set()))  # would run into its T0
        self.assertIsNone(pick([idle], CLASS, now=NOW + timedelta(minutes=21), seconds=1, taken=set()))  # T0 < 10 min
        self.assertIsNone(pick([exe.LabHost("w", exe.WATERFALL, CLASS)], CLASS, now=NOW, seconds=1, taken=set()))
        self.assertIsNone(pick([own, other], CLASS, now=NOW, seconds=1, taken={"p"}))
        self.assertIsNone(pick([other], CLASS, now=NOW, seconds=1, taken=set()))
        second = exe.LabHost("q", exe.PINPOINT, CLASS)
        self.assertEqual(pick([own, second], CLASS, now=NOW, seconds=1, taken=set(), prefer="q"), second)


if __name__ == "__main__":
    unittest.main()
