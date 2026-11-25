#!/usr/bin/env python3
"""The queue janitor watchdog follows the sweep's route.

ci-queue-janitor.yml's sweep runs on the one-job repair VM cmux-gcp-repair-jit-x64, and on cmux-fleet-linux-x64 when the
repository variable CI_QUEUE_JANITOR_ON_FLEET is 1 (cmux#47877). The watchdog
(ci-queue-janitor-watchdog.yml) alerts when no sweep has published a snapshot: it must name the label
the sweep actually waits on, run off that label (a watchdog on the label it watches waits with the
sweep), name no Blacksmith label, and tell the reader which variable moves the sweep.
"""

from __future__ import annotations

import importlib.util
import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
JANITOR = WORKFLOWS / "ci-queue-janitor.yml"
WATCHDOG = WORKFLOWS / "ci-queue-janitor-watchdog.yml"
VARIABLE = "CI_QUEUE_JANITOR_ON_FLEET"


def _routing():
    spec = importlib.util.spec_from_file_location("fork_routing", ROOT / "tests" / "test_ci_fork_runner_routing.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ROUTING = _routing()


def evaluate(value: str, variables: dict[str, str]) -> str:
    """What a workflow value yields in manaflow-ai with these repository variables (a plain string as is)."""
    expression = re.fullmatch(r"\$\{\{(.*)\}\}", str(value).strip(), re.DOTALL)
    if expression is None:
        return str(value)
    context = {"github.repository_owner": "manaflow-ai", f"vars.{VARIABLE}": ""}
    context.update({f"vars.{name}": text for name, text in variables.items()})
    return str(ROUTING.evaluate_runs_on(ROUTING.parse_expression(expression.group(1)), context))


def sweep_runs_on() -> str:
    return yaml.safe_load(JANITOR.read_text(encoding="utf-8"))["jobs"]["sweep"]["runs-on"]


def watch_job() -> dict:
    return yaml.safe_load(WATCHDOG.read_text(encoding="utf-8"))["jobs"]["watch"]


SETTINGS = ({}, {VARIABLE: "1"}, {VARIABLE: "0"}, {VARIABLE: "true"})


class WatchdogFollowsTheSweep(unittest.TestCase):
    def test_it_watches_the_label_the_sweep_runs_on(self) -> None:
        for variables in SETTINGS:
            with self.subTest(variables=variables):
                self.assertEqual(evaluate(watch_job()["env"]["LABEL"], variables), evaluate(sweep_runs_on(), variables))
        # Not vacuous: the variable moves the sweep between two labels.
        self.assertEqual(evaluate(sweep_runs_on(), {}), "cmux-gcp-repair-jit-x64")
        self.assertEqual(evaluate(sweep_runs_on(), {VARIABLE: "1"}), "cmux-fleet-linux-x64")

    def test_it_runs_off_the_label_it_watches_and_off_blacksmith(self) -> None:
        runs_on = watch_job()["runs-on"]
        self.assertNotIn("blacksmith", runs_on.lower())
        for variables in SETTINGS:
            with self.subTest(variables=variables):
                self.assertNotEqual(evaluate(runs_on, variables), evaluate(watch_job()["env"]["LABEL"], variables))

    def test_its_runs_on_holds_no_variable_a_reused_machine_could_take(self) -> None:
        self.assertEqual(ROUTING.runner_label_errors(watch_job()["runs-on"]), [])

    def test_the_recovery_text_names_the_variable_that_moves_the_sweep(self) -> None:
        text = WATCHDOG.read_text(encoding="utf-8")
        self.assertIn(VARIABLE, text)
        # CI_REPAIR_SKIP_FLEET no longer moves the sweep (docs/ci-runners.md), so the alert must not offer it.
        self.assertNotIn("CI_REPAIR_SKIP_FLEET", text)
        self.assertNotIn("LABEL: cmux-fleet-linux-x64\n", text)


if __name__ == "__main__":
    unittest.main()
