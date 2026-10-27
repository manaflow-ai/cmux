#!/usr/bin/env python3
"""mvp_tick.py: the MVP tick's step, its result-v1 conversion, the ingest, the restart and the SCHEDULER_LIVE stop.

  python3 -m unittest scripts/perf-lab/tests/test_mvp_tick.py
"""
from __future__ import annotations

import importlib.util
import json
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

PERF_LAB = Path(__file__).resolve().parent.parent


def load(name: str, path: Path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


mvp = load("perf_lab_mvp_tick", PERF_LAB / "mvp_tick.py")
lab = load("perf_lab_lab", PERF_LAB / "lab.py")
ingest = mvp.ingest

TIP, PARENT, OLD = "a" * 40, "b" * 40, "c" * 40
POSITIONS = {TIP: ingest.CommitPosition(12, mainline=True), PARENT: ingest.CommitPosition(11, mainline=True),
             OLD: ingest.CommitPosition(10, mainline=True)}
POOL_HOST = mvp.PoolHost("cmux20-bench", "apple-m6", 16)


def report(*, refresh_ms=8.33, macos="26.1", raw_frames=True) -> dict:
    """A split-spring report.json: three rounds per direction, as split-spring.sh returns it."""
    runs = []
    for direction in ("right", "down"):
        for index in range(3):
            run = {"direction": direction, "errors": [], "missed": index, "resizes_sent": 6, "frames_p99_ms": 9.0}
            if raw_frames:
                run["frame_intervals_ms"] = [8.3, 8.4, 16.7]
            runs.append(run)
    return {"tag": "split-spring", "runs": runs, "macos": macos,
            "display": {"requested_hz": 120.0, "vdisplay": True, "refresh_ms": refresh_ms, "line": "ready 5 8.33 main=5"}}


class FakeRepo:
    def __init__(self, shas, live=(), fetch_timeouts=0):
        self.shas, self.live, self.fetched, self.fetch_timeouts = list(shas), set(live), [], fetch_timeouts

    def fetch(self, branch):
        self.fetched.append(branch)
        if self.fetch_timeouts:
            self.fetch_timeouts -= 1
            raise subprocess.TimeoutExpired(["git", "fetch"], 300)
        return True

    def first_parent(self, ref, depth):
        return self.shas[:depth]

    def has_file(self, ref, path):
        return ref in self.live and path == mvp.LIVE_FILE


class FakeFleet:
    """`cmux-ci run` that prints the controller's step lines and ends with `code`; `artifact` copies a report."""

    def __init__(self, codes=(0,), reports=None, worker="cmux20-bench", unreachable=0, artifact_timeouts=0):
        self.codes, self.reports, self.worker = list(codes), list(reports or [report()]), worker
        self.argvs, self.steps = [], 0
        self.unreachable, self.artifact_timeouts = unreachable, artifact_timeouts

    def run_step(self, argv, log):
        self.argvs.append(list(argv))
        if self.unreachable:  # the controller is down: the client prints no step line
            self.unreachable -= 1
            log.write_text("cmux-ci: http://100.89.225.106:18765: connection refused\n")
            return 1
        key = argv[argv.index("--key") + 1]
        step = f"{abs(hash(key)) % 16 ** 12:012x}"
        code = self.codes.pop(0) if self.codes else 0
        state = "passed" if code == 0 else "failed"
        log.write_text(f"cmux-ci: step {step} queued\ncmux-ci: step {step} {state} on {self.worker}: done\n")
        return code

    def artifact(self, step_id, dest):
        if self.artifact_timeouts:
            self.artifact_timeouts -= 1
            raise subprocess.TimeoutExpired(["cmux-ci", "artifact"], 600)
        body = self.reports.pop(0) if self.reports else report()
        dest.write_text(json.dumps(body))
        return subprocess.CompletedProcess([], 0, "", "")


class Clock:
    def __init__(self):
        self.at, self.slept = datetime(2026, 10, 26, 12, tzinfo=timezone.utc), []

    def now(self):
        self.at += timedelta(seconds=1)
        return self.at

    def sleep(self, seconds):
        self.slept.append(seconds)


class TickTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.config = mvp.Config(db=self.dir / "lab.sqlite3", state_dir=self.dir / "state")
        self.clock = Clock()
        self.repo = FakeRepo([TIP, PARENT, OLD])
        self.fleet = FakeFleet()

    def tearDown(self):
        self.tmp.cleanup()

    def seams(self, *, published=lambda sha: True, version=lambda sha: 4, local_live=None, ingest_results=None):
        extra = {"ingest_results": ingest_results} if ingest_results else {}
        return mvp.Seams(repo=self.repo, fleet=self.fleet, published=published, measure_version=version,
                         commit_positions=lambda config: POSITIONS.get, pool_host=lambda worker: POOL_HOST,
                         now=self.clock.now, sleep=self.clock.sleep,
                         local_live=local_live or self.dir / "no-such" / "SCHEDULER_LIVE", **extra)

    def stored_rows(self):
        with sqlite3.connect(self.config.db) as db:
            return db.execute("""SELECT b.sha, s.host_class, s.metric, s.build_config FROM results r
                                 JOIN runs u ON u.id = r.run_id JOIN builds b ON b.id = u.build_id
                                 JOIN series s ON s.id = r.series_id ORDER BY s.metric""").fetchall()

    def test_step_is_the_exclusive_background_bench_measurement_on_the_worker(self):
        record = mvp.tick(self.config, self.seams())
        argv = self.fleet.argvs[0]
        self.assertEqual(argv[:5], ["run", "--class", "exclusive", "--measurement", "--background"])
        for flag, value in (("--script", "scripts/measure/split-spring.sh"), ("--ref", TIP),
                            ("--target-worker", "cmux20-bench"), ("--artifact", mvp.ARTIFACT)):
            self.assertEqual(argv[argv.index(flag) + 1], value)
        self.assertEqual([a for a in argv if a.startswith("--arg=")], ["--arg=--config=bench", "--arg=--vdisplay=120"])
        self.assertEqual(record["state"], mvp.STORED, record)

    def test_a_stored_tick_keys_its_rows_by_sha_and_host_class(self):
        record = mvp.tick(self.config, self.seams())
        self.assertEqual(record["host_class"], "apple-m6/16gb/120hz")
        self.assertEqual(record["added_runs"], 1)
        rows = self.stored_rows()
        self.assertEqual({(sha, host, config) for sha, host, _, config in rows},
                         {(TIP, "apple-m6/16gb/120hz", "bench")})
        self.assertEqual(sorted(metric for *_, metric, _ in rows),
                         sorted(f"split_spring.{d}.{m}" for d in ("right", "down")
                                for m in ("frame", "missed", "resizes_sent")))

    def test_three_consecutive_ticks_store_results_and_pass_require(self):
        self.fleet = FakeFleet(codes=(0, 0, 0), reports=[report(), report(), report()])
        for _ in range(3):
            self.assertEqual(mvp.tick(self.config, self.seams())["state"], mvp.STORED)
        state = mvp.load_state(self.config.state_dir)
        self.assertIsNone(mvp.require_check(state, 3, "cmux20-bench"))
        self.assertEqual(len({t["key"] for t in state["ticks"]}), 3)  # each tick is its own step

    def test_a_60hz_fallback_lands_in_a_60hz_series(self):
        self.fleet = FakeFleet(reports=[report(refresh_ms=16.7)])
        record = mvp.tick(self.config, self.seams())
        self.assertEqual(record["host_class"], "apple-m6/16gb/60hz")

    def test_an_old_tip_without_raw_frames_stores_its_per_gesture_series(self):
        self.fleet = FakeFleet(reports=[report(raw_frames=False)])
        record = mvp.tick(self.config, self.seams())
        self.assertEqual(record["state"], mvp.STORED)
        self.assertNotIn("split_spring.right.frame", record["series"])
        self.assertIn("split_spring.right.frame", record["skipped"])
        self.assertIn("split_spring.right.missed", record["series"])

    def test_a_report_without_a_display_rate_is_unrecorded(self):
        self.fleet = FakeFleet(reports=[{**report(), "display": None}])
        record = mvp.tick(self.config, self.seams())
        self.assertEqual(record["state"], mvp.UNRECORDED)
        self.assertIn("display refresh", record["reason"])
        self.assertFalse(self.config.db.exists() and self.stored_rows())

    def test_a_failed_step_is_retried_then_its_commit_is_skipped(self):
        self.fleet = FakeFleet(codes=(1, 1, 0))
        states = [mvp.tick(self.config, self.seams()) for _ in range(3)]
        self.assertEqual([s["state"] for s in states], [mvp.FAILED, mvp.FAILED, mvp.STORED])
        self.assertEqual([s["sha"] for s in states], [TIP, TIP, PARENT])

    def test_fleet_errors_do_not_count_against_the_tip(self):
        self.fleet = FakeFleet(codes=(0,), unreachable=2)
        record = mvp.loop(self.config, self.seams(), ticks=3)
        ticks = mvp.load_state(self.config.state_dir)["ticks"]
        self.assertEqual([t["state"] for t in ticks], [mvp.FLEET_ERROR, mvp.FLEET_ERROR, mvp.STORED])
        self.assertEqual([t["sha"] for t in ticks], [TIP, TIP, TIP])  # no step ran, so the tip is not given up
        self.assertEqual(mvp.failures(mvp.load_state(self.config.state_dir), TIP), 0)
        self.assertEqual(self.clock.slept, [mvp.IDLE_SECONDS, mvp.IDLE_SECONDS])
        self.assertEqual(record["state"], mvp.STORED)

    def test_a_failed_step_counts_but_a_yield_does_not(self):
        self.fleet = FakeFleet(codes=(75, 1, 1, 0))
        states = [mvp.tick(self.config, self.seams()) for _ in range(4)]
        self.assertEqual([s["state"] for s in states], [mvp.YIELDED, mvp.FAILED, mvp.FAILED, mvp.STORED])
        self.assertEqual([s["sha"] for s in states], [TIP, TIP, TIP, PARENT])

    def test_the_idle_reason_names_given_up_commits(self):
        state = {"ticks": [{"sha": sha, "state": mvp.FAILED} for sha in (TIP, TIP)]}
        sha, why = mvp.candidate(self.config, self.seams(published=lambda sha: False), state)
        self.assertIsNone(sha)
        self.assertIn("1 failed 2 times", why)
        self.assertIn("other 2 have no published cmux-tui tree", why)

    def test_a_git_timeout_is_an_idle_tick_and_the_loop_goes_on(self):
        self.repo = FakeRepo([TIP, PARENT, OLD], fetch_timeouts=1)
        record = mvp.loop(self.config, self.seams(), ticks=2)
        ticks = mvp.load_state(self.config.state_dir)["ticks"]
        self.assertEqual([t["state"] for t in ticks], [mvp.IDLE, mvp.STORED])
        self.assertIn("TimeoutExpired", ticks[0]["reason"])
        self.assertEqual(self.clock.slept, [mvp.IDLE_SECONDS])
        self.assertEqual(record["state"], mvp.STORED)

    def test_a_git_timeout_keeps_the_pending_step(self):
        self.config.state_dir.mkdir(parents=True)
        state = mvp.load_state(self.config.state_dir)
        state.update(seq=3, pending={"sha": PARENT, "key": "perf-lab-mvp-3-bbbbbbbbbbbb", "seq": 3,
                                     "submitted_at": "2026-10-26T11:00:00.000000Z"})
        mvp.save_state(self.config.state_dir, state)
        self.repo = FakeRepo([TIP], fetch_timeouts=1)
        self.assertEqual(mvp.tick(self.config, self.seams())["state"], mvp.IDLE)
        self.assertEqual(mvp.load_state(self.config.state_dir)["pending"]["key"], "perf-lab-mvp-3-bbbbbbbbbbbb")
        self.assertEqual(mvp.tick(self.config, self.seams())["state"], mvp.STORED)
        self.assertEqual(self.fleet.argvs[0][self.fleet.argvs[0].index("--key") + 1], "perf-lab-mvp-3-bbbbbbbbbbbb")

    def test_a_measure_version_timeout_keeps_the_step_pending(self):
        def version(sha):
            raise subprocess.TimeoutExpired(["git", "cat-file"], 60)
        record = mvp.tick(self.config, self.seams(version=version))
        self.assertEqual(record["state"], mvp.FLEET_ERROR)
        self.assertEqual(self.fleet.argvs, [])
        self.assertEqual(mvp.load_state(self.config.state_dir)["pending"]["key"], record["key"])

    def test_a_locked_lab_db_is_unrecorded_and_the_loop_goes_on(self):
        calls = []

        def ingest_results(config, seams, results_dir):
            calls.append(results_dir)
            if len(calls) == 1:
                raise sqlite3.OperationalError("database is locked")
            return mvp._ingest(config, seams, results_dir)

        self.fleet = FakeFleet(codes=(0, 0), reports=[report(), report()])
        record = mvp.loop(self.config, self.seams(ingest_results=ingest_results), ticks=2)
        ticks = mvp.load_state(self.config.state_dir)["ticks"]
        self.assertEqual([t["state"] for t in ticks], [mvp.UNRECORDED, mvp.STORED])
        self.assertIn("database is locked", ticks[0]["reason"])
        self.assertEqual(record["state"], mvp.STORED)

    def test_an_artifact_timeout_is_unrecorded_and_the_loop_goes_on(self):
        self.fleet = FakeFleet(codes=(0, 0), reports=[report()], artifact_timeouts=1)
        mvp.loop(self.config, self.seams(), ticks=2)
        ticks = mvp.load_state(self.config.state_dir)["ticks"]
        self.assertEqual([t["state"] for t in ticks], [mvp.UNRECORDED, mvp.STORED])
        self.assertIn("TimeoutExpired", ticks[0]["reason"])

    def test_a_yield_exit_is_yielded_and_the_loop_waits(self):
        self.fleet = FakeFleet(codes=(75, 0))
        record = mvp.loop(self.config, self.seams(), ticks=2)
        state = mvp.load_state(self.config.state_dir)
        self.assertEqual([t["state"] for t in state["ticks"]], [mvp.YIELDED, mvp.STORED])
        self.assertEqual(self.clock.slept, [mvp.IDLE_SECONDS])
        self.assertEqual(record["state"], mvp.STORED)

    def test_the_loop_starts_the_next_step_when_the_previous_ends(self):
        self.fleet = FakeFleet(codes=(0, 0), reports=[report(), report()])
        mvp.loop(self.config, self.seams(), ticks=2)
        self.assertEqual(self.clock.slept, [])
        self.assertEqual(len(self.fleet.argvs), 2)

    def test_no_published_commit_is_an_idle_tick(self):
        record = mvp.tick(self.config, self.seams(published=lambda sha: False))
        self.assertEqual(record["state"], mvp.IDLE)
        self.assertEqual(self.fleet.argvs, [])

    def test_the_newest_published_commit_is_measured(self):
        mvp.tick(self.config, self.seams(published=lambda sha: sha != TIP))
        argv = self.fleet.argvs[0]
        self.assertEqual(argv[argv.index("--ref") + 1], PARENT)

    def test_an_unreadable_measure_version_fails_without_a_step(self):
        record = mvp.tick(self.config, self.seams(version=lambda sha: None))
        self.assertEqual(record["state"], mvp.FAILED)
        self.assertEqual(self.fleet.argvs, [])

    def test_a_restart_resubmits_the_pending_step_under_its_key(self):
        state = mvp.load_state(self.config.state_dir)
        self.config.state_dir.mkdir(parents=True)
        state.update(seq=7, pending={"sha": PARENT, "key": "perf-lab-mvp-7-bbbbbbbbbbbb", "seq": 7,
                                     "submitted_at": "2026-10-26T11:00:00.000000Z"})
        mvp.save_state(self.config.state_dir, state)
        record = mvp.tick(self.config, self.seams())
        argv = self.fleet.argvs[0]
        self.assertEqual(argv[argv.index("--key") + 1], "perf-lab-mvp-7-bbbbbbbbbbbb")
        self.assertEqual(argv[argv.index("--ref") + 1], PARENT)
        self.assertEqual(record["state"], mvp.STORED)
        self.assertIsNone(mvp.load_state(self.config.state_dir)["pending"])

    def test_scheduler_live_on_a_live_ref_stops_without_a_step(self):
        self.repo = FakeRepo([TIP], live={"origin/perf/chrome-parity"})
        record = mvp.loop(self.config, self.seams())
        self.assertEqual(record["state"], mvp.STOPPED)
        self.assertEqual(self.fleet.argvs, [])

    def test_scheduler_live_in_the_checkout_stops(self):
        live = self.dir / "SCHEDULER_LIVE"
        live.write_text("")
        record = mvp.tick(self.config, self.seams(local_live=live))
        self.assertEqual(record["state"], mvp.STOPPED)

    def test_the_md_file_is_not_the_sentinel(self):
        self.assertFalse((PERF_LAB / "SCHEDULER_LIVE").exists())
        self.assertTrue((PERF_LAB / "SCHEDULER_LIVE.md").exists())

    def test_require_fails_on_another_worker_or_a_failed_tick(self):
        state = {"ticks": [{"seq": 1, "state": mvp.STORED, "ran_on": "cmux20-bench"},
                           {"seq": 2, "state": mvp.IDLE},
                           {"seq": 3, "state": mvp.FAILED, "ran_on": "cmux20-bench", "reason": "build"},
                           {"seq": 4, "state": mvp.STORED, "ran_on": "cmux17"}]}
        why = mvp.require_check(state, 3, "cmux20-bench")
        self.assertIn("tick 3 failed", why)
        self.assertIn("tick 4 stored on cmux17", why)
        self.assertIsNotNone(mvp.require_check(state, 5, "cmux20-bench"))


class ConvertTest(unittest.TestCase):
    RUN = mvp.perf_result.Run(id="mvp-0123456789ab", started_at="2026-10-26T12:00:00.000000Z")

    def test_results_are_valid_result_v1_of_the_bench_config(self):
        results, _ = mvp.to_results(report(), sha=TIP, measure_version=4, pool_host=POOL_HOST, run=self.RUN)
        for result in results:
            result.validate()
            self.assertEqual((result.build.config, result.build.measure_version, result.engine, result.session),
                             ("bench", 4, "none", "light"))
        frame = next(r for r in results if r.metric == "split_spring.right.frame")
        self.assertEqual(len(frame.samples), 9)  # every frame interval of the three rounds

    def test_the_pool_host_class_round_trips_through_ingest(self):
        host = mvp.host_block(report(), POOL_HOST)
        self.assertEqual(ingest._store_host(host, "cmux20-bench").host_class, "apple-m6/16gb/120hz")

    def test_display_jitter_keeps_the_nominal_host_class(self):
        for refresh_ms, hz in ((8.33, 120), (8.37, 120), (8.40, 120), (8.6, 120), (16.67, 60), (16.9, 60)):
            with self.subTest(refresh_ms=refresh_ms):
                host = mvp.host_block(report(refresh_ms=refresh_ms), POOL_HOST)
                self.assertEqual((host.display_hz, host.host_class), (hz, f"apple-m6/16gb/{hz}hz"))
        self.assertEqual(mvp.host_block(report(refresh_ms=8.40), POOL_HOST).fingerprint,
                         mvp.host_block(report(refresh_ms=8.33), POOL_HOST).fingerprint)

    def test_a_stored_tick_at_8_40_ms_lands_in_the_120hz_class(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = mvp.Config(db=Path(tmp) / "lab.sqlite3", state_dir=Path(tmp) / "state")
            clock = Clock()
            seams = mvp.Seams(repo=FakeRepo([TIP]), fleet=FakeFleet(reports=[report(refresh_ms=8.40)]),
                              published=lambda sha: True, measure_version=lambda sha: 4,
                              commit_positions=lambda config: POSITIONS.get, pool_host=lambda worker: POOL_HOST,
                              now=clock.now, sleep=clock.sleep, local_live=Path(tmp) / "no-such")
            self.assertEqual(mvp.tick(config, seams)["host_class"], "apple-m6/16gb/120hz")

    def test_a_display_slower_than_60hz_is_refused(self):
        with self.assertRaises(mvp.TickError):
            mvp.host_block(report(refresh_ms=20.0), POOL_HOST)

    def test_no_macos_is_refused(self):
        with self.assertRaises(mvp.TickError):
            mvp.host_block(report(macos=None), POOL_HOST)

    def test_pool_json_names_cmux20_bench(self):
        self.assertEqual(mvp.PoolHost.load("cmux20-bench"), POOL_HOST)
        with self.assertRaises(mvp.TickError):
            mvp.PoolHost.load("not-a-lab-host")


class CommandTest(unittest.TestCase):
    def test_lab_py_lists_the_mvp_commands(self):
        commands = lab.discover(PERF_LAB)
        for name in ("mvp-tick", "mvp-loop", "mvp-status"):
            self.assertEqual(commands[name][0].name, "mvp_tick.py")

    def test_status_require_exit_codes(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = mvp.load_state(Path(tmp))
            state["ticks"] = [{"seq": n, "state": mvp.STORED, "ran_on": "cmux20-bench"} for n in (1, 2, 3)]
            mvp.save_state(Path(tmp), state)
            self.assertEqual(lab.main(["mvp-status", "--state-dir", tmp, "--require", "3"]), 0)
            self.assertEqual(lab.main(["mvp-status", "--state-dir", tmp, "--require", "4"]), 1)


if __name__ == "__main__":
    unittest.main()
