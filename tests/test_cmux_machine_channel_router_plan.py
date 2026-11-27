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
import time
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
ROUTER = ROOT / ".github/workflows/pr-router.yml"
CHANNEL = ROOT / ".github/workflows/cmux-machine-channel.yml"
PLAN = "scripts/ci/cmux-machine-channel-pr-plan.sh"
READS = (PLAN, "scripts/ci/cmux_machine_channel_head_built.py", "scripts/ci/cmux_tui_tree_key.py", "scripts/ci/timeout.sh",
         "scripts/cmux-next/cmux-tui-build-profiles.json", "scripts/cmux-next/cmux-tui-tree-inputs.txt")
INPUTS = ("build", "x86_64_target_set", "aarch64_target_set", "lto", "artifact_prefix")


def load(path: Path) -> dict:
    return yaml.safe_load(path.read_text())


def git(repo: Path, *args: str, age_s: int = 7200) -> str:
    # Commits are two hours old unless a test says otherwise: a base that took a commit in the last
    # MACHINE_CHANNEL_PR_HEAD_QUIET_MIN minutes builds no PR head.
    when = f"@{int(time.time()) - age_s} +0000"
    env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
           "GIT_COMMITTER_EMAIL": "t@t", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
           "GIT_AUTHOR_DATE": when, "GIT_COMMITTER_DATE": when}
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

    def plan(self, head_repo: str = "manaflow-ai/cmux", extra: dict[str, str] | None = None) -> dict[str, str]:
        out = self.tmp / "out"
        out.write_text("")
        env = {**os.environ, "GITHUB_OUTPUT": str(out), "GITHUB_REPOSITORY": "manaflow-ai/cmux",
               "HEAD_REPO": head_repo, "GITHUB_BASE_REF": "feat-cmux-next"}
        for k in ("HEAD_SHA", "GH_TOKEN", "GITHUB_RUN_ID", "MACHINE_CHANNEL_PR_HEAD_QUIET_MIN"):
            env.pop(k, None)
        env.update(extra or {})
        subprocess.run([str(self.repo / PLAN)], cwd=self.repo, env=env, check=True, capture_output=True)
        return dict(line.split("=", 1) for line in out.read_text().splitlines())

    def commit(self, rel: str, age_s: int = 7200) -> None:
        (self.repo / rel).write_text("v1\n")
        git(self.repo, "commit", "-qam", rel, age_s=age_s)

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

    def merge_ref(self, head_rel: str, base_rel: str, base_age_s: int = 7200) -> None:
        """A pull request merge ref: HEAD^1 the base, HEAD^2 the head, as the route checkout has it."""
        git(self.repo, "checkout", "-qb", "head")
        self.commit(head_rel)
        git(self.repo, "checkout", "-q", "feat-cmux-next")
        if base_rel:
            self.commit(base_rel, age_s=base_age_s)
        git(self.repo, "merge", "-q", "--no-ff", "--no-edit", "head")

    def test_an_up_to_date_head_that_changes_the_tree_builds(self) -> None:
        self.merge_ref("webviews/app.ts", "")
        self.assertEqual(self.plan()["build"], "true")

    def test_a_base_that_just_took_a_commit_builds_nothing(self) -> None:
        # Its push run coalesces this merge, so no push run would take the build (1,290 merges in 24 h, 27 push runs).
        # The base's last commit (HEAD^1, outside the tree inputs) landed 5 min ago.
        self.merge_ref("webviews/app.ts", "docs/readme.md", base_age_s=300)
        self.assertEqual(self.plan()["build"], "false")
        self.assertEqual(self.plan(extra={"MACHINE_CHANNEL_PR_HEAD_QUIET_MIN": "4"})["build"], "true")
        # 0 turns the gate off.
        self.assertEqual(self.plan(extra={"MACHINE_CHANNEL_PR_HEAD_QUIET_MIN": "0"})["build"], "true")

    def test_the_router_passes_the_quiet_window(self) -> None:
        step = next(s for s in load(ROUTER)["jobs"]["route"]["steps"] if s.get("id") == "machine-channel")
        self.assertEqual(step["env"]["MACHINE_CHANNEL_PR_HEAD_QUIET_MIN"],
                         "${{ vars.CI_MACHINE_CHANNEL_PR_HEAD_QUIET_MIN || '30' }}")

    def test_a_head_behind_the_base_builds_nothing(self) -> None:
        # The base moved a tree input after the head forked: the head's key is not the merge's.
        self.merge_ref("webviews/app.ts", "cmux-tui/src/main.rs")
        self.assertEqual(self.plan()["build"], "false")

    def stub_head_built(self, answer: str) -> None:
        stub = self.repo / "scripts/ci/cmux_machine_channel_head_built.py"
        stub.write_text(f"import sys\nassert sys.argv[1:4] == ['{'a' * 40}', '--exclude-run', '7']\nprint('{answer}')\n")

    def test_a_head_an_earlier_run_built_builds_nothing(self) -> None:
        self.merge_ref("webviews/app.ts", "")
        self.stub_head_built("45871056565")
        got = self.plan(extra={"HEAD_SHA": "a" * 40, "GH_TOKEN": "t", "GITHUB_RUN_ID": "7"})
        self.assertEqual(got["build"], "false")

    def test_a_head_no_run_built_yet_builds(self) -> None:
        self.merge_ref("webviews/app.ts", "")
        self.stub_head_built("")
        self.assertEqual(self.plan(extra={"HEAD_SHA": "a" * 40, "GH_TOKEN": "t", "GITHUB_RUN_ID": "7"})["build"], "true")
        # No token (the callee's own plan job on a pull request): no lookup, the build runs.
        self.assertEqual(self.plan(extra={"HEAD_SHA": "a" * 40})["build"], "true")

    def test_the_plan_passes_its_merge_key_and_branch(self) -> None:
        self.merge_ref("webviews/app.ts", "")
        mine = subprocess.run(["python3", str(self.repo / "scripts/ci/cmux_tui_tree_key.py"), "--version", "v2", "HEAD"],
                              cwd=self.repo, check=True, capture_output=True, text=True).stdout.strip()
        stub = self.repo / "scripts/ci/cmux_machine_channel_head_built.py"
        stub.write_text("import sys\n"
                        f"a = sys.argv[1:]\nassert a[a.index('--key') + 1] == '{mine}', a\n"
                        "assert a[a.index('--branch') + 1] == 'lane/x', a\nprint(15)\n")
        got = self.plan(extra={"HEAD_SHA": "a" * 40, "HEAD_REF": "lane/x", "GH_TOKEN": "t", "GITHUB_RUN_ID": "7"})
        self.assertEqual(got["build"], "false")

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


