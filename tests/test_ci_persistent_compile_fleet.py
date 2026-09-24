#!/usr/bin/env python3
"""Coverage for scripts/persistent-compile, the persistent Mac fleet operator command."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import io
from pathlib import Path
import sys
import tempfile
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

    def test_retired_is_refused(self) -> None:
        with self.assertRaisesRegex(fleet.Failure, "retired"):
            fleet.up_plan(mini(enrollment={"nodeId": "n", "state": "retired"}), False, None, False)

    def test_a_quarantined_mini_comes_back_through_acceptance(self) -> None:
        # Quarantine stopped the service; `up` leaves quarantine, re-runs acceptance, starts it.
        local = mini(enrollment={"nodeId": "n", "state": "quarantined", "quarantineReason": "disk_pressure"},
                     service_loaded=False)
        steps = fleet.up_plan(local, False, None, False)
        self.assertEqual([s.key for s in steps], ["requalify", "enroll", "start"])
        self.assertIn("disk_pressure", steps[0].text)

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

        def read_local(*_):
            seen["env"] = fleet.os.environ.get(fleet.TOKEN_ENV)
            raise fleet.Failure("stop here")

        with mock.patch.dict(fleet.os.environ, {fleet.TOKEN_ENV: "secret"}), \
             mock.patch.object(fleet, "require_mac"), mock.patch.object(fleet, "read_local", side_effect=read_local), \
             mock.patch.object(fleet, "ci_xcode", return_value=(fleet.XCODE_APP, "test")), mock.patch("sys.stderr"):
            fleet.main(["up"])
        self.assertIsNone(seen["env"])

    def test_up_refuses_an_unreadable_enrollment(self) -> None:
        local = mini(enrollment=None, enrollment_error="enrollment.json: Expecting value")
        with mock.patch.object(fleet, "require_mac"), mock.patch.object(fleet, "read_local", return_value=local), \
             mock.patch.object(fleet, "ci_xcode", return_value=(fleet.XCODE_APP, "test")):
            with self.assertRaisesRegex(fleet.Failure, "cannot be read"):
                fleet.cmd_up(fleet.parser().parse_args(["up", "--node-id", "cmux-mac-002"]))

    def test_glaeda_root_is_accepted_after_the_command(self) -> None:
        self.assertEqual(fleet.parser().parse_args(["drain", "--glaeda-root", "/g"]).glaeda_root, "/g")
        self.assertIsNone(fleet.parser().parse_args(["drain"]).glaeda_root)


def fleet_state(runners=(), variables=None) -> "fleet.GitHubState":
    github = fleet.GitHubState(auth="someone")
    github.group = good_group()
    github.runners = list(runners)
    github.variables = dict(variables or {})
    return github


class RoutingSwitch(unittest.TestCase):
    """The switch is a repository variable; a wrong value routes nothing or routes into an empty fleet."""

    def run_main(self, argv, github=None, stdin_tty=False):
        calls = []
        with mock.patch.object(fleet, "set_variable", side_effect=lambda n, v: calls.append((n, v))), \
             mock.patch.object(fleet, "routing_state", return_value=github), \
             mock.patch.object(fleet.sys.stdin, "isatty", return_value=stdin_tty), \
             mock.patch("builtins.print") as printed, mock.patch("sys.stderr"):
            code = fleet.main(argv)
        return code, calls, " ".join(str(c.args[0]) for c in printed.call_args_list if c.args)

    def test_cohort_strips_hashes_and_joins(self) -> None:
        _, calls, _ = self.run_main(["pilot", "#14144", "claude/persistent-compile-cli"])
        self.assertEqual(calls, [
            (fleet.COHORT_VARIABLE, "14144,claude/persistent-compile-cli"),
            (fleet.SELECTOR_VARIABLE, "pilot"),
        ])

    def test_pilot_refuses_an_empty_or_comma_cohort(self) -> None:
        # "pilot #" used to set an empty cohort: the selector says pilot and nothing routes.
        for argv in (["pilot", "#"], ["pilot", " "], ["pilot", "1,2"], ["pilot", "a b"]):
            with self.subTest(argv=argv):
                code, calls, _ = self.run_main(argv)
                self.assertEqual((code, calls), (1, []))

    def test_pilot_says_what_it_replaces_and_warns_without_a_runner(self) -> None:
        github = fleet_state(runners=[runner(status="offline")], variables={fleet.COHORT_VARIABLE: "14000"})
        _, calls, out = self.run_main(["pilot", "14157"], github)
        self.assertEqual(calls[0], (fleet.COHORT_VARIABLE, "14157"))
        self.assertIn("replacing the pilot cohort 14000", out)
        self.assertIn("no runner is healthy", out)

    def test_all_asks_first_when_no_runner_is_healthy(self) -> None:
        empty = fleet_state(runners=[runner(status="offline")])
        self.assertEqual(self.run_main(["all"], empty)[1], [])
        self.assertEqual(self.run_main(["all", "-y"], empty)[1], [(fleet.SELECTOR_VARIABLE, "all")])
        self.assertEqual(self.run_main(["all"], fleet_state(runners=[runner()]))[1],
                         [(fleet.SELECTOR_VARIABLE, "all")])

    def test_all_still_works_when_the_fleet_cannot_be_read(self) -> None:
        # Setting a variable does not need the org admin scope that listing runners does.
        self.assertEqual(self.run_main(["all"], None)[1], [(fleet.SELECTOR_VARIABLE, "all")])

    def test_doctor_says_turn_it_off_when_routing_into_an_empty_fleet(self) -> None:
        for selector in ("all", "pilot"):
            with self.subTest(selector=selector):
                github = fleet_state(runners=[runner(status="offline")],
                                     variables={fleet.SELECTOR_VARIABLE: selector, fleet.COHORT_VARIABLE: "1"})
                sections, nxt = fleet.doctor_lines(github, None)
                self.assertIn("scripts/persistent-compile off", nxt)
                self.assertIn("no runner is healthy", fleet.render_doctor(sections, nxt))

    def test_doctor_flags_a_pilot_with_an_empty_cohort(self) -> None:
        github = fleet_state(runners=[runner()], variables={fleet.SELECTOR_VARIABLE: "pilot"})
        sections, nxt = fleet.doctor_lines(github, None)
        self.assertIn(fleet.Line(False, "routing: pilot for (empty cohort: nothing routes)"), dict(sections)["GitHub"])
        self.assertIn("scripts/persistent-compile pilot", nxt)


class XcodePin(unittest.TestCase):
    """The mini must compile with the Xcode the hosted job revalidates with, or every product is refused."""

    def test_the_pin_follows_the_variables_ci_reads(self) -> None:
        for workflow, context in ((PRODUCER, "producer"), (ROOT / ".github/workflows/ci-macos.yml", "admission")):
            with self.subTest(context=context):
                self.assertIn(" || ".join(f"vars.{name}" for name in fleet.XCODE_VARIABLES), workflow.read_text())

    def test_first_set_variable_wins(self) -> None:
        pr, macos15 = fleet.XCODE_VARIABLES
        self.assertEqual(fleet.expected_xcode({pr: "/Applications/Xcode_26.4.app/", macos15: "/x"}),
                         ("/Applications/Xcode_26.4.app", pr))
        self.assertEqual(fleet.expected_xcode({pr: " ", macos15: "/x"}), ("/x", macos15))
        self.assertEqual(fleet.expected_xcode({})[0], fleet.XCODE_APP)

    def test_doctor_checks_the_mini_against_the_pin(self) -> None:
        pr = fleet.XCODE_VARIABLES[0]
        local = mini(xcode=False, xcode_app="/Applications/Xcode_26.4.app", xcode_source=pr)
        nxt = fleet.doctor_lines(fleet_state(variables={pr: "/Applications/Xcode_26.4.app"}), local)[1]
        self.assertIn("/Applications/Xcode_26.4.app", nxt)
        self.assertIn(pr, nxt)

    def test_org_variables_are_read_under_repository_ones(self) -> None:
        pages = {
            f"repos/{fleet.REPO}/actions/organization-variables?per_page=100":
                {"variables": [{"name": "A", "value": "org"}, {"name": "B", "value": "org"}]},
            f"repos/{fleet.REPO}/actions/variables?per_page=100": {"variables": [{"name": "A", "value": "repo"}]},
        }
        with mock.patch.object(fleet, "gh_api", side_effect=lambda path: pages[path]):
            self.assertEqual(fleet.read_variables(), {"A": "repo", "B": "org"})

    def test_repository_variables_survive_a_refused_org_read(self) -> None:
        def api(path: str):
            if "organization-variables" in path:
                raise fleet.Failure("HTTP 403")
            return {"variables": [{"name": "A", "value": "repo"}]}

        with mock.patch.object(fleet, "gh_api", side_effect=api):
            self.assertEqual(fleet.read_variables(), {"A": "repo"})

    def test_an_operator_without_org_admin_still_gets_the_pin(self) -> None:
        pr = fleet.XCODE_VARIABLES[0]
        pages = {
            f"repos/{fleet.REPO}": {"id": REPO_ID},
            f"repos/{fleet.REPO}/actions/organization-variables?per_page=100": {"variables": []},
            f"repos/{fleet.REPO}/actions/variables?per_page=100":
                {"variables": [{"name": pr, "value": "/Applications/Xcode_26.4.app"}]},
        }

        def api(path: str, *args, **kwargs):
            if path.startswith(f"orgs/{fleet.ORG}/"):
                raise fleet.Failure("HTTP 403: Must have admin rights")
            return pages[path]

        with mock.patch.object(fleet, "gh", return_value=(True, "operator")), \
                mock.patch.object(fleet, "gh_api", side_effect=api):
            github = fleet.read_github()
        self.assertIsNotNone(github.error)
        self.assertEqual(fleet.expected_xcode(github.variables), ("/Applications/Xcode_26.4.app", pr))


class Quarantine(unittest.TestCase):
    def test_reasons_match_glaeda(self) -> None:
        self.assertEqual(len(fleet.QUARANTINE_REASONS), 8)
        self.assertEqual(fleet.parser().parse_args(["quarantine", "disk_pressure"]).reason, "disk_pressure")
        with mock.patch("sys.stderr"), self.assertRaises(SystemExit):
            fleet.parser().parse_args(["quarantine", "felt_like_it"])

    def test_quarantine_also_stops_the_runner(self) -> None:
        # Quarantining in Glaeda alone leaves GitHub assigning jobs to the mini.
        transitions, stopped = [], []
        with mock.patch.object(fleet, "require_mac"), \
             mock.patch.object(fleet, "read_local", return_value=mini()), \
             mock.patch.object(fleet, "glaeda_transition", side_effect=lambda l, t, r=None: transitions.append((t, r))), \
             mock.patch.object(fleet, "worker_pids", return_value=[]), \
             mock.patch.object(fleet, "stop_service", side_effect=stopped.append), mock.patch("builtins.print"):
            self.assertEqual(fleet.main(["quarantine", "disk_pressure"]), 0)
        self.assertEqual(transitions, [("quarantined", "disk_pressure")])
        self.assertEqual(stopped, [fleet.runner_dir()])

    def test_the_runner_stops_even_when_glaeda_refuses(self) -> None:
        stopped = []
        with mock.patch.object(fleet, "require_mac"), \
             mock.patch.object(fleet, "read_local", return_value=mini()), \
             mock.patch.object(fleet, "glaeda_transition", side_effect=fleet.Failure("unsupported")), \
             mock.patch.object(fleet, "worker_pids", return_value=[]), \
             mock.patch.object(fleet, "stop_service", side_effect=stopped.append), \
             mock.patch("builtins.print"), mock.patch("sys.stderr"):
            self.assertEqual(fleet.main(["quarantine", "hardware_failure"]), 1)
        self.assertEqual(stopped, [fleet.runner_dir()])

    def test_a_refused_quarantine_without_a_runner_does_not_claim_one_stopped(self) -> None:
        with mock.patch.object(fleet, "require_mac"), \
             mock.patch.object(fleet, "read_local", return_value=mini(runner_configured=False)), \
             mock.patch.object(fleet, "glaeda_transition", side_effect=fleet.Failure("unsupported")), \
             mock.patch.object(fleet, "stop_service") as stop:
            with self.assertRaises(fleet.Failure) as caught:
                fleet.stop_taking_jobs(fleet.parser().parse_args(["quarantine", "disk_pressure"]), "quarantined")
        stop.assert_not_called()
        self.assertNotIn("stopped", str(caught.exception))
        self.assertIn("no runner is configured", str(caught.exception))

    def test_drain_waits_on_the_worker_exit_not_a_timer(self) -> None:
        # Two looks: a job is running, then the worker has exited.
        pids = iter([[4242], []])
        registered, waits = [], []

        class Queue:
            def control(self, changes, max_events, timeout=None):
                if changes:
                    registered.extend(event.ident for event in changes)
                else:
                    waits.append(timeout)
                return []

            def close(self):
                pass

        fake_select = mock.Mock(kqueue=Queue, KQ_FILTER_PROC=-5, KQ_EV_ADD=1, KQ_EV_ONESHOT=16, KQ_NOTE_EXIT=1,
                                kevent=lambda ident, **_: mock.Mock(ident=ident))
        with mock.patch.object(fleet, "select", fake_select), \
             mock.patch.object(fleet, "worker_pids", side_effect=lambda _: next(pids)):
            fleet.wait_for_workers(Path("/r"), fleet.time.monotonic() + 60)
        self.assertEqual(registered, [4242])
        self.assertEqual(len(waits), 1)
        self.assertGreater(waits[0], 0)

    def test_a_worker_gone_before_registration_is_skipped(self) -> None:
        pids = iter([[4242], []])

        class Queue:
            def control(self, changes, max_events, timeout=None):
                if changes:
                    raise ProcessLookupError
                raise AssertionError("waited on a process that was already gone")

            def close(self):
                pass

        fake_select = mock.Mock(kqueue=Queue, KQ_FILTER_PROC=-5, KQ_EV_ADD=1, KQ_EV_ONESHOT=16, KQ_NOTE_EXIT=1,
                                kevent=lambda ident, **_: ident)
        with mock.patch.object(fleet, "select", fake_select), \
             mock.patch.object(fleet, "worker_pids", side_effect=lambda _: next(pids)):
            fleet.wait_for_workers(Path("/r"), fleet.time.monotonic() + 60)

    def test_requarantine_says_the_old_reason_is_kept(self) -> None:
        # Glaeda has no quarantined -> quarantined transition, so a new reason is not recorded.
        local = mini(enrollment={"nodeId": "n", "state": "quarantined", "quarantineReason": "disk_pressure"})
        with mock.patch("builtins.print") as printed, mock.patch.object(fleet, "run_checked") as run:
            fleet.glaeda_transition(local, "quarantined", "hardware_failure")
        run.assert_not_called()
        self.assertIn("disk_pressure", " ".join(str(c.args[0]) for c in printed.call_args_list))

    def test_resume_points_a_quarantined_mini_at_up(self) -> None:
        local = mini(enrollment={"nodeId": "n", "state": "quarantined", "quarantineReason": "disk_pressure"})
        with mock.patch.object(fleet, "require_mac"), mock.patch.object(fleet, "read_local", return_value=local), \
             mock.patch.object(fleet, "glaeda_transition") as transition:
            with self.assertRaisesRegex(fleet.Failure, "persistent-compile up"):
                fleet.cmd_resume(fleet.parser().parse_args(["resume"]))
        transition.assert_not_called()


class CandidatePin(unittest.TestCase):
    def test_doctor_warns_two_weeks_before_the_candidate_expires(self) -> None:
        with mock.patch.object(fleet, "candidate_days_left", return_value=10.0):
            sections, nxt = fleet.doctor_lines(fleet_state(runners=[runner()]), None)
        self.assertIn("expires in 10 days", fleet.render_doctor(sections, nxt))
        with mock.patch.object(fleet, "candidate_days_left", return_value=20.0):
            sections, nxt = fleet.doctor_lines(fleet_state(runners=[runner()]), None)
        self.assertNotIn("Glaeda candidate", fleet.render_doctor(sections, nxt))

    def test_a_mini_without_gh_still_hears_about_expiry(self) -> None:
        github = fleet.GitHubState(gh_missing=True, error="gh is not installed here")
        with mock.patch.object(fleet, "candidate_days_left", return_value=-1.0):
            sections, nxt = fleet.doctor_lines(github, mini())
        self.assertIn("expired at", fleet.render_doctor(sections, nxt))

    def test_expiry_is_a_timestamp(self) -> None:
        self.assertGreater(fleet.candidate_days_left(0), 0)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class CandidateWithoutGh(unittest.TestCase):
    """A mini has no gh: a staged archive is enough, and a missing one is caught before any long step."""

    def test_a_staged_generation_or_the_pinned_archive_is_enough(self) -> None:
        self.assertIsNone(fleet.candidate_blocker(True, None, False, -5.0))
        # Even after the artifact expired: these are still the reviewed bytes.
        self.assertIsNone(fleet.candidate_blocker(False, fleet.CANDIDATE_SHA256, False, -5.0))

    def test_gh_downloads_it_while_the_artifact_lives(self) -> None:
        self.assertIsNone(fleet.candidate_blocker(False, None, True, 10.0))

    def test_no_gh_and_nothing_staged_says_where_to_put_it(self) -> None:
        text = fleet.candidate_blocker(False, None, False, 10.0)
        for part in (str(fleet.candidate_archive()), fleet.CANDIDATE_RUN, fleet.CANDIDATE_ARTIFACT,
                     fleet.CANDIDATE_SHA256, "gh run download", "scp"):
            self.assertIn(part, text)

    def test_a_wrong_archive_is_named(self) -> None:
        text = fleet.candidate_blocker(False, "0" * 64, True, 10.0)
        self.assertIn("0" * 64, text)
        self.assertIn(str(fleet.candidate_archive()), text)

    def test_up_refuses_cleanly_once_the_artifact_expired(self) -> None:
        self.assertIn("expired", fleet.candidate_blocker(False, None, True, -0.5))

    def test_registration_without_gh_or_token_is_caught_first(self) -> None:
        steps = [fleet.UpStep("register", ""), fleet.UpStep("start", "")]
        self.assertIn("persistent-compile token", fleet.up_blockers(steps, False, False)[0])
        self.assertEqual(fleet.up_blockers(steps, True, False), [])

    def up_on_fresh_mini(self, archive_bytes: bytes | None, gh: bool = False) -> tuple[str | None, mock.Mock]:
        local = mini(glaeda=None, enrollment=None, acceptance=False, runner_configured=False,
                     runner_name=None, service_loaded=None)
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "glaeda.tar.gz"
            if archive_bytes is not None:
                archive.write_bytes(archive_bytes)
            with mock.patch.object(fleet, "require_mac"), mock.patch.object(fleet, "read_local", return_value=local), \
                 mock.patch.object(fleet, "ci_xcode", return_value=(fleet.XCODE_APP, "test")), \
                 mock.patch.object(fleet, "gh_installed", return_value=gh), \
                 mock.patch.object(fleet, "candidate_staged", return_value=False), \
                 mock.patch.object(fleet, "candidate_archive", return_value=archive), \
                 mock.patch.object(fleet, "candidate_days_left", return_value=20.0), \
                 mock.patch.dict(fleet.os.environ, {fleet.TOKEN_ENV: "t"}), \
                 mock.patch.object(fleet, "confirm", return_value=False) as confirm, mock.patch("sys.stdout"):
                try:
                    fleet.cmd_up(fleet.parser().parse_args(["up", "--node-id", "cmux-mac-002"]))
                except fleet.Failure as error:
                    return str(error), confirm
        return None, confirm

    def test_up_without_gh_stops_before_the_clone(self) -> None:
        error, confirm = self.up_on_fresh_mini(None)
        self.assertIn("gh run download", error)
        confirm.assert_not_called()

    def test_up_uses_a_staged_archive_with_the_pinned_digest(self) -> None:
        with mock.patch.object(fleet, "CANDIDATE_SHA256", digest(b"reviewed")):
            error, confirm = self.up_on_fresh_mini(b"reviewed")
        self.assertIsNone(error)
        steps = confirm.call_args.args[1]
        self.assertFalse(any("download" in step for step in steps))

    def test_up_rejects_a_staged_archive_with_another_digest(self) -> None:
        error, confirm = self.up_on_fresh_mini(b"truncated", gh=True)
        self.assertIn(digest(b"truncated"), error)
        confirm.assert_not_called()


class NodeIdFirst(unittest.TestCase):
    def test_a_missing_node_id_stops_before_the_setup_dry_run(self) -> None:
        local = mini(enrollment=None, acceptance=False)
        with mock.patch.object(fleet, "require_mac"), mock.patch.object(fleet, "read_local", return_value=local), \
             mock.patch.object(fleet, "ci_xcode", return_value=(fleet.XCODE_APP, "test")), \
             mock.patch.object(fleet, "mini_setup_receipt") as setup:
            with self.assertRaisesRegex(fleet.Failure, "--node-id"):
                fleet.cmd_up(fleet.parser().parse_args(["up"]))
        setup.assert_not_called()

    def test_another_node_id_than_the_enrolled_one_is_refused(self) -> None:
        with self.assertRaisesRegex(fleet.Failure, "already enrolled as cmux-mac-001"):
            fleet.up_plan(mini(), False, "cmux-mac-009", False)
        self.assertEqual(fleet.up_plan(mini(), False, "cmux-mac-001", False), [])


class NoGhOnTheMini(unittest.TestCase):
    def test_doctor_skips_github_quietly(self) -> None:
        with mock.patch.object(fleet, "gh_installed", return_value=False):
            github = fleet.read_github()
        self.assertTrue(github.gh_missing)
        sections, nxt = fleet.doctor_lines(github, mini(enrollment=None))
        text = fleet.render_doctor(sections, nxt)
        self.assertNotIn("gh auth login", text)
        self.assertNotIn("-- gh", text)
        self.assertIn("--node-id", nxt)

    def test_up_names_the_pin_it_assumed(self) -> None:
        with mock.patch.object(fleet, "gh_installed", return_value=False), \
             mock.patch("sys.stderr", new_callable=io.StringIO) as err:
            app, source = fleet.ci_xcode()
        self.assertEqual(app, fleet.XCODE_APP)
        self.assertIn("no gh", source)
        self.assertEqual(err.getvalue().count("\n"), 1)
        self.assertIn(fleet.XCODE_APP, err.getvalue())
        self.assertNotIn("could not read", err.getvalue())


class Heartbeat(unittest.TestCase):
    """Acceptance is a silent 13-minute build; `up` says it is still alive."""

    SILENT_THEN = "import sys, time; time.sleep(0.35); sys.stdout.write({!r}); sys.stdout.flush()"

    def test_a_silent_child_gets_elapsed_lines(self) -> None:
        with mock.patch("sys.stdout", new_callable=io.StringIO) as out, \
             mock.patch("sys.stderr", new_callable=io.StringIO):
            result = fleet.run_with_heartbeat([sys.executable, "-c", self.SILENT_THEN.format("done\n")],
                                              ROOT, label="acceptance", interval=0.1)
        self.assertEqual(result.returncode, 0)
        self.assertIn("acceptance still running", out.getvalue())
        self.assertTrue(out.getvalue().endswith("done\n"))

    def test_captured_stdout_stays_exactly_the_childs(self) -> None:
        receipt = '{"ready": true}'
        with mock.patch("sys.stdout", new_callable=io.StringIO) as out, \
             mock.patch("sys.stderr", new_callable=io.StringIO) as err:
            result = fleet.run_with_heartbeat([sys.executable, "-c", self.SILENT_THEN.format(receipt)],
                                              ROOT, capture=True, interval=0.1)
        self.assertEqual(result.stdout, receipt)
        self.assertEqual(out.getvalue(), "")
        self.assertIn("still running", err.getvalue())

    def test_a_chatty_child_gets_no_heartbeat(self) -> None:
        code = "import sys, time\nfor _ in range(4):\n    print('x', flush=True); time.sleep(0.05)"
        with mock.patch("sys.stdout", new_callable=io.StringIO) as out:
            fleet.run_with_heartbeat([sys.executable, "-c", code], ROOT, interval=0.5)
        self.assertEqual(out.getvalue(), "x\nx\nx\nx\n")

    def test_the_exit_code_is_kept(self) -> None:
        with mock.patch("sys.stdout", new_callable=io.StringIO):
            self.assertEqual(fleet.run_with_heartbeat([sys.executable, "-c", "raise SystemExit(3)"], ROOT).returncode, 3)


if __name__ == "__main__":
    unittest.main()
