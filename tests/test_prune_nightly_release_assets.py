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


class NightlyPruneFrozenFeedTests(unittest.TestCase):
    """Nightly is arm64 only; the last x86_64 and universal build backs frozen feeds."""

    @staticmethod
    def assets() -> list:
        prefix = "cmux-nightly-macos-"
        names = []
        # Builds 1-10 shipped every variant; 11-200 ship arm64 only.
        for build in range(1, 11):
            names += [f"{prefix}{variant}-{build}.dmg" for variant in ("arm64", "x86_64", "universal")]
            names.append(f"{prefix}x86_64-{build}-{build - 1}.delta")
        for build in range(11, 201):
            names.append(f"{prefix}arm64-{build}.dmg")
        names.append(f"cmuxd-remote-manifest-10.json")
        return [
            MODULE.ReleaseAsset(asset_id=index, name=name, build=MODULE.extract_build(name))
            for index, name in enumerate(names)
        ]

    def test_newest_x86_64_and_universal_build_is_never_pruned(self) -> None:
        assets = self.assets()
        self.assertEqual(MODULE.frozen_feed_builds(assets), {10})
        to_delete, _ = MODULE.partition_assets(assets, 100, len(assets) + 4, 950)
        deleted = {asset.name for asset in to_delete}
        for name in (
            "cmux-nightly-macos-x86_64-10.dmg",
            "cmux-nightly-macos-universal-10.dmg",
            "cmux-nightly-macos-x86_64-10-9.delta",
            "cmux-nightly-macos-arm64-10.dmg",
            "cmuxd-remote-manifest-10.json",
        ):
            self.assertNotIn(name, deleted)
        self.assertIn("cmux-nightly-macos-x86_64-9.dmg", deleted)
        self.assertIn("cmux-nightly-macos-arm64-100.dmg", deleted)
        self.assertNotIn("cmux-nightly-macos-arm64-101.dmg", deleted)

    def test_asset_cap_skips_frozen_build(self) -> None:
        assets = self.assets()
        kept = [asset for asset in assets if asset.build >= 101 or asset.build == 10]
        to_delete, _ = MODULE.partition_assets(kept, 100, len(kept), 50)
        self.assertNotIn(10, {asset.build for asset in to_delete})


if __name__ == "__main__":
    unittest.main()
