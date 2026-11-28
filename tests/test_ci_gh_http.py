#!/usr/bin/env python3
"""scripts/ci/gh_http.py: which GitHub refusals are asked again, how long each wait is, and the bounds."""

from __future__ import annotations

import os
import re
import sys
import tempfile
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
        (status, _, _), calls, slept = self.run_with([limited] * 6 + [answer(200)], rate_budget_s=gh_http.RATE_BUDGET_S)
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
                                           clock=lambda: clock[0], now=lambda: 1000.0, log=lines.append,
                                           rate_budget_s=gh_http.RATE_BUDGET_S)
        self.assertEqual(status, 403)
        self.assertEqual(clock[0], 900.0)  # waited once; a second 900 s would pass RATE_BUDGET_S
        self.assertTrue(any("rate-limited until" in line for line in lines), lines)

    def test_default_never_sleeps_past_the_callers_budget(self):
        # ios-fast plan job (timeout 5 min) was cancelled after a 329 s wait: a caller that names no
        # rate_budget_s must not sleep on a far-out reset beyond its budget_s (before: 900 s; after: 0 s).
        limited = answer(403, b'{"message":"API rate limit exceeded"}',
                         x_ratelimit_remaining="0", x_ratelimit_reset="1900")
        for kwargs, cap in (({}, gh_http.BUDGET_S), ({"budget_s": 30.0}, 30.0)):
            clock = [0.0]
            with mock.patch.object(deadline_http, "request", lambda *a, **k: limited):
                status, _, _ = gh_http.request(URL, sleep=lambda s: clock.__setitem__(0, clock[0] + s),
                                               clock=lambda: clock[0], now=lambda: 1000.0, log=lambda _: None,
                                               **kwargs)
            self.assertEqual(status, 403)
            self.assertLessEqual(clock[0], cap)
        # a reset inside the budget is still waited out
        near = answer(403, b"{}", x_ratelimit_remaining="0", x_ratelimit_reset="1050")
        (status, _, _), _, slept = self.run_with([near, answer(200)])
        self.assertEqual((status, slept), (200, [51.0]))

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


NAMED_405 = dict(x_ratelimit_remaining="0", x_ratelimit_reset="1405")  # now=1000: a 405 s named wait


class JobDeadline(unittest.TestCase):
    """cmux run 46109204066: ios-fast-verdict-dispatch's 5-min resolve logged `asking again in 405 s (try 2 of
    4)` at 04:48:16Z and GitHub cancelled the job at 04:53:22Z: a wait past the job's bound turned a readable 403
    into a silent cancel. GH_HTTP_DEADLINE_S caps every wait at the job's bound and gives up loudly instead."""

    def call(self, env, answers, started_ago=0.0):
        clock, slept, lines, calls = [100.0], [], [], []

        def fake(request, seconds, **_):
            calls.append(seconds)
            return answers[min(len(calls), len(answers)) - 1]

        def sleep(seconds):
            slept.append(seconds)
            clock[0] += seconds

        with mock.patch.dict(os.environ, env, clear=False), mock.patch.object(gh_http, "STARTED", 100.0 - started_ago), \
                mock.patch.object(deadline_http, "request", fake):
            for name in (gh_http.DEADLINE_ENV, gh_http.DEADLINE_AT_ENV):
                if name not in env:
                    os.environ.pop(name, None)
            result = gh_http.request(URL, sleep=sleep, clock=lambda: clock[0], now=lambda: 1000.0, log=lines.append)
        return result, slept, lines, calls

    def limited(self):
        return answer(403, b'{"message":"API rate limit exceeded for installation"}', **NAMED_405)

    def test_a_named_wait_past_the_job_bound_is_not_taken_and_the_give_up_is_loud(self):
        (status, _, _), slept, lines, calls = self.call({gh_http.DEADLINE_ENV: "240"}, [self.limited()])
        self.assertEqual((status, slept, len(calls)), (403, [], 1))
        self.assertTrue(any("gave up" in l and "rate-limited until" in l and gh_http.DEADLINE_ENV in l
                            for l in lines), lines)

    def test_without_a_bound_the_same_wait_is_taken(self):
        (status, _, _), slept, _, _ = self.call({}, [self.limited(), answer(200)])
        self.assertEqual((status, slept), (200, [406.0]))

    def test_a_wait_inside_the_bound_is_still_taken(self):
        (status, _, _), slept, _, _ = self.call({gh_http.DEADLINE_ENV: "240"}, [answer(502), answer(200)])
        self.assertEqual((status, slept), (200, [5.0]))

    def test_time_already_spent_in_the_process_counts(self):
        # 230 s of a 240 s bound gone: even a 15 s backoff would pass it.
        _, slept, _, _ = self.call({gh_http.DEADLINE_ENV: "240"}, [answer(502), answer(502), answer(200)],
                                   started_ago=230.0)
        self.assertEqual(sum(slept) <= 10.0, True, slept)

    def test_an_epoch_deadline_from_an_earlier_step_wins(self):
        # GH_HTTP_DEADLINE_AT=1010 with now=1000: 10 s left, whatever this process's own start.
        (status, _, _), slept, _, _ = self.call({gh_http.DEADLINE_ENV: "240", gh_http.DEADLINE_AT_ENV: "1010"},
                                                [answer(502), answer(502), answer(200)])
        self.assertEqual((status, slept), (502, [5.0]))

    def test_the_first_reader_shares_the_deadline_with_later_steps(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "github_env")
            env = {gh_http.DEADLINE_ENV: "240", "GITHUB_ENV": path}
            gh_http.share_deadline(env, now=lambda: 1000.0)
            self.assertEqual(Path(path).read_text(encoding="utf-8"), f"{gh_http.DEADLINE_AT_ENV}=1240\n")
            self.assertEqual(env[gh_http.DEADLINE_AT_ENV], "1240")
            gh_http.share_deadline(env, now=lambda: 2000.0)  # a later reader keeps the job's first clock
            self.assertEqual(Path(path).read_text(encoding="utf-8"), f"{gh_http.DEADLINE_AT_ENV}=1240\n")
        gh_http.share_deadline({"GITHUB_ENV": "/nonexistent/x"})  # no bound: nothing written, no error

    def test_a_bad_value_is_no_bound(self):
        self.assertIsNone(gh_http.deadline_left(env={gh_http.DEADLINE_ENV: "five"}))
        self.assertIsNone(gh_http.deadline_left(env={}))


