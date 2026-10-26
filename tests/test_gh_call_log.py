#!/usr/bin/env python3
"""The `gh-call` lines attribute API calls to workflows without making any call of their own.

  - pr_status.http_api and job_reuse.listing note each response they already
    received: the same number of requests goes out with the note as without it,
    and the line carries the response's X-RateLimit headers and the job's
    GITHUB_WORKFLOW and GITHUB_JOB;
  - outside Actions they print nothing, and a broken header map never fails the call;
  - gh_call_log.py parses the helpers' lines (theirs are inline, since those
    scripts are often checked out alone) and ranks calls per workflow per hour.
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]


def load(name: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / f"scripts/ci/{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


gh_call_log = load("gh_call_log")
pr_status = load("pr_status")
job_reuse = load("job_reuse")

HEADERS = {"X-RateLimit-Resource": "core", "X-RateLimit-Used": "1417", "X-RateLimit-Remaining": "3583",
           "X-RateLimit-Reset": "1793048548"}
ENV = {"GITHUB_ACTIONS": "true", "GITHUB_WORKFLOW": "high-signal review link", "GITHUB_JOB": "link",
       "GH_TOKEN": "t", "GITHUB_REPOSITORY": "o/r"}


class Response(io.BytesIO):
    def __init__(self, body: bytes = b"{}", headers=None):
        super().__init__(body)
        self.headers = HEADERS if headers is None else headers

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class Opener:
    def __init__(self, body: bytes = b"{}", headers=None):
        self.calls, self.body, self.headers = [], body, headers

    def __call__(self, request, timeout=None):
        self.calls.append(request.full_url)
        return Response(self.body, self.headers)


def run_logged(env, fn):
    err = io.StringIO()
    with mock.patch.dict(os.environ, env, clear=True), contextlib.redirect_stderr(err):
        result = fn()
    return result, [line for line in err.getvalue().splitlines() if line.startswith("gh-call\t")]


class HelperNoteTests(unittest.TestCase):
    def test_http_api_notes_the_response_and_sends_nothing_more(self):
        counts = {}
        for label, env in (("plain", {"GH_TOKEN": "t"}), ("actions", ENV)):
            opener = Opener()
            _, lines = run_logged(env, lambda: pr_status.http_api("GET", "/repos/o/r/issues/1/comments?page=2",
                                                                   opener=opener))
            counts[label] = len(opener.calls)
            if label == "plain":
                self.assertEqual(lines, [])
        self.assertEqual(counts, {"plain": 1, "actions": 1})
        (record,) = gh_call_log.parse(lines)
        self.assertEqual((record["workflow"], record["job"], record["resource"], record["used"],
                          record["remaining"], record["reset"]),
                         ("high-signal review link", "link", "core", "1417", "3583", "1793048548"))
        self.assertEqual(record["request"], "GET /repos/o/r/issues/1/comments")

    def test_a_retried_refusal_is_noted_once_per_request(self):
        import urllib.error
        calls = []

        def opener(request, timeout=None):
            calls.append(request.full_url)
            if len(calls) == 1:
                raise urllib.error.HTTPError(request.full_url, 429, "slow down",
                                             {"Retry-After": "0", **HEADERS}, io.BytesIO(b"rate limit"))
            return Response()

        _, lines = run_logged(ENV, lambda: pr_status.http_api("GET", "/x", opener=opener, sleep=lambda s: None))
        self.assertEqual(len(calls), 2)
        self.assertEqual(len(list(gh_call_log.parse(lines))), 2)

    def test_job_reuse_listing_notes_its_one_call(self):
        opener = Opener(b'{"artifacts": []}')
        with mock.patch.object(job_reuse.urllib.request, "urlopen", opener):
            result, lines = run_logged(ENV, lambda: job_reuse.listing("key", None))
        self.assertEqual(result, [])
        self.assertEqual(len(opener.calls), 1)
        (record,) = gh_call_log.parse(lines)
        self.assertEqual(record["request"], "GET /repos/o/r/actions/artifacts")

    def test_a_refused_listing_is_noted_and_still_a_miss(self):
        import urllib.error

        def opener(request, timeout=None):
            opener.calls += 1
            raise urllib.error.HTTPError(request.full_url, 403, "no", HEADERS, io.BytesIO(b"forbidden"))
        opener.calls = 0
        with mock.patch.object(job_reuse.urllib.request, "urlopen", opener):
            def call():
                with self.assertRaises(job_reuse.Miss):
                    job_reuse.listing("key", None)
            _, lines = run_logged(ENV, call)
        self.assertEqual(opener.calls, 1)
        self.assertEqual(len(list(gh_call_log.parse(lines))), 1)

    def test_missing_or_broken_headers_never_fail_the_call(self):
        class Broken:
            def get(self, name):
                raise RuntimeError("no")

        for headers in ({}, Broken()):
            opener = Opener(b'{"ok": 1}', headers)
            result, _ = run_logged(ENV, lambda: pr_status.http_api("GET", "/x", opener=opener))
            self.assertEqual(result, {"ok": 1})


class RankTests(unittest.TestCase):
    def test_the_library_line_round_trips(self):
        import datetime as dt
        text = gh_call_log.line(HEADERS, "post", "/a?token=secret", env=ENV,
                                now=dt.datetime(2026, 10, 26, 22, 47, 50, tzinfo=dt.timezone.utc))
        self.assertNotIn("secret", text)
        self.assertNotIn("SECRET", gh_call_log.line({}, "GET", "/a?token=SECRET\nextra", env=ENV))
        (record,) = gh_call_log.parse([f"2026-10-26T22:47:50.1Z {text}"])
        self.assertEqual(record["request"], "POST /a")
        self.assertEqual(record["time"], "2026-10-26T22:47:50Z")

    def test_rank_counts_per_workflow_per_hour_most_first(self):
        def rec(time, workflow, resource="core", used="10"):
            return f"job\tstep\t{time}.0Z gh-call\t{time}Z\t{workflow}\tj\t{resource}\t{used}\t1\t2\tGET /p"
        lines = [rec("2026-10-26T22:01:00", "a"), rec("2026-10-26T22:02:00", "b", used="900"),
                 rec("2026-10-26T22:03:00", "b"), rec("2026-10-26T22:04:00", "c", resource="graphql"),
                 rec("2026-10-26T23:00:00", "a"), "unrelated line"]
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "1_job.txt").write_text("\n".join(lines))
            rows = gh_call_log.rank(gh_call_log.parse(gh_call_log.log_lines([Path(tmp)])))
        self.assertEqual(rows, [("2026-10-26T22:00Z", "b", 2, 900), ("2026-10-26T22:00Z", "a", 1, 900),
                                ("2026-10-26T23:00Z", "a", 1, 10)])
        table = gh_call_log.table(rows, top=1)
        self.assertIn("| 2026-10-26T22:00Z | b | 2 | 900 |", table)
        self.assertNotIn("| a | 1 | 900", table)


if __name__ == "__main__":
    unittest.main()
