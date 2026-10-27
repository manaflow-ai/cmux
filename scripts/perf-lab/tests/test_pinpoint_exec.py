#!/usr/bin/env python3
"""pinpoint_exec.py: the Pinpoint executor with the real scheduler, ingest, sheriff, lab store and build ledger,
against a fake controller that writes result-v1 artifacts.

  python3 -m unittest scripts/perf-lab/tests/test_pinpoint_exec.py
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import random
import sys
import tempfile
import unittest
from dataclasses import replace
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


exe = _load("perf_lab_pinpoint_exec", LAB / "pinpoint_exec.py")
store, builds, pinpoint, scheduler, sheriff, ingest = exe.store, exe.builds, exe.pinpoint, exe.scheduler, \
    exe.sheriff, exe.ingest
perf_result = ingest.perf_result

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


def pinpoint_host(name: str, host_class: str = CLASS, **options) -> scheduler.Host:
    return scheduler.Host(name, scheduler.PINPOINT, "m6", host_class, **options)


def waterfall_host(name: str, host_class: str = CLASS, lab_class: str = "m6", **options) -> scheduler.Host:
    return scheduler.Host(name, scheduler.WATERFALL, lab_class, host_class, shard=0, **options)


class Crash(Exception):
    """labd dies right after the controller took a request."""


class Refused(Exception):
    """The controller client refused a call."""


class World:
    """labd around the executor: the real scheduler places Pinpoint work, a fake controller runs it. Builders write
    the ledger; a story job writes a result-v1 artifact that the executor ingests."""

    def __init__(self, root: Path, *, unbuildable=(), silent=(), culprit: int = CULPRIT) -> None:
        self.root = root
        self.ledger = builds.BuildLedger(root / "ledger", clock=lambda: NOW)
        self.lab = store.Store(root / "lab.sqlite", clock=lambda: NOW)
        self.lab.migrate()
        self.unbuildable = {SHAS[i] for i in unbuildable}
        self.silent = {SHAS[i] for i in silent}  # builder jobs that end without recording anything
        self.culprit = culprit
        self.hosts = [pinpoint_host("cmux17")]
        self.shard_map = scheduler.ShardMap({})
        self.stories: tuple = ()
        self.branch_log: tuple = ()
        self.sched = scheduler.State()
        self.now = NOW
        self.by_key: dict[str, str] = {}
        self.jobs: dict[str, dict] = {}
        self.build_requests: list = []
        self.story_requests: list = []
        self.other_jobs: list = []
        self.cancelled: list[str] = []
        self.crash_on_story: int | None = None
        self.exit_code = lambda request, number: 0  # the story job's exit code; 1 writes one repeat fewer
        self.not_measurable: set[str] = set()
        self.no_artifact: set[str] = set()  # story jobs (by sha) whose artifact never arrives
        self.find_fails: set[int] = set()  # bisect job ids whose controller lookups raise

    # ----- Controller -----
    def find(self, key):
        if int(key.split(":")[1]) in self.find_fails:
            raise Refused(f"find {key}: 503")
        return self.by_key.get(key)

    def status(self, controller_id):
        job = self.jobs[controller_id]
        return exe.ControllerJob(job["finished"], job["exit"], job.get("not_measurable", False), job["host"],
                                 job.get("artifact"))

    def cancel(self, controller_id):
        self.cancelled.append(controller_id)
        self.jobs[controller_id].update(finished=True, exit=None)

    # ----- labd -----
    def busy(self) -> set[str]:
        return {j["host"] for j in self.jobs.values() if not j["finished"]}

    def ledger_builds(self) -> scheduler.Builds:
        ready, failed = set(), set()
        for sha in SHAS:
            answer = self.ledger.get(sha, "bench")
            if answer is not None:
                (ready if answer.status == "ok" else failed).add((sha, "bench"))
        return scheduler.Builds(ready=frozenset(ready), failed=frozenset(failed))

    def tick(self, executor) -> "exe.TickReport":
        """One labd poll: the executor's tick, then a scheduler plan with its Pinpoint work, then submit."""
        report = executor.tick()
        hosts = [replace(h, busy=h.busy or h.name in self.busy()) for h in self.hosts]
        plan = scheduler.plan(self.sched, self.now, hosts, self.ledger_builds(), self.branch_log,
                              stories=self.stories, shard_map=self.shard_map, pinpoint=executor.pinpoint_work())
        self.build_requests.extend(plan.builds)
        for job in plan.jobs:
            request = executor.story_request(job.work_id) if job.work_id else None
            if request is None:
                self.other_jobs.append(job)
                self._new(job.id, kind="other", host=job.host)
            else:
                self.submit_story(job.host, request)
        self.sched = plan.state  # saved only after submit returned, as Driver does
        return report

    def _new(self, key, **job):
        if key in self.by_key:
            raise AssertionError(f"request {key} sent twice")
        if job["host"] in self.busy():
            raise AssertionError(f"{job['host']} got a second job")
        controller_id = f"c{len(self.jobs) + 1}"
        self.by_key[key] = controller_id
        self.jobs[controller_id] = {"finished": False, "exit": None, "key": key, **job}
        return controller_id

    def submit_story(self, host, request):
        self.story_requests.append((host, request))
        controller_id = self._new(request.key, kind="story", host=host, request=request)
        if self.crash_on_story == len(self.story_requests):
            raise Crash()
        return controller_id

    # ----- the world moves on: every running job and requested build ends -----
    def run_all(self) -> None:
        for request in self.build_requests:
            if self.ledger.get(request.sha, request.config) is not None or request.sha in self.silent:
                continue
            if request.sha in self.unbuildable:
                self.ledger.record(builds.BuildRecord(request.sha, request.config, "failed", 30,
                                                      reason="x.swift:1: error: no"))
            else:
                self.ledger.record(builds.BuildRecord(request.sha, request.config, "ok", 30, digest="d" * 64,
                                                      app="cmux DEV perf-lab.app"))
        for controller_id, job in self.jobs.items():
            if job["finished"]:
                continue
            job["finished"] = True
            self.sched = scheduler.finished(self.sched, job["key"])
            if job["kind"] != "story":
                job["exit"] = 0
                continue
            request = job["request"]
            if request.sha in self.not_measurable:
                job.update(exit=0, not_measurable=True)
                continue
            number = [r.key for _, r in self.story_requests].index(request.key) + 1
            job["exit"] = self.exit_code(request, number)
            if job["exit"] not in exe.MEASURED_EXITS or request.sha in self.no_artifact:
                continue
            repeats = request.repeats - (1 if job["exit"] == 1 else 0)
            if repeats:
                job["artifact"] = self.artifact(controller_id, request, repeats)

    def artifact(self, controller_id: str, request, repeats: int) -> Path:
        folder = self.root / "artifacts" / controller_id
        host = job_host(self.jobs[controller_id]["host"])
        results = []
        for repeat in range(repeats):
            self.now += timedelta(seconds=1)
            results.append(perf_result.Result(
                story=request.story, metric=METRIC, unit="ms", better="lower",
                samples=samples(request.sha, f"{controller_id}-{repeat}", self.culprit),
                build=perf_result.Build(request.sha, request.config, 1), host=host, engine="none", session="light",
                run=perf_result.Run(f"{request.key}-{repeat}", self.now.strftime("%Y-%m-%dT%H:%M:%S.%fZ"))))
        perf_result.write_ndjson(folder, results)
        return folder


