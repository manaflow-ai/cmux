#!/usr/bin/env python3

import argparse
import importlib.util
import re
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


def next_release(builds: list[int], *, source_only: tuple[int, ...] = ()) -> list:
    """nightly-next assets: per build three dmgs, one delta, the daemon manifest
    and the cmux-next source archive that the app's MPL-2.0 offer names."""
    raw = []
    next_id = 1
    for build in builds:
        names = [f"cmux-next-source-{build}.tar.gz"]
        if build not in source_only:
            names += [
                f"cmux-next-macos-{build}.dmg",
                f"cmux-next-macos-arm64-{build}.dmg",
                f"cmux-next-macos-x86_64-{build}.dmg",
                f"cmux-next-macos-arm64-{build}-{build - 1}.delta",
                f"cmuxd-remote-manifest-{build}.json",
            ]
        for name in names:
            raw.append({"id": next_id, "name": name})
            next_id += 1
    return raw


class SourceArchiveRetentionTests(unittest.TestCase):
    """A source archive goes only together with the app binaries that name it.

    Each nightly-next app offers the Ghostty Zig package sources (MPL-2.0
    section 3.2(a)) in cmux-next-source-<build>.tar.gz on the same release. The
    archive must stay while any app asset of its build stays, and it is never
    deleted by age.
    """

    PATTERNS = MODULE.immutable_asset_patterns("cmux-next-macos-")

    def plan(self, raw: list, keep_builds: int, max_assets: int = 950) -> list:
        assets, _ = MODULE.collect_immutable_assets({"assets": raw}, self.PATTERNS)
        to_delete, _ = MODULE.partition_assets(assets, keep_builds, len(raw), max_assets)
        return to_delete

    def test_source_archive_is_an_asset_of_its_build(self) -> None:
        self.assertEqual(MODULE.extract_build("cmux-next-source-1234.tar.gz", self.PATTERNS), 1234)
        self.assertIsNone(MODULE.extract_build("cmux-next-source-abc.tar.gz", self.PATTERNS))
        self.assertTrue(MODULE.is_source_archive("cmux-next-source-1234.tar.gz"))
        self.assertFalse(MODULE.is_source_archive("cmux-next-macos-1234.dmg"))

    def test_the_daemon_notice_is_an_asset_of_its_build(self) -> None:
        # cmuxd-remote-THIRD_PARTY_LICENSES-<build>.txt goes with its binaries.
        self.assertEqual(MODULE.extract_build("cmuxd-remote-THIRD_PARTY_LICENSES-1234.txt", self.PATTERNS), 1234)

    def test_pruned_build_takes_its_source_archive_and_kept_builds_keep_theirs(self) -> None:
        deleted = {asset.name for asset in self.plan(next_release([1, 2, 3]), keep_builds=2)}
        self.assertIn("cmux-next-source-1.tar.gz", deleted)
        self.assertIn("cmux-next-macos-arm64-1.dmg", deleted)
        self.assertNotIn("cmux-next-source-2.tar.gz", deleted)
        self.assertNotIn("cmux-next-source-3.tar.gz", deleted)

    def test_asset_cap_prunes_whole_builds_with_their_source(self) -> None:
        raw = next_release([10, 11, 12, 13])
        to_delete = self.plan(raw, keep_builds=100, max_assets=len(raw) - 1)
        self.assertEqual({asset.build for asset in to_delete}, {10})
        self.assertIn("cmux-next-source-10.tar.gz", {asset.name for asset in to_delete})

    def test_source_archive_is_deleted_after_every_app_asset_of_its_build(self) -> None:
        # An interrupted pass (rate limit) then leaves an orphan archive, never
        # an app with no archive.
        to_delete = self.plan(next_release([1, 2, 3, 4]), keep_builds=2)
        for build in (1, 2):
            names = [asset.name for asset in to_delete if asset.build == build]
            self.assertEqual(names[-1], f"cmux-next-source-{build}.tar.gz", names)

    def test_retention_check_refuses_a_source_delete_that_leaves_app_assets(self) -> None:
        raw = next_release([1, 2])
        assets, _ = MODULE.collect_immutable_assets({"assets": raw}, self.PATTERNS)
        bad = [asset for asset in assets if asset.name in {
            "cmux-next-source-1.tar.gz", "cmux-next-macos-1.dmg"}]
        with self.assertRaises(RuntimeError) as raised:
            MODULE.check_source_archive_retention(assets, bad)
        self.assertIn("cmux-next-source-1.tar.gz", str(raised.exception))
        whole = [asset for asset in assets if asset.build == 1]
        MODULE.check_source_archive_retention(assets, whole)

    def test_only_the_count_and_cap_rules_delete(self) -> None:
        # No age rule: with room to spare nothing goes, however old.
        self.assertEqual(self.plan(next_release([1, 2, 3]), keep_builds=100), [])
        usage = subprocess.run(
            [sys.executable, str(ROOT / "scripts/prune_nightly_release_assets.py"), "--help"],
            capture_output=True, text=True, check=True,
        ).stdout
        options = set(re.findall(r"--[a-z][a-z-]*", usage))
        self.assertTrue(options, usage)
        for option in options:
            self.assertNotRegex(option, r"age|day|hour|time|older", option)


if __name__ == "__main__":
    unittest.main()
