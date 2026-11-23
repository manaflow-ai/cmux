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
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import run_ci_guards  # noqa: E402
import git_fixture_env  # noqa: F401  (disables git auto maintenance)

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
                and s["name"] not in (run_ci_guards.DEPENDENCY_STEPS | run_ci_guards.EVENT_CONDITION_STEPS)
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

    def test_a_local_run_is_not_a_manual_dispatch(self) -> None:
        history = [u for u in self.units if u.job == "workflow-guard-history"]
        self.assertTrue(history)
        names = {step.name for unit in history for step in unit.steps}
        self.assertNotIn("Fetch main history for a manual dispatch", names)
        self.assertIn("Validate SwiftPM lockfile policy", names)

    def test_expressions_are_resolved(self) -> None:
        for unit in self.units:
            for step in unit.steps:
                self.assertNotIn("${{ matrix.group }}", step.run, step.name)
        ios = next(u for u in self.units if u.group == "release-ios")
        env = next(s.env for s in ios.steps if "BASE_SHA" in s.env)
        self.assertEqual(env["BASE_SHA"], "base")
        preflight = next(u for u in self.units if u.group == "preflight")
        registry = next(
            s for s in preflight.steps if s.name == "Validate Python test execution registry"
        )
        self.assertEqual(registry.env["CMUX_TEST_REGISTRY_BASE_REF"], "base")

    def test_registry_comparison_is_empty_without_a_local_base(self) -> None:
        units = run_ci_guards.plan(self.workflow, "", "head")
        preflight = next(u for u in units if u.group == "preflight")
        registry = next(
            s for s in preflight.steps if s.name == "Validate Python test execution registry"
        )
        self.assertEqual(registry.env["CMUX_TEST_REGISTRY_BASE_REF"], "")

    def test_groups_that_pass_state_between_steps_run_in_order(self) -> None:
        by_group = {unit.group or unit.job: unit for unit in self.units}
        # agent-chat's bun install feeds its bun test (working-directory).
        self.assertTrue(run_ci_guards.is_stateful(by_group["preflight-agent-chat"]))
        # The remaining static preflight checks are independent and can be
        # scheduled by verify-local without carrying Bun state between steps.
        self.assertFalse(run_ci_guards.is_stateful(by_group["preflight"]))
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


GUARD_FIXTURE = """jobs:
  workflow-guard-tests:
    strategy:
      matrix:
        group: [ci]
    steps:
      - name: Quick step
        run: while [ ! -e hung-started ]; do sleep 0.05; done; sleep 0.2; echo quick
      - name: Hung step
        run: touch hung-started; sleep 120
"""
# Quick step finishes only once Hung step runs, so a signal sent when Quick
# step prints always finds Hung step still running (a fleet run raced it).


class RunReportsTiming(unittest.TestCase):
    """A run prints each step as it finishes, and a run stopped by a signal
    (the job timeout) names the steps still running and how long they ran."""

    def start_run(self, root: Path, preexec_fn=None) -> subprocess.Popen[str]:
        (root / ".github/workflows").mkdir(parents=True)
        (root / ".github/workflows/ci-guards.yml").write_text(GUARD_FIXTURE)
        for args in (["init", "-q"], ["add", "-A"], ["-c", "user.name=t", "-c", "user.email=t@t",
                                                    "commit", "-qm", "fixture"]):
            subprocess.run(["git", *args], cwd=root, check=True)
        return subprocess.Popen(
            [sys.executable, str(ROOT / "scripts/ci/run_ci_guards.py"), "--root", str(root), "--jobs", "2"],
            cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            env={**os.environ, "CMUX_GUARDS_BASE_SHA": "none"}, preexec_fn=preexec_fn,
        )

    def test_sigint_stops_a_run_started_with_sigint_ignored(self) -> None:
        """A runner started in the background (Freestyle's cmux-linux VMs) hands
        its jobs SIGINT ignored; the guard runner still stops on Ctrl-C."""
        with tempfile.TemporaryDirectory() as temp:
            proc = self.start_run(Path(temp), preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_IGN))
            try:
                assert proc.stdout is not None
                for line in proc.stdout:
                    if "Quick step" in line:
                        break
                proc.send_signal(signal.SIGINT)
                output, _ = proc.communicate(timeout=20)
            finally:
                proc.kill()
            self.assertEqual(proc.returncode, 130, output)
            self.assertIn("1 still running:", output)

    def test_steps_get_default_sighup_when_started_with_it_ignored(self) -> None:
        """nohup leaves SIGHUP ignored; a step that tests its hangup handling
        (verify-cmux-tui-hosted.sh) needs it back at its default."""
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / ".github/workflows").mkdir(parents=True)
            (root / ".github/workflows/ci-guards.yml").write_text("""jobs:
  workflow-guard-tests:
    strategy:
      matrix:
        group: [ci]
    steps:
      - name: Reads its dispositions
        run: grep -E '^Sig(Ign)' /proc/self/status > dispositions
""")
            for args in (["init", "-q"], ["add", "-A"], ["-c", "user.name=t", "-c", "user.email=t@t",
                                                        "commit", "-qm", "fixture"]):
                subprocess.run(["git", *args], cwd=root, check=True)
            def ignore() -> None:
                for signum in (signal.SIGINT, signal.SIGHUP, signal.SIGQUIT):
                    signal.signal(signum, signal.SIG_IGN)
            done = subprocess.run(
                [sys.executable, str(ROOT / "scripts/ci/run_ci_guards.py"), "--root", str(root), "--jobs", "1"],
                cwd=root, capture_output=True, text=True, timeout=60, preexec_fn=ignore,
                env={**os.environ, "CMUX_GUARDS_BASE_SHA": "none"},
            )
            self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
            ignored = int((root / "dispositions").read_text().split()[1], 16)
            for signum in (signal.SIGINT, signal.SIGHUP, signal.SIGQUIT):
                self.assertFalse(ignored & (1 << (signum - 1)), f"{signum.name} still ignored: {ignored:#x}")

    def test_sigterm_names_the_steps_still_running(self) -> None:
        for signum in (signal.SIGTERM, signal.SIGINT):
            with self.subTest(signal=signum.name), tempfile.TemporaryDirectory() as temp:
                proc = self.start_run(Path(temp))
                lines = []
                try:
                    assert proc.stdout is not None
                    for line in proc.stdout:
                        lines.append(line)
                        if "Quick step" in line:
                            break
                    # The finished step was printed before the run ended.
                    self.assertRegex(lines[-1], r"^  ok +[0-9.]+s  at +[0-9]+s  workflow-guard-tests / ci: Quick step")
                    proc.send_signal(signum)
                    output, _ = proc.communicate(timeout=60)
                finally:
                    proc.kill()
                self.assertEqual(proc.returncode, 130, output)
                self.assertIn("1 still running:", output)
                self.assertRegex(output, r"still running +[0-9.]+s  workflow-guard-tests / ci: Hung step")


