#!/usr/bin/env python3
"""scripts/ci/run_ci_guards.py must run what ci-guards.yml runs, and finish.

The runner reads ci-guards.yml instead of keeping its own list, so the cases
here pin the reading: every guard job and matrix group is planned, `uses:`
steps and the per-job dependency installs are left out, and the step names
the runner special-cases still exist. The last case is the hang it was built
around: a guard test that leaks a background child must not keep the runner
waiting on the child's copy of the output pipe.
"""

from __future__ import annotations

import concurrent.futures
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import run_ci_guards  # noqa: E402

FAST_WORKFLOW = ROOT / ".github/workflows/ci-fast-guards.yml"


class PlanFollowsTheWorkflow(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workflow = run_ci_guards.load_yaml(run_ci_guards.WORKFLOW)
        cls.units = run_ci_guards.plan(cls.workflow, "base", "head")

    def test_every_guard_job_is_planned(self) -> None:
        planned_jobs = {unit.job for unit in self.units}
        self.assertEqual(planned_jobs, set(run_ci_guards.GUARD_JOBS))
        guard_jobs = {
            name for name in self.workflow["jobs"] if name.startswith("workflow-guard-")
        }
        self.assertEqual(guard_jobs, set(run_ci_guards.GUARD_JOBS), "a new guard job needs a GUARD_JOBS entry")

    def test_every_routed_group_is_planned(self) -> None:
        text = run_ci_guards.WORKFLOW.read_text(encoding="utf-8")
        named = set(re.findall(r"matrix\.group == '([a-z0-9-]+)'", text))
        planned = {unit.group for unit in self.units if unit.group}
        self.assertEqual(named, planned)
        for group in run_ci_guards.FAST_GROUPS:
            self.assertIn(group, planned)

    def test_every_run_step_is_planned_once_per_group(self) -> None:
        job = self.workflow["jobs"]["workflow-guard-tests"]
        for unit in (u for u in self.units if u.job == "workflow-guard-tests"):
            expected = [
                s["name"]
                for s in job["steps"]
                if "run" in s
                and s["name"] not in run_ci_guards.DEPENDENCY_STEPS
                and (not s.get("if") or f"'{unit.group}'" in s["if"])
            ]
            self.assertEqual([s.name for s in unit.steps], expected, unit.label)

    def test_uses_steps_and_dependency_installs_are_left_out(self) -> None:
        names = {step.name for unit in self.units for step in unit.steps}
        self.assertFalse(names & run_ci_guards.DEPENDENCY_STEPS)
        self.assertNotIn("Checkout", names)

    def test_special_cased_step_names_still_exist(self) -> None:
        names = {
            str(step.get("name"))
            for job in run_ci_guards.GUARD_JOBS
            for step in self.workflow["jobs"][job]["steps"]
        }
        self.assertLessEqual(run_ci_guards.DEPENDENCY_STEPS, names)
        self.assertLessEqual(run_ci_guards.LINUX_ONLY_STEPS, names)
        self.assertLessEqual(set(run_ci_guards.PORTABLE_SUBSTITUTES), names)
        self.assertLessEqual(run_ci_guards.EVENT_CONDITION_STEPS, names)

    def test_expressions_are_resolved(self) -> None:
        for unit in self.units:
            for step in unit.steps:
                self.assertNotIn("${{ matrix.group }}", step.run, step.name)
        ios = next(u for u in self.units if u.group == "release-ios")
        env = next(s.env for s in ios.steps if "BASE_SHA" in s.env)
        self.assertEqual(env["BASE_SHA"], "base")

    def test_groups_that_pass_state_between_steps_run_in_order(self) -> None:
        by_group = {unit.group or unit.job: unit for unit in self.units}
        # agent-chat's bun install feeds its bun test (working-directory).
        self.assertTrue(run_ci_guards.is_stateful(by_group["preflight"]))
        # The fast group's steps are independent, which is what makes it fast.
        self.assertFalse(run_ci_guards.is_stateful(by_group["ci"]))


class PlanRefusesWhatItCannotRun(unittest.TestCase):
    def workflow(self, step: dict) -> dict:
        jobs = {name: {"steps": []} for name in run_ci_guards.GUARD_JOBS}
        jobs["workflow-guard-tests"] = {
            "strategy": {"matrix": {"group": "${{ fromJSON(inputs.groups) }}"}},
            "steps": [{"name": "a", "if": "${{ matrix.group == 'ci' }}", "run": "true"}, step],
        }
        return {"jobs": jobs}

    def test_an_unknown_condition_fails_instead_of_dropping_the_step(self) -> None:
        step = {"name": "b", "if": "${{ matrix.group == 'ci' && !cancelled() }}", "run": "true"}
        with self.assertRaises(run_ci_guards.PlanError):
            run_ci_guards.plan(self.workflow(step), "base", "head")

    def test_an_unknown_expression_fails_instead_of_resolving_empty(self) -> None:
        step = {"name": "b", "if": "${{ matrix.group == 'ci' }}", "run": 'test "${{ github.event_name }}" = x'}
        with self.assertRaises(run_ci_guards.PlanError):
            run_ci_guards.plan(self.workflow(step), "base", "head")
        literal = {"name": "b", "if": "${{ matrix.group == 'ci' }}", "run": "echo ${{ github.sha || 'none' }}"}
        units = run_ci_guards.plan(self.workflow(literal), "base", "head")
        self.assertEqual(units[0].steps[1].run, "echo head")

    def test_a_submodule_checkout_makes_its_group_sequential(self) -> None:
        unit = run_ci_guards.Unit("j", "g", [
            run_ci_guards.Step("init", "git submodule update --init vendor/bonsplit", {}, None),
            run_ci_guards.Step("use", "python3 lint.py", {}, None),
        ])
        self.assertTrue(run_ci_guards.is_stateful(unit))


class StepsFinish(unittest.TestCase):
    def test_a_leaked_background_child_does_not_hang_the_runner(self) -> None:
        step = run_ci_guards.Step(
            name="leaks a child",
            run="python3 -c 'import signal; signal.pause()' & echo started",
            env={},
            working_directory=None,
        )
        with tempfile.TemporaryDirectory() as temp, concurrent.futures.ThreadPoolExecutor(1) as pool:
            future = pool.submit(run_ci_guards.run_step, step, Path(temp), {"PATH": "/usr/bin:/bin"}, Path(temp) / "log")
            # A hang raises TimeoutError here instead of blocking the suite.
            code, output = future.result(timeout=60)
        self.assertEqual(code, 0)
        self.assertIn("started", output)

    def test_a_failing_step_reports_its_exit_code_and_output(self) -> None:
        step = run_ci_guards.Step(name="fails", run="echo nope; exit 3", env={}, working_directory=None)
        with tempfile.TemporaryDirectory() as temp:
            code, output = run_ci_guards.run_step(step, Path(temp), {"PATH": "/usr/bin:/bin"}, Path(temp) / "log")
        self.assertEqual(code, 3)
        self.assertIn("nope", output)


class PortableSubstitutes(unittest.TestCase):
    PAYLOAD = ROOT / "scripts/ci/run_ci_guard_payload.sh"

    def run_payload(self, text: str) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temp:
            payload = Path(temp) / "ci-guard.sh"
            payload.write_text(text)
            return subprocess.run(["bash", str(self.PAYLOAD), str(payload)], cwd=temp,
                                  capture_output=True, text=True, timeout=60)

    def test_the_substitute_runs_the_real_payload(self) -> None:
        self.assertEqual(
            run_ci_guards.PORTABLE_SUBSTITUTES["Run canonical CMUX CI guard profile"],
            "scripts/ci/run_ci_guard_payload.sh",
        )
        # Every line of the real ci-guard.sh is one the substitute recognizes.
        text = (ROOT / "scripts/ci/workloads/ci-guard.sh").read_text(encoding="utf-8")
        stubbed = re.sub(r"(?m)^(\./|python3 )(?!\"\$root).*$", "bash -c true", text)
        result = self.run_payload(stubbed)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_every_command_runs_and_a_failure_is_reported(self) -> None:
        result = self.run_payload('set -euo pipefail\nstage start test\n./a.sh\nbash -c "exit 0"\npython3 -c "import sys; print(7); sys.exit(3)"\n')
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL: ./a.sh", result.stdout)
        self.assertIn("FAIL: python3 -c", result.stdout)
        self.assertIn("7", result.stdout)
        self.assertNotIn('FAIL: bash -c "exit 0"', result.stdout)

    def test_an_unrecognized_line_fails_instead_of_being_skipped(self) -> None:
        result = self.run_payload("./a.sh\nswift test\n")
        self.assertEqual(result.returncode, 2)
        self.assertIn("unrecognized line", result.stderr)


class FastWorkflowReportsOnEveryPullRequest(unittest.TestCase):
    def test_no_path_filter_and_the_shared_command(self) -> None:
        workflow = run_ci_guards.load_yaml(FAST_WORKFLOW)
        triggers = workflow.get("on") or workflow.get(True)
        # A required check that a path filter skips never reports.
        self.assertIn("pull_request", triggers)
        self.assertFalse((triggers.get("pull_request") or {}).get("paths"))
        self.assertIn("merge_group", triggers)
        self.assertEqual(triggers["push"]["branches"], ["main"])
        job = workflow["jobs"]["fast-guards"]
        self.assertEqual(job["name"], "CI fast guards")
        runs = [s.get("run", "") for s in job["steps"]]
        self.assertTrue(any(r.startswith("scripts/ci/guards-local.sh") for r in runs))


if __name__ == "__main__":
    unittest.main()
