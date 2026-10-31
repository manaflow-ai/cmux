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
import copy
import re
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
                and s["name"] not in (run_ci_guards.DEPENDENCY_STEPS | run_ci_guards.WORKSPACE_STEPS
                                      | run_ci_guards.EVENT_CONDITION_STEPS)
                and (not s.get("if") or f"'{unit.group}'" in s["if"])
            ]
            self.assertEqual([s.name for s in unit.steps], expected, unit.label)

    def test_the_workspace_reset_never_runs_inside_a_guard_group(self) -> None:
        # It deinits every submodule; inside the parallel groups it raced release-notary's ghostty-next
        # checkout (#29130 review). The Actions job runs it once, before the guard steps.
        names = [s["name"] for s in self.workflow["jobs"]["workflow-guard-tests"]["steps"]]
        self.assertIn("Drop stale submodule checkouts (self-hosted reused workspace)", names)
        for unit in self.units:
            with self.subTest(unit=unit.label):
                self.assertFalse(any(s.name in run_ci_guards.WORKSPACE_STEPS for s in unit.steps))

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
        preflight = next(u for u in self.units if u.group == "preflight")
        conventions = next(s for s in preflight.steps if s.name == "Validate iOS package conventions for this change")
        self.assertEqual(conventions.env["BASE_SHA"], "base")
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

    def test_fast_guard_skip_gate_is_a_supported_group_condition(self) -> None:
        step = {
            "name": "gated",
            "if": "${{ matrix.group == 'ci' && steps.fast-guard.outputs.skip != 'true' }}",
            "run": "true",
        }
        workflow = copy.deepcopy(self.workflow)
        workflow["jobs"]["workflow-guard-tests"]["steps"].append(step)
        units = run_ci_guards.plan(workflow, "base", "head")
        ci = next(unit for unit in units if unit.group == "ci")
        self.assertIn("gated", {step.name for step in ci.steps})

    def test_or_group_condition_runs_each_named_group_only(self) -> None:
        workflow = copy.deepcopy(self.workflow)
        workflow["jobs"]["workflow-guard-tests"]["steps"].append(
            {
                "name": "or-gated",
                "if": "${{ matrix.group == 'preflight-agent-chat' || matrix.group == 'release-ios' }}",
                "run": "true",
            }
        )
        units = run_ci_guards.plan(workflow, "base", "head")
        by_group = {unit.group: {step.name for step in unit.steps} for unit in units}
        self.assertIn("or-gated", by_group["preflight-agent-chat"])
        self.assertIn("or-gated", by_group["release-ios"])
        self.assertNotIn("or-gated", by_group["preflight"])


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

    def test_an_unknown_or_condition_fails_instead_of_selecting_one_group(self) -> None:
        step = {"name": "b", "if": "${{ matrix.group == 'ci' || always() }}", "run": "true"}
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

    def test_the_submodule_init_script_makes_its_group_sequential(self) -> None:
        """release-tooling initializes ghostty with scripts/ci/init-submodule.sh before the Zig version
        sync reads ghostty/build.zig.zon; run in parallel, the sync ran first and failed (#23534)."""
        unit = run_ci_guards.Unit("j", "g", [
            run_ci_guards.Step("init", "bash scripts/ci/init-submodule.sh ghostty", {}, None),
            run_ci_guards.Step("use", "./tests/test_ghostty_zig_version_sync.sh", {}, None),
        ])
        self.assertTrue(run_ci_guards.is_stateful(unit))

    def test_the_zig_installer_test_keeps_its_github_env_to_itself(self) -> None:
        """Run in order, release-tooling's Zig download test published its fake zig through the job's
        GITHUB_ENV, and the next step (the Zig package fetch test) ran that deleted zig (#23534)."""
        text = (ROOT / "tests/test_install_zig_ci_download_resume.sh").read_text(encoding="utf-8")
        body = text[text.index("run_install() {"):]
        body = body[:body.index('"$SCRIPT"')]
        self.assertIn('GITHUB_ENV="$TMP_DIR/', body)
        self.assertIn('GITHUB_PATH="$TMP_DIR/', body)


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


