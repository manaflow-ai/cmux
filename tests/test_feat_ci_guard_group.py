#!/usr/bin/env python3
"""ci-guards.yml's `ci` group runs for feat-cmux-next pull requests and pushes.

ci.yml's "CI fast guards" job runs the group (scripts/ci/guards-local.sh, among them
tests/test_preflight_trust.py and every workflow lint) but skips pull requests into
feat-cmux-next, and ci-guards.yml's routed matrix leaves the group to it. So nothing ran it
for the branch: test_preflight_trust.py errored in all five tests there unseen (#23006).
"""
import os
from pathlib import Path
import sys
import shutil
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
from blacksmith_linux_sizes import blacksmith_route  # noqa: E402
WORKFLOWS = ROOT / ".github/workflows"


def triggers(workflow: dict) -> dict:
    found = workflow.get("on", workflow.get(True)) or {}
    return found if isinstance(found, dict) else {name: {} for name in ([found] if isinstance(found, str) else found)}


def covers_feat(trigger) -> bool:
    if trigger is None:
        return True
    branches = (trigger or {}).get("branches")
    return not (trigger or {}).get("paths") and (branches is None or "feat-cmux-next" in branches)


def runs_ci_group(job: dict) -> bool:
    """The job runs guards-local.sh's default set (the `ci` group) and nothing keeps it off feat-cmux-next."""
    condition = str(job.get("if", ""))
    if "feat-cmux-next" in condition and "!=" in condition:
        return False
    for step in job.get("steps") or []:
        command = str(step.get("run", ""))
        if "scripts/ci/guards-local.sh" in command and "--group" not in command and "--list" not in command:
            return True
    return False


class FeatRunsTheCiGuardGroup(unittest.TestCase):
    def test_a_workflow_runs_the_ci_group_on_feat_pull_requests_and_pushes(self):
        for event in ("pull_request", "push"):
            with self.subTest(event=event):
                found = []
                for path in sorted(WORKFLOWS.glob("*.yml")):
                    workflow = yaml.safe_load(path.read_text(encoding="utf-8"))
                    on = triggers(workflow)
                    if event not in on or not covers_feat(on[event]):
                        continue
                    found += [f"{path.name}:{name}" for name, job in (workflow.get("jobs") or {}).items()
                              if runs_ci_group(job)]
                self.assertTrue(found, f"no {event} workflow for feat-cmux-next runs scripts/ci/guards-local.sh")


class TheBaseIsCheckedOutOnPullRequests(unittest.TestCase):
    """On pull_request, github.event.before is null, and the expression language's loose `!=` turns null and the
    all-zeros sha into 0, so `github.event.before != '000…'` was false. The base checkout was skipped, and every base
    red counted as the change's (24 reds on every feat PR, run 39562873067). The zero test must be on the chosen sha."""

    def test_the_zero_sha_test_is_on_the_sha_it_checks_out(self):
        workflow = yaml.safe_load((WORKFLOWS / "cmux-next-guards.yml").read_text(encoding="utf-8"))
        steps = [s for job in workflow["jobs"].values() for s in job.get("steps") or []
                 if s.get("name") == "Checkout the base"]
        self.assertEqual(len(steps), 1)
        step = steps[0]
        chosen = step["with"]["ref"].removeprefix("${{").removesuffix("}}").strip()
        self.assertIn(f"({chosen}) != '{'0' * 40}'", step["if"])
        self.assertNotIn(f"github.event.before != '{'0' * 40}'", step["if"])


class OneBaseForTheDiffTheCheckoutAndTheGuards(unittest.TestCase):
    """GitHub's pull_request.base.sha lags the merge commit's first parent once the base moves: #23534's
    second run judged its head against a base 40 commits old, so the iOS conventions diff blamed the PR for
    a violation the base had taken since. The routing diff, the base checkout and CMUX_GUARDS_BASE_SHA use
    one sha: HEAD^1 for a pull request, the previous tip for a push."""

    def test_the_base_checkout_and_the_guards_use_the_diff_base(self):
        workflow = yaml.safe_load((WORKFLOWS / "cmux-next-guards.yml").read_text(encoding="utf-8"))
        steps = workflow["jobs"]["ci-guard-group"]["steps"]
        by_name = {step.get("name"): step for step in steps}
        changes = by_name["Changed files"]
        self.assertEqual(changes.get("id"), "changes")
        self.assertIn("git rev-parse HEAD^1", changes["run"])
        self.assertIn("base=", changes["run"])
        expression = "${{ steps.changes.outputs.base }}"
        self.assertEqual(by_name["Checkout the base"]["with"]["ref"], expression)
        runs = [step for step in steps if "guards-local.sh" in str(step.get("run", ""))]
        self.assertEqual(len(runs), 1)
        self.assertEqual(runs[0]["env"]["CMUX_GUARDS_BASE_SHA"], expression)


