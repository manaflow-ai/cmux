#!/usr/bin/env python3
"""scripts/ci/r2_cas.py's lease against an in-memory R2 (no network), and the
nightly-next lease wrapper's bucket guard (scripts/ci/nightly-steps/publish-lease.sh)."""

from __future__ import annotations

import email.utils
import importlib.util
import io
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import unittest
import urllib.error
import warnings

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
        # Errors to raise on upcoming requests: (exception, after_applying) pairs. after_applying
        # means the request reaches R2 and only its response is lost.
        self.failures: list[tuple[Exception, bool]] = []

    def _error(self, url: str, code: int):
        return urllib.error.HTTPError(url, code, str(code), {}, io.BytesIO())

    def open(self, request, *, timeout):
        if self.failures:
            error, after = self.failures.pop(0)
            if not after:
                raise error
            self._apply(request)
            raise error
        return self._apply(request)

    def _apply(self, request):
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
        self.assertEqual(r2_cas.main(["unlock", "--key", "locks/c.json", "--owner", "b"]), r2_cas.NOTHING_TO_RELEASE)
        self.assertEqual(r2_cas.main(["unlock", "--key", "locks/c.json", "--owner", "a"]), 0)
        self.assertEqual(r2_cas.main(["holds", "--key", "locks/c.json", "--owner", "a"]), r2_cas.CONFLICT)
        self.assertEqual(r2_cas.main(["unlock", "--key", "locks/c.json", "--owner", "a"]), r2_cas.NOTHING_TO_RELEASE)
        self.assertEqual(r2_cas.main(["unlock", "--key", "locks/never.json", "--owner", "a"]), r2_cas.NOTHING_TO_RELEASE)

    def test_lock_retries_transient_r2_errors_within_its_wait(self):
        self.r2.failures = [(urllib.error.URLError(ConnectionResetError()), False),
                            (self.r2._error("u", 503), False), (TimeoutError(), False),
                            (self.r2._error("u", 429), False)]
        self.assertTrue(self.lock("run-1", wait=10_000))  # four polls on the runner's fast clock
        self.assertTrue(r2_cas.holds("locks/l.json", "run-1"))

    def test_lock_gives_up_on_transient_errors_only_when_its_wait_runs_out(self):
        self.r2.failures = [(self.r2._error("u", 500), False)] * 20
        self.assertFalse(self.lock("run-1", wait=30))

    def test_lock_does_not_retry_a_permanent_error(self):
        self.r2.failures = [(self.r2._error("u", 403), False)]
        with self.assertRaises(urllib.error.HTTPError):
            self.lock("run-1", wait=60)

    def test_a_lease_put_whose_response_was_lost_reads_back_as_this_attempts(self):
        real_store = r2_cas._store
        lost = []

        def lossy_store(key, lease, etag):
            written = real_store(key, lease, etag)
            if not lost:
                lost.append(True)
                raise urllib.error.URLError(ConnectionResetError("response lost"))
            return written

        r2_cas._store = lossy_store
        try:
            self.assertTrue(self.lock("run-1", ttl=600, wait=60))
        finally:
            r2_cas._store = real_store
        # The landed PUT, then the conditional rewrite that confirms it: never a second taker.
        self.assertEqual(sum(1 for method, *_ in self.r2.requests if method == "PUT"), 2)
        self.assertIn("if-match", self.r2.requests[-1][2])
        # Another attempt of the same owner (a later job of the run) has its own token: it waits.
        self.assertFalse(self.lock("run-1", ttl=600, wait=0))

    def test_expiry_is_judged_by_the_records_own_ttl_not_the_waiters(self):
        self.assertTrue(self.lock("run-1", ttl=3600))
        self.r2.now += 901
        self.assertFalse(self.lock("run-2", ttl=900), "a waiter with a shorter TTL took a live lease")
        self.r2.now += 3600
        self.assertTrue(self.lock("run-2", ttl=900))

    def test_an_active_lease_in_the_old_format_is_not_taken_after_the_new_ttl(self):
        # #32275's record: no token, no ttl, written with a 10800s TTL and never renewed.
        self.r2.objects["locks/l.json"] = (b'{"owner": "41000000000-1"}', '"old"', self.r2.now)
        self.r2.now += 901
        self.assertFalse(self.lock("run-2", ttl=900))
        self.assertTrue(r2_cas.holds("locks/l.json", "41000000000-1"))
        self.r2.now += r2_cas.LEGACY_TTL - 901
        self.assertFalse(self.lock("run-2", ttl=900))
        self.r2.now += 1
        self.assertTrue(self.lock("run-2", ttl=900))

    def test_a_recovered_lease_past_its_ttl_is_rewritten_before_it_counts_as_held(self):
        real_store = r2_cas._store
        lost = []

        def lossy_store(key, lease, etag):
            written = real_store(key, lease, etag)
            if not lost:
                lost.append(True)
                raise urllib.error.URLError(ConnectionResetError("response lost"))
            return written

        r2_cas._store = lossy_store
        try:
            # ttl 5 < the 10s poll: by the retry's read the landed lease has expired.
            self.assertTrue(self.lock("run-1", ttl=5, wait=60))
        finally:
            r2_cas._store = real_store
        self.assertEqual(sum(1 for method, *_ in self.r2.requests if method == "PUT"), 2)
        self.assertEqual(self.r2.objects["locks/l.json"][2], self.r2.now, "the recovered lease was not rewritten")
        # Before any heartbeat, a second writer finds it fresh.
        self.assertFalse(self.lock("run-2", ttl=5))
        self.assertTrue(r2_cas.holds("locks/l.json", "run-1"))

    def test_renewal_keeps_the_records_ttl(self):
        self.assertTrue(r2_cas.lock("locks/l.json", "run-1", 900, 0, self.clock, self.sleep, token="t1"))
        self.assertTrue(r2_cas.renew("locks/l.json", "run-1", "t1"))
        self.assertEqual(r2_cas._lease(self.r2.objects["locks/l.json"][0])["ttl"], 900)

    def test_renewal_keeps_a_short_lease_alive_and_changes_its_etag(self):
        self.assertTrue(r2_cas.lock("locks/l.json", "run-1", 60, 0, self.clock, self.sleep, token="t1"))
        for _ in range(5):
            before = self.r2.objects["locks/l.json"][1]
            self.r2.now += 45
            self.assertTrue(r2_cas.renew("locks/l.json", "run-1", "t1"))
            self.assertNotEqual(self.r2.objects["locks/l.json"][1], before)
            self.assertFalse(self.lock("run-2", ttl=60))
        # Without renewals the short TTL frees it.
        self.r2.now += 61
        self.assertTrue(self.lock("run-2", ttl=60))
        self.assertFalse(r2_cas.renew("locks/l.json", "run-1", "t1"), "a taken lease is not renewed")

    def test_a_waiter_that_read_the_lease_expired_cannot_take_it_after_a_renewal(self):
        self.assertTrue(r2_cas.lock("locks/l.json", "run-1", 60, 0, self.clock, self.sleep, token="t1"))
        self.r2.now += 61
        real_store = r2_cas._store

        def renew_first(key, lease, etag):
            real_store(key, {"owner": "run-1", "token": "t1"}, self.r2.objects[key][1])  # the holder renews
            return real_store(key, lease, etag)

        r2_cas._store = renew_first
        try:
            self.assertFalse(self.lock("run-2", ttl=60, wait=0))
        finally:
            r2_cas._store = real_store
        self.assertTrue(r2_cas.holds("locks/l.json", "run-1"))

    def heartbeat(self, worker=None, alive=lambda pid: True, max_hold=3600):
        log: list[str] = []
        reason = r2_cas.heartbeat("locks/l.json", "run-1", "t1", 60, max_hold, worker,
                                  clock=lambda: self.r2.now, sleep=lambda s: setattr(self.r2, "now", self.r2.now + s),
                                  alive=alive, log=log.append)
        return reason, log

    def test_heartbeat_stops_once_the_lease_is_released(self):
        self.assertTrue(r2_cas.lock("locks/l.json", "run-1", 900, 0, self.clock, self.sleep, token="t1"))
        real_renew = r2_cas.renew
        beats = []

        def renew_then_release(key, owner, token):
            beats.append(self.r2.now)
            if len(beats) == 3:
                r2_cas.unlock(key, owner)
            return real_renew(key, owner, token)

        r2_cas.renew = renew_then_release
        try:
            reason, _ = self.heartbeat()
        finally:
            r2_cas.renew = real_renew
        self.assertEqual(len(beats), 3)
        self.assertIn("no longer", reason)

    def test_heartbeat_keeps_beating_through_r2_errors(self):
        self.assertTrue(r2_cas.lock("locks/l.json", "run-1", 900, 0, self.clock, self.sleep, token="t1"))
        self.r2.failures = [(self.r2._error("u", 503), False), (urllib.error.URLError("down"), False)]
        reason, log = self.heartbeat(max_hold=600)
        self.assertEqual(reason, "max hold reached")
        self.assertEqual(len(log), 2)
        self.assertTrue(r2_cas.holds("locks/l.json", "run-1"))
        self.assertLess(self.r2.now - self.r2.objects["locks/l.json"][2], 900)

    def test_heartbeat_stops_when_the_jobs_runner_worker_exits(self):
        self.assertTrue(r2_cas.lock("locks/l.json", "run-1", 900, 0, self.clock, self.sleep, token="t1"))
        reason, _ = self.heartbeat(worker=12345, alive=lambda pid: False)
        self.assertIn("Runner.Worker", reason)

    def test_heartbeat_stops_at_its_max_hold(self):
        self.assertTrue(r2_cas.lock("locks/l.json", "run-1", 900, 0, self.clock, self.sleep, token="t1"))
        start = self.r2.now
        reason, _ = self.heartbeat(max_hold=600)
        self.assertEqual(reason, "max hold reached")
        self.assertLessEqual(self.r2.now - start, 660)

    def test_cli_lock_starts_the_heartbeat_and_unlock_stops_it(self):
        started, stopped = [], []
        real_start, real_stop = r2_cas.start_heartbeat, r2_cas.stop_heartbeat
        r2_cas.start_heartbeat = lambda *args: started.append(args) or 1
        r2_cas.stop_heartbeat = stopped.append
        try:
            args = ["--key", "locks/h.json", "--owner", "a"]
            self.assertEqual(r2_cas.main(["lock", *args, "--ttl", "900", "--wait", "0", "--renew-every", "60",
                                          "--max-hold", "10800", "--pid-file", "/tmp/x.pid"]), 0)
            self.assertEqual(r2_cas.main(["unlock", *args, "--pid-file", "/tmp/x.pid"]), 0)
        finally:
            r2_cas.start_heartbeat, r2_cas.stop_heartbeat = real_start, real_stop
        key, owner, token, every, max_hold, pid_file = started[0]
        self.assertEqual((key, owner, every, max_hold, pid_file), ("locks/h.json", "a", 60, 10800, "/tmp/x.pid"))
        self.assertEqual(r2_cas._lease(self.r2.objects["locks/h.json"][0])["token"], token)
        self.assertEqual(stopped, ["/tmp/x.pid"])

    def test_cli_refuses_a_renewal_interval_too_close_to_the_ttl(self):
        with self.assertRaises(SystemExit):
            r2_cas.main(["lock", "--key", "locks/h.json", "--owner", "a", "--ttl", "100", "--wait", "0",
                         "--renew-every", "60", "--max-hold", "600", "--pid-file", "/tmp/x.pid"])
        self.assertNotIn("locks/h.json", self.r2.objects)


