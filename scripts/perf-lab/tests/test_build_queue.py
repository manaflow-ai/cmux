#!/usr/bin/env python3
"""build_queue.py and capacity.py: build order, ledger reuse, builder affinity, per-commit builds, the step runner,
coverage and the capacity report.

  python3 -m unittest scripts/perf-lab/tests/test_build_queue.py
"""
from __future__ import annotations

import importlib.util
import io
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from argparse import Namespace
from datetime import datetime, timedelta, timezone
from pathlib import Path

LAB = Path(__file__).resolve().parent.parent


def _load(name: str):
    module_name = f"perf_lab_{name}"
    if module_name in sys.modules:
        return sys.modules[module_name]
    spec = importlib.util.spec_from_file_location(module_name, LAB / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


bq = _load("build_queue")
capacity = _load("capacity")
builds = _load("builds")
scheduler = _load("scheduler")

NOW = datetime(2026, 10, 27, 12, 0, tzinfo=timezone.utc)
DIGEST = "d" * 64
BUILDERS = ("aws-m4pro-7", "aws-m4pro-8")


def sha(n: int) -> str:
    return f"{n:040x}"


def receipt(commit: str, *, config: str = "bench", status: str = "ok", seconds: int = 300,
            cached: bool = False, digest: str = DIGEST) -> dict:
    if status == "failed":
        return {"sha": commit, "config": config, "status": "failed", "seconds": seconds, "digest": None,
                "reason": "x.swift:1: error: boom", "defines": [], "app": None, "cached": cached}
    return {"sha": commit, "config": config, "status": "ok", "seconds": seconds, "digest": digest,
            "reason": None, "defines": ["CMUX_BENCH_HOOKS"], "app": "cmux DEV perf-lab.app", "cached": cached}


class QueueCase(unittest.TestCase):
    """A 40-commit first-parent chain: sha(n) is at position n."""

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="build-queue-"))
        self.addCleanup(shutil.rmtree, self.dir)
        self.ledger = self.dir / "ledger"
        self.keys: dict[tuple[str, str], str] = {}
        self.queue = self.make()

    def make(self, state=None):
        return bq.BuildQueue(state or bq.QueueState(), self.ledger, position=lambda s: int(s, 16) or None,
                             product_key=lambda s, c: self.keys.get((s, c)))

    def newest_first(self, top: int, count: int) -> list[str]:
        return [sha(n) for n in range(top, top - count, -1)]

    def build(self, job, *, at=NOW, **kwargs):
        return self.queue.finish(job.id, 0, receipt(job.sha, config=job.config, **kwargs), at)


class OrderTest(QueueCase):
    def test_twelve_commit_batch_queues_twelve_builds_tip_first(self):
        batch = self.newest_first(12, 12)  # sha(12) is the batch tip
        self.queue.enqueue_plan({"builds": [{"sha": sha(12), "config": "bench", "reason": "batch-tip"}]}, NOW)
        self.queue.backfill(batch, NOW)
        order = self.queue.order()
        self.assertEqual(len(order), 12)
        self.assertEqual((order[0].sha, order[0].kind), (sha(12), "tip"))
        self.assertEqual([j.sha for j in order[1:]], batch[1:], "per-commit builds newest first")
        started = self.queue.assign(BUILDERS[:1], NOW)
        self.assertEqual([j.sha for j in started], [sha(12)])

    def test_existing_midpoint_build_gets_no_job(self):
        ledger = builds.BuildLedger(self.ledger)
        ledger.record(builds.BuildRecord(sha=sha(20), config="bench", status="ok", seconds=1, digest=DIGEST,
                                         app="cmux DEV perf-lab.app"))
        ledger.record(builds.BuildRecord(sha=sha(21), config="bench", status="failed", seconds=1, reason="error"))
        for commit in (sha(20), sha(21)):
            self.assertIsNone(self.queue.enqueue(commit, "bench", "bisect:42:try-3", NOW))
        self.assertEqual(self.queue.state.jobs, [])
        self.assertIsNotNone(self.queue.enqueue(sha(22), "bench", "bisect:42:try-3", NOW))

    def test_classes_and_tips_in_commit_order(self):
        self.queue.backfill([sha(30)], NOW)
        self.queue.enqueue(sha(9), "bench", "bisect:1", NOW)
        self.queue.enqueue(sha(8), "bench", "lane:canary-3", NOW)
        self.queue.enqueue(sha(7), "bench", "tier", NOW)
        self.queue.enqueue(sha(6), "bench", "batch-tip", NOW)
        self.queue.enqueue(sha(5), "bench", "batch-tip", NOW)
        self.assertEqual([(j.sha, j.kind) for j in self.queue.order()],
                         [(sha(5), "tip"), (sha(6), "tip"), (sha(7), "tier"), (sha(8), "lane"),
                          (sha(9), "midpoint"), (sha(30), "backfill")])

    def test_request_promotes_a_waiting_per_commit_build(self):
        self.queue.backfill(self.newest_first(10, 3), NOW)
        self.assertIsNone(self.queue.enqueue(sha(9), "bench", "bisect:7", NOW))
        self.assertEqual(self.queue.order()[0].sha, sha(9))
        self.assertEqual(len(self.queue.open_jobs()), 3)

    def test_debug_is_never_queued(self):
        with self.assertRaises(builds.BuildError):
            self.queue.enqueue(sha(1), "debug", "tier", NOW)


