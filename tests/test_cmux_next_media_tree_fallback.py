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
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-next-media.yml"
STEP = "Use a published cmux-tui tree for an unpublished base"

# The fake models what the real pin-cmux-tui.sh does with its environment:
# - key (no --rev) prints CMUX_TUI_TREE_KEY when set (checkout_tree_key), so a
#   key inherited from the job hides the checkout's own; key --rev HEAD never
#   reads it.
# - resolve-newest-published skips a commit whose copy of a
#   CMUX_TUI_TREE_SAME_PATHS path differs: "newest" is the newest published
#   tree, "newest-same-caps" the newest whose daemon-capabilities.json matches.
# - it appends a block to a non-empty GITHUB_STEP_SUMMARY, and with
#   CMUX_TUI_TREE_DISPATCH=1 records a publisher dispatch.
FAKE_PIN = """#!/usr/bin/env bash
here="$(dirname "$0")"
case "$1" in
  key)
    if [ "${2-}" != --rev ] && [ -n "${CMUX_TUI_TREE_KEY:-}" ]; then echo "$CMUX_TUI_TREE_KEY"; exit 0; fi
    cat "$here/key" ;;
  resolve-newest-published)
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "### cmux-tui client" >> "$GITHUB_STEP_SUMMARY"; fi
    if [ "${CMUX_TUI_TREE_DISPATCH:-}" = 1 ]; then echo dispatched >> "$here/dispatches"; fi
    pick=newest
    for path in ${CMUX_TUI_TREE_SAME_PATHS:-}; do
      [ "$path" = "$CAPS_PATH" ] && [ -f "$here/newest-same-caps" ] && pick=newest-same-caps
    done
    [ -f "$here/$pick" ] || { echo "no published tree" >&2; exit 1; }
    cat "$here/$pick" ;;
  *) exit 2 ;;
esac
"""

# The file bundle-cmux-tui.sh's capability check reads (check-daemon-capabilities.sh).
CAPS_PATH = re.search(r'capabilities="\$repo_root/([^"]+)"',
                      (ROOT / "scripts" / "cmux-next" / "check-daemon-capabilities.sh").read_text()).group(1)


def checkout(path: Path, key: str, newest: str | None = None, same_caps: str | None = None) -> None:
    pin = path / "scripts" / "cmux-next"
    pin.mkdir(parents=True)
    (pin / "pin-cmux-tui.sh").write_text(FAKE_PIN)
    os.chmod(pin / "pin-cmux-tui.sh", 0o755)
    (pin / "key").write_text(key + "\n")
    if newest is not None:
        (pin / "newest").write_text(newest)
    if same_caps is not None:
        (pin / "newest-same-caps").write_text(same_caps)


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

    def run_step(self, **job_env: str) -> dict[str, str]:
        self.outputs = self.tmp / "outputs"
        self.outputs.write_text("")
        env_file = self.tmp / "env"
        env_file.write_text("")
        env = dict(os.environ, GITHUB_WORKSPACE=str(self.workspace), RUNNER_TEMP=str(self.tmp / "runner"),
                   GITHUB_ENV=str(env_file), GITHUB_OUTPUT=str(self.outputs),
                   GITHUB_STEP_SUMMARY=str(self.tmp / "summary"), CAPS_PATH=CAPS_PATH, **job_env)
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
        # The tour comment says so: the before and after apps run an older daemon.
        self.assertIn("c" * 12, self.outputs.read_text())
        self.assertIn("note=", self.outputs.read_text())

    def test_the_stand_in_serves_the_base_daemon_capabilities(self) -> None:
        # bundle-cmux-tui.sh checks the daemon serves every capability in
        # daemon-capabilities.json: the newest published tree here predates a
        # capability the base lists, so the stand-in is the newest one whose
        # capability list matches the base's.
        checkout(self.base, "b" * 40, resolved("c" * 40, 1), same_caps=resolved("d" * 40, 3))
        checkout(self.workspace, "b" * 40)
        env = self.run_step()
        self.assertEqual(env.get("BASE_TUI_TREE_KEY"), "d" * 40)
        self.assertEqual(env.get("HEAD_TUI_TREE_KEY"), "d" * 40)

    def test_the_search_writes_no_summary_and_dispatches_no_publisher(self) -> None:
        # The nightly's "cmux-tui client" summary block would claim the tour's
        # stand-in as a build input; a dispatch would start a publisher run.
        checkout(self.base, "b" * 40, resolved("c" * 40, 2))
        checkout(self.workspace, "b" * 40)
        self.run_step(CMUX_TUI_TREE_DISPATCH="1")
        summary = self.tmp / "summary"
        self.assertFalse(summary.exists() and summary.read_text(), "the step wrote a summary block")
        self.assertFalse((self.base / "scripts" / "cmux-next" / "dispatches").exists(), "the step dispatched a publisher")

    def test_an_inherited_tree_key_does_not_hide_a_head_cmux_tui_change(self) -> None:
        # pin-cmux-tui.sh key prints CMUX_TUI_TREE_KEY when the job has one;
        # head and base would then compare equal although the head changes cmux-tui.
        checkout(self.base, "b" * 40, resolved("c" * 40, 2))
        checkout(self.workspace, "e" * 40)
        self.assertEqual(self.run_step(CMUX_TUI_TREE_KEY="f" * 40), {})

    def test_a_head_that_changes_cmux_tui_keeps_both_trees_exact(self) -> None:
        # The head waits for its own tree anyway; a stand-in base would credit
        # the daemon changes between it and the merge base to the pull request.
        checkout(self.base, "b" * 40, resolved("c" * 40, 2))
        checkout(self.workspace, "e" * 40)
        self.assertEqual(self.run_step(), {})

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

    def test_the_builds_take_the_keys_and_the_comment_the_note(self) -> None:
        workflow = yaml.safe_load(WORKFLOW.read_text())
        steps = {s.get("name"): s for s in workflow["jobs"]["tour"]["steps"]}
        self.assertIn("BASE_TUI_TREE_KEY", steps["Build the base app"]["run"])
        self.assertIn("HEAD_TUI_TREE_KEY", steps["Build the head app"]["run"])
        self.assertEqual(steps[STEP].get("id"), "tree")
        self.assertIn("steps.tree.outputs.note", workflow["jobs"]["tour"]["outputs"]["tree_note"])
        publish = {s.get("name"): s for s in workflow["jobs"]["publish"]["steps"]}
        step = publish["Upload the media and update the comment"]
        self.assertIn("needs.tour.outputs.tree_note", step["env"]["TREE_NOTE"])
        # The step publishes through .github/actions/pr-media-publish; its command composes the note.
        self.assertIn("$TREE_NOTE", step["with"]["command"])


if __name__ == "__main__":
    unittest.main()
