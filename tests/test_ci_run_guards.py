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
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import run_ci_guards  # noqa: E402


def pid_gone(pid: int, seconds: float = 10) -> bool:
    """Until PID is gone (killed, and reaped by whoever adopted it), SECONDS at most: whether it went."""
    import time  # noqa: PLC0415

    deadline = time.monotonic() + seconds
    while True:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.05)
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)
# tests/guard_child_env.py, loaded by path like git_fixture_env: every spawned guard run gets its own step files.
_guard_child_spec = _git_fixture_importlib.spec_from_file_location(
    "guard_child_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "guard_child_env.py"))
guard_child_env = _git_fixture_importlib.module_from_spec(_guard_child_spec)
_guard_child_spec.loader.exec_module(guard_child_env)


class AffectedSelectionFailsOpen(unittest.TestCase):
    def test_a_selection_that_raises_runs_every_step(self):
        import guard_step_inputs  # noqa: PLC0415

        units = run_ci_guards.plan(run_ci_guards.load_yaml(run_ci_guards.WORKFLOW), "base", "head")
        original = guard_step_inputs.changed_paths

        def broken(*_args, **_kwargs):
            raise ValueError("broken selection")

        guard_step_inputs.changed_paths = broken
        try:
            self.assertIs(run_ci_guards.affected_units(units, "base"), units)
        finally:
            guard_step_inputs.changed_paths = original


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

    def test_only_a_stateful_groups_head_runs_in_order(self) -> None:
        """release-notary initializes ghostty-next first and hands nothing on after it; its other 123
        steps ran one by one, the CI guard group's longest chain. They wait for the head, then run in
        parallel. A group passing GITHUB_ENV keeps every step in order (each task has its own sandbox)."""
        Step, Unit = run_ci_guards.Step, run_ci_guards.Unit
        unit = Unit("j", "g", [
            Step("init", "bash scripts/ci/init-submodule.sh ghostty", {}, None),
            Step("use a", "python3 a.py", {}, None),
            Step("use b", "python3 b.py", {}, None),
        ])
        self.assertEqual(run_ci_guards.ordered_split(unit), 1)
        env_unit = Unit("j", "g", [
            Step("bind", 'echo X=1 >> "$GITHUB_ENV"', {}, None),
            Step("init", "git submodule update --init vendor/x", {}, None),
            Step("use", "python3 a.py", {}, None),
        ])
        self.assertEqual(run_ci_guards.ordered_split(env_unit), 3)
        planned = run_ci_guards.plan(run_ci_guards.load_yaml(run_ci_guards.WORKFLOW), "base", "head")
        by_group = {u.group or u.job: u for u in planned}
        self.assertEqual(run_ci_guards.ordered_split(by_group["release-notary"]), 1)
        self.assertEqual(run_ci_guards.ordered_split(by_group["preflight-agent-chat"]), 3)

    def test_a_stateful_groups_tail_waits_for_its_head_then_runs_together(self) -> None:
        import contextlib  # noqa: PLC0415
        import io  # noqa: PLC0415
        import threading  # noqa: PLC0415
        import time  # noqa: PLC0415

        Step, Unit = run_ci_guards.Step, run_ci_guards.Unit
        tail = [Step(f"use {n}", f"python3 {n}.py", {}, None) for n in "abcd"]
        units = [Unit("workflow-guard-tests", "ci", [
            Step("Initialize ghostty-next", "git submodule update --init ghostty-next", {}, None), *tail,
        ])]
        events: list[tuple[str, str]] = []
        lock = threading.Lock()

        def fake_run_steps(unit, steps, base_env, base_sha, keep_going, on_result=None, root=None):
            results = []
            for step in steps:
                with lock:
                    events.append(("start", step.name))
                time.sleep(0.2)
                with lock:
                    events.append(("end", step.name))
                results.append(run_ci_guards.StepResult(unit, step, True, 0.2, ""))
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
        head_end = events.index(("end", "Initialize ghostty-next"))
        self.assertEqual([n for k, n in events[:head_end] if k == "start"], ["Initialize ghostty-next"])
        starts = [n for k, n in events[head_end:] if k == "start"]
        self.assertEqual(sorted(starts), sorted(s.name for s in tail))
        first_tail_end = next(i for i, (k, n) in enumerate(events) if k == "end" and i > head_end)
        started_together = [n for k, n in events[head_end:first_tail_end] if k == "start"]
        self.assertEqual(len(started_together), 4, f"the tail ran one by one: {events}")

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


class CleanTreeStepsRunInTheirOwnCopy(unittest.TestCase):
    """The canonical guard profile (cmux_workload_profile.py run) refuses a checkout with source
    changes. Run in the pool, it raced release-tooling's `init-submodule.sh ghostty` in the same
    checkout and failed with "checkout has tracked source changes" (run 39702173417). It then ran
    alone before every other step, so 15 of 16 workers sat idle for its 146-168 s on every guard
    group run (2026-11-21). It now runs in a clean worktree of HEAD of its own, beside the others."""

    PROFILE = "python3 scripts/ci/cmux_workload_profile.py run cmux.ci.guard --generation 1"

    def test_the_workload_profile_runs_in_a_copy_beside_the_other_steps(self) -> None:
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
        roots: dict[str, Path] = {}
        lock = threading.Lock()

        def fake_run_steps(unit, steps, base_env, base_sha, keep_going, on_result=None, root=None):
            results = []
            for step in steps:
                with lock:
                    events.append(("start", step.name))
                    roots[step.name] = root or run_ci_guards.ROOT
                time.sleep(0.3 if "cmux_workload_profile.py run" in step.run else 0.05)
                with lock:
                    events.append(("end", step.name))
                result = run_ci_guards.StepResult(unit, step, True, 0.0, f"ran in {root or run_ci_guards.ROOT}")
                results.append(result)
                if on_result is not None:
                    on_result(result)
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
        profile = "Run canonical CMUX CI guard profile"
        self.assertNotEqual(roots[profile], run_ci_guards.ROOT, "the workload profile ran in the shared checkout")
        self.assertFalse(roots[profile].exists(), "the profile's copy was left behind")
        for name, root in roots.items():
            if name != profile:
                self.assertEqual(root, run_ci_guards.ROOT, name)
        profile_end = events.index(("end", profile))
        started_beside = [name for kind, name in events[:profile_end] if kind == "start" and name != profile]
        self.assertTrue(started_beside, f"no step ran beside the workload profile: {events}")

    def test_the_copy_is_a_clean_checkout_of_head_and_its_output_names_the_checkout(self) -> None:
        Step, Unit = run_ci_guards.Step, run_ci_guards.Unit
        with tempfile.TemporaryDirectory() as temp:
            repo = Path(temp) / "repo"
            repo.mkdir()
            git = lambda *a: subprocess.run(["git", *a], cwd=repo, check=True, capture_output=True, text=True).stdout
            git("init", "-q")
            (repo / "tracked.txt").write_text("one\n")
            git("add", "tracked.txt")
            git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "one")
            (repo / "tracked.txt").write_text("changed by another step\n")
            (repo / "untracked.txt").write_text("written by another step\n")
            step = Step("Run canonical CMUX CI guard profile",
                        "git status --porcelain=v1 --untracked-files=all; pwd; cat tracked.txt", {}, None)
            unit = Unit("workflow-guard-tests", "ci", [step])
            saved = run_ci_guards.ROOT
            run_ci_guards.ROOT = repo
            try:
                results = run_ci_guards.run_in_clean_copy(unit, [step], dict(os.environ), "", True)
            finally:
                run_ci_guards.ROOT = saved
            self.assertEqual(len(results), 1)
            self.assertTrue(results[0].ok, results[0].output)
            lines = results[0].output.strip().splitlines()
            self.assertEqual(lines, [str(repo), "one"], "the copy saw the shared checkout's changes or its own path")
            self.assertEqual(git("worktree", "list", "--porcelain").count("worktree "), 1, "the copy is still registered")


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
                                  env=guard_child_env.guard_child_env(temp),
                                  capture_output=True, text=True, timeout=60)

    def test_the_substitute_runs_the_real_payload(self) -> None:
        self.assertEqual(
            run_ci_guards.PORTABLE_SUBSTITUTES["Run canonical CMUX CI guard profile"],
            "scripts/ci/run_ci_guard_payload.sh",
        )
        # Every line of the real ci-guard.sh is one the substitute recognizes.
        text = (ROOT / "scripts/ci/workloads/ci-guard.sh").read_text(encoding="utf-8")
        stubbed = re.sub(r"(?m)^(check )?(\./|python3 )(?!\"\$root).*$", r"\1bash -c true", text)
        self.assertIn("check bash -c true", stubbed)
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
        # No diff fails open to every routed group, release-notary included.
        self.assertIn("workflow-guard-tests / release-notary:", listed)

    def test_a_product_change_skips_release_notary(self) -> None:
        listed = self.listed(["Packages/macOS/CmuxNext/Sources/CmuxNextApp/X.swift"])
        self.assertIn("workflow-guard-tests / ci:", listed)
        self.assertNotIn("workflow-guard-tests / release-notary:", listed)

    def test_a_signing_change_runs_release_notary(self) -> None:
        listed = self.listed(["cmux.nightly.entitlements"])
        self.assertIn("workflow-guard-tests / release-notary:", listed)

    def test_skip_group_leaves_a_routed_group_out(self) -> None:
        import contextlib  # noqa: PLC0415
        import io  # noqa: PLC0415

        out = io.StringIO()
        with tempfile.TemporaryDirectory(prefix="guard-routes-") as temp, contextlib.redirect_stdout(out):
            code = run_ci_guards.main(["--list", "--feat-routes", str(Path(temp) / "none.txt"),
                                       "--skip-group", "release-notary"])
        self.assertEqual(code, 0)
        listed = "\n".join(line for line in out.getvalue().splitlines() if not line.startswith(" "))
        self.assertIn("workflow-guard-tests / ci:", listed)
        self.assertIn("workflow-guard-tests / preflight:", listed)
        # The routed-groups line still names it; the plan leaves it out.
        self.assertNotIn("workflow-guard-tests / release-notary:", listed)


