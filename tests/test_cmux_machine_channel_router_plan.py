#!/usr/bin/env python3
"""The machine channel's pull request plan runs in pr-router.yml's route job, not on a runner of its own.

"does the machine channel need this commit" was a whole cmux-linux runner with a fetch-depth 200 checkout on every
full-tier head for a 0.3 s answer: 943 runs, 1,460 runner-min in 6 h (2026-11-26 02Z..08Z). The route job already
has the merge commit and the base, so it runs scripts/ci/cmux-machine-channel-pr-plan.sh and passes the answer as
workflow_call inputs; the plan job runs only when that answer is missing.

Every tree key call also named a `key` subcommand cmux_tui_tree_key.py does not have (it takes
`[--version V] [REV]`), so each key came back empty: every full-tier head built both musl targets (840 builds a
target in those 6 h) and the merge's finder never matched a head build. The tests below run the real CLI.

Leo, 2026-11-25: "de facto, im asking for 99% fewer minutes of ci time, period."

Run: python3 tests/test_cmux_machine_channel_router_plan.py
"""

from __future__ import annotations

import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
ROUTER = ROOT / ".github/workflows/pr-router.yml"
CHANNEL = ROOT / ".github/workflows/cmux-machine-channel.yml"
PLAN = "scripts/ci/cmux-machine-channel-pr-plan.sh"
READS = (PLAN, "scripts/ci/cmux_tui_tree_key.py", "scripts/ci/timeout.sh",
         "scripts/cmux-next/cmux-tui-build-profiles.json", "scripts/cmux-next/cmux-tui-tree-inputs.txt")
INPUTS = ("build", "x86_64_target_set", "aarch64_target_set", "lto", "artifact_prefix")


def load(path: Path) -> dict:
    return yaml.safe_load(path.read_text())


def git(repo: Path, *args: str) -> str:
    env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
           "GIT_COMMITTER_EMAIL": "t@t", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True,
                          env=env).stdout.strip()


class RouterAnswersThePlan(unittest.TestCase):
    def test_the_route_job_runs_the_plan_when_it_starts_the_channel(self) -> None:
        route = load(ROUTER)["jobs"]["route"]
        step = next(s for s in route["steps"] if s.get("id") == "machine-channel")
        self.assertEqual(step["run"], PLAN)
        self.assertIn("'cmux-machine-channel.yml'", step["if"])
        self.assertIn("steps.route.outputs.start", step["if"])
        # A failure leaves the answer empty and the callee's plan job answers: it never fails the router.
        self.assertTrue(step["continue-on-error"])
        self.assertLess(step["timeout-minutes"], route["timeout-minutes"])
        sparse = route["steps"][0]["with"]["sparse-checkout"].split()
        for path in READS:
            self.assertIn(path, sparse)
        for name in INPUTS:
            self.assertEqual(route["outputs"][f"machine_channel_{name}"], f"${{{{ steps.machine-channel.outputs.{name} }}}}")

    def test_the_caller_passes_every_answer(self) -> None:
        caller = load(ROUTER)["jobs"]["machine-channel-pr-head"]
        self.assertEqual(caller["with"], {n: f"${{{{ needs.route.outputs.machine_channel_{n} }}}}" for n in INPUTS})
        declared = load(CHANNEL)[True]["workflow_call"]["inputs"]
        self.assertEqual(set(declared), set(INPUTS))
        for name in INPUTS:
            self.assertEqual(declared[name], {"type": "string", "default": ""})

    def test_the_plan_job_runs_only_without_an_answer_and_the_builds_take_it(self) -> None:
        jobs = load(CHANNEL)["jobs"]
        self.assertIn("(inputs.build || '') == ''", jobs["plan"]["if"])
        for arch in ("x86_64", "aarch64"):
            job = jobs[f"build-{arch}"]
            # A skipped plan must not skip the builds: !cancelled(), and the router's answer first.
            self.assertEqual(job["if"], "${{ !cancelled() && (inputs.build || needs.plan.outputs.build) == 'true' }}")
            self.assertEqual(job["with"]["target_set"],
                             f"${{{{ inputs.{arch}_target_set || needs.plan.outputs.{arch}_target_set }}}}")
            self.assertEqual(job["with"]["lto"], "${{ inputs.lto || needs.plan.outputs.lto }}")
            self.assertEqual(job["with"]["artifact_prefix"],
                             "${{ inputs.artifact_prefix || needs.plan.outputs.artifact_prefix }}")
        plan_run = next(s for s in jobs["plan"]["steps"] if s.get("id") == "plan")["run"]
        self.assertIn(PLAN, plan_run)

    def test_no_caller_names_a_key_subcommand(self) -> None:
        for path in (CHANNEL, ROOT / PLAN, ROOT / "scripts/ci/cmux_machine_channel_pr_head.py"):
            text = path.read_text()
            self.assertNotIn('"$tk" key ', text, path)
            self.assertNotIn('"key", "--version"', text, path)


