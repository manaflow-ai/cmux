#!/usr/bin/env python3
"""A media tour never waits for feat-cmux-next to publish its cmux-tui tree.

When a merge changes cmux-tui, its tree publishes only after every target of
cmux-tui-artifacts builds: 45 min for 6c4456b782d9 (run 39311342536). Each
tour whose merge base was that commit waited in reload.sh for it, ~37 min
(jobs 118261657253, 118263198175). The tour's "Use a published cmux-tui tree"
step now gives the base build the newest published tree in the merge base's
history, and the head build the same tree when the pull request changes no
cmux-tui tree input, so before and after still run one daemon. A head that
changes cmux-tui keeps its own tree, and a published base tree is used as is.
The step's shell runs here against a fake pin-cmux-tui.sh.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-next-media.yml"
STEP = "Use a published cmux-tui tree for an unpublished base"

FAKE_PIN = """#!/usr/bin/env bash
# key: this checkout's tree key; resolve-newest-published: lines like the real one.
case "$1" in
  key) cat "$(dirname "$0")/key" ;;
  resolve-newest-published)
    [ -f "$(dirname "$0")/newest" ] || { echo "no published tree" >&2; exit 1; }
    cat "$(dirname "$0")/newest" ;;
  *) exit 2 ;;
esac
"""


def checkout(path: Path, key: str, newest: str | None = None) -> None:
    pin = path / "scripts" / "cmux-next"
    pin.mkdir(parents=True)
    (pin / "pin-cmux-tui.sh").write_text(FAKE_PIN)
    os.chmod(pin / "pin-cmux-tui.sh", 0o755)
    (pin / "key").write_text(key + "\n")
    if newest is not None:
        (pin / "newest").write_text(newest)


def resolved(key: str, behind: int) -> str:
    return f"commit=c\nkey={key}\nsource_commit={'9' * 40}\ntip_key=t\nbehind={behind}\nbehind_hours=1\n"


class TreeFallbackTest(unittest.TestCase):
    def setUp(self) -> None:
        steps = {s.get("name"): s for s in yaml.safe_load(WORKFLOW.read_text())["jobs"]["tour"]["steps"]}
        self.assertIn(STEP, steps)
        self.step = steps[STEP]
        self.tmp = Path(tempfile.mkdtemp())
        self.workspace = self.tmp / "ws"
        self.base = self.tmp / "runner" / "cmux-next-base"

    def run_step(self) -> dict[str, str]:
        env_file = self.tmp / "env"
        env_file.write_text("")
        env = dict(os.environ, GITHUB_WORKSPACE=str(self.workspace), RUNNER_TEMP=str(self.tmp / "runner"),
                   GITHUB_ENV=str(env_file), GITHUB_STEP_SUMMARY=str(self.tmp / "summary"))
        result = subprocess.run(["bash", "-c", self.step["run"]], cwd=self.workspace, env=env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return dict(line.split("=", 1) for line in env_file.read_text().splitlines() if "=" in line)

    def test_unpublished_base_and_unchanged_head_share_the_newest_published_tree(self) -> None:
        checkout(self.base, "b" * 40, resolved("c" * 40, 2))
        checkout(self.workspace, "b" * 40)
        env = self.run_step()
        self.assertEqual(env.get("BASE_TUI_TREE_KEY"), "c" * 40)
        self.assertEqual(env.get("HEAD_TUI_TREE_KEY"), "c" * 40)

    def test_a_head_that_changes_cmux_tui_keeps_its_own_tree(self) -> None:
        checkout(self.base, "b" * 40, resolved("c" * 40, 2))
        checkout(self.workspace, "e" * 40)
        env = self.run_step()
        self.assertEqual(env.get("BASE_TUI_TREE_KEY"), "c" * 40)
        self.assertNotIn("HEAD_TUI_TREE_KEY", env)

    def test_a_published_base_tree_is_used_as_is(self) -> None:
        checkout(self.base, "b" * 40, resolved("b" * 40, 0))
        checkout(self.workspace, "b" * 40)
        self.assertEqual(self.run_step(), {})

    def test_nothing_published_in_reach_leaves_the_wait(self) -> None:
        checkout(self.base, "b" * 40)
        checkout(self.workspace, "b" * 40)
        self.assertEqual(self.run_step(), {})

    def test_a_reused_base_app_needs_no_tree(self) -> None:
        checkout(self.workspace, "b" * 40)  # no base worktree: the app came from the cache
        self.assertEqual(self.run_step(), {})

    def test_the_builds_take_the_keys(self) -> None:
        steps = {s.get("name"): s for s in yaml.safe_load(WORKFLOW.read_text())["jobs"]["tour"]["steps"]}
        self.assertIn("BASE_TUI_TREE_KEY", steps["Build the base app"]["run"])
        self.assertIn("HEAD_TUI_TREE_KEY", steps["Build the head app"]["run"])


if __name__ == "__main__":
    unittest.main()
