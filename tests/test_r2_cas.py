#!/usr/bin/env python3
"""scripts/ci/r2_cas.py's lease against an in-memory R2 (no network), and the
nightly-next lease wrapper's bucket guard (scripts/ci/nightly-steps/publish-lease.sh)."""

from __future__ import annotations

import email.utils
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import unittest
import urllib.error

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("r2_cas", ROOT / "scripts/ci/r2_cas.py")
r2_cas = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(r2_cas)

ENV = {
    "AWS_ACCESS_KEY_ID": "test-key",
    "AWS_SECRET_ACCESS_KEY": "test-secret",
    "R2_ENDPOINT": "https://r2.invalid",
    "R2_BUCKET": "cmux-nightly-next",
}


class _Response(io.BytesIO):
    def __init__(self, body: bytes, headers: dict[str, str]):
        super().__init__(body)
        self.headers = headers

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False


class FakeR2:
    """Objects with ETags and Last-Modified on R2's own clock, honouring If-Match and If-None-Match."""

    def __init__(self):
        self.objects: dict[str, tuple[bytes, str, float]] = {}
        self.now = 1_800_000_000.0  # R2's clock, seconds
        self.version = 0
        self.requests: list[tuple[str, str, dict[str, str]]] = []

    def _error(self, url: str, code: int):
        return urllib.error.HTTPError(url, code, str(code), {}, io.BytesIO())

    def open(self, request, *, timeout):
        url = request.full_url
        key = url.split("/cmux-nightly-next/", 1)[1]
        headers = {name.lower(): value for name, value in request.header_items()}
        method = request.get_method()
        self.requests.append((method, key, headers))
        date = email.utils.formatdate(self.now, usegmt=True)
        if method == "GET":
            if key not in self.objects:
                raise self._error(url, 404)
            body, etag, modified = self.objects[key]
            return _Response(body, {"ETag": etag, "Date": date,
                                    "Last-Modified": email.utils.formatdate(modified, usegmt=True)})
        if method == "PUT":
            current = self.objects.get(key)
            if "if-none-match" in headers and current is not None:
                raise self._error(url, 412)
            if "if-match" in headers and (current is None or current[1] != headers["if-match"]):
                raise self._error(url, 412)
            self.version += 1
            self.objects[key] = (request.data or b"", f'"{self.version}"', self.now)
            return _Response(b"", {"Date": date})
        if method == "DELETE":
            self.objects.pop(key, None)
            return _Response(b"", {"Date": date})
        raise AssertionError(method)


