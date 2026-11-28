#!/usr/bin/env python3
"""The light pull request jobs check out from a pool VM's git mirror, as the fast gates do.

2026-11-25 step timings: the size budget's two jobs, cmux-tui spec's `changes` and rust workspaces'
`plan` spent 50-140 s of their 1.5-3 min in actions/checkout (a blob:none fetch that borrows the pool
mirror copies its promisor objects; the Cargo plan cloned the whole tree). On a cmux-runner-pool VM
each now runs an unfiltered fetch into a fresh .git that borrows /var/lib/cmux-git, with the same
commit, depth and sparse paths; every other runner, and every non-pull-request run, keeps the action.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import yaml

ROOT = Path(__file__).resolve().parents[1]
NOT_POOL = "!startsWith(runner.name, 'cmux-runner-pool-')"
POOL = "startsWith(runner.name, 'cmux-runner-pool-')"
# (workflow, job, extra condition both steps share, whether the twin is pull_request-only)
CASES = (
    ("cmux-next-size-budget.yml", "plan", "", False),
    ("cmux-next-size-budget.yml", "size-budget", "needs.plan.outputs.tool == 'true' && ", False),
    ("cmux-tui-spec.yml", "changes", "", True),
    ("rust-workspaces.yml", "plan", "", True),
    # path_route: 4-6 s of blob:none checkout and 4-5 s of blob prefetch of its ~31 s, on ~7,500 runs a day.
    ("cmux-next.yml", "path_route", "", False),
)


def steps_of(workflow: str, job: str) -> list[dict]:
    doc = yaml.safe_load((ROOT / ".github/workflows" / workflow).read_text())
    return doc["jobs"][job]["steps"]


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True, text=True).stdout


class LightJobsPoolMirrorCheckout(unittest.TestCase):
    def pair(self, workflow: str, job: str) -> tuple[dict, dict]:
        steps = steps_of(workflow, job)
        action = next(s for s in steps if s.get("uses", "").startswith("actions/checkout@") and s.get("name") == "Checkout")
        pool = next(s for s in steps if s.get("name") == "Pool mirror: Checkout")
        self.assertGreater(steps.index(pool), steps.index(action))
        # Checkout retries now sit between the action and its pool alternative.
        # Only failure-gated retries/pauses may intervene, never a consumer.
        for step in steps[steps.index(action) + 1:steps.index(pool)]:
            self.assertIn(step.get("if"), (
                "steps.checkout.outcome == 'failure'",
                "steps.checkout.outcome == 'failure' && steps.checkout-retry.outcome == 'failure'",
            ))
            if "uses" in step:
                self.assertEqual(step["uses"], action["uses"])
                self.assertEqual(step["with"], action["with"])
            else:
                self.assertRegex(step.get("run", ""), r'^rm -rf "\$GITHUB_WORKSPACE/\.git"; sleep [0-9]+$')
        return action, pool

    def test_a_consumer_cannot_precede_the_pool_checkout(self):
        steps = steps_of("cmux-next-size-budget.yml", "plan")
        index = next(i for i, s in enumerate(steps) if s.get("name") == "Pool mirror: Checkout")
        steps.insert(index, {"name": "Consumer", "run": "python3 scripts/check.py"})
        with patch(__name__ + ".steps_of", return_value=steps):
            with self.assertRaises(AssertionError):
                self.pair("cmux-next-size-budget.yml", "plan")

    def test_each_light_checkout_has_a_pool_twin_with_the_same_paths(self):
        for workflow, job, extra, pr_only in CASES:
            with self.subTest(workflow=workflow, job=job):
                action, pool = self.pair(workflow, job)
                cond_a = action["if"].replace("${{", "").replace("}}", "").strip()
                cond_p = pool["if"].replace("${{", "").replace("}}", "").strip()
                if pr_only:
                    self.assertEqual(cond_a, f"github.event_name != 'pull_request' || {NOT_POOL}")
                    self.assertEqual(cond_p, f"github.event_name == 'pull_request' && {POOL}")
                else:
                    self.assertEqual(cond_a, f"{extra}{NOT_POOL}")
                    self.assertEqual(cond_p, f"{extra}{POOL}")
                self.assertEqual(pool["env"]["SHA"], "${{ github.sha }}")
                sparse = action["with"].get("sparse-checkout", "")
                if action["with"].get("sparse-checkout-cone-mode") is False:
                    self.assertEqual(pool["env"]["SPARSE"], sparse)
                elif sparse:
                    # Cone mode: the folder, written as its non-cone pattern.
                    self.assertEqual(pool["env"]["SPARSE"].split(), ["/" + p.strip("/") + "/" for p in sparse.split()])
                else:
                    self.assertEqual(pool["env"]["SPARSE"], "")
                fetch = next(line for line in pool["run"].splitlines()
                             if re.search(r"\bgit(?:\s+-c\s+\S+)*\s+fetch\s", line))
                self.assertNotIn("--filter", fetch)
                self.assertIn("--depth=2", fetch)
                self.assertNotIn("$TOKEN", fetch)
                self.assertIn('echo "$mirror" > .git/objects/info/alternates', pool["run"])

    def run_pool(self, step: dict, sparse: str, extra: dict[str, str] | None = None) -> Path:
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        seed = tmp / "seed"
        git(tmp, "init", "-q", "-b", "main", str(seed))
        files = {rel: rel for rel in ("scripts/cmux-next/a.py", "webviews/b.ts", "outside/c.txt")}
        for rel, text in {**files, **(extra or {})}.items():
            (seed / rel).parent.mkdir(parents=True, exist_ok=True)
            (seed / rel).write_text(text)
        git(seed, "add", "-A")
        git(seed, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "one")
        (seed / "scripts/cmux-next/d.py").write_text("d")
        git(seed, "add", "-A")
        git(seed, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "two")
        sha = git(seed, "rev-parse", "HEAD").strip()
        git(tmp, "clone", "-q", "--bare", str(seed), str(tmp / "mirror.git"))
        run = step["run"].replace("/var/lib/cmux-git/cmux.git/objects", str(tmp / "mirror.git/objects")).replace(
            "https://github.com/$GITHUB_REPOSITORY", "file://" + str(seed))
        ws = tmp / "ws"
        (ws / ".git").mkdir(parents=True)
        (ws / "stale.txt").write_text("from an earlier job")
        env = {**os.environ, "GITHUB_WORKSPACE": str(ws), "SHA": sha, "TOKEN": "t", "SPARSE": sparse}
        subprocess.run(["bash", "-c", run], env=env, check=True, capture_output=True, text=True)
        self.assertEqual(git(ws, "rev-parse", "HEAD").strip(), sha)
        git(ws, "rev-parse", "HEAD^1")
        self.assertFalse((ws / "stale.txt").exists())
        self.assertEqual(subprocess.run(["git", "-C", str(ws), "config", "--get", "remote.origin.promisor"],
                                        capture_output=True, text=True).stdout.strip(), "")
        return ws

    def test_sparse_twin_checks_out_only_its_paths_with_every_blob(self):
        _, pool = self.pair("cmux-next-size-budget.yml", "size-budget")
        ws = self.run_pool(pool, pool["env"]["SPARSE"])
        self.assertTrue((ws / "scripts/cmux-next/d.py").exists())
        self.assertFalse((ws / "outside").exists())
        # The checker sizes every blob of both commits through git: all present, no lazy fetch.
        git(ws, "ls-tree", "-r", "-l", "HEAD^1")

    def test_path_route_twin_checks_out_its_pattern_list_at_once(self):
        _, pool = self.pair("cmux-next.yml", "path_route")
        # The commit's pattern list joins the step's own paths, so the widen step that follows changes nothing.
        ws = self.run_pool(pool, pool["env"]["SPARSE"], {"scripts/ci/path-route-sparse-checkout.txt": "/webviews/\n"})
        patterns = (ws / ".git/info/sparse-checkout").read_text().split()
        for line in pool["env"]["SPARSE"].split() + ["/webviews/"]:
            self.assertIn(line, patterns)
        self.assertTrue((ws / "webviews/b.ts").exists() and (ws / "scripts/ci/path-route-sparse-checkout.txt").exists())
        self.assertFalse((ws / "outside").exists())

    def test_whole_tree_twin_checks_out_everything(self):
        _, pool = self.pair("rust-workspaces.yml", "plan")
        ws = self.run_pool(pool, pool["env"]["SPARSE"])
        self.assertTrue((ws / "outside/c.txt").exists() and (ws / "webviews/b.ts").exists())


if __name__ == "__main__":
    unittest.main()
