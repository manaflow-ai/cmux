#!/usr/bin/env python3
"""scripts/ci/gh_http.py: which GitHub refusals are asked again, how long each wait is, and the bounds."""

from __future__ import annotations

import sys
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "ci"))

import deadline_http  # noqa: E402
import gh_http  # noqa: E402

URL = "https://api.github.com/repos/o/r/pulls/1"


def answer(status: int, body: bytes = b"{}", **headers: str):
    return status, body, deadline_http.Headers({k.replace("_", "-").lower(): v for k, v in headers.items()})


class RefusalWait(unittest.TestCase):
    def wait(self, status, body=b"", attempt=0, now=1000.0, **headers):
        _, _, parsed = answer(status, body, **headers)
        return gh_http.refusal_wait(status, parsed, body, attempt, now)

    def test_answers_asking_again_cannot_change(self):
        for status in (200, 201, 204, 301, 400, 401, 404, 409, 422):
            self.assertIsNone(self.wait(status), status)
        self.assertIsNone(self.wait(403, b'{"message": "Resource not accessible by integration"}'))

    def test_rate_limits_and_server_errors_wait(self):
        self.assertEqual(self.wait(429), 5.0)
        self.assertEqual(self.wait(502, attempt=1), 15.0)
        self.assertEqual(self.wait(503, attempt=5), 30.0)
        self.assertEqual(self.wait(403, b'{"message": "API rate limit exceeded for installation"}'), 5.0)
        self.assertEqual(self.wait(403, b"You have triggered an abuse detection mechanism"), 5.0)

    def test_retry_after_and_reset_are_honored_and_capped(self):
        self.assertEqual(self.wait(403, retry_after="7"), 7.0)
        self.assertEqual(self.wait(429, retry_after="600"), 600.0)
        self.assertEqual(self.wait(429, retry_after="99999"), gh_http.RATE_MAX_WAIT_S)
        self.assertEqual(self.wait(403, x_ratelimit_remaining="0", x_ratelimit_reset="1020"), 21.0)
        self.assertEqual(self.wait(403, x_ratelimit_remaining="0", x_ratelimit_reset="9000"), gh_http.RATE_MAX_WAIT_S)
        self.assertEqual(self.wait(403, x_ratelimit_remaining="0", x_ratelimit_reset="10"), 1.0)


