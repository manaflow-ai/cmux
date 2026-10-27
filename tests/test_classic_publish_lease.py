"""Newest-wins classic publication (scripts/ci/classic_publish_lease.py).

Runs the real r2_cas lease logic against an in-memory R2 with ETags and ages.
"""

from __future__ import annotations

import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("classic_publish_lease", ROOT / "scripts/ci/classic_publish_lease.py")
lease = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lease)
r2 = lease.r2_cas


class FakeR2:
    def __init__(self):
        self.objects: dict[str, tuple[str, bytes, float]] = {}
        self.version = 0
        self.refuse_next_put = False

    def read(self, key):
        if key not in self.objects:
            return None, b"", 0.0
        return self.objects[key]

    def put(self, key, body, *, etag, cache_control, content_type):
        current = self.objects.get(key)
        if self.refuse_next_put:
            self.refuse_next_put = False
            return False
        if (etag is None and current is not None) or (etag is not None and (current is None or current[0] != etag)):
            return False
        self.version += 1
        self.objects[key] = (f'"{self.version}"', body, 0.0)
        return True

    def age(self, key, seconds):
        etag, body, _ = self.objects[key]
        self.objects[key] = (etag, body, seconds)

    def json(self, key):
        return json.loads(self.objects[key][1])


ENV = {"LEASE_KEY": "nightly/locks/publish-lease.json", "CLAIM_KEY": "nightly/locks/publish-claim.json",
       "LEASE_OWNER": "run-a", "LEASE_WAIT": "0"}


class ClassicPublishLeaseTests(unittest.TestCase):
    def setUp(self):
        self.fake = FakeR2()
        self.saved = (r2.read, r2.put, lease.start_heartbeat)
        r2.read, r2.put = self.fake.read, self.fake.put
        self.heartbeats = []
        lease.start_heartbeat = lambda key, owner: self.heartbeats.append(owner)

    def tearDown(self):
        r2.read, r2.put, lease.start_heartbeat = self.saved

    def env(self, owner):
        return {**ENV, "LEASE_OWNER": owner}

    def test_the_newest_build_claims_and_holds(self):
        self.assertEqual(lease.acquire(100, raise_claim=True, env=self.env("a")), "proceed")
        self.assertEqual(self.fake.json(ENV["CLAIM_KEY"])["build"], 100)
        self.assertTrue(r2.holds(ENV["LEASE_KEY"], "a"))
        self.assertEqual(self.heartbeats, ["a"])

    def test_an_older_build_steps_aside_without_taking_the_lease(self):
        lease.claim(ENV["CLAIM_KEY"], 200, "b")
        self.assertEqual(lease.acquire(100, raise_claim=True, env=self.env("a")), "yield")
        self.assertNotIn(ENV["LEASE_KEY"], self.fake.objects)
        self.assertEqual(self.fake.json(ENV["CLAIM_KEY"])["build"], 200)

    def test_a_rerun_of_the_claimed_build_proceeds(self):
        lease.claim(ENV["CLAIM_KEY"], 100, "a1")
        self.assertEqual(lease.acquire(100, raise_claim=True, env=self.env("a2")), "proceed")

    def test_a_holder_yields_at_its_next_write_once_a_newer_build_claims(self):
        lease.acquire(100, raise_claim=True, env=self.env("a"))
        self.assertEqual(lease.check(100, env=self.env("a")), "proceed")
        lease.claim(ENV["CLAIM_KEY"], 200, "b")
        self.assertEqual(lease.check(100, env=self.env("a")), "yield")

    def test_a_waiter_that_a_newer_build_overtook_releases_and_yields(self):
        lease.acquire(100, raise_claim=True, env=self.env("a"))
        lease.claim(ENV["CLAIM_KEY"], 150, "b")  # b claimed; a still holds
        # c (build 120) claimed before b, then waited; it gets the lease once a releases.
        r2.unlock(ENV["LEASE_KEY"], "a")
        self.assertEqual(lease.acquire(120, raise_claim=False, env=self.env("c")), "yield")
        self.assertFalse(r2.holds(ENV["LEASE_KEY"], "c"))
        self.assertEqual(lease.acquire(150, raise_claim=True, env=self.env("b")), "proceed")

    def test_a_held_lease_blocks_and_an_abandoned_one_frees_after_the_ttl(self):
        lease.acquire(100, raise_claim=True, env=self.env("a"))
        with self.assertRaises(RuntimeError):
            lease.acquire(200, raise_claim=True, env=self.env("b"))
        self.fake.age(ENV["LEASE_KEY"], lease.LEASE_TTL + 1)  # a died: no heartbeat
        self.assertEqual(lease.acquire(200, raise_claim=True, env=self.env("b")), "proceed")
        with self.assertRaises(RuntimeError):
            lease.check(100, env=self.env("a"))  # a never writes without the lease

    def test_check_renews_and_tolerates_losing_the_write_to_the_heartbeat(self):
        lease.acquire(100, raise_claim=True, env=self.env("a"))
        self.fake.age(ENV["LEASE_KEY"], lease.LEASE_TTL - 5)
        self.assertEqual(lease.check(100, env=self.env("a")), "proceed")
        self.assertEqual(self.fake.read(ENV["LEASE_KEY"])[2], 0.0)  # renewed
        self.fake.refuse_next_put = True  # the heartbeat renewed between the read and the write
        self.assertEqual(lease.check(100, env=self.env("a")), "proceed")

    def test_the_delta_republish_compares_with_the_claim_without_raising_it(self):
        lease.claim(ENV["CLAIM_KEY"], 100, "a")
        self.assertEqual(lease.acquire(90, raise_claim=False, env=self.env("d")), "yield")
        self.assertEqual(self.fake.json(ENV["CLAIM_KEY"])["build"], 100)
        self.assertEqual(lease.acquire(100, raise_claim=False, env=self.env("d")), "proceed")

    def test_the_heartbeat_keeps_a_live_lease_and_stops_once_it_is_gone(self):
        lease.acquire(100, raise_claim=True, env=self.env("a"))
        beats = []

        def sleep(_):
            beats.append(1)
            if len(beats) == 3:
                self.fake.refuse_next_put = True  # check renewed first: still held
            if len(beats) == 5:
                r2.unlock(ENV["LEASE_KEY"], "a")

        lease.heartbeat(ENV["LEASE_KEY"], "a", sleep=sleep)
        self.assertEqual(len(beats), 5)

    def test_a_yield_tells_the_job_to_skip_its_writes(self):
        with tempfile.NamedTemporaryFile("r+", suffix=".env") as env_file:
            saved = os.environ.get("GITHUB_ENV")
            os.environ["GITHUB_ENV"] = env_file.name
            try:
                self.assertEqual(lease._skip("ALREADY_PUBLISHED", "yield"), "yield")
                self.assertEqual(lease._skip("ALREADY_PUBLISHED", "proceed"), "proceed")
            finally:
                if saved is None:
                    del os.environ["GITHUB_ENV"]
                else:
                    os.environ["GITHUB_ENV"] = saved
            self.assertEqual(Path(env_file.name).read_text(), "ALREADY_PUBLISHED=true\n")


if __name__ == "__main__":
    unittest.main()
