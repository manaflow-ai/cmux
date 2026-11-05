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
      - name: Run the no-socket lane
        run: scripts/ci/run_python_test_lane.py --lane macos-cli-no-socket
"""


class RegistryBlastRadiusTests(unittest.TestCase):
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

    def test_write_only_registers_the_named_tests(self) -> None:
        """The pre-commit hook passes only the commit's own tests (#21946): registering every
        unregistered test the base carries wrote the same entries into every pull request."""
        root = self.make_root(tests=["test_kept.py", "test_base.py", "test_mine.py"], registry=self.kept_registry())
        workflow = root / ".github" / "workflows" / "ci-guards.yml"
        workflow.write_text(
            GUARD_WORKFLOW + "      - run: python3 tests/test_base.py\n      - run: python3 tests/test_mine.py\n",
            encoding="utf-8",
        )

        self.assertEqual(validator.register_derivable(root, only={"tests/test_mine.py"}), ["tests/test_mine.py"])
        self.assertEqual(validator.register_derivable(root, only=set()), [])
        self.assertEqual(validator.register_derivable(root), ["tests/test_base.py"])  # unrestricted, as before

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
NEXT_GUARDS_PATH = ROOT / ".github" / "workflows" / "cmux-next-guards.yml"


class RegistryFindingsJudgedAgainstTheBase(unittest.TestCase):
    """Leo, 2026-11-05, after one direct push's unregistered test reddened every pull request:
    "There is no way that, like, the notion of not adding tests should block CI."

    A registry finding the base already has warns, naming the file and the commit that added it.
    Only a finding this change adds fails. With --warn-only (a push) nothing fails.
    """

    def setUp(self) -> None:
        temp = Path(tempfile.mkdtemp(prefix="cmux-registry-base-findings-"))
        self.addCleanup(shutil.rmtree, temp, ignore_errors=True)
        self.repo = temp
        self.git("init", "-b", "main")
        (temp / "tests").mkdir()
        (temp / ".github" / "workflows").mkdir(parents=True)
        self.write(".github/workflows/ci-guards.yml",
                   "name: guards\njobs:\n  guard:\n    steps:\n      - run: python3 tests/test_base.py\n")
        self.write("tests/test_base.py", "")
        self.write("tests/test-execution.toml",
                   'version = 1\n\n[[test]]\npath = "tests/test_base.py"\nlane = "linux-guard"\n')
        self.commit("base")

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-c", "user.email=ci@example.com", "-c", "user.name=ci", *args],
                              cwd=self.repo, check=True, capture_output=True, text=True).stdout.strip()

    def write(self, path: str, text: str) -> None:
        (self.repo / path).write_text(text, encoding="utf-8")

    def register(self, path: str) -> None:
        with (self.repo / "tests" / "test-execution.toml").open("a", encoding="utf-8") as registry:
            registry.write(f'\n[[test]]\npath = "{path}"\nlane = "linux-guard"\n')

    def commit(self, message: str) -> str:
        self.git("add", "-A")
        self.git("commit", "-m", message)
        return self.git("rev-parse", "HEAD")

    def run_validator(self, base: str, *extra: str) -> subprocess.CompletedProcess[str]:
        env = {**os.environ, "GITHUB_ACTIONS": "true"}
        env.pop("GITHUB_STEP_SUMMARY", None)
        return subprocess.run([sys.executable, str(VALIDATOR), "--repo-root", str(self.repo),
                               "--base-sha", base, *extra],
                              cwd=self.repo, capture_output=True, text=True, env=env)

    def direct_push_of_a_dead_registration(self) -> str:
        """test_nightly_one_mini.py's shape: registered linux-guard, no workflow step runs it."""
        self.write("tests/test_direct.py", "")
        self.register("tests/test_direct.py")
        return self.commit("direct push: a test no step runs")

    def test_a_dead_registration_already_on_the_base_warns_with_its_commit(self) -> None:
        added_by = self.direct_push_of_a_dead_registration()
        base = self.git("rev-parse", "HEAD")
        self.git("checkout", "-b", "feature")
        self.write("tests/test_base.py", "# an unrelated change\n")
        self.commit("feature")

        result = self.run_validator(base)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        warning = next((line for line in result.stdout.splitlines()
                        if line.startswith("::warning file=tests/test_direct.py")), "")
        self.assertIn("linux-guard lane is not run by any workflow", warning, result.stdout)
        self.assertIn(added_by[:12], warning)

    def test_a_dead_registration_this_branch_adds_still_fails(self) -> None:
        base = self.git("rev-parse", "HEAD")
        self.git("checkout", "-b", "feature")
        self.direct_push_of_a_dead_registration()

        result = self.run_validator(base)

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("tests/test_direct.py: linux-guard lane is not run by any workflow", result.stderr)

    def test_an_unregistered_test_already_on_the_base_names_the_commit_that_added_it(self) -> None:
        self.write("tests/test_orphan.py", "")
        added_by = self.commit("direct push: an unregistered test")
        base = added_by
        self.git("checkout", "-b", "feature")
        self.write("tests/test_base.py", "# an unrelated change\n")
        self.commit("feature")

        result = self.run_validator(base)

        self.assertEqual(result.returncode, 0, result.stderr)
        warning = next((line for line in result.stdout.splitlines()
                        if line.startswith("::warning file=tests/test_orphan.py")), "")
        self.assertIn(added_by[:12], warning, result.stdout)

    def test_a_test_this_branch_renames_without_registering_fails_as_added(self) -> None:
        self.write("tests/test_old.py", "print('a test long enough to be detected as a rename')\n" * 5)
        self.commit("old test, unregistered on the base")
        base = self.git("rev-parse", "HEAD")
        self.git("checkout", "-b", "feature")
        self.git("mv", "tests/test_old.py", "tests/test_new.py")
        self.commit("rename")

        result = self.run_validator(base)

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("tests/test_new.py: added by this pull request with no execution registry entry",
                      result.stderr)

    def test_warn_only_turns_every_finding_into_a_warning(self) -> None:
        """A push to feat-cmux-next: the pushed commit's own finding warns too; base-red-watch reads it."""
        base = self.git("rev-parse", "HEAD")
        added_by = self.direct_push_of_a_dead_registration()

        result = self.run_validator(base, "--warn-only")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        warning = next((line for line in result.stdout.splitlines()
                        if line.startswith("::warning file=tests/test_direct.py")), "")
        self.assertIn("linux-guard lane is not run by any workflow", warning, result.stdout)
        self.assertIn(added_by[:12], warning)

    def test_the_feat_cmux_next_step_warns_only_on_a_push(self) -> None:
        text = NEXT_GUARDS_PATH.read_text(encoding="utf-8")
        line = next(line for line in text.splitlines()
                    if "validate_test_execution_registry.py --pr-lanes feat-cmux-next" in line)
        self.assertIn("github.event_name == 'push' && '--warn-only'", line)


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