class ATestSpawnedGuardRunLeavesTheCallersFilesAlone(unittest.TestCase):
    """The guard runner points CMUX_GUARD_CHECK_RESULTS, GITHUB_STEP_SUMMARY, GITHUB_OUTPUT and GITHUB_ENV at the
    running step's own files. A guard run a test spawns (a failing payload fixture, the runner-guard fixtures) must
    write none of them: on #41333 the payload fixtures' `./a.sh` reds landed in the real step's results and the CI
    guard group charged them to the change."""

    def test_the_fixture_suites_leave_all_four_files_byte_identical(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            outer = {name: Path(temp) / f"outer-{name.lower()}" for name in
                     ("CMUX_GUARD_CHECK_RESULTS", "GITHUB_STEP_SUMMARY", "GITHUB_OUTPUT", "GITHUB_ENV")}
            for name, path in outer.items():
                path.write_text(f"1\tthe caller's own {name}\n", encoding="utf-8")
            before = {name: path.read_bytes() for name, path in outer.items()}
            env = {key: value for key, value in os.environ.items() if not key.startswith("CMUX_GUARD_")}
            env.update({name: str(path) for name, path in outer.items()})
            done = subprocess.run(
                [sys.executable, "-m", "unittest", "-q",
                 "test_ci_run_guards.PortableSubstitutes", "test_ci_guard_check_isolation"],
                cwd=ROOT / "tests", env=env, capture_output=True, text=True, timeout=600,
            )
            self.assertEqual(done.returncode, 0, done.stdout[-3000:] + done.stderr[-3000:])
            after = {name: path.read_bytes() for name, path in outer.items()}
            for name in outer:
                with self.subTest(file=name):
                    self.assertEqual(after[name], before[name])


class DeterminismGateReportsEachFinding(unittest.TestCase):
    """The determinism gate's --guard-checks reports one red guard check per (path, rule), with no line number, so a
    base already red on the step excuses only the findings the base has (cmux#42416 landed two new findings behind
    test_cargo_locks_explain.py's base reds)."""

    def test_each_active_path_and_rule_is_one_red_check(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "repo"
            (repo / "tests").mkdir(parents=True)
            # Built from parts so this file's own text holds no duration assert for the gate to find.
            check = "self.assert" + "Less(elapsed, {})"
            (repo / "tests" / "test_timing.py").write_text(
                "import unittest\n\nclass T(unittest.TestCase):\n"
                "    def test_a(self):\n        elapsed = 1.0\n        " + check.format("2.0") + "\n\n"
                "    def test_b(self):\n        elapsed = 1.0\n        " + check.format("3.0") + "\n"
            )
            allowlist = Path(tmp) / "allowlist.txt"
            allowlist.write_text("")
            results = Path(tmp) / "checks"
            env = {key: value for key, value in os.environ.items() if not key.startswith("CMUX_GUARD_")}
            env["CMUX_GUARD_CHECK_RESULTS"] = str(results)
            argv = [sys.executable, str(ROOT / "scripts" / "check-test-determinism.py"), "--repo-root", str(repo),
                    "--allowlist", str(allowlist), "--roots", "tests", "--strict"]
            plain = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=120)
            self.assertEqual(plain.returncode, 1, plain.stdout + plain.stderr)
            self.assertFalse(results.exists(), "without --guard-checks the gate writes no checks")
            reported = subprocess.run(argv + ["--guard-checks"], env=env, capture_output=True, text=True, timeout=120)
            self.assertEqual(reported.returncode, 1, reported.stdout + reported.stderr)
            self.assertEqual(results.read_text().splitlines(), ["0\ttests/test_timing.py: assert-on-duration"])
            self.assertEqual(run_ci_guards.read_check_results(results),
                             {"tests/test_timing.py: assert-on-duration": False})


class CheckoutSetupRunsFirst(unittest.TestCase):
    """release-notary ran as one ordered task because its first step initializes ghostty-next: 124 steps one after
    another, 915 s on 4 vCPU, past nightly-guards' 15-minute job on every push (run 44110521024). Through main(),
    the init runs alone first and every other step then shares the pool (ordered_split)."""

    def run_main(self, units, jobs="4"):
        import contextlib  # noqa: PLC0415
        import io  # noqa: PLC0415
        import threading  # noqa: PLC0415
        import time  # noqa: PLC0415

        events: list[tuple[str, str]] = []
        lock = threading.Lock()
        running = [0, 0]  # now, most at once

        def fake_run_steps(unit, steps, base_env, base_sha, keep_going, on_result=None, root=None):
            results = []
            for step in steps:
                with lock:
                    events.append(("start", step.name))
                    running[0] += 1
                    running[1] = max(running)
                time.sleep(0.2)
                with lock:
                    events.append(("end", step.name))
                    running[0] -= 1
                result = run_ci_guards.StepResult(unit, step, True, 0.0, "")
                results.append(result)
                if on_result is not None:
                    on_result(result)
            return results

        saved = run_ci_guards.plan, run_ci_guards.run_steps
        run_ci_guards.plan = lambda workflow, base_sha, head_sha: units
        run_ci_guards.run_steps = fake_run_steps
        try:
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                code = run_ci_guards.main(["--group", "release-notary", "--jobs", jobs, "--no-stamp"])
        finally:
            run_ci_guards.plan, run_ci_guards.run_steps = saved
        return code, events, running[1]

    def test_the_init_finishes_first_and_every_other_step_runs_in_parallel(self) -> None:
        Step, Unit = run_ci_guards.Step, run_ci_guards.Unit
        steps = [Step("Initialize ghostty-next", "git submodule update --init --depth 1 ghostty-next", {}, None)]
        steps += [Step(f"guard {n}", f"python3 tests/t{n}.py", {}, None) for n in range(8)]
        code, events, most = self.run_main([Unit("workflow-guard-tests", "release-notary", steps)])
        self.assertEqual(code, 0)
        self.assertEqual(sorted(name for kind, name in events if kind == "start"), sorted(s.name for s in steps))
        self.assertEqual(events[:2], [("start", "Initialize ghostty-next"), ("end", "Initialize ghostty-next")])
        self.assertEqual(most, 4, "the group's steps did not share the pool")


class ATimedOutRunStopsItsSteps(unittest.TestCase):
    """Steps run in their own sessions. A run its caller's `timeout` stopped (SIGTERM) left them running: the guard
    group's base re-run is bounded that way."""

    def test_sigterm_ends_every_running_step(self) -> None:
        import signal  # noqa: PLC0415
        import time  # noqa: PLC0415

        with tempfile.TemporaryDirectory(prefix="guard-term-") as temp:
            pid_file = Path(temp) / "pid"
            driver = Path(temp) / "driver.py"
            driver.write_text(
                "import sys\n"
                f"sys.path.insert(0, {str(ROOT / 'scripts/ci')!r})\n"
                "import run_ci_guards as r\n"
                f"step = r.Step('sleeps', 'sleep 300 & echo $! > {pid_file}; wait', {{}}, None)\n"
                "r.plan = lambda w, b, h: [r.Unit('workflow-guard-tests', 'g', [step])]\n"
                "sys.exit(r.main(['--group', 'g', '--jobs', '1', '--no-stamp']))\n",
                encoding="utf-8")
            proc = subprocess.Popen([sys.executable, str(driver)], cwd=ROOT, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, text=True)
            deadline = time.monotonic() + 60
            while not (pid_file.is_file() and pid_file.read_text().strip()) and time.monotonic() < deadline:
                time.sleep(0.1)
            child = int(pid_file.read_text())
            proc.send_signal(signal.SIGTERM)
            output, _ = proc.communicate(timeout=60)
            self.assertEqual(proc.returncode, 130, output)
            self.assertIn("interrupted", output)
            self.assertTrue(pid_gone(child), "the step's child outlived the run")


class TheDeadlineStopsTheRun(unittest.TestCase):
    def test_a_step_past_the_deadline_is_stopped_and_has_no_result(self) -> None:
        import json  # noqa: PLC0415
        import time  # noqa: PLC0415

        with tempfile.TemporaryDirectory(prefix="guard-deadline-") as temp:
            pid_file, results = Path(temp) / "pid", Path(temp) / "results.json"
            driver = Path(temp) / "driver.py"
            driver.write_text(
                "import sys\n"
                f"sys.path.insert(0, {str(ROOT / 'scripts/ci')!r})\n"
                "import run_ci_guards as r\n"
                "steps = [r.Step('quick', 'true', {}, None),\n"
                f"         r.Step('sleeps', 'sleep 300 & echo $! > {pid_file}; wait', {{}}, None)]\n"
                "r.plan = lambda w, b, h: [r.Unit('workflow-guard-tests', 'g', steps)]\n"
                "sys.exit(r.main(['--group', 'g', '--jobs', '2', '--no-stamp', '--deadline', '3',\n"
                f"                '--results', {str(results)!r}]))\n",
                encoding="utf-8")
            run = subprocess.run([sys.executable, str(driver)], cwd=ROOT, capture_output=True, text=True, timeout=120)
            self.assertEqual(run.returncode, 124, run.stdout + run.stderr)
            self.assertIn("timed out after 3s", run.stdout)
            self.assertNotIn("FAIL", run.stdout)
            found = json.loads(results.read_text(encoding="utf-8"))
            self.assertEqual(found, {"_cmux_complete": False, "quick": True})
            self.assertTrue(pid_gone(int(pid_file.read_text())), "the stopped step's child outlived the run")


class ACutShortTipRunIsNoVerdict(unittest.TestCase):
    def test_an_incomplete_results_file_fails_and_says_it_timed_out(self) -> None:
        import json  # noqa: PLC0415

        with tempfile.TemporaryDirectory() as temp:
            results = Path(temp) / "r.json"
            for complete, code in ((True, 0), (False, 1)):
                with self.subTest(complete=complete):
                    results.write_text(json.dumps({"_cmux_complete": complete, "a step": True}), encoding="utf-8")
                    run = subprocess.run([sys.executable, str(ROOT / "scripts/ci/guards_new_reds.py"), "--tip",
                                          str(results)], capture_output=True, text=True, timeout=60)
                    self.assertEqual(run.returncode, code, run.stdout + run.stderr)
                    self.assertEqual("timed out" in run.stdout, not complete)


if __name__ == "__main__":
    unittest.main()
