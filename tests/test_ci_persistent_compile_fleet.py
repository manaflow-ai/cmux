#!/usr/bin/env python3
"""Coverage for scripts/persistent-compile, the persistent Mac fleet operator command."""

from __future__ import annotations

import argparse
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest import mock


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

    def test_glaeda_candidate_pin_is_exact(self) -> None:
        # A reviewed candidate is named by its run, full source commit and archive digest together.
        self.assertRegex(fleet.CANDIDATE_RUN, r"^[0-9]+$")
        self.assertRegex(fleet.CANDIDATE_SOURCE, r"^[0-9a-f]{40}$")
        self.assertRegex(fleet.CANDIDATE_SHA256, r"^[0-9a-f]{64}$")
        self.assertIn(fleet.CANDIDATE_SOURCE, fleet.candidate_archive().name)

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
        self.assertEqual(self.next_step(self.github(group=False)), "scripts/persistent-compile group   (org admin)")

    def test_up_from_off_the_mini(self) -> None:
        self.assertIn("on the mini: scripts/persistent-compile up --node-id", self.next_step(self.github()))

    def test_every_unfinished_mini_state_points_at_up(self) -> None:
        fresh = enrolled("eligible")
        fresh.enrollment = None
        self.assertEqual(self.next_step(self.github(), fresh), "scripts/persistent-compile up --node-id cmux-mac-NNN")
        self.assertEqual(self.next_step(self.github(), enrolled("enrolling")), "scripts/persistent-compile up")
        self.assertEqual(self.next_step(self.github(), enrolled("eligible")), "scripts/persistent-compile up")

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


def mini(**changes) -> "fleet.LocalState":
    local = enrolled("eligible")
    local.runner_configured = True
    local.runner_name = "cmux-mac-001-persistent-compile"
    local.service_loaded = True
    for key, value in changes.items():
        setattr(local, key, value)
    return local


class UpPlan(unittest.TestCase):
    """`up` is one re-runnable command, so each state must map to exactly the remaining steps."""

    def keys(self, local, setup=False, node_id=None, token=False) -> list[str]:
        return [step.key for step in fleet.up_plan(local, setup, node_id, token)]

    def test_a_fresh_mini_does_everything(self) -> None:
        local = mini(glaeda=None, enrollment=None, acceptance=False, runner_configured=False,
                     runner_name=None, service_loaded=None)
        self.assertEqual(self.keys(local, setup=True, node_id="cmux-mac-002"),
                         ["clone", "setup", "enroll", "register", "start"])

    def test_a_running_mini_has_nothing_to_do(self) -> None:
        self.assertEqual(self.keys(mini()), [])

    def test_a_first_enrollment_needs_a_node_id(self) -> None:
        with self.assertRaisesRegex(fleet.Failure, "--node-id"):
            fleet.up_plan(mini(enrollment=None), False, None, False)

    def test_resumes_after_a_rejected_acceptance(self) -> None:
        local = mini(enrollment={"nodeId": "cmux-mac-001", "state": "enrolling"}, acceptance=False,
                     runner_configured=False, service_loaded=None)
        self.assertEqual(self.keys(local), ["enroll", "register", "start"])

    def test_a_stopped_service_is_only_started(self) -> None:
        self.assertEqual(self.keys(mini(service_loaded=False)), ["start"])

    def test_quarantined_and_retired_are_refused(self) -> None:
        for state in ("quarantined", "retired"):
            with self.subTest(state=state), self.assertRaisesRegex(fleet.Failure, state):
                fleet.up_plan(mini(enrollment={"nodeId": "n", "state": state}), False, None, False)

    def test_the_candidate_is_downloaded_only_when_enrollment_needs_it(self) -> None:
        fresh = mini(enrollment=None, acceptance=False, runner_configured=False, runner_name=None, service_loaded=None)
        self.assertEqual([s.key for s in fleet.up_plan(fresh, False, "cmux-mac-002", False, have_candidate=False)],
                         ["download", "enroll", "register", "start"])
        self.assertEqual([s.key for s in fleet.up_plan(mini(), False, None, False, have_candidate=False)], [])

    def test_an_old_glaeda_checkout_is_fast_forwarded(self) -> None:
        self.assertEqual([s.key for s in fleet.up_plan(mini(), True, None, False, glaeda_current=False)],
                         ["update", "setup"])

    def test_the_plan_names_the_token_source(self) -> None:
        local = mini(runner_configured=False, service_loaded=None)
        texts = [s.text for s in fleet.up_plan(local, False, None, True)]
        self.assertTrue(any(fleet.TOKEN_ENV in text for text in texts))


class MiniSetupReceipt(unittest.TestCase):
    def test_only_unchanged_and_kept_actions_are_settled(self) -> None:
        self.assertFalse(fleet.setup_pending({"actions": [{"state": "unchanged"}, {"state": "kept"}]}))
        self.assertTrue(fleet.setup_pending({"actions": [{"state": "unchanged"}, {"state": "create"}]}))

    def test_human_steps_leave_out_what_up_does_itself(self) -> None:
        receipt = {"operatorSteps": [
            {"needs": "sudo", "command": "sudo pmset -c sleep 0", "why": "unattended builds"},
            {"needs": "operator", "command": "scripts/glaeda-mini-enroll --apply", "why": "enroll"},
            {"needs": "org admin", "command": "scripts/persistent-compile register --apply", "why": "runner"},
        ]}
        self.assertEqual(fleet.human_steps(receipt), ["[sudo] sudo pmset -c sleep 0   (unattended builds)"])