ROOT = Path(__file__).resolve().parents[1]
CI = ROOT / "scripts" / "ci"


def readers() -> set[str]:
    """scripts/ci modules that read GitHub through gh_http, directly or through another reader."""
    found, texts = {"gh_http"}, {p.stem: p.read_text(encoding="utf-8") for p in CI.glob("*.py")}
    grew = True
    while grew:
        grew = False
        for stem, text in texts.items():
            if stem not in found and any(re.search(rf"^\s*(import {m}\b|from {m} import)", text, re.M) for m in found):
                found.add(stem)
                grew = True
    return found - {"gh_http"}


def bounded_jobs():
    """(workflow, job, timeout minutes, job text) for every job with a literal timeout-minutes."""
    for wf in sorted((ROOT / ".github" / "workflows").glob("*.yml")):
        lines = wf.read_text(encoding="utf-8").splitlines()
        if "jobs:" not in lines:
            continue
        starts = [i for i in range(lines.index("jobs:") + 1, len(lines)) if re.match(r"^  [A-Za-z0-9_-]+:\s*$", lines[i])]
        for k, s in enumerate(starts):
            body = "\n".join(lines[s:starts[k + 1] if k + 1 < len(starts) else len(lines)])
            m = re.search(r"^    timeout-minutes:\s*(\d+)\s*(#.*)?$", body, re.M)
            if m:
                yield wf.name, lines[s].strip(" :"), int(m.group(1)), body


class WorkflowsBoundTheirReaders(unittest.TestCase):
    def test_every_short_job_running_a_reader_sets_a_deadline_inside_its_timeout(self):
        # A job shorter than RATE_BUDGET_S (20 min) can be cancelled mid-wait; its GH_HTTP_DEADLINE_S makes
        # gh_http give up loudly first. Longer jobs outlast RATE_BUDGET_S and need none.
        # A schedule runs main's copy of its workflow, so its bound lands through a main twin PR (pre-push gate
        # "Scheduled workflows match main's"); until then it is named here, not silently skipped.
        main_only = {("ui-proof-stale-sweep.yml", "sweep")}
        mods = readers()
        self.assertIn("ios_fast_dispatch", mods)
        missing, seen = [], 0
        for wf, job, minutes, body in bounded_jobs():
            if (wf, job) in main_only or minutes * 60 > gh_http.RATE_BUDGET_S or not any(re.search(rf"\b{m}\.py\b", body) for m in mods):
                continue
            seen += 1
            m = re.search(r'^      GH_HTTP_DEADLINE_S:\s*"?(\d+)"?', body, re.M)
            if not m or not 0 < int(m.group(1)) < minutes * 60:
                missing.append(f"{wf} {job} (timeout-minutes {minutes}): GH_HTTP_DEADLINE_S {m and m.group(1)}")
        self.assertGreater(seen, 10)
        self.assertEqual(missing, [], "set job-level env GH_HTTP_DEADLINE_S to timeout-minutes*60 less 60")

    def test_the_cancelled_resolve_job_is_bounded(self):
        jobs = {(wf, job): body for wf, job, _, body in bounded_jobs()}
        self.assertIn('GH_HTTP_DEADLINE_S: "240"', jobs[("ios-fast-verdict-dispatch.yml", "resolve")])


if __name__ == "__main__":
    unittest.main()
