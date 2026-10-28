#!/usr/bin/env python3
"""tests/runs_on_labels.py resolves every label a runs-on can select, and refuses all but Blacksmith Linux.

The three cmux-tui runner checks that used to pin an exact runs-on string read it now. These cases prove
the check is strict where it matters (a GitHub-hosted label outside the fork branch, a personal machine,
any other label, an empty value) and loose where it should be (vCPU size, overflow wiring), on the real
workflows and on copies of them mutated the ways a bad change would.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
from runs_on_labels import EMPTY, Unknown, disallowed_labels, linux_runner_values, resolve_labels  # noqa: E402
# The personal Linux workstation's label, from the fleet rule lint: the one file allowed to spell it.
from test_ci_fleet_rule_lints import CANDIDATE_WORDS_ANY_CASE  # noqa: E402

PERSONAL_WORKSTATION_LABEL = CANDIDATE_WORDS_ANY_CASE[0]

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"
FORK = "github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04'"


def daemon_runs_on(text: str) -> str:
    return yaml.load(text, Loader=yaml.BaseLoader)["jobs"]["cmux-next-daemon-tests"]["runs-on"]


def lint_runner(text: str) -> str:
    [row] = yaml.load(text, Loader=yaml.BaseLoader)["jobs"]["lint"]["strategy"]["matrix"]["include"]
    return row["runner"]


# (workflow, how to read the runs-on, the values each described variable may hold)
SITES = (
    ("cmux-tui-artifacts.yml", daemon_runs_on, {}),
    ("cmux-tui.yml", lint_runner, {"LINUX_RUNNER": linux_runner_values()}),
)


class ResolveLabels(unittest.TestCase):
    def test_the_fork_branch_never_evaluates_in_manaflow_ai(self):
        self.assertEqual(resolve_labels("${{ " + FORK + " || 'blacksmith-4vcpu-ubuntu-2404' }}"),
                         {"blacksmith-4vcpu-ubuntu-2404"})
        # In a fork it is the hosted label.
        self.assertEqual(resolve_labels("${{ " + FORK + " || 'blacksmith-4vcpu-ubuntu-2404' }}", owner="someone"),
                         {"ubuntu-24.04"})

    def test_a_variable_gate_yields_both_sides(self):
        self.assertEqual(
            resolve_labels("${{ vars.CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-16vcpu-ubuntu-2404' || 'blacksmith-32vcpu-ubuntu-2404' }}"),
            {"blacksmith-16vcpu-ubuntu-2404", "blacksmith-32vcpu-ubuntu-2404"})

    def test_a_variable_read_as_a_label_is_unknown_or_falsy(self):
        labels = resolve_labels("${{ vars.LINUX_RUNNER }}")
        self.assertIn(EMPTY, labels)
        self.assertIn("vars.LINUX_RUNNER", labels)
        self.assertTrue(any(isinstance(label, Unknown) for label in labels))

    def test_a_described_variable_takes_its_values_and_contains_is_exact(self):
        variables = {"LINUX_RUNNER": {"ubuntu-24.04", "blacksmith-32vcpu-ubuntu-2404"}}
        expression = "${{ contains(vars.LINUX_RUNNER, '32vcpu') && vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}"
        self.assertEqual(resolve_labels(expression, variables=variables),
                         {"blacksmith-32vcpu-ubuntu-2404", "blacksmith-4vcpu-ubuntu-2404"})
        self.assertIn("ubuntu-24.04", resolve_labels("${{ vars.LINUX_RUNNER || 'x' }}", variables=variables))

    def test_numbers_null_and_booleans_follow_github_truthiness(self):
        self.assertEqual(resolve_labels("${{ !0 && 'ubuntu-latest' || 'b' }}"), {"ubuntu-latest"})
        self.assertEqual(resolve_labels("${{ 0 && 'a' || 'b' }}"), {"b"})
        self.assertEqual(resolve_labels("${{ null || 'b' }}"), {"b"})
        self.assertEqual(resolve_labels("${{ 1 && 'a' || 'b' }}"), {"a"})
        # Mixed types are coerced by GitHub; the resolver keeps both outcomes.
        self.assertEqual(resolve_labels("${{ 0 == false && 'ubuntu-latest' || 'b' }}"), {"ubuntu-latest", "b"})
        self.assertEqual(resolve_labels("${{ '1' == 1 && 'a' || 'b' }}"), {"a", "b"})
        self.assertEqual(resolve_labels("${{ 'A' == 'a' && 'x' || 'y' }}"), {"x"})

    def test_literals_lists_parentheses_and_negation(self):
        self.assertEqual(resolve_labels("blacksmith-2vcpu-ubuntu-2404"), {"blacksmith-2vcpu-ubuntu-2404"})
        self.assertEqual(resolve_labels(["a", "${{ 'b' }}"]), {"a", "b"})
        self.assertEqual(resolve_labels("${{ !(github.event_name == 'push') && 'x' || 'y' }}"), {"x", "y"})
        self.assertEqual(resolve_labels("${{ 'it''s' }}"), {"it's"})


class DisallowedLabels(unittest.TestCase):
    def test_any_blacksmith_linux_size_passes(self):
        for label in ("blacksmith-2vcpu-ubuntu-2404", "blacksmith-64vcpu-ubuntu-2404", "blacksmith-4vcpu-ubuntu-2404-arm"):
            with self.subTest(label=label):
                self.assertEqual(disallowed_labels("${{ " + FORK + " || '" + label + "' }}"), {})

    def test_hosted_personal_other_and_empty_labels_fail(self):
        cases = {
            "${{ vars.X && 'ubuntu-latest' || 'blacksmith-4vcpu-ubuntu-2404' }}": "ubuntu-latest",
            "${{ vars.X && 'ubuntu-24.04' || 'blacksmith-4vcpu-ubuntu-2404' }}": "ubuntu-24.04",
            "${{ vars.X && 'macos-26' || 'blacksmith-4vcpu-ubuntu-2404' }}": "macos-26",
            "${{ vars.X && 'windows-2022' || 'blacksmith-4vcpu-ubuntu-2404' }}": "windows-2022",
            "${{ vars.X && '%s' || 'blacksmith-4vcpu-ubuntu-2404' }}" % PERSONAL_WORKSTATION_LABEL: PERSONAL_WORKSTATION_LABEL,
            "${{ vars.X && 'blacksmith-6vcpu-macos-26' || 'blacksmith-4vcpu-ubuntu-2404' }}": "blacksmith-6vcpu-macos-26",
            "${{ vars.X && 'glaeda-side-light-xcode-26.6' || 'blacksmith-4vcpu-ubuntu-2404' }}": "glaeda-side-light-xcode-26.6",
            "${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}": "vars.LINUX_RUNNER",
            "${{ vars.X && 'blacksmith-4vcpu-ubuntu-2404' }}": "''",
        }
        for expression, label in cases.items():
            with self.subTest(expression=expression):
                self.assertIn(label, disallowed_labels(expression))

    def test_a_described_variable_is_checked_by_its_values(self):
        variables = {"LINUX_RUNNER": linux_runner_values()}
        # Read bare, LINUX_RUNNER can be the overflow switch's hosted Linux.
        self.assertIn("ubuntu-24.04", disallowed_labels("${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}",
                                                         variables=variables))
        guarded = "${{ contains(vars.LINUX_RUNNER, '32vcpu') && vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}"
        self.assertEqual(disallowed_labels(guarded, variables=variables), {})
        # A value outside the set fails like a literal would.
        self.assertIn("macos-26", disallowed_labels(guarded.replace("'32vcpu'", "'macos'"),
                                                    variables={"LINUX_RUNNER": {"macos-26"}}))

    def test_no_label_at_all_fails(self):
        self.assertEqual(set(disallowed_labels([])), {"[]"})
        self.assertIn("''", disallowed_labels(""))


class Workflows(unittest.TestCase):
    def test_the_current_workflows_pass(self):
        for name, read, allow in SITES:
            with self.subTest(workflow=name):
                runs_on = read((WORKFLOWS / name).read_text(encoding="utf-8"))
                self.assertEqual(disallowed_labels(runs_on, variables=allow), {}, runs_on)

    def test_a_mutated_workflow_with_a_hosted_label_or_a_personal_machine_fails(self):
        for name, read, allow in SITES:
            text = (WORKFLOWS / name).read_text(encoding="utf-8")
            runs_on = read(text)
            self.assertIn("'blacksmith-32vcpu-ubuntu-2404'", runs_on, f"{name}: the mutation needs a target")
            for bad in ("ubuntu-latest", "ubuntu-24.04", "macos-26", PERSONAL_WORKSTATION_LABEL):
                mutated = text.replace(runs_on, runs_on.replace("'blacksmith-32vcpu-ubuntu-2404'", f"'{bad}'"))
                with self.subTest(workflow=name, label=bad):
                    self.assertNotEqual(mutated, text)
                    self.assertIn(bad, disallowed_labels(read(mutated), variables=allow))

    def test_the_lint_runner_fails_without_its_32vcpu_guard(self):
        # LINUX_RUNNER can hold the overflow switch's hosted ubuntu-24.04; only the guard keeps it out.
        text = (WORKFLOWS / "cmux-tui.yml").read_text(encoding="utf-8")
        runs_on = lint_runner(text)
        guard = "contains(vars.LINUX_RUNNER, '32vcpu') && "
        self.assertIn(guard, runs_on)
        mutated = text.replace(runs_on, runs_on.replace(guard, ""))
        self.assertIn("ubuntu-24.04", disallowed_labels(lint_runner(mutated), variables={"LINUX_RUNNER": linux_runner_values()}))


if __name__ == "__main__":
    sys.exit(unittest.main())