def job_host(name: str):
    return perf_result.Host(fingerprint=hashlib.sha256(name.encode()).hexdigest(), host_class=CLASS,
                            chip="Apple M6", macos="26.1", macos_build="25B78", display_hz=120)


def positions(sha: str):
    return ingest.CommitPosition(SHAS.index(sha), mainline=True) if sha in SHAS else None


def samples(sha: str, seed: str, culprit: int = CULPRIT) -> list[float]:
    rng = random.Random(f"{sha}:{seed}")
    base = AFTER if SHAS.index(sha) >= culprit else BEFORE
    return [base + rng.gauss(0, 0.3) for _ in range(5)]


def run(uuid: str, kind: str, started: datetime) -> store.Run:
    return store.Run(run_uuid=uuid, kind=kind, measure_version="1", story=STORY, engine="native", macos_major=26,
                     macos_build="25A1", features_hash="f", safe_mode="off", started_at=started)


def add_group(world: World, *, state: str = "new", start: int = 1) -> int:
    """One alert group over (start-1, 16]; a second group needs another start (one alert per series and range)."""
    db = world.lab._db
    stamp = NOW.isoformat()
    group_id = db.execute(
        "INSERT INTO alert_groups (state, start_pos, end_pos, created_at, updated_at) VALUES (?, ?, 16, ?, ?)",
        (state, start, stamp, stamp)).lastrowid
    series_id = db.execute("SELECT id FROM series ORDER BY id LIMIT 1").fetchone()[0]
    db.execute(
        """INSERT INTO alerts (series_id, group_id, rule, start_pos, end_pos, median_before, median_after,
                               is_improvement, created_at) VALUES (?, ?, 'edivisive', ?, 16, ?, ?, 0, ?)""",
        (series_id, group_id, start, BEFORE, AFTER, stamp))
    return group_id