class PlanOnAFixtureRepo(unittest.TestCase):
    """The plan script and the finder's tree_key on a two-commit fixture laid out as the route checkout is."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.repo = self.tmp / "repo"
        for rel in READS:
            (self.repo / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / rel, self.repo / rel)
        (self.repo / "scripts/cmux-next/cmux-tui-tree-inputs.txt").write_text("tree cmux-tui\ntree webviews\n")
        for rel in ("cmux-tui/src/main.rs", "webviews/app.ts", "docs/readme.md"):
            (self.repo / rel).parent.mkdir(parents=True, exist_ok=True)
            (self.repo / rel).write_text("v0\n")
        git(self.repo, "init", "-q", "-b", "feat-cmux-next")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-qm", "base")

    def plan(self, head_repo: str = "manaflow-ai/cmux") -> dict[str, str]:
        out = self.tmp / "out"
        out.write_text("")
        env = {**os.environ, "GITHUB_OUTPUT": str(out), "GITHUB_REPOSITORY": "manaflow-ai/cmux",
               "HEAD_REPO": head_repo, "GITHUB_BASE_REF": "feat-cmux-next"}
        subprocess.run([str(self.repo / PLAN)], cwd=self.repo, env=env, check=True, capture_output=True)
        return dict(line.split("=", 1) for line in out.read_text().splitlines())

    def commit(self, rel: str) -> None:
        (self.repo / rel).write_text("v1\n")
        git(self.repo, "commit", "-qam", rel)

    def test_a_change_outside_the_tree_inputs_builds_nothing(self) -> None:
        self.commit("docs/readme.md")
        got = self.plan()
        self.assertEqual(got["build"], "false")
        self.assertEqual(got["x86_64_target_set"], "linux-x86_64")
        self.assertEqual(got["aarch64_target_set"], "linux-aarch64")
        self.assertEqual(got["artifact_prefix"], "machine-channel-")

    def test_a_change_to_a_tree_input_builds(self) -> None:
        self.commit("webviews/app.ts")
        self.assertEqual(self.plan()["build"], "true")

    def test_a_fork_head_builds_nothing(self) -> None:
        self.commit("webviews/app.ts")
        self.assertEqual(self.plan("someone/cmux")["build"], "false")

    def test_the_finder_reads_a_key(self) -> None:
        spec = importlib.util.spec_from_file_location("pr_head_fixture", ROOT / "scripts/ci/cmux_machine_channel_pr_head.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        shutil.copy2(ROOT / "scripts/ci/cmux_machine_channel_pr_head.py", self.repo / "scripts/ci/")
        mod.ROOT = self.repo
        key = mod.tree_key(git(self.repo, "rev-parse", "HEAD"))
        self.assertRegex(key, r"^[0-9a-f]{40}$")


if __name__ == "__main__":
    unittest.main()
