#!/usr/bin/env python3
"""cmux-next base autofix lands its repairs while feat-cmux-next keeps moving, and never lands a wrong one.

2026-10-19: the settings exports went stale on feat-cmux-next (defaults-snapshot red on every PR) because
each push cancelled the running Mac export job and the autofix job, and autofix refused to push once the
base had moved. With merges minutes apart, 9 runs in a row were cancelled and the repair never landed.
A repair generated at an older head may be re-applied on the moved tip only when nothing in between touched
that repair's areas; otherwise the newer run regenerates it (a revert in between would make it wrong).
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


def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


class BaseAutofixFinishes(unittest.TestCase):
    def test_a_running_regeneration_or_repair_finishes(self):
        # A newer push still replaces a pending run, so at most one waits.
        for job in ("action-exports", "autofix"):
            with self.subTest(job=job):
                self.assertFalse(DOC["jobs"][job]["concurrency"]["cancel-in-progress"])

    def push(self, moved: dict[str, str] | None, *, reject_without_moving=False):
        """Run the push loop: a repair of EXPORT at HEAD_SHA, while feat-cmux-next gained `moved`."""
        work = Path(tempfile.mkdtemp())
        env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
               "GIT_COMMITTER_EMAIL": "t@t"}
        os.environ.update({k: v for k, v in env.items() if k.startswith("GIT_")})
        git(work, "init", "-q", "--bare", "remote.git")
        seed = work / "seed"
        git(work, "clone", "-q", "remote.git", "seed")
        git(seed, "checkout", "-q", "-b", "feat-cmux-next")
        for path, text in ((SETTINGS, "k1"), (EXPORT, "old"), ("README.md", "r"),
                           ("scripts/cmux-next/autofix-areas.sh", (ROOT / "scripts/cmux-next/autofix-areas.sh").read_text())):
            (seed / path).parent.mkdir(parents=True, exist_ok=True)
            (seed / path).write_text(text)
        (seed / "scripts/cmux-next/autofix-areas.sh").chmod(0o755)
        git(seed, "add", "-A")
        git(seed, "commit", "-qm", "base")
        git(seed, "push", "-q", "origin", "feat-cmux-next")
        head = git(seed, "rev-parse", "HEAD")
        runner = work / "runner"
        git(work, "clone", "-q", "--depth=1", "-b", "feat-cmux-next", f"file://{work}/remote.git", "runner")
        if moved:
            for path, text in moved.items():
                (seed / path).write_text(text)
            git(seed, "commit", "-qam", "someone merged")
            git(seed, "push", "-q", "origin", "feat-cmux-next")
        (runner / EXPORT).write_text("new")
        git(runner, "commit", "-qam", "repair")
        if reject_without_moving:
            hook = work / "remote.git" / "hooks" / "pre-receive"
            hook.write_text("#!/bin/sh\nexit 1\n")
            hook.chmod(0o755)
        loop = PUSH[PUSH.index('repair="$(git rev-parse HEAD)"'):]
        script = (f'set -euo pipefail\nremote="file://{work}/remote.git"\nwith_auth=(env)\n'
                  f'HEAD_SHA={head}\nGITHUB_STEP_SUMMARY=/dev/null\n{loop}')
        done = subprocess.run(["bash", "-c", script], cwd=runner, capture_output=True, text=True)
        git(seed, "pull", "-q", "origin", "feat-cmux-next")
        return done, (seed / EXPORT).read_text(), done.stdout + done.stderr

    def test_the_repair_lands_on_a_base_that_moved_elsewhere(self):
        done, export, out = self.push({"README.md": "r2"})
        self.assertEqual(done.returncode, 0, out)
        self.assertEqual(export, "new")

    def test_a_repair_whose_inputs_changed_meanwhile_is_left_to_the_newer_run(self):
        # The settings sources moved (a revert, say): this run's export would be wrong at the tip.
        done, export, out = self.push({SETTINGS: "k0"})
        self.assertEqual(done.returncode, 1)
        self.assertEqual(export, "old")
        self.assertIn("newer run", out)

    def test_a_push_rejected_without_the_base_moving_says_so(self):
        done, export, out = self.push(None, reject_without_moving=True)
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
