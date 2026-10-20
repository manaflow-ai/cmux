#!/usr/bin/env python3
"""cmux-next base autofix lands its repairs while feat-cmux-next keeps moving, and never lands a wrong one.

2026-10-19: the settings exports went stale on feat-cmux-next (defaults-snapshot red on every PR) because
each push cancelled the running Mac export job and the autofix job, and autofix refused to push once the
base had moved. With merges minutes apart, 9 runs in a row were cancelled and the repair never landed.
A repair generated at an older head may be re-applied on the moved tip only when nothing in between touched
that repair's areas; otherwise the newer run regenerates it (a revert in between would make it wrong).
That is judged file by file (2026-10-20): the files of untouched areas land even when another area moved,
and the run still fails so the next run's "since" covers what was left out.
"""
from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
DOC = yaml.safe_load((ROOT / ".github/workflows/cmux-next-base-autofix.yml").read_text())
PUSH = next(step for step in DOC["jobs"]["autofix"]["steps"] if step.get("name") == "Push the repairs")["run"]
SETTINGS = "Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Settings.swift"
EXPORT = "schemas/settings/settings-schema.json"
SNAPSHOT = "schemas/defaults/cmux-next.json"
SHORTCUTS = "web/data/cmux-shortcuts.generated.json"
SURFACES = "plans/cmux-next/action-surfaces.json"
WEBVIEWS = "webviews/src/generated.ts"
APP = "first-party-apps/app/fragment.json"


def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


