"""The feat-cmux-next headless debug cmux-tui is saved where conformance reads it.

cmux-tui-headless-debug.yml builds the daemon cmux-tui-sdks.yml's live
conformance job runs against, once per key, on feat-cmux-next. It only helps
if both compute the same key, cache the same path, and run on the same runner
and toolchains; a drift makes every pull request compile it again, silently.
"""

from __future__ import annotations

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


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
        self.consumer = load("cmux-tui-sdks.yml")["jobs"]["conformance"]

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
        self.assertIn("./.github/actions/setup-cmux-tui-rust", [s.get("uses") for s in self.producer["steps"]])

    def test_it_runs_on_the_runner_a_same_repository_pull_request_uses(self) -> None:
        # The key names RUNNER_OS and RUNNER_ARCH only, so the runner type
        # must be the one conformance picks for a same-repository pull request.
        self.assertIn("vars.LINUX_RUNNER || 'blacksmith-8vcpu-ubuntu-2404'", self.consumer["runs-on"])
        self.assertEqual(self.producer["runs-on"], "${{ vars.LINUX_RUNNER || 'blacksmith-8vcpu-ubuntu-2404' }}")

    def test_only_feat_cmux_next_pushes_and_dispatches_save_it(self) -> None:
        triggers = self.producer_doc[True]  # YAML 1.1 reads `on` as true.
        self.assertEqual(sorted(triggers), ["push", "workflow_dispatch"])
        self.assertEqual(triggers["push"]["branches"], ["feat-cmux-next"])
        self.assertIn("cmux-tui/**", triggers["push"]["paths"])
        self.assertEqual(self.producer_doc["permissions"], {"contents": "read"})


if __name__ == "__main__":
    unittest.main()
