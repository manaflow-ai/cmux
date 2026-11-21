#!/usr/bin/env python3
"""The step table (ci/steps.toml) and its runner (scripts/ci/ci_steps.py).

Leo, 2026-11-13: "Few jobs on warm trees; the PR runs what base runs on the tree that lands. 267 jobs
per PR become one step table and at most 8 jobs; a landing train tests the merge result (3.81 base
reds per 100 landings today). Advisory steps run idle-class and never block."

This test holds two things:

  - the table: at most 8 jobs, and a step that does not block runs in the `advisory` job, class `idle`;
  - the runner: an advisory step's failure or timeout is a warning and the job passes; a blocking
    step's failure fails it; a label event runs only the steps that list the label; `--only` runs the
    named subset, skips a name the table lacks with a notice, and runs every routed step when empty;
  - the workflows: pr-body-checks.yml and pr-checks.yml each run their own advisory steps from the base.
"""

from __future__ import annotations

import io
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
sys.path.insert(0, str(ROOT / "tests"))
import ci_steps  # noqa: E402
from test_ci_post_merge_checks import BASE, branch_matches, load_workflows, triggers  # noqa: E402


def table(steps: str, jobs: str = 'linux = "l"\nadvisory = "a"') -> ci_steps.Table:
    import tomllib

    return ci_steps.parse(tomllib.loads(f"[jobs]\n{jobs}\n{textwrap.dedent(steps)}"))


class TableRulesTest(unittest.TestCase):
    def test_the_repository_table_loads(self) -> None:
        t = ci_steps.load()
        self.assertLessEqual(len(t.jobs), ci_steps.MAX_JOBS)
        self.assertIn("advisory", t.jobs)
        for step in t.steps.values():
            if not step.blocks:
                self.assertEqual((step.job, step.klass), ("advisory", "idle"), step.name)

    def test_at_most_eight_jobs(self) -> None:
        jobs = "\n".join(f'j{i} = "x"' for i in range(9))
        with self.assertRaisesRegex(ci_steps.TableError, "at most 8"):
            table("", jobs)

    def test_an_advisory_step_runs_idle_in_the_advisory_job(self) -> None:
        with self.assertRaisesRegex(ci_steps.TableError, "does not block"):
            table('[step.a]\njob = "linux"\nblocks = false\nclass = "idle"\nrun = "true"')
        with self.assertRaisesRegex(ci_steps.TableError, "does not block"):
            table('[step.a]\njob = "advisory"\nblocks = false\nrun = "true"')
        with self.assertRaisesRegex(ci_steps.TableError, "holds only"):
            table('[step.a]\njob = "advisory"\nrun = "true"')

    def test_unknown_job_or_key(self) -> None:
        with self.assertRaisesRegex(ci_steps.TableError, "not one of"):
            table('[step.a]\njob = "mac"\nrun = "true"')
        with self.assertRaisesRegex(ci_steps.TableError, "unknown keys"):
            table('[step.a]\njob = "linux"\nrun = "true"\nblock = false')

    def test_route_by_inputs_and_label(self) -> None:
        t = table('''
            [step.web]
            job = "linux"
            inputs = ["webviews/**"]
            run = "true"
            [step.rust]
            job = "linux"
            inputs = ["cmux-tui/**/*.rs"]
            run = "true"
            [step.perf]
            job = "advisory"
            blocks = false
            class = "idle"
            labels = ["perf"]
            run = "true"
        ''')
        self.assertEqual(ci_steps.route(t, ["webviews/src/a.tsx"]), {"linux": ["web"], "advisory": ["perf"]})
        self.assertEqual(ci_steps.route(t, ["cmux-tui/src/main.rs"])["linux"], ["rust"])
        self.assertEqual(ci_steps.route(t, ["docs/x.md"]), {"advisory": ["perf"]})
        self.assertEqual(ci_steps.route(t, None)["linux"], ["web", "rust"], "an unknown diff routes every step")
        self.assertEqual(ci_steps.route(t, None, "perf"), {"advisory": ["perf"]})
        self.assertEqual(ci_steps.route(t, None, "risk:low"), {})


