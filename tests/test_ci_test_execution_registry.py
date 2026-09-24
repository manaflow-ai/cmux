#!/usr/bin/env python3
"""The execution registry validator only fails the pull request at fault.

An unregistered test that a pull request adds is that pull request's problem.
An unregistered test that was already on the base branch is not, and failing
on it turns every open pull request red for a reason its author cannot fix.
"""

from __future__ import annotations

import importlib.util
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / "scripts" / "ci" / "validate_test_execution_registry.py"

spec = importlib.util.spec_from_file_location("validate_test_execution_registry", VALIDATOR)
assert spec and spec.loader
validator = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = validator
spec.loader.exec_module(validator)


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


if __name__ == "__main__":
    unittest.main()
