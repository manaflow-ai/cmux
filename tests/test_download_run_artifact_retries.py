#!/usr/bin/env python3
"""scripts/ci/download-run-artifact.py waits through a refused GitHub call instead of failing.

Run 40378565252 (2026-10-26): the prepare job's parallel download got HTTP 403 (the
installation's secondary limit, no rate-limit headers) on the artifact lookup, so the job fell
back to actions/download-artifact's single connection and spent 611 s fetching the unsigned app.
"""
import email.message
import email.utils
import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest import mock
import urllib.error

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("artifact_download", ROOT / "scripts/ci/download-run-artifact.py")
download = importlib.util.module_from_spec(spec)
spec.loader.exec_module(download)


def refused(code: int, **headers: str) -> urllib.error.HTTPError:
    message = email.message.Message()
    for key, value in headers.items():
        message[key.replace("_", "-")] = value
    return urllib.error.HTTPError("https://api.github.invalid/x", code, "refused", message, None)


class RetryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.slept: list[float] = []
        self.now = [1000.0]

        def fake_sleep(seconds: float) -> None:
            self.slept.append(seconds)
            self.now[0] += seconds

        for name, value in (("sleep", fake_sleep), ("clock", lambda: self.now[0])):
            patcher = mock.patch.object(download, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        download.retry_deadline = None
        self.addCleanup(setattr, download, "retry_deadline", None)

    def flaky(self, errors: list[Exception], result: str = "ok"):
        def call() -> str:
            if errors:
                raise errors.pop(0)
            return result
        return call

    def test_a_secondary_limit_403_without_headers_is_retried_with_backoff(self) -> None:
        call = self.flaky([refused(403), refused(403), refused(502), refused(501)])
        self.assertEqual(download.with_retries(call, "lookup"), "ok")
        self.assertEqual(self.slept, [10.0, 20.0, 40.0, 80.0])

    def test_retry_after_seconds_and_date_and_the_limit_reset_are_honoured(self) -> None:
        now = 1_800_000_000.0
        self.assertEqual(download.retry_wait(refused(429, Retry_After="7"), 1, now), 7.0)
        date = email.utils.formatdate(now + 30, usegmt=True)
        self.assertEqual(download.retry_wait(refused(429, Retry_After=date), 1, now), 30.0)
        reset = refused(403, X_RateLimit_Remaining="0", X_RateLimit_Reset=str(int(now + 44)))
        self.assertEqual(download.retry_wait(reset, 1, now), 45.0)

    def test_a_persistent_refusal_stops_after_max_attempts(self) -> None:
        self.assertEqual(download.retry_wait(refused(429, Retry_After="0"), 1), 1.0)
        calls = []

        def always():
            calls.append(1)
            raise refused(429, Retry_After="0")

        with self.assertRaises(urllib.error.HTTPError):
            download.with_retries(always, "lookup")
        self.assertEqual(len(calls), download.MAX_ATTEMPTS)

    def test_slow_calls_count_against_the_wall_clock_deadline(self) -> None:
        def slow_refusal():
            self.now[0] += 100  # each refused call itself takes 100 s
            raise refused(403)

        with self.assertRaises(urllib.error.HTTPError):
            download.with_retries(slow_refusal, "lookup")
        # Started at 1000; no retry may begin after the deadline.
        self.assertLessEqual(self.now[0] - 1000.0, download.RETRY_BUDGET_SECONDS + 100)

    def test_a_not_found_is_never_retried(self) -> None:
        with self.assertRaises(urllib.error.HTTPError):
            download.with_retries(self.flaky([refused(404)]), "lookup")
        self.assertEqual(self.slept, [])


class CallSiteTests(unittest.TestCase):
    """api_json and blob_url go through the retry, and share one deadline."""

    def setUp(self) -> None:
        self.slept: list[float] = []
        self.now = [1000.0]

        def fake_sleep(seconds: float) -> None:
            self.slept.append(seconds)
            self.now[0] += seconds

        for name, value in (("sleep", fake_sleep), ("clock", lambda: self.now[0])):
            patcher = mock.patch.object(download, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        download.retry_deadline = None
        self.addCleanup(setattr, download, "retry_deadline", None)

    def test_the_lookup_retries_a_403_then_returns_the_listing(self) -> None:
        body = json.dumps({"artifacts": [{"name": "app", "expired": False, "created_at": "1"}]}).encode()
        responses = [refused(403), io.BytesIO(body)]

        class Response(io.BytesIO):
            def __enter__(self): return self
            def __exit__(self, *exc): return False

        def urlopen(req, timeout):
            item = responses.pop(0)
            if isinstance(item, Exception):
                raise item
            return Response(item.getvalue())

        with mock.patch.object(download.urllib.request, "urlopen", urlopen):
            artifact = download.find_artifact("o/r", "1", "app", "token")
        self.assertEqual(artifact["name"], "app")
        self.assertEqual(self.slept, [10.0])

    def test_the_redirect_retries_a_refusal_and_a_missing_redirect_still_exits(self) -> None:
        redirect = refused(302, Location="https://blob.invalid/archive.zip")
        outcomes = [refused(403), redirect]

        class Opener:
            def open(self, req, timeout):
                item = outcomes.pop(0)
                if item is None:
                    return None
                raise item

        with mock.patch.object(download.urllib.request, "build_opener", lambda *a: Opener()):
            self.assertEqual(download.blob_url({"archive_download_url": "https://api.invalid/zip"}, "t"),
                             "https://blob.invalid/archive.zip")
            outcomes.append(None)
            with self.assertRaises(SystemExit):
                download.blob_url({"archive_download_url": "https://api.invalid/zip"}, "t")

    def test_the_lookup_and_the_redirect_share_one_deadline(self) -> None:
        def lookup_refusal():
            self.now[0] += download.RETRY_BUDGET_SECONDS  # the lookup's retries use up the budget
            raise refused(403)

        with self.assertRaises(urllib.error.HTTPError):
            download.with_retries(lookup_refusal, "lookup")
        self.slept.clear()

        class Opener:
            def open(self, req, timeout):
                raise refused(403)

        with mock.patch.object(download.urllib.request, "build_opener", lambda *a: Opener()):
            with self.assertRaises(urllib.error.HTTPError):
                download.blob_url({"archive_download_url": "https://api.invalid/zip"}, "t")
        self.assertEqual(self.slept, [], "the redirect retried after the lookup spent the deadline")


if __name__ == "__main__":
    unittest.main()