class Confirm(unittest.TestCase):
    def test_yes_skips_the_question(self) -> None:
        with mock.patch("builtins.print"):
            self.assertTrue(fleet.confirm(argparse.Namespace(yes=True), ["x"]))

    def test_non_interactive_without_yes_changes_nothing(self) -> None:
        with mock.patch.object(fleet.sys.stdin, "isatty", return_value=False), mock.patch("builtins.print"):
            self.assertFalse(fleet.confirm(argparse.Namespace(yes=False), ["x"]))

    def test_yes_is_accepted_before_or_after_the_command(self) -> None:
        for argv in (["-y", "up"], ["up", "-y"], ["group", "--yes"]):
            with self.subTest(argv=argv):
                self.assertTrue(fleet.parser().parse_args(argv).yes)
        self.assertFalse(fleet.parser().parse_args(["up"]).yes)

    def test_only_y_is_yes(self) -> None:
        for answer, expected in (("y", True), ("YES", True), ("", False), ("n", False)):
            with self.subTest(answer=answer), \
                 mock.patch.object(fleet.sys.stdin, "isatty", return_value=True), \
                 mock.patch("builtins.input", return_value=answer), mock.patch("builtins.print"):
                self.assertEqual(fleet.confirm(argparse.Namespace(yes=False), ["x"]), expected)


class DayTwo(unittest.TestCase):
    """Drain, resume and re-runs, found in review of the first version."""

    def test_a_drained_mini_is_not_reported_as_routing(self) -> None:
        local = mini(enrollment={"nodeId": "cmux-mac-001", "state": "draining"}, service_loaded=False)
        github = fleet.GitHubState(auth="someone")
        github.group = good_group()
        github.runners = [runner(status="offline")]
        github.variables = {fleet.SELECTOR_VARIABLE: "pilot", fleet.COHORT_VARIABLE: "1"}
        self.assertIn("resume", fleet.doctor_lines(github, local)[1])

    def test_selector_case_is_not_normalised(self) -> None:
        # The router compares the value exactly; "Pilot" routes nothing.
        github = fleet.GitHubState(auth="someone")
        github.group = good_group()
        github.runners = [runner()]
        github.variables = {fleet.SELECTOR_VARIABLE: "Pilot"}
        sections, nxt = fleet.doctor_lines(github, None)
        self.assertIn("routing: off", fleet.render_doctor(sections, nxt))

    def test_runner_config_with_a_byte_order_mark_is_read(self) -> None:
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / ".runner"
            path.write_bytes(b"\xef\xbb\xbf" + b'{"agentName": "cmux-mac-001-persistent-compile"}')
            self.assertEqual(fleet.read_json(path)[0], {"agentName": "cmux-mac-001-persistent-compile"})

    def test_stop_disables_so_a_reboot_does_not_restart_the_runner(self) -> None:
        calls = []
        loaded = iter([True, False])
        with mock.patch.object(fleet, "service_label", return_value="actions.runner.x"), \
             mock.patch.object(fleet, "service_loaded", side_effect=lambda _: next(loaded)), \
             mock.patch.object(fleet, "launchctl", side_effect=lambda *a: calls.append(a)):
            fleet.stop_service(Path("/r"))
        uid = fleet.os.getuid()
        self.assertEqual(calls, [("disable", f"gui/{uid}/actions.runner.x"), ("bootout", f"gui/{uid}/actions.runner.x")])

    def test_stop_and_start_are_safe_to_repeat(self) -> None:
        calls = []
        with mock.patch.object(fleet, "service_plist", return_value=Path("/p/actions.runner.x.plist")), \
             mock.patch.object(fleet, "service_loaded", return_value=False), \
             mock.patch.object(fleet, "launchctl", side_effect=lambda *a: calls.append(a)):
            fleet.stop_service(Path("/r"))  # already stopped: no bootout
        self.assertEqual([c[0] for c in calls], ["disable"])
        calls.clear()
        with mock.patch.object(fleet, "service_plist", return_value=Path("/p/actions.runner.x.plist")), \
             mock.patch.object(fleet, "service_loaded", return_value=True), \
             mock.patch.object(fleet, "launchctl", side_effect=lambda *a: calls.append(a)):
            fleet.start_service(Path("/r"))  # already loaded: no bootstrap
        self.assertEqual([c[0] for c in calls], ["enable"])

    def test_up_takes_the_token_out_of_the_environment_first(self) -> None:
        seen = {}

        def read_local(_):
            seen["env"] = fleet.os.environ.get(fleet.TOKEN_ENV)
            raise fleet.Failure("stop here")

        with mock.patch.dict(fleet.os.environ, {fleet.TOKEN_ENV: "secret"}), \
             mock.patch.object(fleet, "require_mac"), mock.patch.object(fleet, "read_local", side_effect=read_local), \
             mock.patch("sys.stderr"):
            fleet.main(["up"])
        self.assertIsNone(seen["env"])

    def test_up_refuses_an_unreadable_enrollment(self) -> None:
        local = mini(enrollment=None, enrollment_error="enrollment.json: Expecting value")
        with mock.patch.object(fleet, "require_mac"), mock.patch.object(fleet, "read_local", return_value=local):
            with self.assertRaisesRegex(fleet.Failure, "cannot be read"):
                fleet.cmd_up(fleet.parser().parse_args(["up", "--node-id", "cmux-mac-002"]))

    def test_glaeda_root_is_accepted_after_the_command(self) -> None:
        self.assertEqual(fleet.parser().parse_args(["drain", "--glaeda-root", "/g"]).glaeda_root, "/g")
        self.assertIsNone(fleet.parser().parse_args(["drain"]).glaeda_root)


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
