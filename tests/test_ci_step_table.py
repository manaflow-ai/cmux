#!/usr/bin/env python3
"""The step table (ci/steps.toml) and its runner (scripts/ci/ci_steps.py).

Leo, 2026-11-13: "Few jobs on warm trees; the PR runs what base runs on the tree that lands. 267 jobs
per PR become one step table and at most 8 jobs; a landing train tests the merge result (3.81 base
reds per 100 landings today). Advisory steps run idle-class and never block."

This test holds three things:

  - the table: at most 8 jobs, and a step that does not block runs in the `advisory` job, class `idle`;
  - the runner: an advisory step's failure or timeout is a warning and the job passes; a blocking
    step's failure fails it; a label event runs only the steps that list the label;
  - the budget: the jobs a pull request into feat-cmux-next can start stay at or under
    [budget] pr_jobs, which only goes down, toward target_pr_jobs.
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

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
sys.path.insert(0, str(ROOT / "tests"))
import ci_steps  # noqa: E402
from test_ci_post_merge_checks import BASE, branch_matches, load_workflows, triggers  # noqa: E402


def table(steps: str, jobs: str = 'linux = "l"\nadvisory = "a"') -> ci_steps.Table:
    import tomllib

    return ci_steps.parse(tomllib.loads(f"[jobs]\n{jobs}\n{textwrap.dedent(steps)}"))


def matrix_size(job: dict) -> int:
    """The jobs a job's matrix expands to: the product of its literal lists, less `exclude`, and
    each `include` entry when there are no lists. A matrix read from an expression counts as 1."""
    matrix = (job.get("strategy") or {}).get("matrix") if isinstance(job, dict) else None
    if not isinstance(matrix, dict):
        return 1
    lists = [v for k, v in matrix.items() if k not in ("include", "exclude") and isinstance(v, list)]
    include = matrix.get("include") if isinstance(matrix.get("include"), list) else []
    exclude = matrix.get("exclude") if isinstance(matrix.get("exclude"), list) else []
    if not lists:
        return max(1, len(include))
    size = 1
    for values in lists:
        size *= len(values)
    return max(1, size - len(exclude))


def pr_jobs(workflows: dict[str, dict], base: str = BASE) -> int:
    """Jobs a pull request into `base` can start: each job of each workflow it triggers times its
    matrix, a job that calls a local reusable workflow counted as that workflow's jobs (at any
    depth) times the caller's matrix."""

    def count(name: str, seen: tuple[str, ...] = ()) -> int:
        total = 0
        for job in (workflows[name].get("jobs") or {}).values():
            uses = job.get("uses") if isinstance(job, dict) else None
            if isinstance(uses, str) and uses.startswith("./.github/workflows/"):
                callee = uses.rsplit("/", 1)[1].split("@", 1)[0]
                if callee in workflows and callee not in seen:
                    total += matrix_size(job) * count(callee, seen + (name,))
                    continue
            total += matrix_size(job)
        return total

    return sum(
        count(name)
        for name, doc in workflows.items()
        if any(
            event in triggers(doc) and branch_matches(triggers(doc)[event], base, push=False)
            for event in ("pull_request", "pull_request_target")
        )
    )


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
    def run_job(self, t: ci_steps.Table, job: str, label: str | None = None) -> tuple[int, str]:
        out = io.StringIO()
        env = {k: v for k, v in os.environ.items() if k != "GITHUB_STEP_SUMMARY"}
        old = os.environ
        os.environ = env  # the summary goes nowhere
        try:
            code = ci_steps.run_job(t, job, None, label, out)
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
                [sys.executable, "scripts/ci/ci_steps.py", "run", "--job", "advisory"],
                cwd=ROOT, env=env, capture_output=True, text=True, timeout=120,
            )
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            for name in ("design-spec", "perf-section", "cloud-backend"):
                self.assertIn(f"::group::{name}", run.stdout)
            self.assertNotIn("::error title", run.stdout)

    def test_the_workflow_runs_the_base_table(self) -> None:
        wf = yaml.safe_load((ROOT / ".github/workflows/pr-body-checks.yml").read_text())
        body = wf["jobs"]["body"]
        sparse = body["steps"][0]["with"]["sparse-checkout"]
        self.assertIn("ci/steps.toml", sparse)
        self.assertIn("scripts/ci/ci_steps.py", sparse)
        step = next(s for s in body["steps"] if s.get("name") == "Run the advisory steps")
        self.assertIs(step.get("continue-on-error"), True)
        self.assertIn('ci_steps.py run --job advisory --label "$LABEL"', step["run"])
        names = [s.get("name", "") for s in body["steps"]]
        for gone in ("Check the description cites each changed surface's spec",
                     "Check the description for a Performance table",
                     "Check where the cloud backend change belongs"):
            self.assertNotIn(gone, names, "the step table runs it")


class PullRequestJobBudgetTest(unittest.TestCase):
    def test_counting(self) -> None:
        workflows = {
            "pr.yml": {"on": {"pull_request": {"branches": [BASE]}}, "jobs": {
                "a": {}, "b": {}, "call": {"uses": "./.github/workflows/lib.yml"}}},
            "lib.yml": {"on": "workflow_call", "jobs": {"x": {}, "y": {}}},
            "main.yml": {"on": {"pull_request": {"branches": ["main"]}}, "jobs": {"m": {}}},
            "push.yml": {"on": "push", "jobs": {"p": {}}},
        }
        self.assertEqual(pr_jobs(workflows), 4)

    def test_counting_matrices(self) -> None:
        shards = {"strategy": {"matrix": {"shard": list(range(20))}}}
        workflows = {
            "pr.yml": {"on": "pull_request", "jobs": {
                "shards": shards,
                "grid": {"strategy": {"matrix": {"os": ["a", "b"], "py": [1, 2, 3], "exclude": [{"os": "a", "py": 1}]}}},
                "include": {"strategy": {"matrix": {"include": [{"x": 1}, {"x": 2}]}}},
                "dynamic": {"strategy": {"matrix": "${{ fromJSON(needs.a.outputs.m) }}"}},
                "call": {"uses": "./.github/workflows/lib.yml", "strategy": {"matrix": {"n": [1, 2]}}}}},
            "lib.yml": {"on": "workflow_call", "jobs": {"x": shards}},
        }
        self.assertEqual(pr_jobs(workflows), 20 + 5 + 2 + 1 + 2 * 20)

    def test_pull_request_jobs_stay_within_the_budget(self) -> None:
        budget = ci_steps.load().budget
        found = pr_jobs(load_workflows())
        print(f"jobs a pull request into {BASE} can start: {found} (budget {budget['pr_jobs']}, "
              f"target {budget['target_pr_jobs']})")
        self.assertLessEqual(
            found, budget["pr_jobs"],
            f"A pull request into {BASE} can now start {found} jobs, over the budget of "
            f"{budget['pr_jobs']} in ci/steps.toml. Add a step to an existing job of the table "
            "instead of a new job; the budget only goes down.",
        )
        self.assertLessEqual(budget["target_pr_jobs"], ci_steps.MAX_JOBS)


if __name__ == "__main__":
    unittest.main()