class HeartbeatProcessTests(unittest.TestCase):
    def test_start_heartbeat_runs_detached_and_stop_heartbeat_ends_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            pid_file = os.path.join(tmp, "lease.pid")
            saved = {name: os.environ.get(name) for name in ENV}
            os.environ.update(ENV)
            try:
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore", ResourceWarning)  # waited on below, by PID
                    pid = r2_cas.start_heartbeat("locks/p.json", "a", "t", 60, 600, pid_file)
            finally:
                for name, value in saved.items():
                    if value is None:
                        os.environ.pop(name, None)
                    else:
                        os.environ[name] = value
            self.assertEqual(int(Path(pid_file).read_text()), pid)
            self.assertNotEqual(os.getsid(pid), os.getsid(0), "the heartbeat runs in its own session")
            r2_cas.stop_heartbeat(pid_file)
            _, status = os.waitpid(pid, 0)
            self.assertTrue(os.WIFSIGNALED(status) and os.WTERMSIG(status) == signal.SIGTERM)
            self.assertFalse(Path(pid_file).exists())
            r2_cas.stop_heartbeat(pid_file)  # a second stop is a no-op

    def test_runner_worker_pid_finds_a_live_ancestor_or_none(self):
        pid = r2_cas.runner_worker_pid()
        self.assertTrue(pid is None or r2_cas._alive(pid))


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

    def run_with_r2_cas_exit(self, code, *args, **env):
        """The wrapper with r2_cas.py stubbed to exit `code` (every other python3 call runs for real)."""
        with tempfile.TemporaryDirectory() as tmp:
            shim = Path(tmp) / "python3"
            shim.write_text(f'#!/bin/sh\ncase "$1" in *r2_cas.py) exit {code} ;; esac\nexec "{sys.executable}" "$@"\n')
            shim.chmod(shim.stat().st_mode | stat.S_IEXEC)
            return self.run_wrapper(*args, PATH=f"{tmp}:{os.environ['PATH']}", RUNNER_TEMP=tmp, **env)

    def test_unlock_reports_a_release_and_nothing_to_release_apart(self):
        result = self.run_with_r2_cas_exit(0, "unlock", LEASE_KEY="nightly-next/locks/x.json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Released nightly-next/locks/x.json", result.stdout)
        result = self.run_with_r2_cas_exit(r2_cas.NOTHING_TO_RELEASE, "unlock", LEASE_KEY="nightly-next/locks/x.json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Nothing to release", result.stdout)
        self.assertNotIn("Released", result.stdout)

    def test_lock_requires_the_heartbeat_settings(self):
        result = self.run_with_r2_cas_exit(0, "lock", LEASE_KEY="nightly-next/locks/x.json")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("LEASE_RENEW", result.stderr)


if __name__ == "__main__":
    unittest.main()
