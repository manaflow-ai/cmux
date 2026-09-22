#!/usr/bin/env python3

import argparse
import importlib.util
import sys
import unittest
from pathlib import Path
from unittest import mock


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
    def test_best_effort_prune_ignores_github_rate_limit(self) -> None:
        error = MODULE.GitHubAPIError(403, '{"message":"API rate limit exceeded"}')
        with mock.patch.object(MODULE, "parse_args", return_value=args(best_effort=True)), \
                mock.patch.object(MODULE, "load_release", side_effect=error):
            self.assertEqual(MODULE.main(), 0)

    def test_strict_prune_still_fails_on_github_rate_limit(self) -> None:
        error = MODULE.GitHubAPIError(403, '{"message":"API rate limit exceeded"}')
        with mock.patch.object(MODULE, "parse_args", return_value=args(best_effort=False)), \
                mock.patch.object(MODULE, "load_release", side_effect=error):
            with self.assertRaises(MODULE.GitHubAPIError):
                MODULE.main()


if __name__ == "__main__":
    unittest.main()