class Request(unittest.TestCase):
    def run_with(self, answers, req=URL, **kwargs):
        """gh_http.request with deadline_http.request answering ANSWERS in turn (an exception is raised) on a
        fake clock that sleep advances."""
        clock = [0.0]
        calls, slept = [], []

        def fake(request, seconds, **_):
            calls.append((request.get_method(), seconds))
            item = answers[len(calls) - 1]
            if isinstance(item, BaseException):
                raise item
            return item

        def sleep(seconds):
            slept.append(seconds)
            clock[0] += seconds

        with mock.patch.object(deadline_http, "request", fake):
            result = gh_http.request(req, sleep=sleep, clock=lambda: clock[0], now=lambda: 1000.0,
                                     log=lambda _: None, **kwargs)
        return result, calls, slept

    def test_a_passing_refusal_is_asked_again(self):
        (status, body, _), calls, slept = self.run_with(
            [answer(403, b'{"message":"API rate limit exceeded"}'), answer(502), answer(200, b'{"ok":1}')])
        self.assertEqual((status, body), (200, b'{"ok":1}'))
        self.assertEqual(len(calls), 3)
        self.assertEqual(slept, [5.0, 15.0])

    def test_a_lasting_refusal_is_answered_at_once(self):
        for status in (401, 404):
            (got, _, _), calls, slept = self.run_with([answer(status)])
            self.assertEqual((got, len(calls), slept), (status, 1, []))
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.run_with([answer(403, b'{"message":"Must have admin rights"}')], raise_errors=True)
        self.assertEqual(caught.exception.code, 403)

    def test_tries_are_bounded_and_the_last_answer_returned(self):
        (status, _, _), calls, slept = self.run_with([answer(503)] * 10)
        self.assertEqual(status, 503)
        self.assertEqual(len(calls), gh_http.TRIES)
        self.assertEqual(slept, [5.0, 15.0, 30.0])
        with self.assertRaises(urllib.error.HTTPError):
            self.run_with([answer(503)] * 10, raise_errors=True)

    def test_a_wait_past_the_budget_is_not_taken(self):
        (status, _, _), calls, slept = self.run_with([answer(503)] * 4, budget_s=10)
        self.assertEqual(status, 503)
        self.assertEqual(slept, [5.0])
        self.assertEqual(len(calls), 2)

    def test_a_named_rate_limit_is_waited_out_past_the_tries(self):
        # cmux run 46019347396: an installation limit gave up after 2 tries and 60 s. Here reset is 100 s out
        # (now=1000): wait to it, beyond TRIES, and succeed.
        limited = answer(403, b'{"message":"API rate limit exceeded for installation"}',
                         x_ratelimit_remaining="0", x_ratelimit_reset="1100")
        (status, _, _), calls, slept = self.run_with([limited] * 6 + [answer(200)])
        self.assertEqual(status, 200)
        self.assertGreater(len(calls), gh_http.TRIES)
        self.assertTrue(all(w == 101.0 for w in slept), slept)

    def test_rate_budget_zero_gives_up_on_a_long_named_limit_at_once(self):
        # A caller with another token (proof_record.with_tokens) asks for no long rate wait: before, the 5-min
        # `ios fast verdict status` job slept 900 s here and was cancelled at its timeout.
        limited = answer(403, b'{"message":"API rate limit exceeded for installation"}',
                         x_ratelimit_remaining="0", x_ratelimit_reset="1900")
        (status, _, _), calls, slept = self.run_with([limited] * 3, rate_budget_s=0)
        self.assertEqual(status, 403)
        self.assertEqual(len(calls), 1)
        self.assertEqual(slept, [])

    def test_a_rate_limit_past_the_budget_gives_up_naming_when_it_ends(self):
        limited = answer(403, b'{"message":"API rate limit exceeded for installation"}',
                         x_ratelimit_remaining="0", x_ratelimit_reset="1900")
        lines = []
        clock = [0.0]
        with mock.patch.object(deadline_http, "request", lambda *a, **k: limited):
            status, _, _ = gh_http.request(URL, sleep=lambda s: clock.__setitem__(0, clock[0] + s),
                                           clock=lambda: clock[0], now=lambda: 1000.0, log=lines.append)
        self.assertEqual(status, 403)
        self.assertEqual(clock[0], 900.0)  # waited once; a second 900 s would pass RATE_BUDGET_S
        self.assertTrue(any("rate-limited until" in line for line in lines), lines)

    def test_limited_until_names_the_end(self):
        _, _, parsed = answer(403, x_ratelimit_remaining="0", x_ratelimit_reset="3600")
        self.assertEqual(gh_http.limited_until(parsed, 3000.0), "01:00Z")
        self.assertIsNone(gh_http.limited_until(answer(403)[2], 3000.0))

    def test_network_errors_are_asked_again_then_raised(self):
        (status, _, _), calls, _ = self.run_with([urllib.error.URLError("reset"), TimeoutError(), answer(200)])
        self.assertEqual((status, len(calls)), (200, 3))
        with self.assertRaises(urllib.error.URLError):
            self.run_with([urllib.error.URLError("down")] * 4)

    def test_a_write_is_sent_once(self):
        post = urllib.request.Request(URL, data=b"{}", method="POST")
        (status, _, _), calls, slept = self.run_with([answer(502), answer(201)], req=post)
        self.assertEqual((status, len(calls), slept), (502, 1, []))
        with self.assertRaises(TimeoutError):
            self.run_with([TimeoutError(), answer(201)], req=post)

    def test_a_later_try_never_outlasts_the_budget(self):
        _, calls, _ = self.run_with([answer(500), answer(200)], budget_s=20)
        self.assertEqual(calls[0][1], gh_http.CALL_S)
        self.assertEqual(calls[1][1], 15.0)  # 20 s budget, 5 s waited


if __name__ == "__main__":
    unittest.main()
