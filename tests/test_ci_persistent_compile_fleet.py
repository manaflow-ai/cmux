#!/usr/bin/env python3
"""Coverage for scripts/persistent-compile, the persistent Mac fleet operator command."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/persistent_compile_fleet.py"
PRODUCER = ROOT / ".github/workflows/persistent-macos-compile.yml"
ROUTE = ROOT / "scripts/ci/persistent_mac_route.py"

spec = importlib.util.spec_from_file_location("persistent_compile_fleet", SCRIPT)
fleet = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = fleet  # dataclasses resolve annotations through sys.modules
spec.loader.exec_module(fleet)

REPO_ID = 1000


def good_group() -> dict:
    return {
        "id": 7,
        "name": fleet.GROUP,
        "visibility": "selected",
        "allows_public_repositories": True,
        "restricted_to_workflows": True,
        "selected_workflows": [fleet.WORKFLOW_REF],
    }


def runner(name: str = "cmux-mac-001-persistent-compile", labels=None, status="online", busy=False) -> dict:
    return {
        "name": name,
        "status": status,
        "busy": busy,
        "labels": [{"name": label} for label in (labels or fleet.LABELS)],
    }


def enrolled(state: str) -> "fleet.LocalState":
    return fleet.LocalState(
        is_mac=True,
        xcode=True,
        enrollment={"nodeId": "cmux-mac-001", "state": state},
        enrollment_error=None,
        acceptance=state == "eligible",
        runner_configured=False,
        runner_name=None,
        service_loaded=None,
        glaeda=Path("/tmp/glaeda"),
    )


class MatchesTheProducer(unittest.TestCase):
    """The group and labels are compared literally by GitHub; drift strands every job."""

    def test_group_and_labels_are_the_producer_runs_on(self) -> None:
        text = PRODUCER.read_text()
        self.assertIn(f"      group: {fleet.GROUP}\n", text)
        self.assertIn(f"      labels: [{', '.join(fleet.LABELS)}]\n", text)

    def test_workflow_ref_names_the_producer_on_main(self) -> None:
        path = fleet.WORKFLOW_REF.split("@")[0].removeprefix(fleet.REPO + "/")
        self.assertTrue((ROOT / path).samefile(PRODUCER))
        self.assertTrue(fleet.WORKFLOW_REF.endswith("@refs/heads/main"))

    def test_selector_values_are_ones_the_router_accepts(self) -> None:
        text = ROUTE.read_text()
        for value in ("pilot", "all", "off"):
            self.assertIn(f'"{value}"', text)

    def test_runner_pin_is_a_sha256(self) -> None:
        self.assertRegex(fleet.RUNNER_SHA256, r"^[0-9a-f]{64}$")
        self.assertIn(fleet.RUNNER_VERSION, fleet.RUNNER_URL)
        self.assertIn("osx-arm64", fleet.RUNNER_URL)


class GroupPolicy(unittest.TestCase):
    def test_missing_group_is_created(self) -> None:
        self.assertEqual(fleet.group_changes(None, REPO_ID, []), ["create the group"])

    def test_correct_group_needs_nothing(self) -> None:
        self.assertEqual(fleet.group_changes(good_group(), REPO_ID, [REPO_ID]), [])

    def test_every_weakening_is_reported(self) -> None:
        cases = {
            "visibility": ("all", "visibility"),
            "allows_public_repositories": (False, "public"),
            "restricted_to_workflows": (False, "restrict"),
            "selected_workflows": ([fleet.WORKFLOW_REF, f"{fleet.REPO}/.github/workflows/ci.yml@refs/heads/main"],
                                   "selected workflows"),
        }
        for key, (value, needle) in cases.items():
            with self.subTest(key=key):
                group = good_group() | {key: value}
                changes = fleet.group_changes(group, REPO_ID, [REPO_ID])
                self.assertEqual(len(changes), 1, changes)
                self.assertIn(needle, changes[0])

    def test_a_workflow_on_another_branch_is_not_enough(self) -> None:
        group = good_group() | {"selected_workflows": [fleet.WORKFLOW_REF.replace("heads/main", "heads/dev")]}
        self.assertTrue(fleet.group_changes(group, REPO_ID, [REPO_ID]))

    def test_cmux_must_be_granted(self) -> None:
        self.assertEqual(fleet.group_changes(good_group(), REPO_ID, [5]), [f"grant {fleet.REPO} access"])

    def test_other_repositories_are_a_warning(self) -> None:
        self.assertEqual(fleet.group_warnings(REPO_ID, [REPO_ID]), [])
        self.assertTrue(fleet.group_warnings(REPO_ID, [REPO_ID, 5]))


class RunnerHealth(unittest.TestCase):
    def test_exact_labels_online_is_healthy(self) -> None:
        self.assertEqual(fleet.runner_problems(runner()), [])

    def test_extra_or_missing_label_is_a_problem(self) -> None:
        self.assertTrue(fleet.runner_problems(runner(labels=[*fleet.LABELS, "macfleet"])))
        self.assertTrue(fleet.runner_problems(runner(labels=fleet.LABELS[:3])))

    def test_offline_is_a_problem(self) -> None:
        self.assertEqual(fleet.runner_problems(runner(status="offline")), ["status is offline"])


class DoctorNextStep(unittest.TestCase):
    """Whoever runs it gets one command to run next, in the order the rollout needs."""

    def github(self, group=True, runners=(), variables=None) -> "fleet.GitHubState":
        state = fleet.GitHubState(auth="someone")
        state.group = good_group() if group else None
        state.group_changes = [] if group else ["create the group"]
        state.runners = list(runners)
        state.variables = variables or {}
        return state

    def next_step(self, github, local=None) -> str | None:
        return fleet.doctor_lines(github, local)[1]

    def test_signed_out(self) -> None:
        self.assertIn("gh auth login", self.next_step(fleet.GitHubState(error="gh is not signed in")))

    def test_group_first(self) -> None:
        self.assertIn("group --apply", self.next_step(self.github(group=False)))

    def test_register_from_off_the_mini(self) -> None:
        self.assertIn("register --apply", self.next_step(self.github()))

    def test_enroll_before_register_on_the_mini(self) -> None:
        local = enrolled("eligible")
        local.enrollment = None
        self.assertIn("glaeda-mini-enroll", self.next_step(self.github(), local))

    def test_finish_acceptance(self) -> None:
        self.assertIn("glaeda-mini-enroll", self.next_step(self.github(), enrolled("enrolling")))

    def test_register_once_eligible(self) -> None:
        self.assertIn("register --apply", self.next_step(self.github(), enrolled("eligible")))

    def test_resume_a_stopped_service(self) -> None:
        local = enrolled("eligible")
        local.runner_configured = True
        local.service_loaded = False
        self.assertEqual(self.next_step(self.github(runners=[runner(status="offline")]), local),
                         "scripts/persistent-compile resume")

    def test_pilot_once_a_runner_is_healthy(self) -> None:
        self.assertIn("pilot", self.next_step(self.github(runners=[runner()])))

    def test_nothing_left_while_routing(self) -> None:
        github = self.github(runners=[runner()], variables={fleet.SELECTOR_VARIABLE: "pilot",
                                                            fleet.COHORT_VARIABLE: "14144"})
        sections, nxt = fleet.doctor_lines(github, None)
        self.assertIsNone(nxt)
        self.assertIn("pilot for 14144", fleet.render_doctor(sections, nxt))

    def test_no_pilot_suggestion_without_a_healthy_runner(self) -> None:
        self.assertNotIn("pilot", self.next_step(self.github(runners=[runner(status="offline")])) or "")


class PilotCohort(unittest.TestCase):
    def test_cohort_strips_hashes_and_joins(self) -> None:
        calls = []
        original = fleet.set_variable
        fleet.set_variable = lambda name, value: calls.append((name, value))
        try:
            fleet.main(["pilot", "#14144", "claude/persistent-compile-cli"])
        finally:
            fleet.set_variable = original
        self.assertEqual(calls, [
            (fleet.COHORT_VARIABLE, "14144,claude/persistent-compile-cli"),
            (fleet.SELECTOR_VARIABLE, "pilot"),
        ])


if __name__ == "__main__":
    unittest.main()