class AssignTest(QueueCase):
    def test_second_consecutive_build_is_incremental(self):
        self.queue.enqueue(sha(10), "bench", "batch-tip", NOW)
        first, = self.queue.assign(BUILDERS[:1], NOW)
        self.assertIsNone(first.incremental_from)
        self.build(first, seconds=1500)
        self.assertFalse(first.incremental)
        self.queue.enqueue(sha(11), "bench", "batch-tip", NOW)
        second, = self.queue.assign(BUILDERS[:1], NOW + timedelta(minutes=30))
        self.assertEqual(second.incremental_from, sha(10))
        self.build(second, at=NOW + timedelta(minutes=35), seconds=240)
        self.assertTrue(second.incremental)
        self.assertEqual((second.state, second.seconds, second.wall_seconds), (bq.DONE, 240, 300))
        self.assertEqual(self.queue.state.last_built[BUILDERS[0]], {"bench": sha(11)})

    def test_cached_receipt_is_not_incremental_and_keeps_the_tree(self):
        self.queue.enqueue(sha(10), "bench", "batch-tip", NOW)
        job, = self.queue.assign(BUILDERS[:1], NOW)
        self.build(job)
        self.queue.enqueue(sha(4), "bench", "bisect:1", NOW)
        again, = self.queue.assign(BUILDERS[:1], NOW)
        self.build(again, cached=True)
        self.assertFalse(again.incremental)
        self.assertEqual(self.queue.state.last_built[BUILDERS[0]], {"bench": sha(10)})

    def test_midpoint_goes_to_the_builder_with_the_nearest_tree(self):
        self.queue.state.last_built = {BUILDERS[0]: {"bench": sha(10)}, BUILDERS[1]: {"bench": sha(30)}}
        self.queue.enqueue(sha(28), "bench", "bisect:1", NOW)
        self.queue.enqueue(sha(12), "bench", "bisect:2", NOW)
        started = {j.sha: j.builder for j in self.queue.assign(BUILDERS, NOW)}
        self.assertEqual(started, {sha(28): BUILDERS[1], sha(12): BUILDERS[0]})

    def test_per_commit_builds_only_on_idle_builders(self):
        self.queue.backfill(self.newest_first(20, 5), NOW)
        self.queue.enqueue(sha(21), "bench", "batch-tip", NOW)
        self.queue.enqueue(sha(22), "bench", "batch-tip", NOW)
        self.queue.enqueue(sha(23), "bench", "batch-tip", NOW)
        started = self.queue.assign(BUILDERS, NOW)
        self.assertEqual({j.kind for j in started}, {"tip"}, "no per-commit build while a tip waits")
        for job in started:
            self.build(job)
        started = self.queue.assign(BUILDERS, NOW)
        self.assertEqual([j.kind for j in started], ["tip"], "the waiting tip first; the other builder stays free")
        self.build(started[0])
        started = self.queue.assign(BUILDERS, NOW)
        self.assertEqual([(j.kind, j.sha) for j in started], [("backfill", sha(20))],
                         "one per-commit build, newest first; one builder is kept for the next tip")
        self.assertEqual(self.queue.assign(BUILDERS, NOW), [])
        single = self.make()
        single.backfill([sha(5)], NOW)
        self.assertEqual(len(single.assign(BUILDERS[:1], NOW)), 1, "a single builder keeps no reserve")

    def test_busy_builder_and_running_builder_get_nothing(self):
        self.queue.enqueue(sha(1), "bench", "batch-tip", NOW)
        self.queue.enqueue(sha(2), "bench", "batch-tip", NOW)
        self.assertEqual([j.builder for j in self.queue.assign(BUILDERS, NOW, busy=[BUILDERS[0]])], [BUILDERS[1]])
        self.assertEqual(self.queue.assign(BUILDERS, NOW, busy=[BUILDERS[0]]), [])

    def test_a_pair_recorded_elsewhere_is_dropped(self):
        self.queue.enqueue(sha(3), "bench", "bisect:1", NOW)
        builds.BuildLedger(self.ledger).record(builds.BuildRecord(sha=sha(3), config="bench", status="ok",
                                                                  seconds=1, digest=DIGEST, app="a.app"))
        self.assertEqual(self.queue.assign(BUILDERS, NOW), [])
        self.assertEqual(self.queue.state.jobs[0].state, bq.DROPPED)


