#!/usr/bin/env python3
"""The execution registry validator only fails the pull request at fault.

An unregistered test that a pull request adds is that pull request's problem.
An unregistered test that was already on the base branch is not, and failing
on it turns every open pull request red for a reason its author cannot fix.
"""

from __future__ import annotations

import importlib.util
import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path
import git_fixture_env  # noqa: F401  (disables git auto maintenance)
from test_ci_change_areas import (
    GUARD_WORKFLOW as GUARD_WORKFLOW_PATH,
    workflow_job_block,
    workflow_job_step_script,
)


ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / "scripts" / "ci" / "validate_test_execution_registry.py"

spec = importlib.util.spec_from_file_location("validate_test_execution_registry", VALIDATOR)
assert spec and spec.loader
validator = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = validator
spec.loader.exec_module(validator)

sys.path.insert(0, str(ROOT / "scripts" / "ci"))
RUNNER = ROOT / "scripts" / "ci" / "run_python_test_lane.py"
runner_spec = importlib.util.spec_from_file_location("run_python_test_lane", RUNNER)
assert runner_spec and runner_spec.loader
runner = importlib.util.module_from_spec(runner_spec)
sys.modules[runner_spec.name] = runner
runner_spec.loader.exec_module(runner)


GUARD_WORKFLOW = """\
name: CI guards
jobs:
  workflow-guard-tests:
    steps:
      - name: Validate the kept test
        run: python3 tests/test_kept.py
      - name: Run the CLI lane
        run: scripts/ci/run_python_test_lane.py --lane macos-cli-no-socket
"""