class RunnerTest(unittest.TestCase):
    def run_job(self, t: ci_steps.Table, job: str, label: str | None = None,
                only: list[str] | None = None) -> tuple[int, str]:
        out = io.StringIO()
        env = {k: v for k, v in os.environ.items() if k != "GITHUB_STEP_SUMMARY"}
        old = os.environ
        os.environ = env  # the summary goes nowhere
        try:
            code = ci_steps.run_job(t, job, None, label, out, only=only)
        finally:
            os.environ = old
        return code, out.getvalue()

    def test_an_advisory_failure_or_timeout_never_blocks(self) -> None:
        t = table('''
            [step.fails]
            job = "advisory"
            blocks = false
            class = "idle"
            title = "Fails"
            run = "echo before; exit 3"
            [step.hangs]
            job = "advisory"
            blocks = false
            class = "idle"
            timeout = 1
            run = "sleep 30"
            [step.passes]
            job = "advisory"
            blocks = false
            class = "idle"
            run = "echo fine"
        ''')
        code, out = self.run_job(t, "advisory")
        self.assertEqual(code, 0, out)
        self.assertIn("::warning title=Fails::step fails exited 3 (advisory: never blocks)", out)
        self.assertIn("step hangs ran past its 1 s (advisory: never blocks)", out)
        self.assertIn("before", out)
        self.assertIn("fine", out)
        self.assertNotIn("::error", out)

    def test_a_timed_out_step_whose_group_cannot_be_signalled_still_times_out(self) -> None:
        # macOS answers killpg with EPERM, not ESRCH, when each process left in the step's group is a zombie
        # (tests/test_ci_killpg_tolerates_eperm.py). The step ran past its timeout all the same: no exception,
        # code None, and what the step printed is read.
        step = table('[step.slow]\njob = "linux"\ntimeout = 1\nrun = "echo before; sleep 2"').steps["slow"]
        with mock.patch.object(ci_steps.os, "killpg", side_effect=PermissionError(1, "Operation not permitted")):
            result = ci_steps.run_step(step)
        self.assertIsNone(result.code)
        self.assertIn("before", result.output)

    def test_a_blocking_failure_fails_the_job(self) -> None:
        t = table('[step.a]\njob = "linux"\nrun = "false"\n[step.b]\njob = "linux"\nrun = "true"')
        code, out = self.run_job(t, "linux")
        self.assertEqual(code, 1)
        self.assertIn("::error title=a::step a exited 1", out)

    def test_bash_runs_strict(self) -> None:
        t = table('[step.a]\njob = "linux"\nrun = "false | true\\necho reached"')
        code, out = self.run_job(t, "linux")
        self.assertEqual(code, 1, "pipefail: a failed stage fails the step")
        self.assertNotIn("reached", out)

    def test_steps_run_at_once(self) -> None:
        steps = "".join(f'[step.s{i}]\njob = "linux"\nrun = "sleep 1"\n' for i in range(4))
        t = table(steps)
        start = __import__("time").monotonic()
        code, _ = self.run_job(t, "linux")
        self.assertEqual(code, 0)
        self.assertLess(__import__("time").monotonic() - start, 3.5)

    def test_a_label_event_runs_only_its_steps(self) -> None:
        t = table('''
            [step.perf]
            job = "advisory"
            blocks = false
            class = "idle"
            labels = ["perf"]
            run = "echo perf-ran"
            [step.other]
            job = "advisory"
            blocks = false
            class = "idle"
            run = "echo other-ran"
        ''')
        _, out = self.run_job(t, "advisory", "perf")
        self.assertIn("perf-ran", out)
        self.assertNotIn("other-ran", out)
        _, out = self.run_job(t, "advisory", "media-tour")
        self.assertIn("No step of job advisory", out)

    ONLY = '''
        [step.one]
        job = "advisory"
        blocks = false
        class = "idle"
        run = "echo one-ran"
        [step.two]
        job = "advisory"
        blocks = false
        class = "idle"
        run = "echo two-ran"
        [step.three]
        job = "advisory"
        blocks = false
        class = "idle"
        run = "echo three-ran"
    '''

    def test_only_runs_the_named_subset(self) -> None:
        t = table(self.ONLY)
        self.assertEqual(ci_steps.parse_only("one, three"), ["one", "three"])
        self.assertEqual(ci_steps.parse_only("one three\n"), ["one", "three"])
        code, out = self.run_job(t, "advisory", only=ci_steps.parse_only("one,three"))
        self.assertEqual(code, 0, out)
        self.assertIn("one-ran", out)
        self.assertIn("three-ran", out)
        self.assertNotIn("two-ran", out)

    def test_only_skips_a_name_the_table_lacks(self) -> None:
        # The pull request that adds a step runs against a base whose table lacks it: a notice, never an error.
        t = table(self.ONLY)
        code, out = self.run_job(t, "advisory", only=["two", "added-later"])
        self.assertEqual(code, 0, out)
        self.assertIn("::notice title=Step table::no step added-later", out)
        self.assertIn("two-ran", out)
        self.assertNotIn("one-ran", out)
        code, out = self.run_job(t, "advisory", only=["added-later"])
        self.assertEqual(code, 0, out)
        self.assertIn("No step of job advisory", out)

    def test_empty_only_runs_every_routed_step(self) -> None:
        t = table(self.ONLY)
        self.assertEqual(ci_steps.parse_only(""), [])
        for only in (None, [], ci_steps.parse_only(" , ")):
            with self.subTest(only=only):
                _, out = self.run_job(t, "advisory", only=only)
                for name in ("one", "two", "three"):
                    self.assertIn(f"{name}-ran", out)

    def test_only_on_the_command_line(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, "steps.toml")
            path.write_text('[jobs]\nadvisory = "a"\n' + textwrap.dedent(self.ONLY))
            env = {k: v for k, v in os.environ.items() if k != "GITHUB_STEP_SUMMARY"}
            run = subprocess.run(
                [sys.executable, str(ROOT / "scripts/ci/ci_steps.py"), "--table", str(path), "run", "--job", "advisory",
                 "--only", "three gone"], env=env, capture_output=True, text=True, timeout=60,
            )
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("three-ran", run.stdout)
            self.assertNotIn("one-ran", run.stdout)
            self.assertIn("no step gone", run.stdout)