class FinishTest(QueueCase):
    def start(self, commit: str, reason: str = "batch-tip"):
        self.queue.enqueue(commit, "bench", reason, NOW)
        job, = self.queue.assign(BUILDERS[:1], NOW)
        return job

    def test_ok_and_failed_receipts_go_to_the_ledger(self):
        job = self.start(sha(5))
        self.build(job)
        ledger = builds.BuildLedger(self.ledger)
        self.assertTrue(ledger.has_build(sha(5), "bench"))
        bad = self.start(sha(6))
        self.queue.finish(bad.id, 1, receipt(sha(6), status="failed"), NOW)
        self.assertEqual((bad.state, ledger.get(sha(6), "bench").status), (bq.FAILED, "failed"))
        self.assertIn([sha(6), "bench"], self.queue.scheduler_document()["failed"])

    def test_infra_exit_builds_again_then_gives_up(self):
        job = self.start(sha(5))
        for attempt in range(1, bq.INFRA_ATTEMPTS):
            ended = self.queue.finish(job.id, 75, None, NOW)
            self.assertEqual((ended.state, job.state), (bq.INFRA, bq.QUEUED))
            self.assertEqual(self.queue.assign(BUILDERS[:1], NOW), [job])
            self.assertEqual(job.attempts, attempt + 1)
        self.queue.finish(job.id, 75, None, NOW)
        self.assertEqual(job.state, bq.GAVE_UP)
        self.assertIsNone(builds.BuildLedger(self.ledger).get(sha(5), "bench"))
        document = self.queue.scheduler_document()
        self.assertIn([sha(5), "bench"], document["failed"])
        self.assertNotIn([sha(5), "bench"], document["queued"])
        self.queue.backfill([sha(5)], NOW)
        self.assertEqual(self.queue.open_jobs(), [], "a given-up commit is not built again per commit")

    def test_refused_step_gives_up_at_once(self):
        job = self.start(sha(5))
        self.queue.finish(job.id, 2, None, NOW)
        self.assertEqual(job.state, bq.GAVE_UP)

    def test_receipt_of_another_build_is_not_recorded(self):
        job = self.start(sha(5))
        self.queue.finish(job.id, 0, receipt(sha(6)), NOW)
        self.assertEqual(job.state, bq.QUEUED)
        self.assertIsNone(builds.BuildLedger(self.ledger).get(sha(6), "bench"))

    def test_same_product_key_takes_the_build_over(self):
        self.keys = {(sha(5), "bench"): "k1", (sha(6), "bench"): "k1", (sha(6), "bench-checks"): "k1c"}
        self.build(self.start(sha(5)), digest="e" * 64)
        self.assertIsNone(self.queue.enqueue(sha(6), "bench", "bisect:1", NOW))
        record = builds.BuildLedger(self.ledger).get(sha(6), "bench")
        self.assertEqual((record.digest, record.seconds, record.job), ("e" * 64, 0, f"reuse:{sha(5)}"))
        self.assertEqual(self.queue.state.jobs[-1].state, bq.REUSED)
        self.assertIsNotNone(self.queue.enqueue(sha(6), "bench-checks", "tier", NOW), "another config builds")

    def test_queued_job_with_the_key_of_a_new_build_takes_it_over(self):
        self.keys = {(sha(5), "bench"): "k1", (sha(4), "bench"): "k1", (sha(3), "bench"): "k3"}
        running = self.start(sha(5))
        self.queue.backfill([sha(4), sha(3)], NOW)
        self.build(running)
        self.assertEqual(builds.BuildLedger(self.ledger).get(sha(4), "bench").job, f"reuse:{sha(5)}")
        self.assertEqual([j.sha for j in self.queue.open_jobs()], [sha(3)])

    def test_scheduler_document_leaves_per_commit_builds_out(self):
        self.queue.backfill(self.newest_first(20, 4), NOW)
        self.queue.enqueue(sha(30), "bench", "batch-tip", NOW)
        self.assertEqual([j.kind for j in self.queue.assign(BUILDERS, NOW)], ["tip"])
        self.queue.state.jobs.append(bq.Job(id="b999990", sha=sha(31), config="bench", kind="tip",
                                            reason="batch-tip", enqueued_at=bq.stamp(NOW), state=bq.DONE,
                                            started_at=bq.stamp(NOW), ended_at=bq.stamp(NOW + timedelta(seconds=400))))
        document = self.queue.scheduler_document()
        self.assertEqual(document["queued"], [[sha(30), "bench"]])
        self.assertEqual(document["expected_seconds"], 400)
        parsed = scheduler.builds_from_document(document)
        self.assertEqual(parsed.queued, frozenset({(sha(30), "bench")}))

    def test_state_round_trips(self):
        self.queue.enqueue(sha(5), "bench", "batch-tip", NOW)
        self.build(self.queue.assign(BUILDERS[:1], NOW)[0])
        path = self.dir / "state.json"
        bq.save_state(path, self.queue.state)
        again = bq.load_state(path)
        self.assertEqual(again.to_document(), self.queue.state.to_document())
        self.assertTrue(bq.Job.from_json(json.loads(json.dumps(again.jobs[0].__dict__))).pair, (sha(5), "bench"))