class RegistryBlastRadiusTests(unittest.TestCase):
    def test_cli_product_lane_selects_the_hook_spool_regression(self) -> None:
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts/ci/run_python_test_lane.py"),
             "--lane", "macos-cli-product", "--list"],
            cwd=ROOT, capture_output=True, text=True, check=True,
        )
        self.assertEqual(
            result.stdout.splitlines(),
            ["tests/test_claude_hook_spool.py", "tests/test_cli_hooks_setup_arguments.py"],
        )
        errors, _, _ = validator.validate(
            ROOT,
            added={"tests/test_claude_hook_spool.py", "tests/test_cli_hooks_setup_arguments.py"},
        )
        self.assertEqual(errors, [])

    def make_root(self, *, tests: list[str], registry: str) -> Path:
        root = Path(tempfile.mkdtemp(prefix="cmux-test-execution-registry-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        (root / "tests").mkdir()
        (root / ".github" / "workflows").mkdir(parents=True)
        (root / ".github" / "workflows" / "ci-guards.yml").write_text(
            GUARD_WORKFLOW, encoding="utf-8"
        )
        for name in tests:
            (root / "tests" / name).write_text("#!/usr/bin/env python3\n", encoding="utf-8")
        (root / "tests" / "test-execution.toml").write_text(registry, encoding="utf-8")
        return root

    def kept_registry(self) -> str:
        return 'version = 1\n\n[[test]]\npath = "tests/test_kept.py"\nlane = "linux-guard"\n'

    def test_pre_existing_unregistered_test_warns_instead_of_failing(self) -> None:
        root = self.make_root(
            tests=["test_kept.py", "test_orphan.py"],
            registry=self.kept_registry(),
        )
        errors, warnings, _ = validator.validate(root, added=set())

        self.assertEqual(errors, [])
        self.assertTrue(
            any("tests/test_orphan.py" in warning for warning in warnings),
            warnings,
        )

    def test_unregistered_test_added_by_this_branch_fails(self) -> None:
        root = self.make_root(
            tests=["test_kept.py", "test_orphan.py"],
            registry=self.kept_registry(),
        )
        errors, _, _ = validator.validate(root, added={"tests/test_orphan.py"})

        self.assertTrue(
            any("tests/test_orphan.py" in error for error in errors),
            errors,
        )

    def test_unknown_added_set_never_fails_on_unregistered_tests(self) -> None:
        """No base sha means no comparison, so nothing unrelated can go red."""
        root = self.make_root(
            tests=["test_kept.py", "test_orphan.py"],
            registry=self.kept_registry(),
        )
        errors, warnings, _ = validator.validate(root)

        self.assertEqual(errors, [])
        self.assertTrue(warnings)

    def test_stale_entry_fails_even_for_an_unrelated_branch(self) -> None:
        root = self.make_root(
            tests=["test_kept.py"],
            registry=self.kept_registry()
            + '\n[[test]]\npath = "tests/test_deleted.py"\nlane = "linux-guard"\n',
        )
        errors, _, _ = validator.validate(root, added=set())

        self.assertTrue(
            any("tests/test_deleted.py: registry entry points to a missing test" in error for error in errors),
            errors,
        )

    def test_malformed_entry_fails_even_for_an_unrelated_branch(self) -> None:
        root = self.make_root(
            tests=["test_kept.py"],
            registry=self.kept_registry()
            + '\n[[test]]\npath = "tests/test_kept.py"\nlane = "manual"\n',
        )
        errors, _, _ = validator.validate(root, added=set())

        self.assertTrue(any("manual tests require a reason" in error for error in errors), errors)

    def test_duplicate_this_branch_introduces_fails(self) -> None:
        root = self.make_root(
            tests=["test_kept.py"],
            registry=self.kept_registry() + "\n" + self.kept_registry().partition("\n\n")[2],
        )
        errors, _, _ = validator.validate(root, added=set(), base_duplicates=set())

        self.assertTrue(
            any("tests/test_kept.py: registered more than once" in error for error in errors),
            errors,
        )

    def test_duplicate_already_on_the_base_branch_only_warns(self) -> None:
        """#13738 and #13739 each registered tests/test_sync_test_wiring.py."""
        root = self.make_root(
            tests=["test_kept.py"],
            registry=self.kept_registry() + "\n" + self.kept_registry().partition("\n\n")[2],
        )
        errors, warnings, _ = validator.validate(
            root, added=set(), base_duplicates={"tests/test_kept.py"}
        )

        self.assertEqual(errors, [])
        self.assertTrue(
            any("tests/test_kept.py: registered more than once" in warning for warning in warnings),
            warnings,
        )

    def test_dead_lane_fails_even_for_an_unrelated_branch(self) -> None:
        root = self.make_root(
            tests=["test_kept.py", "test_lane.py"],
            registry=self.kept_registry()
            + '\n[[test]]\npath = "tests/test_lane.py"\nlane = "no-such-lane"\n',
        )
        errors, _, _ = validator.validate(root, added=set())

        self.assertTrue(
            any("lane 'no-such-lane' has no workflow invocation" in error for error in errors),
            errors,
        )

    def test_failure_names_the_lane_a_workflow_already_runs(self) -> None:
        root = self.make_root(tests=["test_kept.py"], registry='version = 1\n\n[[test]]\npath = "tests/test_lane.py"\nlane = "manual"\nreason = "placeholder"\n')
        (root / "tests" / "test_lane.py").write_text("#!/usr/bin/env python3\n", encoding="utf-8")
        errors, _, _ = validator.validate(root, added={"tests/test_kept.py"})

        message = next(error for error in errors if error.startswith("tests/test_kept.py:"))
        self.assertIn("[[test]]", message)
        self.assertIn('path = "tests/test_kept.py"', message)
        self.assertIn('lane = "linux-guard"', message)
        self.assertIn("ci-guards.yml", message)

    def test_hint_offers_the_live_lanes_when_no_workflow_runs_the_file(self) -> None:
        root = self.make_root(tests=["test_kept.py", "test_orphan.py"], registry=self.kept_registry())
        errors, _, _ = validator.validate(root, added={"tests/test_orphan.py"})

        message = next(error for error in errors if error.startswith("tests/test_orphan.py:"))
        self.assertIn('path = "tests/test_orphan.py"', message)
        self.assertIn('lane = "<lane>"', message)
        self.assertIn("macos-cli-no-socket", message)

    def recipe_root(self, workflow_line: str) -> Path:
        root = self.make_root(
            tests=["test_kept.py", "test_recipe.py"],
            registry=self.kept_registry() + '\n[[test]]\npath = "tests/test_recipe.py"\nlane = "linux-guard"\n',
        )
        (root / "scripts").mkdir()
        (root / "scripts" / "verify-local.py").write_text(
            'CHECKS = (("recipe", "tests", "Recipe test", ["python3", "tests/test_recipe.py"]),)\n',
            encoding="utf-8",
        )
        (root / ".github" / "workflows" / "ci.yml").write_text(
            f"jobs:\n  static-preflight:\n    steps:\n      {workflow_line}\n", encoding="utf-8"
        )
        return root

    def test_a_test_the_shared_preflight_recipe_runs_is_live(self) -> None:
        root = self.recipe_root("- run: python3 scripts/verify-local.py")
        errors, _, _ = validator.validate(root, added=set())
        self.assertEqual(errors, [])

    def test_a_commented_out_recipe_run_does_not_make_its_tests_live(self) -> None:
        root = self.recipe_root("# - run: python3 scripts/verify-local.py")
        errors, _, _ = validator.validate(root, added=set())
        self.assertIn("tests/test_recipe.py: linux-guard lane is not run by any workflow", errors)

    def test_a_step_that_only_names_the_recipe_does_not_make_its_tests_live(self) -> None:
        root = self.recipe_root("- name: Document scripts/verify-local.py")
        errors, _, _ = validator.validate(root, added=set())
        self.assertIn("tests/test_recipe.py: linux-guard lane is not run by any workflow", errors)

    def test_an_only_selection_credits_just_the_selected_checks(self) -> None:
        root = self.recipe_root("- run: python3 scripts/verify-local.py --only other")
        errors, _, _ = validator.validate(root, added=set())
        self.assertIn("tests/test_recipe.py: linux-guard lane is not run by any workflow", errors)
        root = self.recipe_root("- run: python3 scripts/verify-local.py --only recipe")
        errors, _, _ = validator.validate(root, added=set())
        self.assertEqual(errors, [])

    def test_an_invocation_that_may_skip_checks_does_not_make_its_tests_live(self) -> None:
        for args in ("--affected", "--affected=origin/main", "--list", "--only recipe --list",
                     "--swift-changed", "--aff"):
            with self.subTest(args=args):
                root = self.recipe_root(f"- run: python3 scripts/verify-local.py {args}")
                errors, _, _ = validator.validate(root, added=set())
                self.assertIn("tests/test_recipe.py: linux-guard lane is not run by any workflow", errors)

    def test_full_recipe_options_keep_its_tests_live(self) -> None:
        for args in ("--all", "--timeout 120", "--receipt out.json", "--only=recipe", "&& echo done"):
            with self.subTest(args=args):
                root = self.recipe_root(f"- run: python3 scripts/verify-local.py {args}")
                errors, _, _ = validator.validate(root, added=set())
                self.assertEqual(errors, [])

    def test_a_commented_out_recipe_check_is_not_live(self) -> None:
        root = self.recipe_root("- run: python3 scripts/verify-local.py")
        (root / "scripts" / "verify-local.py").write_text(
            'CHECKS = (\n    # ("recipe", "tests", "Recipe test", ["python3", "tests/test_recipe.py"]),\n)\n',
            encoding="utf-8",
        )
        errors, _, _ = validator.validate(root, added=set())
        self.assertIn("tests/test_recipe.py: linux-guard lane is not run by any workflow", errors)

    def test_write_registers_a_test_a_workflow_already_runs(self) -> None:
        root = self.make_root(tests=["test_kept.py", "test_new.py"], registry=self.kept_registry())
        workflow = root / ".github" / "workflows" / "ci-guards.yml"
        workflow.write_text(GUARD_WORKFLOW + "      - run: python3 tests/test_new.py\n", encoding="utf-8")

        self.assertEqual(validator.register_derivable(root), ["tests/test_new.py"])
        errors, _, _ = validator.validate(root, added={"tests/test_new.py"})
        self.assertEqual(errors, [])
        self.assertEqual(validator.register_derivable(root), [])  # idempotent

    def test_a_test_a_workflow_runs_through_a_workload_profile_is_live(self) -> None:
        root = self.make_root(
            tests=["test_kept.py", "test_profiled.py"],
            registry=self.kept_registry()
            + '\n[[test]]\npath = "tests/test_profiled.py"\nlane = "linux-guard"\n',
        )
        workflow = root / ".github" / "workflows" / "ci-guards.yml"
        workflow.write_text(
            GUARD_WORKFLOW + "      - run: python3 scripts/ci/cmux_workload_profile.py run test.guard\n",
            encoding="utf-8",
        )
        (root / "scripts" / "ci" / "workloads").mkdir(parents=True)
        (root / "scripts" / "ci" / "cmux-workload-profiles.json").write_text(
            '{"profiles": [{"id": "test.guard", "entrypoint": "scripts/ci/workloads/guard.sh"}]}',
            encoding="utf-8",
        )
        (root / "scripts" / "ci" / "workloads" / "guard.sh").write_text(
            "python3 tests/test_profiled.py\n", encoding="utf-8"
        )

        errors, _, _ = validator.validate(root, added=set())
        self.assertEqual(errors, [])

    def test_write_leaves_a_test_no_workflow_runs_for_a_person_to_place(self) -> None:
        root = self.make_root(tests=["test_kept.py", "test_orphan.py"], registry=self.kept_registry())
        before = (root / "tests" / "test-execution.toml").read_text(encoding="utf-8")

        self.assertEqual(validator.register_derivable(root), [])
        self.assertEqual((root / "tests" / "test-execution.toml").read_text(encoding="utf-8"), before)

    def test_added_tests_are_measured_from_the_merge_base(self) -> None:
        root = Path(tempfile.mkdtemp(prefix="cmux-test-execution-registry-git-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)

        def git(*args: str) -> None:
            subprocess.run(
                ["git", "-c", "user.email=ci@example.com", "-c", "user.name=ci", *args],
                cwd=root,
                check=True,
                capture_output=True,
            )

        (root / "tests").mkdir()
        git("init", "-b", "main")
        (root / "tests" / "test_base.py").write_text("", encoding="utf-8")
        git("add", "-A")
        git("commit", "-m", "base")
        branch_point = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=root, text=True
        ).strip()

        git("checkout", "-b", "feature")
        (root / "tests" / "test_mine.py").write_text("", encoding="utf-8")
        git("add", "-A")
        git("commit", "-m", "mine")

        git("checkout", "main")
        (root / "tests" / "test_theirs.py").write_text("", encoding="utf-8")
        git("add", "-A")
        git("commit", "-m", "theirs")
        base_tip = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=root, text=True
        ).strip()
        git("checkout", "feature")

        self.assertNotEqual(base_tip, branch_point)
        # Somebody else's unregistered test landed on main after this branch
        # started. It must not be attributed to this branch.
        self.assertEqual(
            validator.newly_added_tests(base_tip, root),
            {"tests/test_mine.py"},
        )

    def test_validator_exit_code_tracks_added_tests_in_a_git_fixture(self) -> None:
        with tempfile.TemporaryDirectory(prefix="cmux-test-execution-registry-exit-") as temp:
            root = Path(temp)
            origin = root / "origin.git"
            repo = root / "checkout"

            def git(*args: str, cwd: Path = repo) -> None:
                subprocess.run(
                    [
                        "git",
                        "-c",
                        "user.email=ci@example.com",
                        "-c",
                        "user.name=ci",
                        *args,
                    ],
                    cwd=cwd,
                    check=True,
                    capture_output=True,
                    text=True,
                )

            subprocess.run(["git", "init", "--bare", str(origin)], check=True, capture_output=True, text=True)
            repo.mkdir()
            git("init", "-b", "main")
            git("remote", "add", "origin", str(origin))
            (repo / "tests").mkdir()
            (repo / ".github" / "workflows").mkdir(parents=True)
            (repo / ".github" / "workflows" / "ci-guards.yml").write_text(
                "name: guards\njobs:\n  guard:\n    steps:\n      - run: python3 tests/test_base.py\n      - run: python3 tests/test_feature.py\n",
                encoding="utf-8",
            )
            (repo / "tests" / "test_base.py").write_text("", encoding="utf-8")
            (repo / "tests" / "test-execution.toml").write_text(
                'version = 1\n\n[[test]]\npath = "tests/test_base.py"\nlane = "linux-guard"\n',
                encoding="utf-8",
            )
            git("add", "-A")
            git("commit", "-m", "base")
            git("push", "-u", "origin", "main")

            git("checkout", "-b", "feature")
            (repo / "tests" / "test_feature.py").write_text("", encoding="utf-8")
            git("add", "-A")
            git("commit", "-m", "feature test")

            git("checkout", "main")
            (repo / "tests" / "test_main.py").write_text("", encoding="utf-8")
            git("add", "-A")
            git("commit", "-m", "main test")
            git("push", "origin", "main")
            main_tip = subprocess.check_output(
                ["git", "rev-parse", "main"], cwd=repo, text=True
            ).strip()
            git("checkout", "feature")

            def validate() -> subprocess.CompletedProcess[str]:
                return subprocess.run(
                    [
                        sys.executable,
                        str(VALIDATOR),
                        "--repo-root",
                        str(repo),
                        "--base-sha",
                        main_tip,
                    ],
                    cwd=repo,
                    capture_output=True,
                    text=True,
                )

            self.assertEqual(validate().returncode, 1)

            with (repo / "tests" / "test-execution.toml").open("a", encoding="utf-8") as registry:
                registry.write('\n[[test]]\npath = "tests/test_feature.py"\nlane = "linux-guard"\n')
            git("add", "tests/test-execution.toml")
            git("commit", "-m", "register feature test")
            self.assertEqual(validate().returncode, 0)

            git("merge", "main")
            # This test arrived through the catch-up merge, so the current main
            # tip must keep it at warning severity.
            self.assertEqual(validate().returncode, 0)

    def test_registry_workflow_resolves_the_current_base_ref(self) -> None:
        block = workflow_job_block("workflow-guard-tests", GUARD_WORKFLOW_PATH)
        start = block.index("      - name: Validate Python test execution registry")
        end = block.index("      - name:", start + 1)
        step = block[start:end]

        self.assertIn(
            "CMUX_TEST_REGISTRY_BASE_REF: ${{ github.event.pull_request.base.ref || github.event.merge_group.base_ref || '' }}",
            step,
        )
        self.assertNotIn("github.event.pull_request.base.sha", step)
        self.assertIn(
            'git fetch --no-tags --depth=1 origin "$CMUX_TEST_REGISTRY_BASE_REF"',
            step,
        )
        self.assertIn('CMUX_TEST_REGISTRY_BASE_SHA="$(git rev-parse FETCH_HEAD)"', step)
        self.assertIn('validate_test_execution_registry.py "${args[@]+"${args[@]}"}"', step)
        self.assertIn('args=(--base-sha "$CMUX_TEST_REGISTRY_BASE_SHA")', step)

    def test_newly_added_tests_show_why_the_workflow_needs_the_current_base_tip(self) -> None:
        root = Path(tempfile.mkdtemp(prefix="cmux-test-execution-registry-git-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)

        def git(*args: str) -> None:
            subprocess.run(
                ["git", "-c", "user.email=ci@example.com", "-c", "user.name=ci", *args],
                cwd=root,
                check=True,
                capture_output=True,
            )

        (root / "tests").mkdir()
        git("init", "-b", "main")
        (root / "tests" / "test_base.py").write_text("", encoding="utf-8")
        git("add", "-A")
        git("commit", "-m", "base")
        stale_base_sha = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=root, text=True
        ).strip()

        git("checkout", "-b", "feature")
        (root / "tests" / "test_mine.py").write_text("", encoding="utf-8")
        git("add", "-A")
        git("commit", "-m", "mine")

        git("checkout", "main")
        (root / "tests" / "test_theirs.py").write_text("", encoding="utf-8")
        git("add", "-A")
        git("commit", "-m", "theirs")
        main_tip = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=root, text=True
        ).strip()

        git("checkout", "feature")
        git("merge", "main")

        # This is correct for a stale base input. It documents why the workflow
        # must resolve and pass main's current tip instead.
        self.assertEqual(
            validator.newly_added_tests(stale_base_sha, root),
            {"tests/test_mine.py", "tests/test_theirs.py"},
        )
        self.assertEqual(
            validator.newly_added_tests(main_tip, root),
            {"tests/test_mine.py"},
        )

        # Execute the workflow fetch against the fixture's origin and observe
        # the validator arguments, including the no-base push-event path.
        git("remote", "add", "origin", str(root))
        script = workflow_job_step_script(
            "workflow-guard-tests",
            "Validate Python test execution registry",
            GUARD_WORKFLOW_PATH,
        )
        script = script.replace(
            'python3 scripts/ci/validate_test_execution_registry.py "${args[@]+"${args[@]}"}"',
            'printf "%s\\n" "${args[@]+"${args[@]}"}"',
        )
        for base_ref, expected in (("main", ["--base-sha", main_tip]), ("", [""])):
            with self.subTest(base_ref=base_ref):
                result = subprocess.run(
                    ["bash", "-c", script],
                    cwd=root,
                    env={**os.environ, "CMUX_TEST_REGISTRY_BASE_REF": base_ref},
                    check=True,
                    text=True,
                    capture_output=True,
                )
                self.assertEqual(result.stdout.splitlines(), expected)


# Each fake test records its start, then waits until `peers` tests have
# started (or 5 s pass) so the runner's concurrency is observable.
LANE_TEST = """\
import os, pathlib, sys, time
log = pathlib.Path(os.environ["LANE_LOG"])
name = pathlib.Path(__file__).stem
with log.open("a") as stream:
    stream.write(f"start {name}\\n")
peers = int(os.environ.get("LANE_PEERS", "0"))
deadline = time.monotonic() + 5
while name.startswith("test_par") and time.monotonic() < deadline:
    if sum(line.startswith("start test_par") for line in log.read_text().splitlines()) >= peers:
        break
    time.sleep(0.02)
with log.open("a") as stream:
    stream.write(f"end {name}\\n")
print(f"output from {name}")
if name.endswith("hang"):
    time.sleep(60)
sys.exit(3 if name.endswith("fail") else 0)
"""


class LaneRunnerTests(unittest.TestCase):
    def test_invalid_timeouts_are_rejected_before_listing_tests(self) -> None:
        for timeout in ("0", "-1", "nan", "inf", "-inf"):
            with self.subTest(timeout=timeout):
                result = subprocess.run(
                    [sys.executable, str(RUNNER), "--lane", "linux-guard",
                     "--list", f"--timeout={timeout}"],
                    cwd=ROOT, capture_output=True, text=True,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("--timeout must be a positive finite number", result.stderr)
                self.assertEqual(result.stdout, "")

    def run_lane(self, registry: str, names: list[str], *args: str, peers: int) -> tuple[int, list[str], str]:
        root = Path(tempfile.mkdtemp(prefix="cmux-lane-runner-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        (root / "tests").mkdir()
        for name in names:
            (root / "tests" / f"{name}.py").write_text(LANE_TEST, encoding="utf-8")
        manifest = root / "tests" / "test-execution.toml"
        manifest.write_text(registry, encoding="utf-8")
        log = root / "lane.log"
        log.touch()
        output = io.StringIO()
        with mock.patch.object(runner, "ROOT", root), mock.patch.object(runner, "MANIFEST", manifest), \
                mock.patch.dict(runner.os.environ, {"LANE_LOG": str(log), "LANE_PEERS": str(peers)}), \
                mock.patch.object(runner.sys, "stdout", output):
            code = runner.main(list(args))
        return code, log.read_text().splitlines(), output.getvalue()

    @staticmethod
    def entry(name: str, lane: str, extra: str = "") -> str:
        return f'\n[[test]]\npath = "tests/{name}.py"\nlane = "{lane}"\n{extra}'

    def test_jobs_run_tests_concurrently(self) -> None:
        names = ["test_par_a", "test_par_b", "test_par_c"]
        registry = "version = 1\n" + "".join(self.entry(name, "lane-a") for name in names)
        code, log, output = self.run_lane(registry, names, "--lane", "lane-a", "--jobs", "3", peers=3)
        self.assertEqual(code, 0, output)
        events = [line.split()[0] for line in log]
        self.assertEqual(events[:3], ["start"] * 3, log)
        # Output stays grouped per test, in registry order.
        self.assertLess(output.index("output from test_par_a"), output.index("==> tests/test_par_b.py"))

    def test_serial_entries_run_alone_before_the_pool(self) -> None:
        names = ["test_par_a", "test_par_b", "test_serial"]
        registry = (
            "version = 1\n"
            + self.entry("test_par_a", "lane-a")
            + self.entry("test_serial", "lane-b", "serial = true\n")
            + self.entry("test_par_b", "lane-b")
        )
        code, log, output = self.run_lane(
            registry, names, "--lane", "lane-a", "--lane", "lane-b", "--jobs", "4", peers=2
        )
        self.assertEqual(code, 0, output)
        self.assertEqual(log[:2], [log[0], "end test_serial"], log)
        self.assertTrue(log[0].startswith("start test_serial"), log)

    def test_a_failure_reports_every_failing_test_after_running_all(self) -> None:
        names = ["test_par_fail", "test_par_ok", "test_par_other_fail"]
        registry = "version = 1\n" + "".join(self.entry(name, "lane-a") for name in names)
        code, log, output = self.run_lane(registry, names, "--lane", "lane-a", "--jobs", "2", peers=2)
        self.assertEqual(code, 1)
        self.assertEqual(sum(line.startswith("end") for line in log), 3, log)
        self.assertIn("FAILED: tests/test_par_fail.py (exit 3)", output)
        self.assertIn("FAILED: tests/test_par_other_fail.py (exit 3)", output)

    def test_a_process_start_failure_reports_the_test_and_continues(self) -> None:
        original_popen = runner.subprocess.Popen

        def start_process(command, **kwargs):
            if Path(command[1]).stem == "test_start_fail":
                raise OSError("simulated process creation failure")
            return original_popen(command, **kwargs)

        for serial in (False, True):
            with self.subTest(serial=serial):
                names = ["test_start_fail", "test_ok"]
                registry = (
                    "version = 1\n"
                    + self.entry("test_start_fail", "lane-a", "serial = true\n" if serial else "")
                    + self.entry("test_ok", "lane-a")
                )
                with mock.patch.object(runner.subprocess, "Popen", side_effect=start_process):
                    code, log, output = self.run_lane(
                        registry, names, "--lane", "lane-a", "--jobs", "2", peers=0
                    )
                self.assertEqual(code, 1)
                self.assertIn("end test_ok", log)
                self.assertIn("output from test_ok", output)
                self.assertIn("simulated process creation failure", output)
                self.assertIn("FAILED: tests/test_start_fail.py (exit 1)", output)
                self.assertIn("2 tests in", output)
                self.assertIn("1 failed", output)

    def test_a_hung_test_is_killed_and_reported(self) -> None:
        # Neither process waits for a peer; only the deliberate hang reaches
        # the timeout, regardless of which process the scheduler starts first.
        names = ["test_hang", "test_ok"]
        registry = "version = 1\n" + "".join(self.entry(name, "lane-a") for name in names)
        code, log, output = self.run_lane(
            registry, names, "--lane", "lane-a", "--jobs", "2", "--timeout", "1", peers=0
        )
        self.assertEqual(code, 1)
        self.assertIn("killed after 1s timeout", output)
        self.assertIn("FAILED: tests/test_hang.py (exit 124)", output)
        self.assertIn("output from test_ok", output)

    def test_serial_parses_as_a_toml_boolean(self) -> None:
        entries = runner.load_registry.__globals__["parse_registry"](
            'version = 1\n[[test]]\npath = "tests/test_x.py"\nlane = "a"\nserial = true\n', "inline"
        )
        self.assertIs(entries[0]["serial"], True)

    def test_workflow_discovery_reads_every_lane_of_one_invocation(self) -> None:
        workflow = "run: python3 scripts/ci/run_python_test_lane.py --jobs 8 --lane one --lane=two --lane three\n"
        self.assertEqual(validator.runner_lanes_from_workflow_text(workflow), {"one", "two", "three"})


if __name__ == "__main__":
    unittest.main()
