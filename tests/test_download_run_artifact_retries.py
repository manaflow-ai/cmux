#!/usr/bin/env python3
"""scripts/ci/download-run-artifact.py waits through a refused GitHub call instead of failing.

Run 40378565252 (2026-10-26): the prepare job's parallel download got HTTP 403 (the
installation's secondary limit, no rate-limit headers) on the artifact lookup, so the job fell
back to actions/download-artifact's single connection and spent 611 s fetching the unsigned app.
"""
import email.message
import importlib.util
from pathlib import Path
import unittest
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
        download.sleep = self.slept.append
        download.waited_seconds = 0.0
        self.addCleanup(setattr, download, "waited_seconds", 0.0)

    def flaky(self, errors: list[Exception], result: str = "ok"):
        def call() -> str:
            if errors:
                raise errors.pop(0)
            return result
        return call

    def test_a_secondary_limit_403_without_headers_is_retried_with_backoff(self) -> None:
        call = self.flaky([refused(403), refused(403), refused(502)])
        self.assertEqual(download.with_retries(call, "lookup"), "ok")
        self.assertEqual(self.slept, [10.0, 20.0, 40.0])

    def test_retry_after_and_the_limit_reset_are_honoured(self) -> None:
        call = self.flaky([refused(429, Retry_After="7")])
        self.assertEqual(download.with_retries(call, "lookup"), "ok")
        self.assertEqual(self.slept, [7.0])

    def test_the_budget_is_shared_and_bounded(self) -> None:
        download.waited_seconds = download.RETRY_BUDGET_SECONDS - 5
        with self.assertRaises(urllib.error.HTTPError):
            download.with_retries(self.flaky([refused(403)]), "lookup")
        self.assertEqual(self.slept, [])

    def test_a_not_found_is_never_retried(self) -> None:
        with self.assertRaises(urllib.error.HTTPError):
            download.with_retries(self.flaky([refused(404)]), "lookup")
        self.assertEqual(self.slept, [])


if __name__ == "__main__":
    unittest.main()
