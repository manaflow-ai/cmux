"""One classic publisher at a time, newest first (scripts/ci/classic_publish_lease.py).

Runs the real r2_cas lease logic against an in-memory R2 whose ETags, like
R2's, follow the bytes, and whose objects age on R2's clock.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("classic_publish_lease", ROOT / "scripts/ci/classic_publish_lease.py")
lease = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lease)
r2 = lease.r2_cas

LEASE = "nightly/locks/publish-lease.json"
CLAIM = "nightly/locks/publish-claim.json"


class FakeR2:
    def __init__(self):
        self.objects: dict[str, tuple[str, bytes, float]] = {}
        self.refuse_next_put = False

    def read(self, key):
        return self.objects.get(key, (None, b"", 0.0))

    def put(self, key, body, *, etag, cache_control, content_type):
        current = self.objects.get(key)
        if self.refuse_next_put:
            self.refuse_next_put = False
            return False
        if (etag is None and current is not None) or (etag is not None and (current is None or current[0] != etag)):
            return False
        self.objects[key] = (f'"{hashlib.md5(body).hexdigest()}"', body, 0.0)
        return True

    def age(self, key, seconds):
        etag, body, _ = self.objects[key]
        self.objects[key] = (etag, body, seconds)

    def json(self, key):
        return json.loads(self.objects[key][1])


class Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now


class ClassicPublishLeaseTests(unittest.TestCase):
    def setUp(self):
        self.fake = FakeR2()
        self.saved = (r2.read, r2.put)
        r2.read, r2.put = self.fake.read, self.fake.put
        self.beats = []
        self.tmp = tempfile.TemporaryDirectory()

    def tearDown(self):
        r2.read, r2.put = self.saved
        self.tmp.cleanup()

    def env(self, owner, wait=0):
        return {"LEASE_KEY": LEASE, "CLAIM_KEY": CLAIM, "LEASE_OWNER": owner, "LEASE_WAIT": str(wait),
                "RUNNER_TEMP": self.tmp.name}

    def acquire(self, build, owner, wait=0, on_sleep=None, finished=lambda owner, env: True):
        clock = Clock()

        def sleep(seconds):
            clock.now += seconds
            if on_sleep:
                on_sleep(clock.now)

        lease.acquire(build, env=self.env(owner, wait), clock=clock, sleep=sleep,
                      heartbeat=lambda key, who: self.beats.append(who), finished=finished)

    def claim(self, build, owner, age=0.0):
        lease._put(CLAIM, {"build": build, "owner": owner}, self.fake.read(CLAIM)[0])
        self.fake.age(CLAIM, age)

    def test_the_newest_waiter_takes_the_lease_and_withdraws_its_claim(self):
        self.acquire(100, "a")
        self.assertTrue(r2.holds(LEASE, "a"))
        self.assertEqual(self.beats, ["a"])
        self.assertTrue(self.fake.json(CLAIM)["withdrawn"])

    def test_an_older_waiter_never_takes_the_lease_while_a_newer_one_waits(self):
        self.claim(200, "b")
        with self.assertRaises(RuntimeError):
            self.acquire(100, "a")
        self.assertNotIn(LEASE, self.fake.objects)
        self.assertEqual(self.fake.json(CLAIM)["build"], 200)  # a's timeout did not withdraw b's claim

    def test_the_newest_build_waits_only_for_the_holder(self):
        self.acquire(100, "a")  # an older build already holds the lease
        self.acquire(200, "b", wait=600, on_sleep=lambda now: now >= 30 and lease.release(self.env("a")))
        self.assertTrue(r2.holds(LEASE, "b"))

    def test_a_claim_from_a_failed_or_dead_waiter_frees_the_queue(self):
        self.claim(200, "b")
        lease.withdraw(CLAIM, "b")  # b's release withdrew it
        self.acquire(100, "a")
        self.assertTrue(r2.holds(LEASE, "a"))
        lease.release(self.env("a"))
        self.claim(300, "c", age=lease.CLAIM_TTL + 1)  # c died while waiting
        self.acquire(150, "d")
        self.assertTrue(r2.holds(LEASE, "d"))

    def test_a_waiter_whose_wait_runs_out_withdraws_its_claim(self):
        self.acquire(100, "a")
        with self.assertRaises(RuntimeError):
            self.acquire(200, "b", wait=60)
        self.assertTrue(self.fake.json(CLAIM)["withdrawn"])
        lease.release(self.env("a"))
        self.acquire(150, "c")
        self.assertTrue(r2.holds(LEASE, "c"))

    def test_a_renewal_changes_the_etag_so_a_waiter_that_read_it_expired_cannot_take_it(self):
        self.acquire(100, "a")
        self.fake.age(LEASE, lease.LEASE_TTL + 1)
        expired_etag = self.fake.read(LEASE)[0]
        self.assertTrue(lease.renew(LEASE, "a"))  # a's heartbeat, between b's read and b's write
        self.assertNotEqual(self.fake.read(LEASE)[0], expired_etag)
        self.assertFalse(r2.put(LEASE, json.dumps({"owner": "b"}).encode(), etag=expired_etag,
                                cache_control="no-store", content_type="application/json"))
        self.assertTrue(r2.holds(LEASE, "a"))

    def test_an_abandoned_lease_frees_after_the_ttl_and_its_holder_never_writes_again(self):
        self.acquire(100, "a")
        with self.assertRaises(RuntimeError):
            self.acquire(200, "b")
        self.fake.age(LEASE, lease.LEASE_TTL + 1)  # a's job died: no heartbeat
        self.acquire(200, "b")
        self.assertTrue(r2.holds(LEASE, "b"))
        with self.assertRaises(RuntimeError):
            lease.check(self.env("a"))

    def test_an_expired_lease_is_taken_only_once_its_holders_job_has_completed(self):
        self.acquire(100, "11-1-publish")
        self.fake.age(LEASE, lease.LEASE_TTL + 1)  # every renewal failed, but the job may still write
        asked = []
        running = lambda owner, env: asked.append(owner) or False
        with self.assertRaises(RuntimeError):
            self.acquire(200, "22-1-publish", finished=running)
        self.assertEqual(asked, ["11-1-publish"])
        self.assertTrue(r2.holds(LEASE, "11-1-publish"))
        self.acquire(200, "22-1-publish", finished=lambda owner, env: owner == "11-1-publish")
        self.assertTrue(r2.holds(LEASE, "22-1-publish"))

    def test_the_holders_own_job_decides_and_anything_unread_counts_as_running(self):
        self.assertFalse(lease.job_finished("not-a-run", {"GITHUB_REPOSITORY": "o/r"}))
        with tempfile.TemporaryDirectory() as tmp:
            gh = Path(tmp) / "gh"
            gh.write_text("#!/bin/sh\n[ -n \"$GH_FAIL\" ] && exit 1\nprintf 'publish\\tcompleted\\nrepublish-deltas\\tin_progress\\n'\n")
            gh.chmod(0o755)
            env = {"GITHUB_REPOSITORY": "o/r", "PATH": f"{tmp}:/usr/bin:/bin"}
            # The same run's delta job runs while its publish job, which failed to unlock, has ended.
            self.assertTrue(lease.job_finished("11-1-publish", env))
            self.assertFalse(lease.job_finished("11-1-republish-deltas", env))
            self.assertFalse(lease.job_finished("11-1-generate-deltas", env))  # not listed
            self.assertFalse(lease.job_finished("11-1-publish", {**env, "GH_FAIL": "1"}))

    def test_a_claimant_overtaken_before_it_won_the_lock_steps_back(self):
        real = lease.try_lock

        def try_lock(key, owner, env, finished):
            won = real(key, owner, env, finished)
            if owner == "a" and won and not self.overtaken:
                self.overtaken = True
                self.claim(200, "b")  # b claimed between a's claim and a's lock
            return won

        self.overtaken = False
        lease.try_lock = try_lock
        try:
            with self.assertRaises(RuntimeError):
                self.acquire(100, "a")
        finally:
            lease.try_lock = real
        self.assertFalse(r2.holds(LEASE, "a"))
        self.acquire(200, "b")
        self.assertTrue(r2.holds(LEASE, "b"))

    def test_check_renews_and_tolerates_losing_the_write_to_the_heartbeat(self):
        self.acquire(100, "a")
        self.fake.age(LEASE, lease.LEASE_TTL - 5)
        lease.check(self.env("a"))
        self.assertEqual(self.fake.read(LEASE)[2], 0.0)
        self.fake.refuse_next_put = True  # the heartbeat renewed between the read and the write
        lease.check(self.env("a"))

    def test_the_heartbeat_keeps_a_live_lease_and_stops_once_it_is_gone(self):
        self.acquire(100, "a")
        beats = []

        def sleep(_):
            beats.append(1)
            if len(beats) == 3:
                self.fake.refuse_next_put = True
            if len(beats) == 5:
                r2.unlock(LEASE, "a")

        lease.heartbeat(LEASE, "a", sleep=sleep)
        self.assertEqual(len(beats), 5)

    def test_release_frees_the_lease_for_the_next_waiter(self):
        self.acquire(100, "a")
        lease.release(self.env("a"))
        self.assertFalse(r2.holds(LEASE, "a"))
        self.acquire(90, "b")
        self.assertTrue(r2.holds(LEASE, "b"))


if __name__ == "__main__":
    unittest.main()