import test_execution_registry as registry  # noqa: E402  (scripts/ci is on sys.path above)

# The last feat-cmux-next commit with the single tests/test-execution.toml (639 entries).
PRE_SPLIT = "2337f96e4399ce0eba7fafb38fea5861634082ae"

LEGACY_REGISTRY = """\
# The header.
version = 1

[[test]]
path = "tests/test_ci_zeta.py"
lane = "linux-guard"

[[test]]
path = "tests/test_web_one.py"
lane = "macos-shell"
# A comment that stays with its entry.
serial = true

[[test]]
path = "tests/test_ci_alpha.py"
lane = "manual"
reason = "Run by hand."

# A section comment between entries.

[[test]]
path = "tests/test_lonely.py"
lane = "linux-guard"
requirements = ["fish"]

[[test]]
path = "tests/test_ci_mid.py"
lane = "legacy"
"""


def by_path(entries: list[dict[str, object]]) -> list[dict[str, object]]:
    return sorted(entries, key=lambda entry: str(entry["path"]))


class RegistrySplitTests(unittest.TestCase):
    """Leo, 2026-11-05, on hot files every pull request conflicts on: "i meant can you do all of htem".

    tests/test-execution.toml became tests/test-execution.d/<area>.toml. Every reader sees the
    same entries the single file gave, and a new entry touches only its area's file.
    """

    def make_legacy_root(self, text: str = LEGACY_REGISTRY) -> Path:
        root = Path(tempfile.mkdtemp(prefix="cmux-registry-split-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        (root / "tests").mkdir()
        (root / registry.LEGACY).write_text(text, encoding="utf-8")
        return root

    def test_the_split_reads_back_exactly_the_single_file(self) -> None:
        root = self.make_legacy_root()
        before = registry.load_tree(root)
        registry.split_legacy(root, minimum=2)

        self.assertFalse((root / registry.LEGACY).exists())
        self.assertEqual(sorted(path.name for path in (root / registry.FRAGMENTS).iterdir()),
                         ["ci.toml", "other.toml"])
        self.assertEqual(by_path(registry.load_tree(root)), by_path(before))
        self.assertEqual(registry.layout_findings(root), [])
        ci = (root / registry.FRAGMENTS / "ci.toml").read_text(encoding="utf-8")
        self.assertLess(ci.index("test_ci_alpha"), ci.index("test_ci_mid"))
        self.assertLess(ci.index("test_ci_mid"), ci.index("test_ci_zeta"))
        self.assertIn("# A comment that stays with its entry.\nserial = true",
                      (root / registry.FRAGMENTS / "other.toml").read_text(encoding="utf-8"))

    def test_the_merged_text_is_one_registry_tomllib_reads(self) -> None:
        import tomllib

        root = self.make_legacy_root()
        before = registry.load_tree(root)
        registry.split_legacy(root, minimum=2)
        merged = tomllib.loads(registry.merged_text(registry.registry_sources(root)))
        self.assertEqual(merged["version"], 1)
        self.assertEqual(by_path(merged["test"]), by_path(before))

    def test_the_real_pre_split_registry_splits_into_the_same_entries(self) -> None:
        """The byte-identical check on the real file: the single file at the last commit that had it,
        split here, reads back the same 639 entries."""
        try:
            text = subprocess.check_output(["git", "show", f"{PRE_SPLIT}:{registry.LEGACY}"], cwd=ROOT,
                                           text=True, stderr=subprocess.DEVNULL)
        except (OSError, subprocess.CalledProcessError):
            self.skipTest(f"{PRE_SPLIT[:12]} is not in this clone's history")
        root = self.make_legacy_root(text)
        before = registry.load_tree(root)
        registry.split_legacy(root)
        after = registry.load_tree(root)
        self.assertEqual(len(after), 639)
        self.assertEqual(by_path(after), by_path(before))
        self.assertEqual(registry.layout_findings(root), [])

    def test_the_checked_in_fragments_are_placed_and_sorted(self) -> None:
        self.assertFalse((ROOT / registry.LEGACY).exists(), "the single registry file came back")
        self.assertEqual(registry.layout_findings(ROOT), [])

    def test_an_old_single_file_beside_the_fragments_is_read_and_flagged(self) -> None:
        root = self.make_legacy_root()
        registry.split_legacy(root, minimum=2)
        (root / registry.LEGACY).write_text(
            'version = 1\n\n[[test]]\npath = "tests/test_stale.py"\nlane = "linux-guard"\n', encoding="utf-8")
        self.assertIn("tests/test_stale.py", [entry["path"] for entry in registry.load_tree(root)])
        self.assertTrue(any("absorb" in finding for finding in registry.layout_findings(root)))

    def test_a_misplaced_or_unsorted_entry_warns_and_fix_repairs_it(self) -> None:
        root = self.make_legacy_root()
        registry.split_legacy(root, minimum=2)
        with (root / registry.FRAGMENTS / "other.toml").open("a", encoding="utf-8") as other:
            other.write('\n[[test]]\npath = "tests/test_ci_beta.py"\nlane = "linux-guard"\n')
        findings = registry.layout_findings(root)
        self.assertTrue(any(finding.startswith("tests/test_ci_beta.py: registered in") for finding in findings))
        self.assertTrue(any("not sorted" in finding for finding in findings))

        before = registry.load_tree(root)
        self.assertEqual(registry.main(["--repo-root", str(root), "fix"]), 0)
        self.assertEqual(registry.layout_findings(root), [])
        self.assertEqual(by_path(registry.load_tree(root)), by_path(before))

    def test_a_fragment_may_not_carry_a_version_or_be_empty(self) -> None:
        with self.assertRaisesRegex(ValueError, "only \\[\\[test\\]\\] entries"):
            registry.parse_registry("version = 1\n", "x.toml", fragment=True)
        with self.assertRaisesRegex(ValueError, "expected \\[\\[test\\]\\] entries"):
            registry.parse_registry("# nothing\n", "x.toml", fragment=True)

    def test_write_registers_a_new_test_in_its_area_at_its_sorted_place(self) -> None:
        root = self.make_legacy_root()
        registry.split_legacy(root, minimum=2)
        (root / ".github" / "workflows").mkdir(parents=True)
        (root / ".github" / "workflows" / "ci-guards.yml").write_text(
            "jobs:\n  g:\n    steps:\n      - run: python3 tests/test_ci_beta.py\n"
            "      - run: python3 tests/test_new_area.py\n", encoding="utf-8")
        for name in ("test_ci_zeta", "test_web_one", "test_ci_alpha", "test_lonely", "test_ci_mid",
                     "test_ci_beta", "test_new_area"):
            (root / "tests" / f"{name}.py").write_text("", encoding="utf-8")
        other_before = (root / registry.FRAGMENTS / "other.toml").read_text(encoding="utf-8")

        self.assertEqual(validator.register_derivable(root, only={"tests/test_ci_beta.py"}), ["tests/test_ci_beta.py"])

        ci = (root / registry.FRAGMENTS / "ci.toml").read_text(encoding="utf-8")
        self.assertLess(ci.index("test_ci_alpha"), ci.index("test_ci_beta"))
        self.assertLess(ci.index("test_ci_beta"), ci.index("test_ci_mid"))
        self.assertEqual((root / registry.FRAGMENTS / "other.toml").read_text(encoding="utf-8"), other_before)
        self.assertEqual(validator.register_derivable(root), ["tests/test_new_area.py"])
        self.assertIn("tests/test_new_area.py", (root / registry.FRAGMENTS / "other.toml").read_text(encoding="utf-8"))
        self.assertEqual(registry.layout_findings(root), [])


class RegistrySplitGitTests(unittest.TestCase):
    """Reading a commit's registry, and moving an open branch's edits to the old file into the fragments."""

    def setUp(self) -> None:
        self.repo = Path(tempfile.mkdtemp(prefix="cmux-registry-split-git-"))
        self.addCleanup(shutil.rmtree, self.repo, ignore_errors=True)
        self.git("init", "-q", "-b", "main")
        (self.repo / "tests").mkdir()
        (self.repo / registry.LEGACY).write_text(LEGACY_REGISTRY, encoding="utf-8")
        self.commit("the single file")

    def git(self, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["git", "-c", "user.email=ci@example.com", "-c", "user.name=ci", *args],
                              cwd=self.repo, check=check, capture_output=True, text=True)

    def commit(self, message: str) -> str:
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD").stdout.strip()

    def edit_legacy_on_a_branch(self) -> None:
        self.git("checkout", "-q", "-b", "feature")
        text = LEGACY_REGISTRY.replace('lane = "legacy"', 'lane = "linux-guard"')  # changed
        text = text.replace('[[test]]\npath = "tests/test_ci_zeta.py"\nlane = "linux-guard"\n\n', "")  # removed
        text = text.replace('version = 1\n', 'version = 1\n\n[[test]]\npath = "tests/test_web_two.py"\n'
                            'lane = "linux-guard"\n')  # added at the top, the old habit
        (self.repo / registry.LEGACY).write_text(text, encoding="utf-8")
        self.commit("feature edits the single file")
        self.git("checkout", "-q", "main")
        registry.split_legacy(self.repo, minimum=2)
        self.split = self.commit("split")

    def expected(self) -> list[dict[str, object]]:
        entries = [dict(entry) for entry in registry.parse_registry(LEGACY_REGISTRY, "x")
                   if entry["path"] != "tests/test_ci_zeta.py"]
        for entry in entries:
            if entry["path"] == "tests/test_ci_mid.py":
                entry["lane"] = "linux-guard"
        return by_path([*entries, {"path": "tests/test_web_two.py", "lane": "linux-guard"}])

    def test_a_commits_registry_reads_from_git_in_either_layout(self) -> None:
        old = self.git("rev-parse", "HEAD").stdout.strip()
        registry.split_legacy(self.repo, minimum=2)
        new = self.commit("split")
        self.assertEqual(by_path(registry.load_tree_at(self.repo, new)),
                         by_path(registry.load_tree_at(self.repo, old)))
        self.assertEqual(len(registry.registry_sources_at(self.repo, new)), 2)

    def test_absorb_resolves_a_merge_of_the_split_into_a_branch(self) -> None:
        self.edit_legacy_on_a_branch()
        self.git("checkout", "-q", "feature")
        self.assertNotEqual(self.git("merge", "-q", "main", check=False).returncode, 0)  # modify/delete

        self.assertEqual(registry.main(["--repo-root", str(self.repo), "absorb"]), 0)

        self.assertFalse((self.repo / registry.LEGACY).exists())
        self.assertEqual(by_path(registry.load_tree(self.repo)), self.expected())
        self.assertEqual(registry.layout_findings(self.repo), [])
        self.assertEqual(self.git("diff", "--name-only", "--diff-filter=U").stdout.strip(), "")

    def test_absorb_resolves_a_rebase_onto_the_split(self) -> None:
        self.edit_legacy_on_a_branch()
        self.git("checkout", "-q", "feature")
        self.assertNotEqual(self.git("rebase", "main", check=False).returncode, 0)

        self.assertEqual(registry.main(["--repo-root", str(self.repo), "absorb"]), 0)

        self.assertEqual(by_path(registry.load_tree(self.repo)), self.expected())
        self.assertEqual(self.git("diff", "--name-only", "--diff-filter=U").stdout.strip(), "")


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
        with mock.patch.object(runner, "ROOT", root), \
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
        entries = runner.load_tree.__globals__["parse_registry"](
            'version = 1\n[[test]]\npath = "tests/test_x.py"\nlane = "a"\nserial = true\n', "inline"
        )
        self.assertIs(entries[0]["serial"], True)

    def test_workflow_discovery_reads_every_lane_of_one_invocation(self) -> None:
        workflow = "run: python3 scripts/ci/run_python_test_lane.py --jobs 8 --lane one --lane=two --lane three\n"
        self.assertEqual(validator.runner_lanes_from_workflow_text(workflow), {"one", "two", "three"})

    def test_verify_local_jobs_option_keeps_recipe_tests_live(self) -> None:
        workflow = ["run: python3 scripts/verify-local.py --jobs 4\n"]
        discovered = validator.recipe_tests(workflow)
        self.assertIn("tests/test_normalize_pbxproj.py", discovered)


if __name__ == "__main__":
    unittest.main()