FAKE_CLIENT = """#!/bin/sh
# Stands in for cmux-ci run: prints a step id and the builder step's receipt line, exits with FAKE_RC.
for arg in "$@"; do
  case "$arg" in --arg=--build-sha=*) built="${arg#--arg=--build-sha=}" ;; esac
done
echo "cmux-ci: step 0123456789abcdef queued"
echo "perf-lab-build: {\\"sha\\": \\"$built\\", \\"config\\": \\"bench\\", \\"status\\": \\"ok\\", \\"seconds\\": 61, \
\\"digest\\": \\"%s\\", \\"app\\": \\"cmux DEV perf-lab.app\\", \\"defines\\": [\\"CMUX_BENCH_HOOKS\\"], \\"cached\\": false}"
exit "${FAKE_RC:-0}"
""" % DIGEST


class RunnerTest(QueueCase):
    def client(self) -> Path:
        path = self.dir / "cmux-ci"
        path.write_text(FAKE_CLIENT)
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        return path

    def wait(self, runner, job):
        deadline = time.monotonic() + 10
        while (result := runner.result(job)) is None:
            self.assertLess(time.monotonic(), deadline, "the step never wrote its exit code")
            time.sleep(0.05)
        return result

    def test_tick_starts_and_reaps_a_detached_step(self):
        runner = bq.StepRunner(self.dir / "steps", self.client())
        self.queue.enqueue(sha(7), "bench", "batch-tip", NOW)
        report = bq.tick(self.queue, runner, BUILDERS[:1], sha(40), [], NOW)
        job, = self.queue.open_jobs(bq.RUNNING)
        argv = report["started"][0]["argv"]
        self.assertIn(f"--arg=--build-sha={sha(7)}", argv)
        self.assertEqual(argv[argv.index("--ref") + 1], sha(40), "the tip harness builds the old commit")
        self.assertEqual(argv[argv.index("--target-worker") + 1], BUILDERS[0])
        self.assertNotIn("--background", argv)
        code, got, step = self.wait(runner, job)
        self.assertEqual((code, got["sha"], step), (0, sha(7), "0123456789abcdef"))
        report = bq.tick(self.queue, runner, BUILDERS[:1], sha(40), [], NOW + timedelta(minutes=2))
        self.assertEqual(report["reaped"][0]["state"], bq.DONE)
        self.assertTrue(builds.BuildLedger(self.ledger).has_build(sha(7), "bench"))

    def test_lost_client_is_an_infra_attempt(self):
        runner = bq.StepRunner(self.dir / "steps", self.client(), alive=lambda pid: False)
        self.queue.enqueue(sha(7), "bench", "batch-tip", NOW)
        job, = self.queue.assign(BUILDERS[:1], NOW)
        job.pid = 1
        self.assertEqual(runner.result(job), (75, None, None))

    def test_per_commit_step_runs_in_the_background(self):
        self.queue.backfill([sha(3)], NOW)
        job, = self.queue.assign(BUILDERS[:1], NOW)
        self.assertIn("--background", bq.step_argv(job, sha(40)))