PR_CHECKS_STEPS = ("pr-size", "ui-review", "split-plan", "swift-logic", "review-link")


class RepositoryAdvisoryStepsTest(unittest.TestCase):
    """The table's own advisory steps, run as the workflow runs them, against this checkout."""

    def test_they_skip_without_listed_paths_and_never_block(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env = {
                **os.environ, "RUNNER_TEMP": tmp, "BODY": "x", "TITLE": "docs: a typo", "LABELS": "",
                "PATHS_LISTED": "true", "TREE_LISTED": "true", "ADDITIONS": "1", "DELETIONS": "1",
            }
            env.pop("GITHUB_STEP_SUMMARY", None)
            Path(tmp, "paths.txt").write_text("docs/x.md\n")
            Path(tmp, "status.txt").write_text("M\tdocs/x.md\n")
            Path(tmp, "tree.txt").write_text("docs/x.md\n")
            Path(tmp, "design-surfaces.json").write_text("{}")
            run = subprocess.run(
                [sys.executable, "scripts/ci/ci_steps.py", "run", "--job", "advisory",
                 "--only", "design-spec perf-section cloud-backend"],
                cwd=ROOT, env=env, capture_output=True, text=True, timeout=120,
            )
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            for name in ("design-spec", "perf-section", "cloud-backend"):
                self.assertIn(f"::group::{name}", run.stdout)
            for name in PR_CHECKS_STEPS:
                self.assertNotIn(f"::group::{name}", run.stdout)
            self.assertNotIn("::error title", run.stdout)

    def test_the_workflow_runs_the_base_table(self) -> None:
        wf = yaml.safe_load((ROOT / ".github/workflows/pr-body-checks.yml").read_text())
        body = wf["jobs"]["body"]
        sparse = body["steps"][0]["with"]["sparse-checkout"]
        self.assertIn("ci/steps.toml", sparse)
        self.assertIn("scripts/ci/ci_steps.py", sparse)
        step = next(s for s in body["steps"] if s.get("name") == "Run the advisory steps")
        self.assertIs(step.get("continue-on-error"), True)
        self.assertIn('ci_steps.py run --job advisory --label "$LABEL" "${only[@]}"', step["run"])
        self.assertIn('only=(--only "design-spec perf-section cloud-backend")', step["run"])
        names = [s.get("name", "") for s in body["steps"]]
        for gone in ("Check the description cites each changed surface's spec",
                     "Check the description for a Performance table",
                     "Check where the cloud backend change belongs"):
            self.assertNotIn(gone, names, "the step table runs it")


class PrChecksAdvisoryJobTest(unittest.TestCase):
    """pr-checks.yml's advisory job (CI v2 step 6): its five checks are steps of the table, run from the base."""

    def setUp(self) -> None:
        self.table = ci_steps.load()
        wf = yaml.safe_load((ROOT / ".github/workflows/pr-checks.yml").read_text())
        self.job = wf["jobs"]["advisory"]
        self.steps = {s.get("name"): s for s in self.job["steps"]}

    def test_its_steps_are_advisory_idle_steps_of_the_table(self) -> None:
        for name in PR_CHECKS_STEPS:
            with self.subTest(step=name):
                step = self.table.steps[name]
                self.assertEqual((step.job, step.blocks, step.klass), ("advisory", False, "idle"))
                self.assertFalse(step.labels, "a label event runs only pr-body-checks.yml's steps")
                self.assertLessEqual(step.timeout, 10 * 60, "within the run step's timeout")

    def test_it_runs_the_picked_steps_from_the_base_checkout(self) -> None:
        checkout = self.steps["Check out the advisory steps from the base"]
        self.assertEqual(checkout["with"]["ref"], "${{ github.event.pull_request.base.sha }}")
        sparse = checkout["with"]["sparse-checkout"].split()
        for path in ("ci/steps.toml", "scripts/ci/ci_steps.py", "scripts/cmux-next/check-pr-split.py"):
            self.assertIn(path, sparse)
        # Every script a step runs is in the sparse checkout.
        for name in PR_CHECKS_STEPS:
            for path in set(__import__("re").findall(r"scripts/[\w./-]+\.py", self.table.steps[name].run)):
                self.assertIn(path, sparse, f"{name} runs {path}")
        run = self.steps["Run the advisory steps"]
        self.assertIs(run.get("continue-on-error"), True)
        self.assertIn('ci_steps.py run --job advisory --only "$PICKED"', run["run"])
        self.assertIn("::notice::The base branch has no step table", run["run"])
        self.assertEqual(run["if"], "steps.pick.outputs.steps != ''", "an empty --only would run every step")

    def test_split_plan_fetches_two_commits_not_every_branch(self) -> None:
        run = self.table.steps["split-plan"].run
        self.assertNotIn("--unshallow origin\n", run)
        self.assertIn('--shallow-since="14 days ago" origin "$BASE_SHA" "$HEAD_SHA"', run)
        self.assertIn("--no-recurse-submodules", run)
        self.assertIn("--filter=blob:none", run)
        self.assertIn('check-pr-split.py --repo "$repo" --base "$BASE_SHA" --head "$HEAD_SHA" --mode advisory', run)

    def test_split_plan_measures_a_local_pull_request(self) -> None:
        self.measure(old=False)

    def test_split_plan_deepens_when_the_merge_base_is_older_than_its_window(self) -> None:
        self.measure(old=True)

    def measure(self, old: bool) -> None:
        def git(repo: Path, *args: str) -> str:
            dated = {"GIT_AUTHOR_DATE": "2000-01-01T00:00:00Z", "GIT_COMMITTER_DATE": "2000-01-01T00:00:00Z"}
            return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True,
                                  env={**os.environ, **(dated if old else {})}).stdout.strip()

        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp, "src")
            src.mkdir()
            git(src, "init", "-q", "-b", "feat-cmux-next")
            git(src, "config", "user.email", "t@example.com")
            git(src, "config", "user.name", "t")
            git(src, "config", "uploadpack.allowFilter", "true")
            git(src, "config", "uploadpack.allowAnySHA1InWant", "true")
            Path(src, "a.txt").write_text("a\n")
            git(src, "add", "-A")
            git(src, "commit", "-qm", "base")
            base = git(src, "rev-parse", "HEAD")
            git(src, "checkout", "-qb", "pr")
            Path(src, "webviews").mkdir()
            Path(src, "webviews/b.tsx").write_text("b\n")
            git(src, "add", "-A")
            git(src, "commit", "-qm", "pr")
            head = git(src, "rev-parse", "HEAD")
            temp = Path(tmp, "temp")
            temp.mkdir()
            env = {**os.environ, "RUNNER_TEMP": str(temp), "URL": f"file://{src}", "PR": "7",
                   "BASE_SHA": base, "HEAD_SHA": head, "BASE_REF": "feat-cmux-next"}
            run = subprocess.run(["bash", "-euo", "pipefail", "-c", self.table.steps["split-plan"].run],
                                 cwd=ROOT, env=env, capture_output=True, text=True, timeout=120)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn(f"merge-base={base} head={head} files=1 commits=1", run.stdout)
            self.assertEqual("No merge base in the last 14 days" in run.stdout, old, run.stdout)


if __name__ == "__main__":
    unittest.main()
