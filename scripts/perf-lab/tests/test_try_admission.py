#!/usr/bin/env python3
"""try_admission.py: dedupe, the per-session quota, build reuse, queue position and general-fleet placement.

  python3 -m unittest scripts/perf-lab/tests/test_try_admission.py
"""
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import threading
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
_SPEC = importlib.util.spec_from_file_location("perf_lab_try_admission", HERE / "try_admission.py")
admission = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = admission
_SPEC.loader.exec_module(admission)
store = admission.store

BASE = "a" * 40
HEAD = "b" * 40
OTHER = "c" * 40
VALID = {"ok": True, "reasons": [], "hz": 120, "fingerprint": "fp-1", "class": "apple-m4-pro/24gb/120hz"}


class Clock:
    def __init__(self) -> None:
        self.now = datetime(2026, 10, 26, 12, 0, tzinfo=timezone.utc)

    def __call__(self) -> datetime:
        self.now += timedelta(milliseconds=1)
        return self.now


def request(session="s1", base=BASE, head=HEAD, stories=(), features=(), attempts=20):
    return admission.TryRequest.parse(session=session, base=base, head=head, stories=stories, features=features,
                                      attempts=attempts)


def host(name, *labels, busy=False):
    return admission.FleetHost(name=name, labels=frozenset(labels), busy=busy)


class TryAdmissionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "lab.sqlite"
        lab = store.Store(self.path)
        lab.migrate()
        lab.close()
        self.queue = admission.TryQueue(self.path, clock=Clock())

    def tearDown(self) -> None:
        self.queue.close()
        self.tmp.cleanup()

    def test_duplicate_joins_the_existing_job(self) -> None:
        first = self.queue.admit(request("s1", stories=["b", "a"], features=["Y=off", "X=on"]))
        second = self.queue.admit(request("s2", stories=["a", "b", "a"], features=["X=on", "Y=off"], attempts=5))
        self.assertEqual(first.outcome, admission.ADMITTED)
        self.assertEqual(second.outcome, admission.JOINED)
        self.assertEqual(second.job_id, first.job_id)
        self.assertIn(f"joined existing job {first.job_id}", second.receipt)
        self.assertEqual(self.queue.status(first.job_id).sessions, ("s1", "s2"))
        count = self.queue._db.execute("SELECT COUNT(*) FROM jobs WHERE kind = 'try'").fetchone()[0]
        self.assertEqual(count, 1)

    def test_different_work_is_a_new_job(self) -> None:
        jobs = {self.queue.admit(r).job_id for r in (
            request(), request(stories=["x"]), request(features=["X=on"]), request(features=["X=off"]),
            request("s2", head=OTHER))}
        self.assertEqual(len(jobs), 5)

    def test_finished_job_is_not_joined(self) -> None:
        first = self.queue.admit(request())
        self.queue.dispatch([host("m1", "measure")], frozenset())
        self.queue.env_result(first.job_id, "m1", VALID)
        self.queue.finish(first.job_id, admission.DONE)
        again = self.queue.admit(request())
        self.assertEqual(again.outcome, admission.ADMITTED)
        self.assertNotEqual(again.job_id, first.job_id)

    def test_fourth_request_is_refused_with_a_reason(self) -> None:
        ids = [self.queue.admit(request(head=sha * 40)).job_id for sha in "123"]
        fourth = self.queue.admit(request(head="4" * 40))
        self.assertEqual(fourth.outcome, admission.REFUSED)
        self.assertIsNone(fourth.job_id)
        self.assertIn("limit is 3", fourth.reason)
        for job in ids:
            self.assertIn(str(job), fourth.reason)
        self.assertTrue(fourth.receipt.startswith("Perf try refused: session s1"))
        self.assertEqual(self.queue.admit(request("s2", head="4" * 40)).outcome, admission.ADMITTED)

    def test_join_costs_no_quota_and_a_finished_job_frees_one(self) -> None:
        ids = [self.queue.admit(request("s2", head=sha * 40)).job_id for sha in "123"]
        self.assertEqual(self.queue.admit(request("s2", head="1" * 40)).outcome, admission.JOINED)
        self.assertEqual(self.queue.admit(request("s1", head="1" * 40)).outcome, admission.JOINED)
        self.queue.cancel(ids[1], "s2")
        self.assertEqual(self.queue.status(ids[1]).state, admission.CANCELLED)
        self.assertEqual(self.queue.admit(request("s2", head="4" * 40)).outcome, admission.ADMITTED)

    def test_parallel_requests_dedupe_and_hold_the_quota(self) -> None:
        results: list = []

        def admit(req) -> None:
            queue = admission.TryQueue(self.path, clock=Clock(), busy_timeout_ms=30000)
            try:
                results.append(queue.admit(req))
            finally:
                queue.close()

        threads = [threading.Thread(target=admit, args=(request(f"s{i}"),)) for i in range(10)]
        threads += [threading.Thread(target=admit, args=(request("solo", head=f"{i}" * 40),)) for i in range(10)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        shared = [r for r in results if r.outcome != admission.REFUSED and r.job_id is not None]
        same = {r.job_id for r in results if r.outcome == admission.JOINED}
        self.assertEqual(len(same), 1)
        self.assertEqual(sum(r.outcome == admission.REFUSED for r in results), 7)
        self.assertEqual(len({r.job_id for r in shared}), 4)

    def test_queue_position_in_the_receipt(self) -> None:
        a = self.queue.admit(request("s1"))
        b = self.queue.admit(request("s2", head=OTHER))
        self.assertIn("queue position 1 of 1", a.receipt)
        self.assertIn("queue position 2 of 2", b.receipt)
        self.assertEqual((b.position, b.queued), (2, 2))
        self.queue.dispatch([host("m1", "measure")], frozenset())
        self.assertEqual(self.queue.status(b.job_id).position, 1)
        self.assertIsNone(self.queue.status(a.job_id).position)

    def test_batch_tip_builds_are_reused(self) -> None:
        self.queue._db.execute(
            "INSERT INTO builds (sha, config, commit_pos, artifact_digest) VALUES (?, 'bench', 1, 'sha256:base')",
            (BASE,))
        self.queue._db.execute(
            "INSERT INTO builds (sha, config, commit_pos, artifact_digest) VALUES (?, 'debug', 2, 'sha256:dbg')",
            (HEAD,))
        result = self.queue.admit(request())
        self.assertIn(f"base {BASE[:12]} reuses sha256:base", result.receipt)
        self.assertIn(f"head {HEAD[:12]} needs a bench build", result.receipt)
        self.assertEqual(self.queue.status(result.job_id).builds, {"base": "sha256:base", "head": None})

    def test_never_a_perf_lab_host(self) -> None:
        for session in ("s1", "s2", "s3", "s4"):
            self.queue.admit(request(session, head=session[1] * 40))
        fleet = [host("lab-label", "measure", "perf-lab"), host("lab-pool", "measure"),
                 host("no-measure", "build"), host("busy", "measure", busy=True), host("free", "measure")]
        offers = self.queue.dispatch(fleet, frozenset({"lab-pool"}))
        self.assertEqual([o.host for o in offers], ["free"])
        self.assertEqual(self.queue.dispatch(fleet, frozenset({"lab-pool"})), [])

    def test_host_class_named_after_host_env(self) -> None:
        job = self.queue.admit(request()).job_id
        [offer] = self.queue.dispatch([host("m1", "measure")], frozenset())
        self.assertEqual(self.queue.status(job).state, admission.ENV_CHECK)
        status = self.queue.env_result(job, offer.host, VALID)
        self.assertEqual(status.state, admission.RUNNING)
        self.assertEqual(status.receipt(), f"Perf try job {job}: running on m1 @apple-m4-pro/24gb/120hz")
        self.assertIn("@apple-m4-pro/24gb/120hz", self.queue.admit(request("s2")).receipt)

    def test_env_invalid_host_requeues_the_job_without_that_host(self) -> None:
        first = self.queue.admit(request()).job_id
        second = self.queue.admit(request("s2", head=OTHER)).job_id
        fleet = [host("m1", "measure"), host("m2", "measure")]
        offers = self.queue.dispatch(fleet, frozenset())
        self.assertEqual([(o.job_id, o.host) for o in offers], [(first, "m1"), (second, "m2")])
        status = self.queue.env_result(first, "m1", {"ok": False, "reasons": ["network-egress"]})
        self.assertEqual((status.state, status.position), (admission.QUEUED, 1))
        self.assertEqual(self.queue.dispatch([host("m1", "measure")], frozenset()), [])
        self.queue.env_result(second, "m2", VALID)
        self.queue.finish(second, admission.DONE)
        self.assertEqual(self.queue.dispatch(fleet, frozenset()), [admission.Assignment(first, "m2")])

    def test_state_changes_are_checked(self) -> None:
        job = self.queue.admit(request()).job_id
        with self.assertRaises(admission.AdmissionError) as raised:
            self.queue.env_result(job, "m1", VALID)
        self.assertEqual(raised.exception.code, "not-offered")
        with self.assertRaises(admission.AdmissionError) as raised:
            self.queue.finish(job, admission.DONE)
        self.assertEqual(raised.exception.code, "not-running")
        with self.assertRaises(admission.AdmissionError) as raised:
            self.queue.cancel(job, "stranger")
        self.assertEqual(raised.exception.code, "not-owner")
        self.queue.dispatch([host("m1", "measure")], frozenset())
        with self.assertRaises(admission.AdmissionError) as raised:
            self.queue.env_result(job, "m1", {"ok": True})
        self.assertEqual(raised.exception.code, "bad-verdict")

    def test_joined_session_cancel_leaves_the_job_running(self) -> None:
        job = self.queue.admit(request("s1")).job_id
        self.queue.admit(request("s2"))
        self.assertEqual(self.queue.cancel(job, "s1").state, admission.QUEUED)
        self.assertEqual(self.queue.status(job).sessions, ("s2",))
        self.assertEqual(self.queue.cancel(job, "s2").state, admission.CANCELLED)

    def test_request_validation(self) -> None:
        cases = {
            "bad-sha": dict(base="abc1234"),
            "bad-session": dict(session=" "),
            "bad-feature": dict(features=["X=maybe"]),
            "bad-attempts": dict(attempts=0),
            "bad-story": dict(stories=["no spaces"]),
        }
        for code, change in cases.items():
            with self.subTest(code), self.assertRaises(admission.AdmissionError) as raised:
                request(**change)
            self.assertEqual(raised.exception.code, code)
        with self.assertRaises(admission.AdmissionError):
            request(features=["X=on", "X=off"])
        self.assertEqual(request(base=BASE.upper()).base, BASE)

    def test_pool_file(self) -> None:
        pool = Path(self.tmp.name) / "pool.json"
        with self.assertRaises(admission.AdmissionError) as raised:
            admission.lab_hosts(pool)
        self.assertEqual(raised.exception.code, "no-pool")
        pool.write_text(json.dumps({"hosts": [{"name": "cmux15"}, {"name": "cmux16"}]}))
        self.assertEqual(admission.lab_hosts(pool), frozenset({"cmux15", "cmux16"}))
        pool.write_text(json.dumps({"hosts": ["cmux15"]}))
        with self.assertRaises(admission.AdmissionError):
            admission.lab_hosts(pool)

    def test_cli_round_trip(self) -> None:
        def run(*args):
            return subprocess.run([sys.executable, str(HERE / "try_admission.py"), "--store", str(self.path), *args],
                                  capture_output=True, text=True)

        fleet = Path(self.tmp.name) / "fleet.json"
        fleet.write_text(json.dumps({"hosts": [{"name": "cmux15", "labels": ["measure", "perf-lab"]},
                                               {"name": "m1", "labels": ["measure"]}]}))
        pool = Path(self.tmp.name) / "pool.json"
        pool.write_text(json.dumps({"hosts": [{"name": "cmux15"}]}))
        verdict = Path(self.tmp.name) / "env.json"
        verdict.write_text(json.dumps(VALID))
        admitted = run("admit", "--session", "cli", "--base", BASE, "--head", HEAD, "--feature", "X=on")
        self.assertEqual(admitted.returncode, 0, admitted.stderr)
        self.assertIn("Perf try admitted job 1: queue position 1 of 1", admitted.stdout)
        for sha in "123":
            run("admit", "--session", "cli", "--base", BASE, "--head", sha * 40)
        refused = run("admit", "--session", "cli", "--base", BASE, "--head", "4" * 40)
        self.assertEqual(refused.returncode, 2)
        self.assertIn("Perf try refused", refused.stdout)
        dispatched = run("dispatch", "--fleet", str(fleet), "--pool", str(pool))
        self.assertEqual(json.loads(dispatched.stdout), {"job": 1, "host": "m1"})
        started = run("env-result", "1", "--host", "m1", "--verdict", str(verdict))
        self.assertEqual(started.stdout.strip(), "Perf try job 1: running on m1 @apple-m4-pro/24gb/120hz")
        bad = run("admit", "--session", "cli", "--base", "short", "--head", HEAD)
        self.assertEqual(bad.returncode, 1)
        self.assertIn("bad-sha", bad.stderr)


if __name__ == "__main__":
    unittest.main()