def seed_lab(world: World, *, group_state: str = "new") -> int:
    """Waterfall points at the batch tips, their builds in the ledger, and one alert group over the whole range."""
    for index in TIPS:
        world.lab.insert_run(run(f"wf-{index}", "waterfall", NOW + timedelta(minutes=index)),
                             build=store.Build(SHAS[index], "bench", index), host=M6,
                             metrics=[store.Metric(METRIC, "ms", "lower", samples(SHAS[index], "wf"))])
        world.ledger.record(builds.BuildRecord(SHAS[index], "bench", "ok", 30, digest="e" * 64,
                                               app="cmux DEV perf-lab.app"))
    return add_group(world, state=group_state)


def first_parent(good: str, bad: str):
    return SHAS[SHAS.index(good) + 1:SHAS.index(bad) + 1]


class Fixture(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def world(self, **options) -> World:
        return World(self.root, **options)

    def executor(self, world: World, **options) -> exe.Executor:
        options.setdefault("first_parent", first_parent)
        executor = exe.Executor(self.root / "lab.sqlite", self.root / "state", controller=world, ledger=world.ledger,
                                commit_positions=positions, clock=lambda: world.now, **options)
        self.addCleanup(executor.close)
        return executor

    def drive(self, world: World, executor: exe.Executor, rounds: int = 200) -> list:
        reports = []
        for _ in range(rounds):
            reports.append(world.tick(executor))
            if all(row["state"] != "running" for row in self.bisect_rows(world)):
                return reports
            world.run_all()
        self.fail("the bisect did not finish")

    def bisect_rows(self, world: World):
        return world.lab._db.execute(
            "SELECT * FROM jobs WHERE kind = 'bisect' AND alert_group_id IS NOT NULL ORDER BY id").fetchall()

    def bisect_row(self, world: World):
        rows = self.bisect_rows(world)
        return rows[0] if rows else None

    def result(self, world: World, row=None) -> dict:
        return json.loads((row or self.bisect_row(world))["result_json"])

    def group(self, world: World, group_id: int):
        return world.lab._db.execute("SELECT * FROM alert_groups WHERE id = ?", (group_id,)).fetchone()

    def history(self, world: World, group_id: int) -> list[tuple[str, str]]:
        return [(r["from_state"], r["to_state"]) for r in world.lab._db.execute(
            "SELECT * FROM sheriff_history WHERE group_id = ? ORDER BY id", (group_id,))]

    def journal(self, job_id: int = 1) -> dict:
        return json.loads((self.root / "state" / f"bisect-{job_id}.json").read_text())

    def stories_on(self, world: World, sha_index: int) -> list:
        return [r for _, r in world.story_requests if r.sha == SHAS[sha_index]]


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
        actors = {r["actor"] for r in world.lab._db.execute("SELECT actor FROM sheriff_history")}
        self.assertEqual(actors, {exe.ACTOR})

    def test_the_bisect_range_is_the_range_the_issue_links(self) -> None:
        world = self.world()
        group_id = seed_lab(world)
        self.executor(world).start_bisects()
        top = exe.alerts.group_alerts(world.lab, group_id)[0]
        job = json.loads(self.bisect_row(world)["params_json"])["job"]
        self.assertEqual(exe.alerts.waterfall_sha(world.lab, "bench", top.start_pos, before=True), job["good"]["sha"])
        self.assertEqual(exe.alerts.waterfall_sha(world.lab, "bench", top.end_pos, before=False), job["bad"]["sha"])

    def test_closed_or_drifted_groups_are_not_bisected(self) -> None:
        for state in ("lab-drift", "invalid", "culprit", "accepted"):
            with self.subTest(state=state):
                self.tearDown()
                self.setUp()
                world = self.world()
                seed_lab(world, group_state=state)
                self.assertEqual(self.executor(world).start_bisects(), [])
                self.assertIsNone(self.bisect_row(world))

    def test_a_group_a_sheriff_holds_is_not_moved(self) -> None:
        world = self.world()
        group_id = seed_lab(world)
        sheriff.Sheriff(world.lab, session="sheriff-a", lead_session=None, clock=lambda: NOW).take(group_id)
        report = self.executor(world).tick()
        self.assertEqual(report.started, [])
        self.assertIn("held by sheriff-a", report.problems[0])
        self.assertIsNone(self.bisect_row(world))
        self.assertEqual(self.group(world, group_id)["state"], "new")

    def test_unknown_range_waits(self) -> None:
        world = self.world()
        seed_lab(world)
        report = self.executor(world, first_parent=lambda good, bad: None).tick()
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
        for host, request in world.story_requests:
            self.assertEqual((host, request.story, request.config, request.digest[:7]),
                             ("cmux17", STORY, "bench", "sha256:"))

    def test_results_come_through_the_ingest_linked_to_the_story_job(self) -> None:
        world = self.world()
        seed_lab(world)
        self.drive(world, self.executor(world))
        rows = world.lab._db.execute(
            """SELECT u.kind, u.job_id, j.state, json_extract(j.params_json, '$.key') AS key FROM runs u
               JOIN jobs j ON j.id = u.job_id""").fetchall()
        self.assertTrue(rows)
        self.assertEqual({r["kind"] for r in rows}, {"bisect"})
        self.assertEqual({r["state"] for r in rows}, {"done"})
        self.assertEqual({r["key"] for r in rows}, {r.key for _, r in world.story_requests})
        unlinked = world.lab._db.execute("SELECT COUNT(*) FROM runs WHERE kind = 'bisect' AND job_id IS NULL")
        self.assertEqual(unlinked.fetchone()[0], 0)

    def test_partial_story_jobs_exit_1_and_are_read(self) -> None:
        world = self.world()
        seed_lab(world)
        world.exit_code = lambda request, number: 1  # every job writes one repeat fewer than asked
        self.drive(world, self.executor(world))
        self.assertEqual(self.result(world)["outcome"], pinpoint.CULPRITS)
        attempts = [e["attempt"] for e in self.journal()["events"] if e["t"] == "attempt"]
        runs = [r for _, r in world.story_requests]
        self.assertEqual(sum(a["failed"] for a in attempts), len(runs))  # the missing repeat of each job
        self.assertEqual(len(runs), len({r.key for r in runs}))  # none was run again

    def test_build_failure_is_unbuildable(self) -> None:
        world = self.world(unbuildable=(9,))
        seed_lab(world)
        self.drive(world, self.executor(world))
        result = self.result(world)
        self.assertIn([SHAS[9], pinpoint.UNBUILDABLE], result["skipped"])
        self.assertEqual(len([r for r in world.build_requests if r.sha == SHAS[9]]), 1)
        culprit = result["culprits"][0]
        self.assertEqual(culprit["change"]["sha"], SHAS[CULPRIT])
        self.assertEqual(culprit["commits"], [SHAS[9], SHAS[10]])  # the step is in (8, 10] across the skipped commit
        self.assertEqual(self.stories_on(world, 9), [])

    def test_build_the_ledger_already_failed_is_never_requested(self) -> None:
        world = self.world()
        seed_lab(world)
        world.ledger.record(builds.BuildRecord(SHAS[10], "bench", "failed", 30, reason="x.swift:1: error: no"))
        self.drive(world, self.executor(world))
        result = self.result(world)
        self.assertIn([SHAS[10], pinpoint.UNBUILDABLE], result["skipped"])
        self.assertNotIn(SHAS[10], {r.sha for r in world.build_requests})
        self.assertEqual(result["culprits"][0]["commits"], [SHAS[10], SHAS[11]])

    def test_a_build_with_no_ledger_record_waits_and_is_never_unbuildable(self) -> None:
        world = self.world(silent=(10,))
        seed_lab(world)
        executor = self.executor(world)
        reports = []
        for _ in range(30):
            reports.append(world.tick(executor))
            world.run_all()
            world.now += timedelta(minutes=10)
        self.assertEqual(self.bisect_row(world)["state"], "running")
        self.assertEqual(len([r for r in world.build_requests if r.sha == SHAS[10]]), 1)
        self.assertTrue(any("no build ledger record" in p for p in reports[-1].problems))
        self.assertFalse(any(e["t"] == "build" and e["change"]["sha"] == SHAS[10] for e in self.journal()["events"]))
        world.silent.clear()  # the operator fixed the builder; its record answers the outstanding Build
        world.ledger.record(builds.BuildRecord(SHAS[10], "bench", "ok", 30, digest="d" * 64,
                                               app="cmux DEV perf-lab.app"))
        self.drive(world, executor)
        result = self.result(world)
        self.assertEqual([c["change"]["sha"] for c in result["culprits"]], [SHAS[CULPRIT]])
        self.assertEqual(result["skipped"], [])

    def test_not_measurable_change_is_skipped_and_the_range_narrows(self) -> None:
        world = self.world()
        seed_lab(world)
        world.not_measurable = {SHAS[9]}
        self.drive(world, self.executor(world))
        result = self.result(world)
        self.assertIn([SHAS[9], pinpoint.NOT_MEASURABLE], result["skipped"])
        self.assertEqual(result["culprits"][0]["commits"], [SHAS[9], SHAS[10]])

    def test_refused_story_job_runs_again(self) -> None:
        world = self.world()
        seed_lab(world)
        world.exit_code = lambda request, number: 3 if number == 1 else 0  # env-invalid: nothing stored
        reports = self.drive(world, self.executor(world))
        self.assertEqual(self.result(world)["outcome"], pinpoint.CULPRITS)
        self.assertTrue(any("exited 3" in p for r in reports for p in r.problems))
        first = world.story_requests[0][1]
        action = first.key.rsplit(":", 1)[0]
        again = next(r for _, r in world.story_requests if r.key == f"{action}:1")  # the same action, its next try
        self.assertEqual((first.sha, first.repeats), (again.sha, again.repeats))
        self.assertNotEqual(first.lab_job_id, again.lab_job_id)
        state = world.lab._db.execute("SELECT state FROM jobs WHERE id = ?", (first.lab_job_id,)).fetchone()[0]
        self.assertEqual(state, "failed")

    def test_story_job_that_never_measures_fails_its_attempts_after_the_retries(self) -> None:
        world = self.world()
        seed_lab(world)
        world.exit_code = lambda request, number: 3 if request.sha == SHAS[16] else 0
        executor = self.executor(world)
        for _ in range(12):
            world.tick(executor)
            world.run_all()
        first = self.stories_on(world, 16)[0]
        action = first.key.rsplit(":", 1)[0]
        tries = [r.key for r in self.stories_on(world, 16) if r.key.rsplit(":", 1)[0] == action]
        self.assertEqual(tries, [f"{action}:{n}" for n in range(exe.RUN_RETRIES + 1)])
        failed = [e["attempt"] for e in self.journal()["events"]
                  if e["t"] == "attempt" and e["attempt"]["change"]["sha"] == SHAS[16]
                  and e["attempt"]["index"] < first.repeats]
        self.assertEqual(len(failed), first.repeats)
        self.assertTrue(all(a["failed"] for a in failed))

    def test_finished_job_whose_artifact_never_comes_is_run_again(self) -> None:
        world = self.world()
        seed_lab(world)
        world.no_artifact = {SHAS[0]}
        executor = self.executor(world)
        world.tick(executor)
        world.run_all()
        world.no_artifact.clear()
        world.tick(executor)
        self.assertEqual(len(self.stories_on(world, 0)), 1)  # waits for the artifact
        world.now += exe.RESULT_WAIT + timedelta(seconds=1)
        report = world.tick(executor)
        self.assertTrue(any("no artifact" in p for p in report.problems))
        world.run_all()
        world.tick(executor)
        self.assertEqual(len(self.stories_on(world, 0)), 2)

    def test_no_step_goes_back_to_triaged(self) -> None:
        world = self.world(culprit=99)  # every commit measures BEFORE
        group_id = seed_lab(world)
        self.drive(world, self.executor(world))
        self.assertEqual(self.result(world)["outcome"], pinpoint.NO_CULPRIT)
        self.assertEqual(self.group(world, group_id)["state"], "triaged")
        self.assertEqual(self.history(world, group_id)[-1], ("bisecting", "triaged"))

    def test_closed_group_cancels_its_bisect(self) -> None:
        world = self.world()
        group_id = seed_lab(world)
        executor = self.executor(world)
        for _ in range(3):
            world.tick(executor)
            world.run_all()
        world.tick(executor)  # a story job is now running
        running = [cid for cid, j in world.jobs.items() if j["kind"] == "story" and not j["finished"]]
        self.assertTrue(running)
        sheriff.Sheriff(world.lab, session="sheriff-a", lead_session=None, clock=lambda: NOW).set_state(
            group_id, "lab-drift", reason="the .ref series moved")
        sent = len(world.story_requests)
        report = world.tick(executor)
        self.assertEqual(report.cancelled, [1])
        self.assertEqual(world.cancelled, running)
        self.assertEqual(self.bisect_row(world)["state"], "cancelled")
        self.assertEqual(executor.pinpoint_work(), ())
        live = world.lab._db.execute(
            "SELECT COUNT(*) FROM jobs WHERE alert_group_id IS NULL AND state IN ('queued', 'running')").fetchone()[0]
        self.assertEqual(live, 0)
        world.run_all()
        world.tick(executor)
        self.assertEqual(len(world.story_requests), sent)
        self.assertEqual(self.group(world, group_id)["state"], "lab-drift")


class IsolationTests(Fixture):
    def test_a_failing_controller_call_holds_up_only_its_job(self) -> None:
        world = self.world()
        seed_lab(world)
        add_group(world, start=2)
        executor = self.executor(world)
        world.tick(executor)
        world.run_all()
        world.find_fails = {1}
        report = world.tick(executor)
        self.assertTrue(any(p.startswith("bisect 1: controller find") and "503" in p for p in report.problems))
        before = len([r for _, r in world.story_requests if r.key.startswith("perf-lab-pinpoint:2:")])
        for _ in range(5):
            world.run_all()
            world.tick(executor)
        after = len([r for _, r in world.story_requests if r.key.startswith("perf-lab-pinpoint:2:")])
        self.assertGreater(after, before)
        world.find_fails.clear()
        self.drive(world, executor)
        for row in self.bisect_rows(world):
            self.assertEqual(self.result(world, row)["outcome"], pinpoint.CULPRITS)


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
        for _ in range(100):  # a new labd process every tick
            executor = self.executor(world)
            world.tick(executor)
            world.tick(executor)  # a second tick with no news starts nothing
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
                world.tick(executor)
                world.run_all()
        executor.close()
        sent = len(world.story_requests)
        _, request = world.story_requests[-1]
        executor = self.executor(world)
        world.tick(executor)  # finds the request by its key instead of starting it again (World refuses a repeat)
        self.assertEqual(len(world.story_requests), sent)
        row = world.lab._db.execute("SELECT controller_job_id FROM jobs WHERE id = ?", (request.lab_job_id,)).fetchone()
        self.assertEqual(row["controller_job_id"], world.by_key[request.key])
        self.drive(world, executor)
        self.assertEqual(self.result(world)["outcome"], pinpoint.CULPRITS)

    def test_two_bisects_one_host_crash_after_the_second_submit(self) -> None:
        world = self.world()
        seed_lab(world)
        add_group(world, start=2)
        world.crash_on_story = 2  # bisect 2's first story job reached the controller; labd died before saving
        executor = self.executor(world)
        with self.assertRaises(Crash):
            for _ in range(10):
                world.tick(executor)
                world.run_all()
        executor.close()
        self.drive(world, self.executor(world))  # World refuses a second job on a busy host and a repeated key
        self.assertEqual({host for host, _ in world.story_requests}, {"cmux17"})
        for row in self.bisect_rows(world):
            self.assertEqual(self.result(world, row)["outcome"], pinpoint.CULPRITS)

    def test_a_journal_that_does_not_replay_is_refused(self) -> None:
        world = self.world()
        seed_lab(world)
        world.tick(self.executor(world))
        path = next((self.root / "state").glob("bisect-*.json"))
        document = json.loads(path.read_text())
        document["events"][0]["actions"] = []
        path.write_text(json.dumps(document))
        sent = len(world.story_requests)
        executor = self.executor(world)
        report = world.tick(executor)
        self.assertIn("cannot resume", report.problems[0])
        self.assertEqual(executor.pinpoint_work(), ())
        self.assertEqual(len(world.story_requests), sent)
        self.assertEqual(json.loads(path.read_text()), document)  # left as it was for the operator


class HostTests(Fixture):
    def test_never_another_class_or_a_waterfall_host_that_is_not_idle(self) -> None:
        world = self.world()
        seed_lab(world)
        world.hosts = [
            pinpoint_host("cmux17"),
            pinpoint_host("cmux20-bench", OTHER_CLASS),
            waterfall_host("aws-m4pro-5", OTHER_CLASS, lab_class="m4"),
            waterfall_host("cmux15", busy=True),
            waterfall_host("cmux16"),  # holds a T0 shard with a merge waiting: its T0 is due
            pinpoint_host("cmux18", up=False),
        ]
        world.shard_map = scheduler.ShardMap.from_document({"classes": {"m6": {
            "tiers": ["T0"], "shards": [{"index": 0, "stories": {"T0": ["other.story"]}}]}}})
        world.stories = (scheduler.StorySpec("other.story", "T0", 60, "bench"),)
        world.branch_log = ("ff" * 20,)
        self.drive(world, self.executor(world, repeat_seconds=lambda story: 10.0))
        self.assertEqual({host for host, _ in world.story_requests}, {"cmux17"})
        self.assertEqual(self.result(world)["outcome"], pinpoint.CULPRITS)

    def test_borrows_an_idle_waterfall_host_with_no_t0_due(self) -> None:
        world = self.world()
        seed_lab(world)
        world.hosts = [waterfall_host("cmux16")]  # its class has no T0 shard in the map: no T0 is ever due
        self.drive(world, self.executor(world, repeat_seconds=lambda story: 10.0))
        self.assertEqual({host for host, _ in world.story_requests}, {"cmux16"})

    def test_waits_with_no_host_of_its_class(self) -> None:
        world = self.world()
        seed_lab(world)
        world.hosts = [pinpoint_host("cmux20-bench", OTHER_CLASS)]
        executor = self.executor(world)
        for _ in range(5):
            world.tick(executor)
            world.run_all()
        self.assertEqual(world.story_requests, [])
        self.assertEqual(self.bisect_row(world)["state"], "running")
        self.assertEqual({w.host_class for w in executor.pinpoint_work()}, {CLASS})

    def test_two_bisects_share_one_pinpoint_host(self) -> None:
        world = self.world()
        seed_lab(world)
        add_group(world, start=2)
        self.drive(world, self.executor(world))  # World refuses a second job on a busy host
        keys = {r.key.split(":")[1] for _, r in world.story_requests}
        self.assertEqual(keys, {"1", "2"})
        for row in self.bisect_rows(world):
            self.assertEqual(self.result(world, row)["outcome"], pinpoint.CULPRITS)

    def test_published_work_carries_the_story_length_and_the_last_host(self) -> None:
        world = self.world()
        seed_lab(world)
        executor = self.executor(world, repeat_seconds=lambda story: 2.5)
        world.tick(executor)
        world.run_all()
        world.tick(executor)
        runs = [w for w in executor.pinpoint_work() if not w.build_only]
        self.assertTrue(runs)
        for work in runs:
            request = executor.story_request(work.id)
            self.assertEqual((work.kind, work.host_class, work.story), (scheduler.BISECT, CLASS, STORY))
            self.assertEqual(work.seconds, 25)
            self.assertEqual(work.prefer_host, "cmux17")
            self.assertEqual(work.builds, ((request.sha, "bench"),))


if __name__ == "__main__":
    unittest.main()
