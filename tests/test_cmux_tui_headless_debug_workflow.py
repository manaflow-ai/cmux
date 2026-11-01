"""The feat-cmux-next headless debug cmux-tui is saved where conformance reads it.

cmux-tui-headless-debug.yml builds the daemon cmux-tui-sdks.yml's live
conformance job runs against, once per key, on feat-cmux-next. It only helps
if both compute the same key, cache the same path, and run on the same runner
and toolchains; a drift makes every pull request compile it again, silently.
"""

from __future__ import annotations

import unittest
from pathlib import Path
import sys

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
from blacksmith_linux_sizes import blacksmith_route  # noqa: E402


def load(name: str) -> dict:
    return yaml.safe_load((ROOT / ".github" / "workflows" / name).read_text(encoding="utf-8"))


def step(job: dict, name: str) -> dict:
    for item in job["steps"]:
        if item.get("name") == name:
            return item
    raise AssertionError(f"no step {name!r}")


def zig_versions(job: dict) -> list[str]:
    return [str(s["with"]["version"]) for s in job["steps"] if str(s.get("uses", "")).startswith("mlugg/setup-zig@")]


class HeadlessDebugDaemon(unittest.TestCase):
    def setUp(self) -> None:
        self.producer_doc = load("cmux-tui-headless-debug.yml")
        self.producer = self.producer_doc["jobs"]["build"]
        self.consumer_doc = load("cmux-tui-sdks.yml")
        self.consumer = self.consumer_doc["jobs"]["conformance"]

    def test_the_key_and_path_match_conformance(self) -> None:
        key = "Key the headless cmux-tui build"
        self.assertEqual(step(self.producer, key)["run"], step(self.consumer, key)["run"])
        restore = step(self.consumer, "Restore the headless cmux-tui build")["with"]
        save = step(self.producer, "Save the headless cmux-tui build")["with"]
        self.assertEqual(save["path"], restore["path"])
        self.assertEqual(save["key"], restore["key"])

    def test_the_build_and_toolchains_match_conformance(self) -> None:
        build = "Build exact headless cmux-tui"
        self.assertEqual(step(self.producer, build)["run"], step(self.consumer, build)["run"])
        self.assertEqual(step(self.producer, build)["working-directory"], step(self.consumer, build)["working-directory"])
        # Ghostty's zig is the first one conformance installs; the second is the SDKs'.
        self.assertEqual(zig_versions(self.producer), zig_versions(self.consumer)[:1])
        self.assertEqual(self.producer["env"]["GHOSTTY_ZIG_SOURCE"], self.consumer["env"]["GHOSTTY_ZIG_SOURCE"])
        # An inherited CMUX_GHOSTTY_SRC would build another libghostty-vt
        # source under the gitlink-derived key.
        self.assertEqual(self.producer_doc["env"]["CMUX_GHOSTTY_SRC"], "")
        self.assertEqual(self.consumer_doc["env"]["CMUX_GHOSTTY_SRC"], "")
        self.assertIn("./.github/actions/setup-cmux-tui-rust", [s.get("uses") for s in self.producer["steps"]])

    def test_it_runs_on_the_runner_a_same_repository_pull_request_uses(self) -> None:
        # The key names RUNNER_OS and RUNNER_ARCH only, so the runner type
        # must be the one conformance picks for a same-repository pull request.
        trusted = ("!startsWith(vars.LINUX_RUNNER, 'blacksmith-') && vars.LINUX_RUNNER || "
                   + blacksmith_route("cmux-tui-sdks.yml", "conformance") + " }}")
        # The two jobs share one Blacksmith size (.github/runners.json linux_sizes).
        self.assertEqual(blacksmith_route("cmux-tui-sdks.yml", "conformance"),
                         blacksmith_route("cmux-tui-headless-debug.yml", "build"))
        self.assertTrue(self.consumer["runs-on"].endswith("|| " + trusted), self.consumer["runs-on"])
        self.assertEqual(self.producer["runs-on"], "${{ " + trusted)

    def test_a_pull_request_builds_incrementally_from_the_feat_target_dir(self) -> None:
        # The exact-binary key names the whole cmux-tui tree, so a pull request that
        # changes cmux-tui never hits it and compiled the workspace and Ghostty cold
        # (about 309 s of the 7 min job). feat-cmux-next keeps the target dir under one
        # shared key; conformance restores it read-only and rebuilds only what changed.
        def target_cache(job: dict) -> dict:
            names = [s.get("name") for s in job["steps"]]
            cache = step(job, "Cache the cmux-tui target dir")
            self.assertTrue(str(cache.get("uses", "")).startswith("Swatinem/rust-cache@"))
            self.assertLess(names.index("Cache the cmux-tui target dir"), names.index("Build exact headless cmux-tui"))
            self.assertEqual(cache.get("if"), "${{ steps.headless-cache.outputs.cache-hit != 'true' }}")
            return cache["with"]

        produced, consumed = target_cache(self.producer), target_cache(self.consumer)
        for field in ("workspaces", "shared-key", "cache-workspace-crates"):
            self.assertEqual(produced[field], consumed[field], field)
        self.assertEqual(produced["workspaces"], "cmux-tui -> target")
        self.assertEqual(str(produced["cache-workspace-crates"]).lower(), "true")
        self.assertNotIn("save-if", produced)
        # Pull request caches stay read-only, like the exact binary's.
        self.assertIs(consumed["save-if"], False)

    def test_only_feat_cmux_next_pushes_and_dispatches_save_it(self) -> None:
        triggers = self.producer_doc[True]  # YAML 1.1 reads `on` as true.
        self.assertEqual(sorted(triggers), ["push", "workflow_dispatch"])
        self.assertEqual(triggers["push"]["branches"], ["feat-cmux-next"])
        self.assertIn("cmux-tui/**", triggers["push"]["paths"])
        self.assertEqual(self.producer_doc["permissions"], {"contents": "read"})


if __name__ == "__main__":
    unittest.main()
