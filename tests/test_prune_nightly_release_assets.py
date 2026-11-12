#!/usr/bin/env python3

import argparse
import importlib.util
import sys
import subprocess
import unittest
from pathlib import Path
from unittest import mock
from urllib.error import HTTPError


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "prune_nightly_release_assets", ROOT / "scripts/prune_nightly_release_assets.py"
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def args(*, best_effort: bool) -> argparse.Namespace:
    return argparse.Namespace(
        keep_builds=100,
        max_assets=950,
        repo="manaflow-ai/cmux",
        release_tag="nightly",
        name_prefix="cmux-nightly-macos-",
        execute=True,
        best_effort=best_effort,
    )


class NightlyPruneRateLimitTests(unittest.TestCase):
    def test_github_api_retries_transient_503_then_returns_json(self) -> None:
        responses = [
            HTTPError("https://api.github.com", 503, "unavailable", {}, None),
            {"assets": []},
        ]

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def read(self):
                return b'{"assets": []}'

        def fake_urlopen(request, timeout=None):
            response = responses.pop(0)
            if isinstance(response, Exception):
                raise response
            return FakeResponse()

        # Pin the retry knobs so an inherited override cannot change the path.
        env = {
            "GH_TOKEN": "test-token",
            "CMUX_NIGHTLY_GITHUB_API_MAX_ATTEMPTS": "4",
            "CMUX_NIGHTLY_GITHUB_API_RETRY_DELAY_SECONDS": "2",
        }
        with mock.patch.object(MODULE.urllib.request, "urlopen", side_effect=fake_urlopen), \
                mock.patch.object(MODULE.time, "sleep") as sleep, \
                mock.patch.dict(MODULE.os.environ, env, clear=False):
            self.assertEqual(MODULE.github_api_json("GET", "repos/o/r/releases"), {"assets": []})
        self.assertEqual(sleep.call_count, 1)

    def test_github_api_does_not_retry_permission_failure(self) -> None:
        error = HTTPError("https://api.github.com", 403, "forbidden", {}, None)
        with mock.patch.object(MODULE.urllib.request, "urlopen", side_effect=error) as urlopen, \
                mock.patch.object(MODULE.time, "sleep") as sleep, \
                mock.patch.dict(MODULE.os.environ, {"GH_TOKEN": "test-token"}, clear=False):
            with self.assertRaises(MODULE.GitHubAPIError) as raised:
                MODULE.github_api_json("GET", "repos/o/r/releases")
        self.assertEqual(raised.exception.status, 403)
        self.assertEqual(urlopen.call_count, 1)
        sleep.assert_not_called()

    def test_best_effort_prune_ignores_github_rate_limit(self) -> None:
        error = MODULE.GitHubAPIError(403, '{"message":"API rate limit exceeded"}')
        with mock.patch.object(MODULE, "parse_args", return_value=args(best_effort=True)), \
                mock.patch.object(MODULE, "load_release", side_effect=error):
            self.assertEqual(MODULE.main(), 0)

    def test_best_effort_prune_ignores_gh_rate_limit(self) -> None:
        error = subprocess.CalledProcessError(
            1,
            ["gh", "api"],
            stderr="HTTP 403: API rate limit exceeded",
        )
        with mock.patch.object(MODULE, "parse_args", return_value=args(best_effort=True)), \
                mock.patch.object(MODULE, "load_release", side_effect=error):
            self.assertEqual(MODULE.main(), 0)

    def test_best_effort_delete_ignores_gh_rate_limit(self) -> None:
        error = subprocess.CalledProcessError(
            1,
            ["gh", "api", "-X", "DELETE"],
            stderr="HTTP 429: API rate limit exceeded",
        )
        parsed = args(best_effort=True)
        parsed.keep_builds = 1
        parsed.max_assets = 1
        release = {
            "assets": [
                {"id": 1, "name": "cmux-nightly-macos-1.dmg"},
                {"id": 2, "name": "cmux-nightly-macos-2.dmg"},
            ]
        }
        with mock.patch.object(MODULE, "parse_args", return_value=parsed), \
                mock.patch.object(MODULE, "load_release", return_value=release), \
                mock.patch.object(MODULE, "delete_assets", side_effect=error):
            self.assertEqual(MODULE.main(), 0)

    def test_strict_prune_still_fails_on_github_rate_limit(self) -> None:
        error = MODULE.GitHubAPIError(403, '{"message":"API rate limit exceeded"}')
        with mock.patch.object(MODULE, "parse_args", return_value=args(best_effort=False)), \
                mock.patch.object(MODULE, "load_release", side_effect=error):
            with self.assertRaises(MODULE.GitHubAPIError):
                MODULE.main()


if __name__ == "__main__":
    unittest.main()