class BaseAutofixFinishes(unittest.TestCase):
    def test_a_running_regeneration_or_repair_finishes(self):
        # A newer push still replaces a pending run, so at most one waits.
        for job in ("action-exports", "autofix"):
            with self.subTest(job=job):
                self.assertFalse(DOC["jobs"][job]["concurrency"]["cancel-in-progress"])

    def push(self, moved: dict[str, str] | None, *, repair: dict[str, str] | None = None,
             reject_without_moving=False, move_again: dict[str, str] | None = None):
        """Run the push loop: a repair (default: the settings export) made at HEAD_SHA, while feat-cmux-next
        gained `moved`; with `move_again`, the first push is rejected after the branch moves once more."""
        repair = repair or {EXPORT: "new"}
        work = Path(tempfile.mkdtemp())
        os.environ.update({"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                           "GIT_COMMITTER_EMAIL": "t@t"})
        git(work, "init", "-q", "--bare", "remote.git")
        seed = work / "seed"
        git(work, "clone", "-q", "remote.git", "seed")
        git(seed, "checkout", "-q", "-b", "feat-cmux-next")
        files = {SETTINGS: "k1", EXPORT: "old", SNAPSHOT: "old", SHORTCUTS: "old", SURFACES: "old", WEBVIEWS: "old", APP: "a1",
                 "README.md": "r", "unlisted/output.txt": "old",
                 "scripts/cmux-next/autofix-areas.sh": (ROOT / "scripts/cmux-next/autofix-areas.sh").read_text()}
        for path, text in files.items():
            (seed / path).parent.mkdir(parents=True, exist_ok=True)
            (seed / path).write_text(text)
        (seed / "scripts/cmux-next/autofix-areas.sh").chmod(0o755)
        git(seed, "add", "-A")
        git(seed, "commit", "-qm", "base")
        git(seed, "push", "-q", "origin", "feat-cmux-next")
        head = git(seed, "rev-parse", "HEAD")
        git(work, "clone", "-q", "--depth=1", "-b", "feat-cmux-next", f"file://{work}/remote.git", "runner")
        runner = work / "runner"
        if moved:
            for path, text in moved.items():
                (seed / path).write_text(text)
            git(seed, "commit", "-qam", "someone merged")
            git(seed, "push", "-q", "origin", "feat-cmux-next")
        if move_again:
            for path, text in move_again.items():
                (seed / path).write_text(text)
            git(seed, "commit", "-qam", "someone merged again")
            git(seed, "push", "-q", "origin", "HEAD:refs/heads/later")
            hook = work / "remote.git" / "hooks" / "pre-receive"
            hook.write_text("#!/bin/sh\nunset GIT_QUARANTINE_PATH\nif [ ! -e moved-once ]; then touch moved-once; "
                            "git update-ref refs/heads/feat-cmux-next refs/heads/later; exit 1; fi\n")
            hook.chmod(0o755)
        for path, text in repair.items():
            (runner / path).write_text(text)
        git(runner, "commit", "-qam", "repair")
        if reject_without_moving:
            hook = work / "remote.git" / "hooks" / "pre-receive"
            hook.write_text("#!/bin/sh\nexit 1\n")
            hook.chmod(0o755)
        loop = PUSH[PUSH.index('repair="$(git rev-parse HEAD)"'):]
        script = (f'set -euo pipefail\nremote="file://{work}/remote.git"\nwith_auth=(env)\n'
                  f'HEAD_SHA={head}\nGITHUB_STEP_SUMMARY=/dev/null\n{loop}')
        done = subprocess.run(["bash", "-c", script], cwd=runner, capture_output=True, text=True)
        tip = git(work / "remote.git", "rev-parse", "refs/heads/feat-cmux-next")
        landed = {path: git(work / "remote.git", "show", f"{tip}:{path}") for path in repair}
        return done, landed, done.stdout + done.stderr

    def test_the_repair_lands_on_a_base_that_moved_elsewhere(self):
        done, landed, out = self.push({"README.md": "r2"})
        self.assertEqual(done.returncode, 0, out)
        self.assertEqual(landed[EXPORT], "new")

    def test_a_retry_when_the_base_moves_twice(self):
        done, landed, out = self.push({"README.md": "r2"}, move_again={"README.md": "r3"})
        self.assertEqual(done.returncode, 0, out)
        self.assertEqual(landed[EXPORT], "new")
        self.assertIn("attempt 3", out)

    def test_a_repair_whose_inputs_changed_meanwhile_is_left_to_the_newer_run(self):
        # The settings sources moved (a revert, say): this run's export would be wrong at the tip.
        done, landed, out = self.push({SETTINGS: "k0"})
        self.assertEqual(done.returncode, 1)
        self.assertEqual(landed[EXPORT], "old")
        self.assertIn("newer run", out)

    def test_the_unaffected_part_of_a_repair_lands_while_the_affected_part_waits(self):
        # 2026-10-20: 4 of ~50 runs landed in a day. Packages/ (the graph area) moves on nearly every push,
        # so a repair that also carried the graph, settings or webviews never landed any of it. Each file
        # whose areas are untouched since HEAD_SHA is exactly right at the tip, so it lands alone.
        done, landed, out = self.push({SETTINGS: "k0"}, repair={EXPORT: "new", SHORTCUTS: "new"})
        self.assertEqual(landed[SHORTCUTS], "new")
        self.assertEqual(landed[EXPORT], "old")
        self.assertIn(EXPORT, out)
        self.assertIn("next run", out)
        # The run still fails, so the next run's "since" stays at the last whole repair.
        self.assertEqual(done.returncode, 1, out)

    def test_a_partial_repair_stays_partial_when_the_base_moves_again(self):
        done, landed, out = self.push({SETTINGS: "k0"}, repair={EXPORT: "new", SHORTCUTS: "new"},
                                      move_again={"README.md": "r3"})
        self.assertEqual(landed[SHORTCUTS], "new")
        self.assertEqual(landed[EXPORT], "old")
        self.assertIn("attempt 3", out)
        self.assertEqual(done.returncode, 1, out)

    def test_a_partial_repair_never_overwrites_an_output_changed_meanwhile(self):
        # web/data/ is no input area: the tip's own edit of the output keeps it out of the partial repair.
        done, landed, out = self.push({SETTINGS: "k0", SHORTCUTS: "someone else's"},
                                      repair={EXPORT: "new", SHORTCUTS: "new", WEBVIEWS: "new"})
        self.assertEqual(landed[SHORTCUTS], "someone else's")
        self.assertEqual(landed[EXPORT], "old")
        self.assertEqual(landed[WEBVIEWS], "new")
        self.assertEqual(done.returncode, 1, out)

    def test_outputs_built_from_a_left_out_export_wait_with_it(self):
        # Greptile on #22474: an app-host input change leaves the action export out, and the shortcuts
        # file built from that export must not land without it.
        done, landed, out = self.push({APP: "changed"}, repair={SURFACES: "new", SHORTCUTS: "new", WEBVIEWS: "new"})
        self.assertEqual(landed[SURFACES], "old")
        self.assertEqual(landed[SHORTCUTS], "old")
        self.assertEqual(landed[WEBVIEWS], "new")
        self.assertEqual(done.returncode, 1, out)

    def test_the_defaults_snapshot_never_lands_in_a_partial_repair(self):
        # defaults_guard.py also reads *Enabled flags and keybind lines across the sources, outside any area.
        done, landed, out = self.push({SETTINGS: "k0"}, repair={SNAPSHOT: "new", SHORTCUTS: "new"})
        self.assertEqual(landed[SNAPSHOT], "old")
        self.assertEqual(landed[SHORTCUTS], "new")
        self.assertEqual(done.returncode, 1, out)

    def test_the_defaults_snapshot_waits_when_the_action_exports_moved(self):
        # The snapshot is built from the settings and the action exports (coord-2 review of c30bfe5).
        done, landed, out = self.push({SURFACES: "changed"}, repair={SNAPSHOT: "new"})
        self.assertEqual(done.returncode, 1, out)
        self.assertEqual(landed[SNAPSHOT], "old")

    def test_a_shortcuts_repair_lands_past_an_unrelated_change(self):
        done, landed, out = self.push({"README.md": "r2"}, repair={SHORTCUTS: "new"})
        self.assertEqual(done.returncode, 0, out)
        self.assertEqual(landed[SHORTCUTS], "new")

    def test_an_output_no_area_claims_is_never_reapplied(self):
        done, landed, out = self.push({"README.md": "r2"}, repair={"unlisted/output.txt": "new"})
        self.assertEqual(done.returncode, 1, out)
        self.assertEqual(landed["unlisted/output.txt"], "old")
        self.assertIn("unlisted/output.txt", out)

    def test_a_conflict_fails_without_pushing(self):
        # web/data/ is no input area, so only the cherry-pick itself can catch this.
        done, landed, out = self.push({SHORTCUTS: "someone else's"}, repair={SHORTCUTS: "new"})
        self.assertEqual(done.returncode, 1, out)
        self.assertEqual(landed[SHORTCUTS], "someone else's")
        self.assertIn("conflicts", out)

    def test_a_push_rejected_without_the_base_moving_says_so(self):
        done, _, out = self.push(None, reject_without_moving=True)
        self.assertEqual(done.returncode, 1)
        self.assertIn("rejected", out)
        self.assertNotIn("kept moving", out)

    def test_ci_runs_this_test(self):
        steps = DOC_NEXT["jobs"]
        runs = "\n".join(step.get("run", "") for job in steps.values() for step in job.get("steps", []))
        self.assertIn("tests/test_cmux_next_base_autofix_finishes.py", runs)


DOC_NEXT = yaml.safe_load((ROOT / ".github/workflows/cmux-next.yml").read_text())

if __name__ == "__main__":
    unittest.main()