def git(repo: Path, *args: str, env=None) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True,
                          env={**os.environ, **(env or {})}).stdout.strip()


class CommandTest(QueueCase):
    def fixture_repo(self, count: int) -> tuple[Path, list[str]]:
        repo = self.dir / "repo"
        repo.mkdir()
        git(repo, "init", "-q", "-b", "main")
        shas = []
        for n in range(count):
            moment = f"@{int((NOW - timedelta(hours=count - n)).timestamp())} +0000"
            (repo / "f.txt").write_text(str(n))
            git(repo, "add", "f.txt")
            git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", str(n),
                env={"GIT_COMMITTER_DATE": moment, "GIT_AUTHOR_DATE": moment})
            shas.append(git(repo, "rev-parse", "HEAD"))
        git(repo, "update-ref", "refs/perf-lab/feat-cmux-next", shas[-1])
        return repo, shas

    def args(self, repo: Path, **kwargs) -> Namespace:
        base = dict(enqueue=None, tick=False, document=False, coverage=False, status=False, data_dir=self.dir,
                    state=self.dir / "q.json", ledger=self.ledger, repo=repo, mainline=bq.DEFAULT_MAINLINE,
                    pool=LAB / "pool.json", client=self.dir / "no-client", busy=[], since="24h", dry_run=False,
                    json=True, now=bq.stamp(NOW))
        return Namespace(**{**base, **kwargs})

    def run_command(self, module, command, args) -> dict:
        out, err = io.StringIO(), io.StringIO()
        self.assertEqual(module.run(command, args, out=out, err=err), 0, err.getvalue())
        return json.loads(out.getvalue()) if args.json else out.getvalue()

    def test_coverage_since_24h(self):
        repo, shas = self.fixture_repo(30)  # one commit an hour; the newest 24 are in the window
        plan = self.dir / "plan.json"
        plan.write_text(json.dumps({"builds": [{"sha": shas[-1], "config": "bench", "reason": "batch-tip"}]}))
        self.run_command(bq, "builds", self.args(repo, enqueue=plan))
        dry = self.run_command(bq, "builds", self.args(repo, tick=True, dry_run=True))
        self.assertEqual(dry["started"][0]["sha"], shas[-1])
        state = bq.load_state(self.dir / "q.json")
        self.assertEqual([j.kind for j in state.jobs], ["tip"], "a dry run keeps the state")
        queue = bq.BuildQueue(state, self.ledger)
        job, = queue.assign(BUILDERS[:1], NOW)
        queue.finish(job.id, 0, receipt(shas[-1]), NOW + timedelta(minutes=20))
        builds.BuildLedger(self.ledger).record(builds.BuildRecord(sha=shas[-2], config="bench", status="failed",
                                                                  seconds=1, reason="error"))
        bq.save_state(self.dir / "q.json", queue.state)
        report = self.run_command(bq, "builds", self.args(repo, coverage=True))
        self.assertEqual(report["commits"], 24)
        self.assertEqual(report["counts"], {"built": 1, "failed": 1, "missing": 22})
        self.assertEqual(report["tip_build_wait_s"]["max"], 1200)
        text = self.run_command(bq, "builds", self.args(repo, coverage=True, json=False))
        self.assertIn("24 first-parent commits since 24h", text)

    def test_product_key_follows_the_product_closure(self):
        repo, shas = self.fixture_repo(1)
        (repo / "docs").mkdir()
        (repo / "docs" / "a.md").write_text("prose")
        git(repo, "add", "docs")
        git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "docs")
        docs = git(repo, "rev-parse", "HEAD")
        (repo / "f.txt").write_text("code")
        git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-am", "code")
        code = git(repo, "rev-parse", "HEAD")
        keys = bq.Git(repo, "HEAD")
        self.assertEqual(keys.product_key(shas[0], "bench"), keys.product_key(docs, "bench"))
        self.assertNotEqual(keys.product_key(docs, "bench"), keys.product_key(code, "bench"))
        self.assertNotEqual(keys.product_key(docs, "bench"), keys.product_key(docs, "bench-checks"))
        self.assertEqual(keys.position(code), 3)

    def test_lab_py_lists_both_commands(self):
        lab = _load("lab")
        commands = lab.discover(LAB)
        self.assertEqual(commands["builds"][0].name, "build_queue.py")
        self.assertEqual(commands["capacity"][0].name, "capacity.py")