class HeadBuilt(unittest.TestCase):
    def load(self):
        spec = importlib.util.spec_from_file_location("head_built", ROOT / "scripts/ci/cmux_machine_channel_head_built.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    def api(self, artifacts: dict[int, list[dict]]):
        calls: list[str] = []

        def get(path: str) -> object:
            calls.append(path)
            if path.startswith("actions/workflows/"):
                return {"workflow_runs": [{"id": i} for i in artifacts]}
            run = int(path.split("/")[2])
            return {"artifacts": artifacts[run]}

        return get, calls

    def both(self, expired: bool = False) -> list[dict]:
        return [{"name": f"machine-channel-cmux-tui-{t}", "expired": expired}
                for t in ("x86_64-unknown-linux-musl", "aarch64-unknown-linux-musl")]

    def test_an_earlier_run_with_both_artifacts_is_taken_and_this_run_is_left_out(self) -> None:
        mod = self.load()
        get, calls = self.api({10: self.both(), 11: [], 12: self.both()})
        self.assertEqual(mod.built(get, "a" * 40, "machine-channel-", exclude=12), 10)
        self.assertNotIn("actions/runs/12/artifacts?per_page=100", calls)

    def test_one_leg_or_expired_artifacts_are_no_build(self) -> None:
        mod = self.load()
        get, _ = self.api({10: self.both()[:1], 11: self.both(expired=True)})
        self.assertIsNone(mod.built(get, "a" * 40, "machine-channel-"))

    def branch_api(self, own: dict[int, list[dict]], earlier: list[tuple[int, str, list[dict]]]):
        """This head's runs (OWN) and the branch's runs (EARLIER: id, head sha, artifacts)."""
        calls: list[str] = []
        arts = {**own, **{i: a for i, _, a in earlier}}

        def get(path: str) -> object:
            calls.append(path)
            if "branch=" in path:
                return {"workflow_runs": [{"id": i, "head_sha": sha} for i, sha, _ in earlier]}
            if path.startswith("actions/workflows/"):
                return {"workflow_runs": [{"id": i} for i in own]}
            return {"artifacts": arts[int(path.split("/")[2])]}

        return get, calls

    def test_a_base_merge_that_moved_no_input_takes_the_earlier_heads_build(self) -> None:
        # The land queue's update-branch made head a*40; head b*40 (same tree key) built both legs.
        mod = self.load()
        get, calls = self.branch_api({20: []}, [(20, "a" * 40, []), (15, "b" * 40, self.both())])
        keys = {"b" * 40: "d" * 40}
        got = mod.built(get, "a" * 40, "machine-channel-", exclude=20, key="d" * 40, branch="lane/x",
                        key_of=lambda r: keys.get(r, ""))
        self.assertEqual(got, 15)
        self.assertIn("actions/workflows/pr-router.yml/runs?branch=lane%2Fx&event=pull_request&per_page=30", calls)

    def test_an_earlier_head_with_another_key_or_one_leg_builds(self) -> None:
        mod = self.load()
        get, _ = self.branch_api({}, [(16, "c" * 40, self.both()[:1]), (15, "b" * 40, self.both())])
        self.assertIsNone(mod.built(get, "a" * 40, "machine-channel-", key="d" * 40, branch="lane/x",
                                    key_of=lambda r: "e" * 40))
        # No key (an unread one) or no branch: the SHA lookup only, as before.
        get, calls = self.branch_api({}, [(15, "b" * 40, self.both())])
        self.assertIsNone(mod.built(get, "a" * 40, "machine-channel-", key="", branch="lane/x",
                                    key_of=lambda r: "d" * 40))
        self.assertFalse(any("branch=" in c for c in calls))

    def test_the_earlier_head_read_is_bounded(self) -> None:
        mod = self.load()
        earlier = [(100 - i, f"{i:040x}", self.both()) for i in range(10)]
        get, calls = self.branch_api({}, earlier)
        seen: list[str] = []
        got = mod.built(get, "a" * 40, "machine-channel-", key="d" * 40, branch="lane/x",
                        key_of=lambda r: seen.append(r) or "e" * 40)
        self.assertIsNone(got)
        self.assertEqual(len(seen), mod.KEY_READS)
        self.assertLessEqual(sum("/artifacts" in c for c in calls), mod.ARTIFACT_READS)

    def test_the_route_step_passes_the_head_and_the_token(self) -> None:
        route = load(ROUTER)["jobs"]["route"]
        step = next(s for s in route["steps"] if s.get("id") == "machine-channel")
        self.assertEqual(step["env"]["HEAD_SHA"], "${{ github.event.pull_request.head.sha || '' }}")
        self.assertEqual(step["env"]["GH_TOKEN"], "${{ github.token }}")
        self.assertEqual(step["env"]["HEAD_REF"], "${{ github.event.pull_request.head.ref || '' }}")
        self.assertEqual(route["permissions"]["actions"], "read")


if __name__ == "__main__":
    unittest.main()