class TheBaseCheckoutLeavesTheHeadClean(unittest.TestCase):
    """The base is checked out at .guard-base inside the head's workspace, an untracked directory, so the
    ci group's "Run canonical CMUX CI guard profile" refused the head ("checkout has non-ignored source
    changes") on every run. The job excludes it before the guards run."""

    def test_the_base_checkout_is_excluded_from_the_head(self):
        workflow = yaml.safe_load((WORKFLOWS / "cmux-next-guards.yml").read_text(encoding="utf-8"))
        steps = workflow["jobs"]["ci-guard-group"]["steps"]
        run = next(str(step["run"]) for step in steps if "guards-local.sh" in str(step.get("run", "")))
        exclude = run.index("/.guard-base/")
        self.assertIn(".git/info/exclude", run[exclude:exclude + 80])
        self.assertLess(exclude, run.index("scripts/ci/guards-local.sh"))


class APushRunsEveryRoutedGroup(unittest.TestCase):
    """A product-only change (Packages/, webviews/, cmux-tui/ ...) routes no extra group on a pull request
    (detect_linux_guard_changes.FEAT_PRODUCT_AREAS), so a guard such a change breaks would stay unseen. A push
    to feat-cmux-next runs every routed group, judged against the previous tip, so the red shows on the push
    that caused it. The "Changed files" step writes no routing list for a push, and keeps the base."""

    def run_step(self, event: str) -> tuple[bool, str]:
        workflow = yaml.safe_load((WORKFLOWS / "cmux-next-guards.yml").read_text(encoding="utf-8"))
        step = next(s for s in workflow["jobs"]["ci-guard-group"]["steps"] if s.get("name") == "Changed files")
        with tempfile.TemporaryDirectory(prefix="guard-push-") as temp:
            root = Path(temp)
            repo, runner_temp, bin_dir = root / "repo", root / "runner", root / "bin"
            for directory in (repo, runner_temp, bin_dir):
                directory.mkdir()
            env = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}

            def git(*args: str) -> str:
                return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.com",
                                       "-c", "commit.gpgsign=false", *args], cwd=repo, env=env, check=True,
                                      capture_output=True, text=True).stdout.strip()

            git("init", "--quiet")
            (repo / "a.txt").write_text("a\n", encoding="utf-8")
            git("add", "-A")
            git("commit", "--quiet", "-m", "base")
            before = git("rev-parse", "HEAD")
            (repo / "Packages").mkdir()
            (repo / "Packages" / "x.swift").write_text("x\n", encoding="utf-8")
            git("add", "-A")
            git("commit", "--quiet", "-m", "head")
            # The push path fetches the previous tip; this repository already has it.
            real_git = shutil.which("git")
            (bin_dir / "git").write_text(
                f'#!/bin/sh\n[ "$1" = fetch ] && exit 0\nexec "{real_git}" "$@"\n', encoding="utf-8")
            (bin_dir / "git").chmod(0o755)
            output = runner_temp / "github_output"
            subprocess.run(["bash", "-eo", "pipefail", "-c", step["run"]], cwd=repo, check=True,
                           capture_output=True, text=True,
                           env={**env, "PATH": f"{bin_dir}:{env['PATH']}", "EVENT_NAME": event,
                                "BEFORE": before if event == "push" else "", "RUNNER_TEMP": str(runner_temp),
                                "GITHUB_OUTPUT": str(output)})
            listed = (runner_temp / "changed-files.txt").is_file()
            outputs = output.read_text(encoding="utf-8") if output.is_file() else ""
            self.assertIn(f"base={before}", outputs)
            return listed, outputs

    def test_a_push_writes_no_routing_list_but_keeps_its_base(self):
        listed, _ = self.run_step("push")
        self.assertFalse(listed, "a push must run every routed group (no changed-files list)")

    def test_a_pull_request_is_routed_by_its_changed_files(self):
        listed, _ = self.run_step("pull_request")
        self.assertTrue(listed)