class CleanTreeStepsRunAlone(unittest.TestCase):
    """The canonical guard profile (cmux_workload_profile.py run) refuses a checkout with source
    changes. Run in the pool, it raced release-tooling's `init-submodule.sh ghostty` in the same
    checkout and failed with "checkout has tracked source changes" (run 39702173417). It must
    finish before any other guard step starts."""

    PROFILE = "python3 scripts/ci/cmux_workload_profile.py run cmux.ci.guard --generation 1"

    def test_the_workload_profile_finishes_before_any_other_step_starts(self) -> None:
        import contextlib  # noqa: PLC0415
        import io  # noqa: PLC0415
        import threading  # noqa: PLC0415
        import time  # noqa: PLC0415

        Step, Unit = run_ci_guards.Step, run_ci_guards.Unit
        units = [
            Unit("workflow-guard-tests", "ci", [
                Step("lint a", "python3 tests/a.py", {}, None),
                Step("Run canonical CMUX CI guard profile", self.PROFILE, {}, None),
                Step("lint b", "python3 tests/b.py", {}, None),
            ]),
            Unit("workflow-guard-tests", "ci", [
                Step("Initialize Ghostty", "bash scripts/ci/init-submodule.sh ghostty", {}, None),
                Step("Zig sync", "./tests/test_ghostty_zig_version_sync.sh", {}, None),
            ]),
        ]
        events: list[tuple[str, str]] = []
        lock = threading.Lock()

        def fake_run_steps(unit, steps, base_env, base_sha, keep_going):
            results = []
            for step in steps:
                with lock:
                    events.append(("start", step.name))
                time.sleep(0.3 if "cmux_workload_profile.py run" in step.run else 0.05)
                with lock:
                    events.append(("end", step.name))
                results.append(run_ci_guards.StepResult(unit, step, True, 0.0, ""))
            return results

        saved = run_ci_guards.plan, run_ci_guards.run_steps
        run_ci_guards.plan = lambda workflow, base_sha, head_sha: units
        run_ci_guards.run_steps = fake_run_steps
        try:
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                code = run_ci_guards.main(["--group", "ci", "--jobs", "4", "--no-stamp"])
        finally:
            run_ci_guards.plan, run_ci_guards.run_steps = saved

        self.assertEqual(code, 0)
        names = [name for kind, name in events if kind == "start"]
        self.assertEqual(sorted(names), sorted(step.name for unit in units for step in unit.steps))
        profile_end = events.index(("end", "Run canonical CMUX CI guard profile"))
        started_before = [name for kind, name in events[:profile_end]
                          if kind == "start" and name != "Run canonical CMUX CI guard profile"]
        self.assertEqual(started_before, [], f"steps started while the workload profile ran: {events}")


