#!/usr/bin/env python3
"""Each pool mirror checkout keeps one reused workspace per sparse list (rnd rc-454d007c).

Jobs with different sparse lists took turns with one reused .git per runner, so a fast-gates job after a guards job
widened the tree first: median 6.4 s widening, against 1.8 s reusing the same list and 5.1 s fresh (bench run
46133992029, 4 runs each on cmux-linux pool runners). Each list now keeps its own workspace beside
$GITHUB_WORKSPACE, moved in and out by a rename.

This runs every "Pool mirror" checkout step whole against a local mirror: list A, list B, then A again must bring
back A's own workspace (same inodes, nothing rewritten), and the stash keeps at most 4 lists.
"""
from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
MIRROR = "/var/lib/cmux-git/cmux.git/objects"


def pool_steps() -> list[tuple[str, str]]:
    found = []
    for path in sorted((ROOT / ".github/workflows").glob("*.yml")):
        text = path.read_text(encoding="utf-8")
        if MIRROR not in text:
            continue
        for job_name, job in (yaml.load(text, Loader=yaml.BaseLoader).get("jobs") or {}).items():
            for step in job.get("steps") or []:
                run = step.get("run") or ""
                if MIRROR in run and "workspace=$reuse" in run:
                    found.append((f"{path.name}:{job_name}:{step.get('name')}", run))
    return found


def git(cwd: Path, *args: str) -> str:
    env = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"}
    return subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", *args], cwd=cwd, env=env, check=True,
                          capture_output=True, text=True).stdout


class KeyedBySparse(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="pool-keyed-"))
        self.addCleanup(subprocess.run, ["rm", "-rf", str(self.tmp)])
        seed = self.tmp / "seed"
        git(self.tmp, "init", "-q", "-b", "main", str(seed))
        for rel in ("a/x", "b/y", "c/z", "top.txt"):
            (seed / rel).parent.mkdir(parents=True, exist_ok=True)
            (seed / rel).write_text(rel)
        git(seed, "add", "-A")
        git(seed, "commit", "-qm", "one")
        (seed / "a/w").write_text("w")
        git(seed, "add", "-A")
        git(seed, "commit", "-qm", "two")
        self.seed, self.sha = seed, git(seed, "rev-parse", "HEAD").strip()
        git(self.tmp, "clone", "-q", "--bare", str(seed), str(self.tmp / "mirror.git"))
        self.parent = self.tmp / "work"
        self.ws = self.parent / "ws"
        self.ws.mkdir(parents=True)

    def run_step(self, run: str, sparse: str) -> str:
        script = run.replace(MIRROR, str(self.tmp / "mirror.git/objects")).replace(
            "https://github.com/$GITHUB_REPOSITORY", "file://" + str(self.seed))
        env = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GITHUB_WORKSPACE": str(self.ws),
               "GITHUB_REPOSITORY": "o/r", "SHA": self.sha, "TOKEN": "t", "SPARSE": sparse}
        result = subprocess.run(["bash", "-c", script], cwd=self.ws, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_each_list_gets_its_own_workspace_back(self) -> None:
        steps = pool_steps()
        self.assertGreaterEqual(len(steps), 11, steps)
        for label, run in steps:
            with self.subTest(step=label):
                # a fresh workspace per step: one step's layout is not another's
                subprocess.run(["rm", "-rf", str(self.parent)], check=True)
                self.ws.mkdir(parents=True)
                a, b = "/*\n!/*/\n/a/\n", "/*\n!/*/\n/b/\n"
                self.assertIn("workspace=fresh", self.run_step(run, a))
                inode = (self.ws / "a/x").stat().st_ino
                self.assertIn("workspace=fresh", self.run_step(run, b))
                if "git config core.sparseCheckout true" in run:  # a step without patterns checks out every path
                    self.assertFalse((self.ws / "a/x").exists())
                out = self.run_step(run, a)
                self.assertIn("workspace=reused", out)
                self.assertEqual((self.ws / "a/x").stat().st_ino, inode, "A's workspace came back, not rewritten")
                self.assertEqual(git(self.ws, "rev-parse", "HEAD").strip(), self.sha)
                stash = self.parent / ".pool-ws"
                self.assertEqual(len(list(stash.iterdir())), 1)
                self.assertTrue(next(stash.iterdir()).joinpath("b/y").exists())

    def test_stash_keeps_four_lists(self) -> None:
        run = next(r for label, r in pool_steps() if label.startswith("cmux-next-fast-gates.yml"))
        for n in range(7):
            self.run_step(run, f"/*\n!/*/\n/a/\n# list {n}\n")
        self.assertLessEqual(len(list((self.parent / ".pool-ws").iterdir())), 4)

    def test_a_workspace_this_step_did_not_key_is_left_to_the_reuse_check(self) -> None:
        # The first job after this lands finds an unkeyed .git: it is reused in place, not thrown away.
        run = next(r for label, r in pool_steps() if label.startswith("cmux-next-fast-gates.yml"))
        self.run_step(run, "/*\n!/*/\n/a/\n")
        (self.ws / ".git/cmux-pool-key").unlink()
        self.assertIn("workspace=reused", self.run_step(run, "/*\n!/*/\n/b/\n"))
        self.assertFalse((self.parent / ".pool-ws").exists())


if __name__ == "__main__":
    unittest.main()