class TheRoutedGroupsHaveTheirTools(unittest.TestCase):
    """run_ci_guards.py skips `uses:` steps, so the job itself provides what ci-guards.yml's setup steps do:
    bun for preflight-agent-chat, and python3.9 (beside the default python3) for release-tooling's nightly
    prune compatibility step, which runs `PYTHON_BIN=python3.9` (red on #23534's first run)."""

    def test_the_guard_group_job_sets_up_bun_and_python_3_9(self):
        workflow = yaml.safe_load((WORKFLOWS / "cmux-next-guards.yml").read_text(encoding="utf-8"))
        steps = workflow["jobs"]["ci-guard-group"]["steps"]
        uses = {str(step.get("uses", "")).split("@")[0]: step for step in steps if step.get("uses")}
        self.assertIn("oven-sh/setup-bun", uses)
        python = uses.get("actions/setup-python")
        self.assertIsNotNone(python, "no setup-python step")
        self.assertEqual(str(python["with"]["python-version"]), "3.9")
        # The default python3 stays the runner's: the guard venv and the other groups need it.
        self.assertIs(python["with"].get("update-environment"), False)
        runs = "\n".join(str(step.get("run", "")) for step in steps)
        self.assertIn("python3.9", runs)
        self.assertIn("GITHUB_PATH", runs)


class TheGuardGroupRunsOnItsMeasuredSize(unittest.TestCase):
    """The job runs every routed guard group twice (the head, then the base) with a worker per core, and runs on
    every feat-cmux-next pull request and push. On 4 vCPU with 8 workers it took 175-359 s (runs 39873974117,
    39873712114), and on 32 vCPU 3.3 min mean, 4.9 p90 (2026-10-30/31), so the 32 vCPU size bought nothing. Leo,
    2026-11-01: "we should have resized a long-ass time ago." It takes the size .github/runners.json linux_sizes
    measured for it, with
    the Blacksmith outage guard the compile jobs use (tests/test_ci_linux_compile_runners.py), and as many workers
    as the runner has cores."""

    def job(self) -> dict:
        workflow = yaml.safe_load((WORKFLOWS / "cmux-next-guards.yml").read_text(encoding="utf-8"))
        return workflow["jobs"]["ci-guard-group"]

    def test_the_job_runs_on_its_measured_size_and_follows_the_outage_switch(self):
        # Fleet Linux, then a free mini (portable-placement), then Blacksmith at its measured size
        # (scripts/ci/portable_job_placement.py; Leo, 2026-10-31: "i mean the linux things cant our minis just run them").
        placed = "needs.portable-placement.outputs"
        attempt = f"{placed}.placed_attempt == format('{{0}}', github.run_attempt)"
        self.assertEqual(self.job()["needs"], ["portable-placement"])
        self.assertEqual(self.job()["if"], "${{ !cancelled() }}")
        self.assertEqual(
            self.job()["runs-on"],
            "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || github.event_name == 'pull_request'"
            " && github.event.pull_request.head.repo.full_name != github.repository && 'blacksmith-4vcpu-ubuntu-2404'"
            f" || {attempt} && contains({placed}.linux_jobs, ' ci-guard-group ') && {placed}.linux_runner"
            f" || {attempt} && contains({placed}.mini_jobs, ' ci-guard-group ') && {placed}.mini_runner"
            " || !startsWith(vars.LINUX_RUNNER, 'blacksmith-') && vars.LINUX_RUNNER"
            " || " + blacksmith_route("cmux-next-guards.yml", "ci-guard-group") + " }}",
        )

    def test_each_guard_pass_uses_a_worker_per_core(self):
        run = "\n".join(str(step.get("run", "")) for step in self.job()["steps"])
        calls = [line for line in run.splitlines() if "scripts/ci/guards-local.sh" in line]
        self.assertEqual(len(calls), 2, calls)
        for call in calls:
            with self.subTest(call=call):
                # getconf, not nproc: a mini (macOS) has no GNU coreutils.
                self.assertIn('--jobs "$(getconf _NPROCESSORS_ONLN)"', call)
                self.assertNotIn("--jobs 8", call)


if __name__ == "__main__":
    unittest.main()