class AptStepsTakeTurns(unittest.TestCase):
    """Two guard steps that install packages with apt-get (tesseract, zsh) ran at once in the pool
    and one failed on the dpkg lock (pane-toolbar, after #24005). The runner runs apt-get steps one
    at a time, host-wide, and every apt-get in ci-guards.yml waits for the lock instead of failing
    when another job on the same host holds it."""

    WORKFLOW = ROOT / ".github/workflows/ci-guards.yml"

    def test_every_apt_get_in_the_guard_workflow_waits_for_the_lock(self) -> None:
        unguarded = []
        for number, line in enumerate(self.WORKFLOW.read_text(encoding="utf-8").splitlines(), 1):
            # One command per apt-get, up to the next command separator.
            for command in re.findall(r"\bapt-get\b[^;|&]*", line):
                if re.search(r"\s(update|install|upgrade|dist-upgrade|remove|purge)\b", command) \
                        and "DPkg::Lock::Timeout=" not in command:
                    unguarded.append(f"ci-guards.yml:{number}: {command.strip()}")
        self.assertEqual(unguarded, [], "pass -o DPkg::Lock::Timeout=300 to apt-get")

    def test_the_lock_check_sees_options_before_the_subcommand(self) -> None:
        self.assertEqual(re.findall(r"\bapt-get\b[^;|&]*", "sudo apt-get -qq update || sudo apt-get -o DPkg::Lock::Timeout=300 install -y zsh"),
                         ["apt-get -qq update ", "apt-get -o DPkg::Lock::Timeout=300 install -y zsh"])

    def test_an_interrupted_run_stops_waiting_for_another_runners_turn(self) -> None:
        # Another guard run on the host holds the apt turn (a hung test after its install). This run is
        # interrupted while its apt-get step waits for the turn: it must skip the step and exit.
        with tempfile.TemporaryDirectory() as temp:
            lock = Path(temp) / "apt.lock"
            holder = subprocess.Popen(
                [sys.executable, "-c",
                 "import fcntl, sys, time\n"
                 "handle = open(sys.argv[1], 'a')\n"
                 "fcntl.flock(handle, fcntl.LOCK_EX)\n"
                 "print('held', flush=True)\n"
                 "time.sleep(120)\n", str(lock)],
                stdout=subprocess.PIPE, text=True)
            try:
                self.assertEqual(holder.stdout.readline().strip(), "held")
                runner = (
                    "import sys, threading, time\n"
                    "from pathlib import Path\n"
                    f"sys.path.insert(0, {str(ROOT / 'scripts' / 'ci')!r})\n"
                    "import run_ci_guards as r\n"
                    f"r.APT_LOCK = Path({str(lock)!r})\n"
                    "step = r.Step('apt', 'sudo apt-get install -y zsh', {}, None)\n"
                    "result = []\n"
                    f"worker = threading.Thread(target=lambda: result.append(r.run_step(step, Path({temp!r}), {{}}, Path({temp!r}) / 'log')))\n"
                    "worker.start()\n"
                    "time.sleep(0.5)\n"
                    "r.stop_running()\n"
                    "worker.join()\n"
                    "print(result[0][0])\n"
                )
                try:
                    done = subprocess.run([sys.executable, "-c", runner], capture_output=True, text=True, timeout=20)
                except subprocess.TimeoutExpired:
                    self.fail("the interrupted run kept waiting for the other runner's apt turn")
                self.assertEqual(done.stdout.strip(), "130", done.stderr)
            finally:
                holder.kill()
                holder.wait()

    def test_two_apt_get_steps_never_overlap(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            # Each step holds a directory while it runs; a second step running at the same time
            # finds it taken and exits 9.
            run = f'# apt-get install stand-in\nmkdir "{temp}/held" || exit 9\nsleep 0.5\nrmdir "{temp}/held"\n'
            steps = [run_ci_guards.Step(f"apt {n}", run, {}, None) for n in range(2)]
            with concurrent.futures.ThreadPoolExecutor(2) as pool:
                futures = [
                    pool.submit(run_ci_guards.run_step, step, Path(temp), {"PATH": "/usr/bin:/bin"},
                                Path(temp) / f"log{n}")
                    for n, step in enumerate(steps)
                ]
                codes = [future.result(timeout=60)[0] for future in futures]
        self.assertEqual(codes, [0, 0])

    def test_steps_without_apt_get_still_run_together(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            run = f'touch "{temp}/$STEP"\nfor _ in $(seq 50); do [ -e "{temp}/a" ] && [ -e "{temp}/b" ] && exit 0; sleep 0.1; done\nexit 9\n'
            with concurrent.futures.ThreadPoolExecutor(2) as pool:
                futures = [
                    pool.submit(run_ci_guards.run_step, run_ci_guards.Step(name, run, {}, None), Path(temp),
                                {"PATH": "/usr/bin:/bin", "STEP": name}, Path(temp) / f"log-{name}")
                    for name in ("a", "b")
                ]
                codes = [future.result(timeout=60)[0] for future in futures]
        self.assertEqual(codes, [0, 0])


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


class FeatRoutesSelectTheGroups(unittest.TestCase):
    """`--feat-routes FILE` runs the `ci` group plus the groups the changed files in FILE route to
    for a feat-cmux-next pull request (detect_linux_guard_changes.classify_feat)."""

    def listed(self, changed: list[str] | None) -> str:
        import contextlib  # noqa: PLC0415
        import io  # noqa: PLC0415

        with tempfile.TemporaryDirectory(prefix="guard-routes-") as temp:
            path = Path(temp) / "changed.txt"
            if changed is not None:
                path.write_text("\n".join(changed) + "\n", encoding="utf-8")
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = run_ci_guards.main(["--list", "--feat-routes", str(path)])
        self.assertEqual(code, 0)
        return "\n".join(line for line in out.getvalue().splitlines() if not line.startswith(" "))

    def test_a_watchdog_change_runs_the_ci_and_watchdog_groups(self) -> None:
        listed = self.listed(["scripts/ci/hung_test_watchdog.py"])
        self.assertIn("workflow-guard-tests / ci:", listed)
        self.assertIn("workflow-guard-tests / app-host-watchdog:", listed)
        self.assertNotIn("workflow-guard-tests / preflight:", listed)
        self.assertNotIn("release-ios", listed)

    def test_a_missing_file_runs_every_feat_group_but_release_ios(self) -> None:
        listed = self.listed(None)
        for label in ("workflow-guard-tests / ci:", "workflow-guard-tests / preflight:",
                      "workflow-guard-tests / release-tooling:", "workflow-guard-history:",
                      "workflow-guard-source-lints / dispatch-ownership:"):
            with self.subTest(label=label):
                self.assertIn(label, listed)
        self.assertNotIn("release-ios", listed)
        self.assertNotIn("release-notary", listed)


if __name__ == "__main__":
    unittest.main()