class LeaseTests(unittest.TestCase):
    def setUp(self):
        self.r2 = FakeR2()
        self.saved_env = {name: os.environ.get(name) for name in ENV}
        os.environ.update(ENV)
        self.real_open = r2_cas.r2._open_signed_request
        r2_cas.r2._open_signed_request = self.r2.open
        # The runner's clock, far from R2's: expiry must never read it.
        self.runner = [0.0]
        self.clock = lambda: self.runner[0]

    def tearDown(self):
        r2_cas.r2._open_signed_request = self.real_open
        for name, value in self.saved_env.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value

    def sleep(self, seconds):
        # Waiting advances both clocks; the runner's runs far ahead.
        self.runner[0] += seconds * 100
        self.r2.now += seconds

    def lock(self, owner, ttl=60, wait=0):
        return r2_cas.lock("locks/l.json", owner, ttl, wait, self.clock, self.sleep)

    def test_first_writer_takes_a_free_lease_with_if_none_match(self):
        self.assertTrue(self.lock("run-1"))
        method, _, headers = self.r2.requests[-1]
        self.assertEqual((method, headers.get("if-none-match")), ("PUT", "*"))
        self.assertTrue(r2_cas.holds("locks/l.json", "run-1"))

    def test_a_held_lease_refuses_a_second_writer_until_its_wait_ends(self):
        self.assertTrue(self.lock("run-1", ttl=600))
        self.assertFalse(self.lock("run-2", ttl=600, wait=30))
        self.assertTrue(r2_cas.holds("locks/l.json", "run-1"))
        self.assertFalse(r2_cas.holds("locks/l.json", "run-2"))

    def test_a_waiter_gets_the_lease_once_the_holder_releases(self):
        self.assertTrue(self.lock("run-1", ttl=600))
        real_sleep = self.sleep

        def release_then_sleep(seconds):
            r2_cas.unlock("locks/l.json", "run-1")
            real_sleep(seconds)

        self.assertTrue(r2_cas.lock("locks/l.json", "run-2", 600, 60, self.clock, release_then_sleep))
        self.assertTrue(r2_cas.holds("locks/l.json", "run-2"))

    def test_expiry_is_judged_on_r2s_clock_not_the_runners(self):
        self.assertTrue(self.lock("run-1", ttl=60))
        self.runner[0] += 10_000  # the runner's clock jumps; R2's does not
        self.assertFalse(self.lock("run-2", ttl=60))
        self.r2.now += 61
        self.assertTrue(self.lock("run-2", ttl=60))
        self.assertFalse(r2_cas.holds("locks/l.json", "run-1"))

    def test_only_the_holder_releases_and_release_is_a_conditional_put(self):
        self.assertTrue(self.lock("run-1"))
        self.assertFalse(r2_cas.unlock("locks/l.json", "run-2"))
        self.assertTrue(r2_cas.holds("locks/l.json", "run-1"))
        self.assertTrue(r2_cas.unlock("locks/l.json", "run-1"))
        method, _, headers = self.r2.requests[-1]
        self.assertEqual(method, "PUT")
        self.assertIn("if-match", headers)
        self.assertFalse(r2_cas.holds("locks/l.json", "run-1"))
        self.assertFalse(r2_cas.unlock("locks/l.json", "run-1"), "a second release is a no-op")
        self.assertTrue(self.lock("run-3"), "a released lease is free at once")

    def test_a_lost_race_for_a_free_lease_waits_instead_of_overwriting(self):
        real_store = r2_cas._store
        raced = []

        def racing_store(key, lease, etag):
            if not raced:
                raced.append(True)
                real_store(key, {"owner": "run-other"}, etag)  # another writer wins first
            return real_store(key, lease, etag)

        r2_cas._store = racing_store
        try:
            self.assertFalse(self.lock("run-1", ttl=600, wait=0))
        finally:
            r2_cas._store = real_store
        self.assertTrue(r2_cas.holds("locks/l.json", "run-other"))

    def test_cli_lock_and_unlock_exit_codes(self):
        self.assertEqual(r2_cas.main(["lock", "--key", "locks/c.json", "--owner", "a", "--ttl", "60", "--wait", "0"]), 0)
        self.assertEqual(r2_cas.main(["lock", "--key", "locks/c.json", "--owner", "b", "--ttl", "60", "--wait", "0"]),
                         r2_cas.CONFLICT)
        self.assertEqual(r2_cas.main(["holds", "--key", "locks/c.json", "--owner", "a"]), 0)
        self.assertEqual(r2_cas.main(["unlock", "--key", "locks/c.json", "--owner", "a"]), 0)
        self.assertEqual(r2_cas.main(["holds", "--key", "locks/c.json", "--owner", "a"]), r2_cas.CONFLICT)


class PublishLeaseWrapperTests(unittest.TestCase):
    SCRIPT = ROOT / "scripts/ci/nightly-steps/publish-lease.sh"

    def run_wrapper(self, *args, **env):
        base = {"PATH": os.environ["PATH"], "LEASE_OWNER": "1-1", "LEASE_TTL": "60", "LEASE_WAIT": "0",
                "NIGHTLY_NEXT_R2_BUCKET": "cmux-nightly-next", **ENV, "R2_ENDPOINT": "https://127.0.0.1:9"}
        base.update(env)
        return subprocess.run(["bash", str(self.SCRIPT), *args], env=base, capture_output=True, text=True, timeout=60)

    def test_refuses_a_lease_in_mains_bucket_or_outside_the_track_prefix_before_any_request(self):
        result = self.run_wrapper("lock", LEASE_KEY="nightly/locks/x.json", NIGHTLY_NEXT_R2_BUCKET="cmux-binaries")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("nightly-next guard refused", result.stderr)
        result = self.run_wrapper("lock", LEASE_KEY="other/locks/x.json")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("outside prefix", result.stderr)

    def test_rejects_an_unknown_command(self):
        result = self.run_wrapper("steal", LEASE_KEY="nightly-next/locks/x.json")
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
