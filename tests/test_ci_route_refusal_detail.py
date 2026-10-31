#!/usr/bin/env python3
"""A refused routing read says why, and retries once only when GitHub says when.

On 2026-10-26 (22:47 and 22:54Z) the macOS placement logged only "HTTP Error 403:
Forbidden" for its runner reads, which cannot tell a secondary rate limit from a
missing permission. pr_runner_pool.GitHub.get_api and next_macos_cascade.Api._get now
print the status, Retry-After, X-RateLimit-Remaining, X-RateLimit-Resource and the
start of the body. The pool client retries once after Retry-After on a 403 or 429 that
carries one only when its caller opts in (retry_cap > 0, the cap): side-lane placement
does, at 5 s, with one retry shared by both its tokens. Every other caller, the cascade included (its
reads share a 45 s budget), logs and raises after one attempt, as before.
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import sys
import unittest
import urllib.error
from email.message import Message
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]


def load(name: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts/ci" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules.setdefault(name, module)
    spec.loader.exec_module(module)
    return module


pool = load("pr_runner_pool")
cascade = load("next_macos_cascade")


def load_side():
    spec = importlib.util.spec_from_file_location("side_lane_placement_under_test",
                                                  ROOT / "scripts/ci/side_lane_placement.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def refused(code: int, body: str, **headers: str) -> urllib.error.HTTPError:
    message = Message()
    for key, value in headers.items():
        message[key.replace("_", "-")] = value
    return urllib.error.HTTPError("https://api.github.com/x", code, "Forbidden", message, io.BytesIO(body.encode()))


class Ok:
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def read(self, *args):
        return b'{"runners": []}'


def clients():
    return (("pool", pool, lambda: pool.GitHub("t", "o/r", retry_cap=60).get_api("/orgs/o/actions/runners?per_page=100"), 60.0),)


def no_retry_clients():
    return (("cascade", cascade, None),
            ("pool default", pool, lambda: pool.GitHub("t", "o/r").get_api("/orgs/o/x?y=1")))


class RefusalDetailTests(unittest.TestCase):
    def setUp(self):
        api = cascade.Api.__new__(cascade.Api)
        api.route_token = "t"
        self.cascade_api = api

    def call(self, module, fn, answers):
        sleeps: list[float] = []
        err = io.StringIO()
        if module is cascade:
            fn = lambda: self.cascade_api._get("/orgs/o/actions/runner-groups?x=1")  # noqa: E731
        with mock.patch.object(module.urllib.request, "urlopen", side_effect=answers) as opened, \
                mock.patch.object(module.time, "sleep", side_effect=sleeps.append), contextlib.redirect_stderr(err):
            try:
                result = fn()
            except urllib.error.HTTPError as error:
                result = error
        return result, opened.call_count, sleeps, err.getvalue()

    def test_a_secondary_limit_with_retry_after_retries_once_and_says_why(self):
        for name, module, fn, cap in clients():
            with self.subTest(client=name):
                body = '{"message": "You have exceeded a secondary rate limit."}'
                result, calls, sleeps, err = self.call(module, fn, [
                    refused(403, body, Retry_After="7", X_RateLimit_Remaining="4000", X_RateLimit_Resource="core"), Ok()])
                self.assertEqual(result, {"runners": []})
                self.assertEqual((calls, sleeps), (2, [7.0]))
                self.assertIn("HTTP 403 Retry-After=7 X-RateLimit-Remaining=4000 X-RateLimit-Resource=core", err)
                self.assertIn("secondary rate limit", err)
                self.assertIn("retrying once in 7 s", err)
                self.assertNotIn("?", err.split("GET ", 1)[1].split(":", 1)[0])

    def test_the_wait_is_capped(self):
        for name, module, fn, cap in clients():
            with self.subTest(client=name):
                _, _, sleeps, _ = self.call(module, fn, [refused(429, "", Retry_After="3600"), Ok()])
                self.assertEqual(sleeps, [cap])

    def test_a_refusal_without_retry_after_raises_after_one_attempt(self):
        for name, module, fn, cap in clients():
            with self.subTest(client=name):
                body = '{"message": "Resource not accessible by integration"}'
                result, calls, sleeps, err = self.call(module, fn, [refused(403, body, X_RateLimit_Remaining="0")])
                self.assertIsInstance(result, urllib.error.HTTPError)
                self.assertEqual(result.code, 403)
                self.assertEqual((calls, sleeps), (1, []))
                self.assertIn("Resource not accessible by integration", err)
                self.assertIn("X-RateLimit-Remaining=0", err)

    def test_a_second_refusal_is_raised_not_retried_again(self):
        for name, module, fn, cap in clients():
            with self.subTest(client=name):
                result, calls, sleeps, _ = self.call(module, fn, [refused(403, "", Retry_After="1"),
                                                                  refused(403, "", Retry_After="1")])
                self.assertIsInstance(result, urllib.error.HTTPError)
                self.assertEqual((calls, sleeps), (2, [1.0]))

    def test_the_cascade_never_waits_but_says_why(self):
        for name, module, fn in no_retry_clients():
            with self.subTest(client=name):
                body = '{"message": "You have exceeded a secondary rate limit."}'
                result, calls, sleeps, err = self.call(module, fn, [refused(403, body, Retry_After="7"), Ok()])
                self.assertIsInstance(result, urllib.error.HTTPError)
                self.assertEqual((calls, sleeps), (1, []))
                self.assertIn("Retry-After=7", err)
                self.assertIn("secondary rate limit", err)

    def test_only_side_lane_placement_opts_in_and_fits_its_step(self):
        cascade_source = (ROOT / "scripts/ci/next_macos_cascade.py").read_text()
        self.assertNotIn("retry_cap", cascade_source)
        self.assertNotIn("time.sleep(wait)", cascade_source)
        side = (ROOT / "scripts/ci/side_lane_placement.py").read_text()
        self.assertIn("retry_cap=SIDE_RETRY_CAP_SECONDS, retries=retries", side)
        self.assertIn("retries = pool.RetryBudget(1)", side)
        self.assertIn("SIDE_RETRY_CAP_SECONDS = 5.0", side)
        users = [path.name for path in (ROOT / "scripts").rglob("*.py") if "retry_cap=" in path.read_text(errors="ignore")
                 and path.name not in ("pr_runner_pool.py",)]
        # Portable placement reads the runners the way side-lane placement does, with its cap.
        self.assertEqual(sorted(users), ["portable_job_placement.py", "side_lane_placement.py"])
        portable = (ROOT / "scripts/ci/portable_job_placement.py").read_text()
        self.assertIn("retry_cap=side.SIDE_RETRY_CAP_SECONDS, retries=retries", portable)
        self.assertIn("retries = pool.RetryBudget(1)", portable)

    def test_one_retry_per_client_whatever_the_reads(self):
        # Slow refusals on every read (the review's case): the client still retries only once,
        # so it adds one wait and one request to what it takes with no retry at all.
        now = [0.0]
        sleeps: list[float] = []

        def slow(*args, **kwargs):
            now[0] += 10
            raise refused(403, "", Retry_After="30")

        client = pool.GitHub("t", "o/r", retry_cap=5)
        err = io.StringIO()
        with mock.patch.object(pool.urllib.request, "urlopen", side_effect=slow) as opened, \
                mock.patch.object(pool.time, "sleep", side_effect=lambda s: (sleeps.append(s), now.__setitem__(0, now[0] + s))), \
                contextlib.redirect_stderr(err):
            for _ in range(3):
                with self.assertRaises(urllib.error.HTTPError):
                    client.get_api("/orgs/o/actions/runners")
        self.assertEqual(sleeps, [5.0])
        self.assertEqual(opened.call_count, 4)  # three reads, one of them retried
        self.assertEqual(now[0], 3 * 10 + 5 + 10)

    def test_placement_retries_once_across_both_tokens(self):
        # The review's case: every read on both tokens is slow (14 s) and refused with a Retry-After.
        # With no retry the reads take N x 14 s; the shared budget adds one 5 s wait and one request.
        side = load_side()
        now = [0.0]
        sleeps: list[float] = []

        def slow(*args, **kwargs):
            now[0] += 14
            raise refused(403, "", Retry_After="30")

        def run(cap):
            now[0] = 0.0
            sleeps.clear()
            env = {"GITHUB_REPOSITORY": "o/r", "ROUTE_TOKEN": "a", "ROUTE_TOKEN_FALLBACK": "b"}
            with mock.patch.object(pool.urllib.request, "urlopen", side_effect=slow) as opened, \
                    mock.patch.object(pool.time, "sleep",
                                      side_effect=lambda s: (sleeps.append(s), now.__setitem__(0, now[0] + s))), \
                    mock.patch.object(side, "SIDE_RETRY_CAP_SECONDS", cap), \
                    mock.patch.object(side.cascade, "bot_rerun", return_value=False), \
                    mock.patch.object(side, "fast_route", side_effect=RuntimeError("stop after the read")), \
                    contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises(RuntimeError):
                    side.main(env)
            return opened.call_count, list(sleeps), now[0]

        base_calls, base_sleeps, base_time = run(0.0)
        calls, sleeps_seen, elapsed = run(5.0)
        self.assertEqual(base_sleeps, [])
        self.assertEqual(sleeps_seen, [5.0])
        self.assertEqual(calls, base_calls + 1)
        self.assertLessEqual(elapsed - base_time, 5.0 + 15)

    def test_other_statuses_are_not_retried(self):
        for name, module, fn, cap in clients():
            with self.subTest(client=name):
                result, calls, sleeps, _ = self.call(module, fn, [refused(404, "{}", Retry_After="1")])
                self.assertEqual((result.code, calls, sleeps), (404, 1, []))


if __name__ == "__main__":
    unittest.main()