class CapacityTest(QueueCase):
    """A fixture day: builder 7 busy 6 h of 24 (one clean build, then incremental ones), builder 8 idle."""

    def fixture(self) -> bq.QueueState:
        state = bq.QueueState()

        def job(n, kind, state_, start_h, end_h, *, enqueued_h=None, builder=BUILDERS[0], seconds=None, inc=None):
            moment = lambda h: None if h is None else bq.stamp(NOW + timedelta(hours=h))
            state.jobs.append(bq.Job(id=f"b{n:06d}", sha=sha(n), config="bench", kind=kind, reason=kind,
                                     enqueued_at=moment(enqueued_h if enqueued_h is not None else start_h),
                                     state=state_, builder=builder if start_h is not None else None,
                                     started_at=moment(start_h), ended_at=moment(end_h), seconds=seconds,
                                     incremental_from=inc))
        job(1, "tip", bq.DONE, -30, -25, seconds=1800)  # before the window: not counted
        job(2, "tip", bq.DONE, -25, -22, enqueued_h=-26, seconds=1700)  # 2 h inside the window
        job(3, "tip", bq.DONE, -10, -9, enqueued_h=-10.5, seconds=300, inc=sha(2))
        job(4, "backfill", bq.DONE, -5, -4, enqueued_h=-8, seconds=200, inc=sha(3))
        job(5, "tip", bq.RUNNING, -1, None, enqueued_h=-1)  # 1 h so far
        job(6, "midpoint", bq.QUEUED, None, None, enqueued_h=-0.5)
        job(7, "backfill", bq.QUEUED, None, None, enqueued_h=-3)
        return state

    def test_utilization_and_queue_age(self):
        doc = capacity.report(self.fixture(), BUILDERS, NOW, timedelta(hours=24))
        seven, eight = doc["builders"][BUILDERS[0]], doc["builders"][BUILDERS[1]]
        self.assertEqual(seven["busy_s"], 5 * 3600)
        self.assertEqual(seven["utilization"], round(5 / 24, 4))
        self.assertEqual(seven["jobs"], {"done": 3, "running": 1})
        self.assertEqual(seven["incremental_build_s"], {"n": 2, "p50": 200, "p95": 300, "max": 300})
        self.assertEqual(seven["clean_build_s"]["n"], 1)
        self.assertEqual((eight["busy_s"], eight["utilization"]), (0, 0.0))
        self.assertEqual(doc["utilization"], round(5 / 48, 4))
        queue = doc["queue"]
        self.assertEqual(queue["oldest_queued_age_s"], {"midpoint": 1800, "backfill": 3 * 3600})
        self.assertEqual(queue["depth"], {"tip": {"running": 1}, "midpoint": {"queued": 1},
                                          "backfill": {"queued": 1}})
        self.assertEqual(queue["wait_s"]["tip"], {"n": 2, "p50": 0.0, "p95": 1800.0, "max": 1800.0})
        self.assertEqual(queue["wait_s"]["backfill"]["max"], 3 * 3600)
        self.assertEqual((queue["requested"], doc["t0_mode"]), (2, "every-batch"))

    def test_more_than_two_requested_builds_is_every_second_batch(self):
        state = self.fixture()
        for n in (8, 9):
            state.jobs.append(bq.Job(id=f"b{n:06d}", sha=sha(n), config="bench", kind="tip", reason="batch-tip",
                                     enqueued_at=bq.stamp(NOW)))
        self.assertEqual(capacity.report(state, BUILDERS, NOW, timedelta(hours=24))["t0_mode"], "every-2nd-batch")

    def test_command_reads_the_state_and_the_pool(self):
        path = self.dir / "q.json"
        bq.save_state(path, self.fixture())
        out, err = io.StringIO(), io.StringIO()
        args = Namespace(data_dir=self.dir, state=path, pool=LAB / "pool.json", since="24h", json=False,
                         now=bq.stamp(NOW))
        self.assertEqual(capacity.run("capacity", args, out=out, err=err), 0, err.getvalue())
        text = out.getvalue()
        self.assertIn("aws-m4pro-7: 21% busy (18000 s)", text)
        self.assertIn("oldest queued backfill: 10800 s", text)
        bad = Namespace(**{**vars(args), "since": "yesterday"})
        self.assertEqual(capacity.run("capacity", bad, out=io.StringIO(), err=err), 2)


if __name__ == "__main__":
    unittest.main()
