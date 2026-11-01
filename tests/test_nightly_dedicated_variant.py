#!/usr/bin/env python3
"""The dedicated nightly-only mini is opt-in for the two preparation legs."""

import unittest
from pathlib import Path

import yaml

from test_ci_fork_runner_routing import parse_expression
from test_nightly_trusted_routing import evaluate

ROOT = Path(__file__).resolve().parents[1]
DOC = yaml.safe_load((ROOT / ".github/workflows/nightly.yml").read_text())
JOBS = ("prepare-nightly-variant-primary", "prepare-nightly-variant")
LABEL = "glaeda-nightly-only-m4pro"


def context(**changes):
    values = {
        "github.repository": "manaflow-ai/cmux",
        "github.repository_owner": "manaflow-ai",
        "github.ref": "refs/heads/nightly-next",
        "github.run_attempt": 1,
        "needs.decide.outputs.track": "nightly-next",
        "vars.CI_NIGHTLY_ONLY_RUNNER": LABEL,
        "vars.LINUX_RUNNER": "blacksmith-16vcpu-ubuntu-2404",
        "needs.build-nightly-app.outputs.light_attempt": "",
        "needs.build-nightly-app.outputs.light_mini_jobs": "",
    }
    values.update(changes)
    return values


def selected(job, values):
    source = DOC["jobs"][job]["runs-on"].removeprefix("${{").removesuffix("}}")
    return evaluate(parse_expression(source), values)


class DedicatedNightlyVariant(unittest.TestCase):
    def test_only_the_two_preparation_jobs_read_the_reservation(self):
        users = [name for name, job in DOC["jobs"].items()
                 if "CI_NIGHTLY_ONLY_RUNNER" in str(job.get("runs-on", ""))]
        self.assertEqual(users, list(JOBS))

    def test_exact_reservation_wins_without_light_placement(self):
        for job in JOBS:
            with self.subTest(job=job):
                self.assertEqual(selected(job, context()), LABEL)

    def test_unset_or_non_matching_context_keeps_existing_fallbacks(self):
        cases = (
            {"vars.CI_NIGHTLY_ONLY_RUNNER": ""},
            {"vars.CI_NIGHTLY_ONLY_RUNNER": "glaeda-other"},
            {"github.run_attempt": 2},
            {"github.repository": "someone/cmux", "github.repository_owner": "someone"},
            {"needs.decide.outputs.track": "nightly"},
        )
        for job in JOBS:
            for changes in cases:
                with self.subTest(job=job, changes=changes):
                    self.assertNotEqual(selected(job, context(**changes)), LABEL)

    def test_existing_light_placement_still_wins_when_reservation_is_off(self):
        for job in JOBS:
            with self.subTest(job=job):
                values = context(**{
                    "vars.CI_NIGHTLY_ONLY_RUNNER": "",
                    "needs.build-nightly-app.outputs.light_attempt": "1",
                    "needs.build-nightly-app.outputs.light_mini_jobs": f" {job} ",
                    "needs.build-nightly-app.outputs.light_mini_runner": "glaeda-side-std-xcode-26.6",
                })
                self.assertEqual(selected(job, values), "glaeda-side-std-xcode-26.6")


if __name__ == "__main__":
    unittest.main()