PARALLEL_FIXTURE = """import sys, unittest
sys.path.insert(0, {tests!r})
import parallel_unittest

class Fixture(unittest.TestCase):
    def test_passes(self):
        pass

    def test_fails(self):
        self.fail("fixture failure")

if __name__ == "__main__":
    sys.exit(parallel_unittest.main())
"""


class ParallelUnittest(unittest.TestCase):
    def run_fixture(self, workers: str) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "test_fixture.py"
            path.write_text(PARALLEL_FIXTURE.format(tests=str(ROOT / "tests")))
            return subprocess.run([sys.executable, str(path)], capture_output=True, text=True, timeout=60,
                                  env={**os.environ, "CMUX_TEST_WORKERS": workers})

    def test_a_failing_test_fails_the_file_in_parallel_and_in_order(self) -> None:
        for workers in ("1", "2"):
            with self.subTest(workers=workers):
                result = self.run_fixture(workers)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("fixture failure", result.stderr)
        self.assertIn("1 passed, 1 failed", self.run_fixture("2").stdout)


class FastWorkflowReportsOnMainPush(unittest.TestCase):
    def test_main_push_keeps_the_standalone_last_green_guard(self) -> None:
        workflow = run_ci_guards.load_yaml(FAST_WORKFLOW)
        triggers = workflow.get("on") or workflow.get(True)
        self.assertNotIn("pull_request", triggers)
        self.assertNotIn("merge_group", triggers)
        self.assertEqual(triggers["push"]["branches"], ["main"])
        job = workflow["jobs"]["fast-guards"]
        self.assertEqual(job["name"], "CI fast guards")
        runs = [s.get("run", "") for s in job["steps"]]
        self.assertTrue(any(r.startswith("scripts/ci/guards-local.sh") for r in runs))


class StepTimesOrderTheNextRun(unittest.TestCase):
    """CI fast guards hit its 5-minute timeout when its longest step started late: the pool now
    starts the steps that took longest on this machine first, from the times the last run kept."""

    def test_times_are_kept_per_step_and_merged_with_earlier_runs(self) -> None:
        unit = run_ci_guards.Unit(job="workflow-guard-tests", group="ci", steps=[])
        step = lambda name: run_ci_guards.Step(name=name, run="true", env={}, working_directory=None)
        with tempfile.TemporaryDirectory() as directory:
            saved = run_ci_guards.TIMES, run_ci_guards.SEED_TIMES
            run_ci_guards.TIMES = Path(directory) / "times/step-seconds.json"
            run_ci_guards.SEED_TIMES = Path(directory) / "seed.json"
            try:
                self.assertEqual(run_ci_guards.read_times(), {})
                run_ci_guards.write_times([run_ci_guards.StepResult(unit, step("slow"), True, 90.04, ""),
                                           run_ci_guards.StepResult(unit, step("skipped"), None, 0.0, "")])
                run_ci_guards.write_times([run_ci_guards.StepResult(unit, step("fast"), False, 1.0, "")])
                self.assertEqual(run_ci_guards.read_times(),
                                 {"workflow-guard-tests / ci: slow": 90.0, "workflow-guard-tests / ci: fast": 1.0})
                # A fresh runner has only the checked-in seed; a machine's own time wins over it, and
                # writing keeps only the machine's own times.
                run_ci_guards.SEED_TIMES.write_text('{"workflow-guard-tests / ci: slow": 300, "workflow-guard-tests / ci: seeded": 50}')
                self.assertEqual(run_ci_guards.read_times(),
                                 {"workflow-guard-tests / ci: slow": 90.0, "workflow-guard-tests / ci: fast": 1.0,
                                  "workflow-guard-tests / ci: seeded": 50.0})
                run_ci_guards.write_times([])
                self.assertNotIn("seeded", run_ci_guards.TIMES.read_text())
                run_ci_guards.TIMES.write_text("not json")
                self.assertEqual(run_ci_guards.read_times(), {"workflow-guard-tests / ci: slow": 300.0,
                                                              "workflow-guard-tests / ci: seeded": 50.0})
            finally:
                run_ci_guards.TIMES, run_ci_guards.SEED_TIMES = saved

    def test_the_checked_in_seed_puts_the_long_steps_first(self) -> None:
        seed = json.loads(run_ci_guards.SEED_TIMES.read_text())
        self.assertGreaterEqual(seed["workflow-guard-tests / ci: Validate main-fix merge evidence (merged-head checks)"], 60)


if __name__ == "__main__":
    unittest.main()
