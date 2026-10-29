#!/usr/bin/env python3
"""The cloud overflow switch: one Blacksmith probe decides whether overflow goes to Blacksmith."""

from __future__ import annotations

import datetime as dt
import json
import re
import sys
import tempfile
import unittest

import yaml
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import check_repo_variables as check  # noqa: E402
import cloud_overflow_switch as switch  # noqa: E402
import signing_runner_variables as signing  # noqa: E402

WORKFLOW = ROOT / ".github" / "workflows" / "ci-cloud-overflow-probe.yml"
PIN = "/Applications/Xcode_26.6.app"
NOW = dt.datetime(2026, 9, 29, 12, 0, tzinfo=dt.timezone.utc)
LANE_SWITCHES = ("CI_PR_POOL_OWNED", "CI_E2E_OWNED_UI", "CI_IOS_OWNED", "CI_OWNED_POOL_RESCUE",
                 "CI_PR_POOL_OVERFLOW", "CI_PR_POOL_ORDER", "CI_OWNED_POOL_SLOTS")


def ago(minutes: float) -> str:
    return switch.iso(NOW - dt.timedelta(minutes=minutes))


def probe_job(minutes: float, **extra: object) -> dict:
    return {"name": switch.probe_job_name(switch.PROBE_LABELS[0]), "status": "queued", "created_at": ago(minutes),
            # GitHub stamps started_at on a queued job too; only a runner means it started.
            "started_at": ago(minutes), "runner_name": None, "labels": ["blacksmith-4vcpu-ubuntu-2404"], **extra}


class Clock:
    def __init__(self) -> None:
        self.moment = NOW

    def now(self) -> dt.datetime:
        return self.moment

    def sleep(self, seconds: float) -> None:
        self.moment += dt.timedelta(seconds=seconds)


class FakeActions:
    """The GITHUB_TOKEN side: this run's jobs, the in-flight runs, cancels and re-runs."""

    def __init__(self, probe: dict | None, runs: list[dict] | None = None,
                 jobs: dict[int, list[dict]] | None = None) -> None:
        self.probe = probe
        self.in_flight = runs or []
        self.run_jobs = jobs or {}
        self.calls: list[tuple[str, int]] = []
        self.status: dict[int, str] = {}

    def jobs(self, run_id: int, attempt: int | None = None) -> list[dict]:
        if run_id == 1:
            # The same state for every probe in the set (and a drill's label); tests of one
            # probe starting while another stalls pass a list.
            if isinstance(self.probe, list):
                return self.probe
            labels = (*switch.PROBE_LABELS, DRILL)
            return [{**self.probe, "name": switch.probe_job_name(label)} for label in labels] if self.probe else []
        return self.run_jobs.get(run_id, [])

    def runs(self, status: str) -> list[dict]:
        return [run for run in self.in_flight if run.get("status") == status]

    def run(self, run_id: int) -> dict:
        return {"id": run_id, "status": self.status.get(run_id, "in_progress")}

    def force_cancel(self, run_id: int) -> None:
        self.calls.append(("force-cancel", run_id))
        self.status[run_id] = "completed"

    def rerun(self, run_id: int) -> None:
        self.calls.append(("rerun", run_id))


class FakeSwitch:
    """The App token side: variable writes, in order."""

    def __init__(self) -> None:
        self.writes: list[tuple[str, str | None]] = []
        self.health: list[dict] = []  # CI_CLOUD_LABEL_HEALTH, kept apart from the routing writes

    def set_variable(self, name: str, value: str) -> None:
        if name == switch.HEALTH_VARIABLE:
            self.health.append(json.loads(value))
            return
        self.writes.append((name, value))

    def delete_variable(self, name: str) -> None:
        self.writes.append((name, None))


DRILL = "blacksmith-0vcpu-no-such-label"

BLACKSMITH_STEADY = {
    "VAR_LINUX_RUNNER": "blacksmith-4vcpu-ubuntu-2404",
    "VAR_MACOS_RUNNER_PR": "blacksmith-6vcpu-macos-26",
    "VAR_CMUX_CI_XCODE_APP_PR": PIN,
}


def run_main(env: dict[str, str], actions: FakeActions, writer: FakeSwitch | None, *,
             argv: list[str] | None = None) -> tuple[int, str, str]:
    with tempfile.TemporaryDirectory() as tmp:
        out, summary = Path(tmp) / "out", Path(tmp) / "summary"
        full = {"GH_REPO": "manaflow-ai/cmux", "GITHUB_RUN_ID": "1", "GITHUB_RUN_ATTEMPT": "1",
                "GITHUB_OUTPUT": str(out), "GITHUB_STEP_SUMMARY": str(summary), **env}
        clock = Clock()
        code = switch.main(argv or [], full, api=actions, switch=writer, now=clock.now, sleep=clock.sleep)
        return code, out.read_text() if out.exists() else "", summary.read_text() if summary.exists() else ""


class FailoverTests(unittest.TestCase):
    def test_failover_is_derived_from_the_lane_pin(self) -> None:
        values, problems = switch.failover_values(PIN, "")
        self.assertEqual(problems, [])
        # Another Blacksmith Linux size, never GitHub-hosted Ubuntu (Leo, 2026-10-27).
        self.assertEqual(values["LINUX_RUNNER"], "blacksmith-16vcpu-ubuntu-2404")
        # The merge-gating checks' readers accept only the 2 and 4 vCPU Blacksmith labels.
        self.assertEqual(values["CI_TRUSTED_RUNNER"], "blacksmith-2vcpu-ubuntu-2404")
        for name in switch.STD_VARIABLES:
            self.assertEqual(values[name], "glaeda-std-xcode-26.6")
        self.assertEqual(values["MACOS_RUNNER_DISPLAY"], "glaeda-gui-std-xcode-26.6")
        self.assertEqual(values["MACOS_RUNNER_IOS"], "glaeda-ios-sim")
        self.assertEqual(values["CI_PAID_MACOS_OVERFLOW"], "1")
        # Moving the pin moves the failover: nothing names 26.6 itself.
        moved, _ = switch.failover_values("/Applications/Xcode_27.0.app", "")
        self.assertEqual(moved["MACOS_RUNNER_PR"], "glaeda-std-xcode-27.0")

    def test_failover_never_touches_a_lane_switch(self) -> None:
        values, _ = switch.failover_values(PIN, "")
        for name in LANE_SWITCHES:
            self.assertNotIn(name, values)
        self.assertFalse(any(value.startswith("ubuntu-") for value in values.values()))
        for name, value in values.items():
            if switch.cloud_label(value):
                self.assertIn(name, switch.LINUX_VARIABLES)
                self.assertNotEqual(value, "blacksmith-4vcpu-ubuntu-2404")

    def test_overrides_replace_drop_and_refuse(self) -> None:
        values, problems = switch.failover_values(PIN, json.dumps({
            "MACOS_RUNNER_15": "glaeda-side-std-xcode-26.6", "MACOS_RUNNER_26_LARGE": "",
            "MACOS_RUNNER_26": "blacksmith-12vcpu-macos-26", "CI_CLOUD_OVERFLOW_SAVED": "x",
            "CI_PR_POOL_OWNED": "0", "MACOS_RUNNER_PR": "macos-15"}))
        self.assertEqual(values["MACOS_RUNNER_15"], "glaeda-side-std-xcode-26.6")
        self.assertNotIn("MACOS_RUNNER_26_LARGE", values)
        # Signing jobs read MACOS_RUNNER_26: no owned failover, and no override may name it.
        self.assertNotIn("MACOS_RUNNER_26", values)
        # A GitHub-hosted Mac is refused like a Blacksmith label: the pool keeps its owned failover.
        self.assertEqual(values["MACOS_RUNNER_PR"], "glaeda-std-xcode-26.6")
        self.assertEqual(len(problems), 4)
        self.assertNotIn("CI_PR_POOL_OWNED", values)
        _, problems = switch.failover_values(PIN, "[1]")
        self.assertEqual(len(problems), 1)
        # A Linux variable may name another Blacksmith Linux size; never GitHub-hosted Ubuntu.
        values, problems = switch.failover_values(PIN, json.dumps({
            "LINUX_RUNNER": "blacksmith-32vcpu-ubuntu-2404", "CI_TRUSTED_RUNNER": "ubuntu-24.04"}))
        self.assertEqual(values["LINUX_RUNNER"], "blacksmith-32vcpu-ubuntu-2404")
        self.assertEqual(values["CI_TRUSTED_RUNNER"], "blacksmith-2vcpu-ubuntu-2404")
        self.assertEqual(len(problems), 1)
        # CI_TRUSTED_RUNNER's readers accept only the 2 and 4 vCPU labels.
        values, problems = switch.failover_values(PIN, json.dumps({"CI_TRUSTED_RUNNER": "blacksmith-16vcpu-ubuntu-2404"}))
        self.assertEqual(values["CI_TRUSTED_RUNNER"], "blacksmith-2vcpu-ubuntu-2404")
        self.assertEqual(len(problems), 1)
        values, problems = switch.failover_values(PIN, json.dumps({"CI_TRUSTED_RUNNER": "glaeda-std-xcode-26.6"}))
        self.assertEqual((values["CI_TRUSTED_RUNNER"], len(problems)), ("blacksmith-2vcpu-ubuntu-2404", 1))
        values, problems = switch.failover_values(PIN, json.dumps({"CI_TRUSTED_RUNNER": "blacksmith-4vcpu-ubuntu-2404"}))
        self.assertEqual((values["CI_TRUSTED_RUNNER"], problems), ("blacksmith-4vcpu-ubuntu-2404", []))

    def test_no_pin_leaves_macos_alone(self) -> None:
        values, problems = switch.failover_values("", "")
        # Linux variables alone never turn on paid macOS overflow.
        self.assertEqual(values, {"LINUX_RUNNER": "blacksmith-16vcpu-ubuntu-2404",
                                  "CI_TRUSTED_RUNNER": "blacksmith-2vcpu-ubuntu-2404"})
        self.assertEqual(len(problems), 1)


class SigningVariableTests(unittest.TestCase):
    """Signing jobs read their runner from these variables; the switch never points one at a reused machine."""

    PINS = ("/Applications/Xcode_26.6.app", "/Applications/Xcode_27.0.app", "", None)

    def test_the_switch_reads_the_one_list(self) -> None:
        self.assertIs(switch.SIGNING_VARIABLES, signing.EPHEMERAL_RUNNER_VARIABLES)
        self.assertIn("MACOS_RUNNER_26", switch.SIGNING_VARIABLES)
        self.assertIn("LINUX_RUNNER", switch.SIGNING_VARIABLES)

    def test_no_failover_names_a_reused_machine_for_a_signing_variable(self) -> None:
        overrides = ("", json.dumps({"MACOS_RUNNER_26": "glaeda-std-xcode-26.6",
                                     "LINUX_RUNNER": "cmux-linux-owned"}))
        for pin in self.PINS:
            for override in overrides:
                values, problems = switch.failover_values(pin, override)
                for name in switch.SIGNING_VARIABLES:
                    if name in values:
                        self.assertTrue(signing.ephemeral_label(values[name]), (pin, override, name, values[name]))
                if override:
                    self.assertTrue(any("MACOS_RUNNER_26" in p and "ignored" in p for p in problems))
                    self.assertTrue(any("signing jobs run on LINUX_RUNNER" in p for p in problems))
        self.assertNotIn("MACOS_RUNNER_26", switch.failover_values(PIN, "")[0])

    def test_no_override_moves_macos_runner_26(self) -> None:
        # Every value one could give it is refused: GitHub-hosted, a Blacksmith label for a macOS
        # variable, or a reused machine signing jobs would run on.
        for value in ("ubuntu-24.04", "blacksmith-12vcpu-macos-26", "glaeda-std-xcode-26.6"):
            values, problems = switch.failover_values(PIN, json.dumps({"MACOS_RUNNER_26": value}))
            self.assertNotIn("MACOS_RUNNER_26", values, value)
            self.assertEqual(len(problems), 1, value)

    def test_an_ephemeral_linux_override_is_kept(self) -> None:
        values, problems = switch.failover_values(PIN, json.dumps({"LINUX_RUNNER": "blacksmith-32vcpu-ubuntu-2404"}))
        self.assertEqual((values["LINUX_RUNNER"], problems), ("blacksmith-32vcpu-ubuntu-2404", []))

    def test_plan_off_never_writes_a_reused_machine_to_a_signing_variable(self) -> None:
        # Even a failover map that carries one (an older caller) is filtered.
        changed = switch.plan_off({"MACOS_RUNNER_26": "blacksmith-6vcpu-macos-26", "LINUX_RUNNER": None},
                                  {"MACOS_RUNNER_26": "glaeda-std-xcode-26.6", "LINUX_RUNNER": "ubuntu-24.04"})
        self.assertEqual(changed, {"LINUX_RUNNER": {"before": None, "after": "ubuntu-24.04"}})

    def test_resume_skips_an_old_record_naming_a_signing_variable(self) -> None:
        # 2026-10-28: MACOS_RUNNER_26 was put back by hand, equal to the record's before, and the
        # next stalled probe re-applied the owned failover.
        record = {"changed": {
            "MACOS_RUNNER_26": {"before": "blacksmith-6vcpu-macos-26", "after": "glaeda-std-xcode-26.6"},
            "MACOS_RUNNER_PR": {"before": "blacksmith-6vcpu-macos-26", "after": "glaeda-std-xcode-26.6"}}}
        resumes = {item.name: item for item in switch.plan_resume(record, {
            "MACOS_RUNNER_26": "blacksmith-6vcpu-macos-26", "MACOS_RUNNER_PR": "blacksmith-6vcpu-macos-26"})}
        self.assertTrue(resumes["MACOS_RUNNER_26"].skipped)
        self.assertFalse(resumes["MACOS_RUNNER_PR"].skipped)

    def test_a_record_key_in_another_case_is_still_a_signing_variable(self) -> None:
        # GitHub reads variable names without regard to case.
        record = {"changed": {"macos_runner_26": {"before": None, "after": "glaeda-std-xcode-26.6"},
                              "Linux_Runner": {"before": None, "after": "cmux-linux-owned"}}}
        resumes = switch.plan_resume(record, {})
        self.assertEqual(len(resumes), 2)
        self.assertTrue(all(item.skipped for item in resumes))
        self.assertFalse(signing.allowed_value("macos_runner_26", "glaeda-std-xcode-26.6"))

    def test_restore_still_puts_back_a_recorded_value(self) -> None:
        record = {"changed": {"MACOS_RUNNER_26": {"before": "blacksmith-6vcpu-macos-26",
                                                  "after": "glaeda-std-xcode-26.6"}}}
        restores = switch.plan_on(record, {"MACOS_RUNNER_26": "glaeda-std-xcode-26.6"})
        self.assertEqual([(r.name, r.value, r.skipped) for r in restores],
                         [("MACOS_RUNNER_26", "blacksmith-6vcpu-macos-26", "")])

    def test_a_stall_with_an_old_record_never_writes_a_signing_variable(self) -> None:
        record = {"since": ago(60), "probe": "blacksmith-4vcpu-ubuntu-2404", "changed": {
            "MACOS_RUNNER_26": {"before": "blacksmith-6vcpu-macos-26", "after": "glaeda-std-xcode-26.6"}}}
        env = {"VAR_CI_CLOUD_OVERFLOW_SAVED": json.dumps(record),
               "VAR_MACOS_RUNNER_26": "blacksmith-6vcpu-macos-26", "VAR_CMUX_CI_XCODE_APP_PR": PIN}
        writer = FakeSwitch()
        code, _, summary = run_main(env, FakeActions(probe_job(0)), writer)
        self.assertEqual((code, writer.writes), (0, []))
        self.assertIn("not an ephemeral runner", summary)

    def test_a_fresh_stall_never_writes_a_signing_variable(self) -> None:
        env = {**BLACKSMITH_STEADY, "VAR_MACOS_RUNNER_26": "blacksmith-6vcpu-macos-26"}
        writer = FakeSwitch()
        code, _, _ = run_main(env, FakeActions(probe_job(0)), writer)
        self.assertEqual(code, 0)
        record = json.loads(dict(writer.writes)[switch.RECORD_VARIABLE])
        self.assertNotIn("MACOS_RUNNER_26", record["changed"])
        for name, value in writer.writes:
            self.assertTrue(signing.allowed_value(name, value), (name, value))


class PlanTests(unittest.TestCase):
    def test_off_changes_only_what_sends_overflow_to_blacksmith(self) -> None:
        failover, _ = switch.failover_values(PIN, "")
        changed = switch.plan_off({
            "LINUX_RUNNER": "blacksmith-4vcpu-ubuntu-2404",
            "MACOS_RUNNER_15": None,  # unset: its readers fall back to Blacksmith
            "MACOS_RUNNER_26": "macos-26",  # someone chose GitHub-hosted: left alone
            "MACOS_RUNNER_IOS": "glaeda-ios-sim",  # already at its failover: not recorded
            "CI_PAID_MACOS_OVERFLOW": None,
        }, failover)
        self.assertEqual(changed["LINUX_RUNNER"], {"before": "blacksmith-4vcpu-ubuntu-2404",
                                                   "after": "blacksmith-16vcpu-ubuntu-2404"})
        self.assertEqual(changed["MACOS_RUNNER_15"], {"before": None, "after": "glaeda-std-xcode-26.6"})
        self.assertEqual(changed["CI_PAID_MACOS_OVERFLOW"], {"before": None, "after": "1"})
        self.assertNotIn("MACOS_RUNNER_26", changed)
        self.assertNotIn("MACOS_RUNNER_IOS", changed)

    def test_on_restores_deletes_and_leaves_a_hand_edit(self) -> None:
        record = {"changed": {
            "LINUX_RUNNER": {"before": "blacksmith-4vcpu-ubuntu-2404", "after": "blacksmith-16vcpu-ubuntu-2404"},
            "CI_PAID_MACOS_OVERFLOW": {"before": None, "after": "1"},
            "MACOS_RUNNER_PR": {"before": "blacksmith-6vcpu-macos-26", "after": "glaeda-std-xcode-26.6"},
        }}
        restores = {item.name: item for item in switch.plan_on(record, {
            "LINUX_RUNNER": "blacksmith-16vcpu-ubuntu-2404", "CI_PAID_MACOS_OVERFLOW": "1", "MACOS_RUNNER_PR": "macos-26"})}
        self.assertEqual(restores["LINUX_RUNNER"].value, "blacksmith-4vcpu-ubuntu-2404")
        self.assertFalse(restores["LINUX_RUNNER"].skipped)
        self.assertIsNone(restores["CI_PAID_MACOS_OVERFLOW"].value)
        self.assertTrue(restores["MACOS_RUNNER_PR"].skipped)

    def test_probe_outcome_is_measured_by_the_runner(self) -> None:
        self.assertEqual(switch.probe_outcome(probe_job(1), NOW, 5), "waiting")
        self.assertEqual(switch.probe_outcome(probe_job(5), NOW, 5), "stalled")
        self.assertEqual(switch.probe_outcome(probe_job(9, runner_name="bs-1", status="completed"), NOW, 5),
                         "started")
        self.assertEqual(switch.probe_outcome(probe_job(1, status="in_progress"), NOW, 5), "started")
        self.assertEqual(switch.probe_outcome(probe_job(1, status="completed"), NOW, 5), "stalled")
        self.assertEqual(switch.probe_outcome(None, NOW, 5), "waiting")

    def test_probe_minutes_are_clamped(self) -> None:
        self.assertEqual(switch.probe_minutes(""), 5)
        self.assertEqual(switch.probe_minutes("x"), 5)
        self.assertEqual(switch.probe_minutes("1"), 2)
        self.assertEqual(switch.probe_minutes("90"), 20)

    def test_the_probe_set_is_the_compile_sizes(self) -> None:
        # Never one label: one stalled size must not flip the fleet (Leo's no-pins order, 2026-10-28).
        self.assertEqual(switch.PROBE_LABELS, ("blacksmith-32vcpu-ubuntu-2404", "blacksmith-16vcpu-ubuntu-2404"))

    def test_stuck_job_needs_a_blacksmith_label_and_the_wait(self) -> None:
        jobs = [
            {"status": "queued", "labels": ["blacksmith-6vcpu-macos-26"], "created_at": ago(3)},
            {"status": "queued", "labels": ["glaeda-std-xcode-26.6"], "created_at": ago(60)},
            {"status": "queued", "labels": ["blacksmith-4vcpu-ubuntu-2404"], "created_at": ago(40),
             "runner_name": "bs"},
        ]
        self.assertIsNone(switch.stuck_job(jobs, NOW, 5))
        jobs.append({"status": "queued", "labels": ["blacksmith-4vcpu-ubuntu-2404"], "created_at": ago(30)})
        self.assertEqual(switch.stuck_job(jobs, NOW, 5)["created_at"], ago(30))
        # A job already on the failover size is where the switch sends it; re-running moves nothing.
        on_failover = [{"status": "queued", "labels": ["blacksmith-16vcpu-ubuntu-2404"], "created_at": ago(30)}]
        self.assertIsNone(switch.stuck_job(on_failover, NOW, 5, ["blacksmith-16vcpu-ubuntu-2404"]))
        self.assertIsNotNone(switch.stuck_job(on_failover, NOW, 5))
        # Only a destination that was nobody's value before counts: LINUX_RUNNER on 2 vCPU moved to 16,
        # while CI_TRUSTED_RUNNER moved onto 2, so jobs queued on 2 vCPU still move.
        record = {"changed": {
            "LINUX_RUNNER": {"before": "blacksmith-2vcpu-ubuntu-2404", "after": "blacksmith-16vcpu-ubuntu-2404"},
            "CI_TRUSTED_RUNNER": {"before": None, "after": "blacksmith-2vcpu-ubuntu-2404"},
            "MACOS_RUNNER_PR": {"before": None, "after": "glaeda-std-xcode-26.6"}}}
        self.assertEqual(switch.failover_destinations(record, "blacksmith-2vcpu-ubuntu-2404"),
                         {"blacksmith-16vcpu-ubuntu-2404"})

    def test_protected_runs_are_left_alone(self) -> None:
        self.assertTrue(switch.protected_reason({"event": "merge_group"}))
        self.assertTrue(switch.protected_reason({"event": "push", "name": "Release"}))
        self.assertTrue(switch.protected_reason({"event": "pull_request", "run_attempt": 3}))
        self.assertFalse(switch.protected_reason({"event": "pull_request", "name": "CI", "run_attempt": 1}))


class MainTests(unittest.TestCase):
    def test_a_stall_writes_the_record_first_then_the_failovers_then_moves_stuck_runs(self) -> None:
        stuck = {"id": 7, "status": "queued", "event": "pull_request", "name": "CI", "run_attempt": 1,
                 "created_at": ago(40)}
        merge = {"id": 8, "status": "queued", "event": "merge_group", "name": "CI", "run_attempt": 1,
                 "created_at": ago(30)}
        queued = [{"status": "queued", "labels": ["blacksmith-4vcpu-ubuntu-2404"], "created_at": ago(35)}]
        actions = FakeActions(probe_job(0), [stuck, merge], {7: queued, 8: queued})
        writer = FakeSwitch()
        code, out, summary = run_main(BLACKSMITH_STEADY, actions, writer)
        self.assertEqual(code, 0)
        self.assertIn("outcome=stalled", out)
        self.assertEqual(writer.writes[0][0], "CI_CLOUD_OVERFLOW_SAVED")
        record = json.loads(str(writer.writes[0][1]))
        self.assertEqual(record["probe"], ", ".join(switch.PROBE_LABELS))
        # Every Linux size it could move to stalled with the probes, so LINUX_RUNNER is left alone.
        self.assertNotIn("LINUX_RUNNER", record["changed"])
        # No Linux size started, so neither Linux variable moves onto one.
        self.assertNotIn("CI_TRUSTED_RUNNER", record["changed"])
        written = dict(writer.writes[1:])
        self.assertNotIn("LINUX_RUNNER", written)
        self.assertEqual(written["MACOS_RUNNER_PR"], "glaeda-std-xcode-26.6")
        self.assertEqual(written["CI_PAID_MACOS_OVERFLOW"], "1")
        for name in LANE_SWITCHES:
            self.assertNotIn(name, written)
        self.assertEqual(actions.calls, [("force-cancel", 7), ("rerun", 7)])
        self.assertIn("merge_group run", summary)

    def test_a_started_probe_restores_and_deletes_the_record(self) -> None:
        record = {"since": ago(60), "probe": "blacksmith-4vcpu-ubuntu-2404", "changed": {
            "LINUX_RUNNER": {"before": "blacksmith-4vcpu-ubuntu-2404", "after": "blacksmith-16vcpu-ubuntu-2404"},
            "CI_PAID_MACOS_OVERFLOW": {"before": None, "after": "1"},
            "MACOS_RUNNER_PR": {"before": "blacksmith-6vcpu-macos-26", "after": "glaeda-std-xcode-26.6"}}}
        env = {"VAR_CI_CLOUD_OVERFLOW_SAVED": json.dumps(record), "VAR_LINUX_RUNNER": "blacksmith-16vcpu-ubuntu-2404",
               "VAR_CI_PAID_MACOS_OVERFLOW": "1", "VAR_MACOS_RUNNER_PR": "macos-26",
               "VAR_CMUX_CI_XCODE_APP_PR": PIN}
        actions, writer = FakeActions(probe_job(0, status="in_progress", runner_name="bs-1")), FakeSwitch()
        code, out, summary = run_main(env, actions, writer)
        self.assertEqual(code, 0)
        self.assertIn("outcome=started", out)
        self.assertEqual(writer.writes, [("CI_PAID_MACOS_OVERFLOW", None),
                                         ("LINUX_RUNNER", "blacksmith-4vcpu-ubuntu-2404"),
                                         ("CI_CLOUD_OVERFLOW_SAVED", None)])
        self.assertIn("left alone", summary)
        self.assertEqual(actions.calls, [])

    def test_a_stalled_record_finishes_a_partial_switch(self) -> None:
        record = {"since": ago(60), "probe": "blacksmith-4vcpu-ubuntu-2404", "changed": {
            "LINUX_RUNNER": {"before": "blacksmith-4vcpu-ubuntu-2404", "after": "blacksmith-16vcpu-ubuntu-2404"},
            "MACOS_RUNNER_PR": {"before": "blacksmith-6vcpu-macos-26", "after": "glaeda-std-xcode-26.6"}}}
        env = {"VAR_CI_CLOUD_OVERFLOW_SAVED": json.dumps(record),
               "VAR_LINUX_RUNNER": "blacksmith-4vcpu-ubuntu-2404",
               "VAR_MACOS_RUNNER_PR": "blacksmith-6vcpu-macos-26", "VAR_CMUX_CI_XCODE_APP_PR": PIN}
        writer = FakeSwitch()
        code, out, _ = run_main(env, FakeActions(probe_job(0)), writer)
        self.assertEqual(code, 0)
        self.assertIn("outcome=stalled", out)
        # The owned macOS pool is retried; 16 vCPU stalled with the rest, so LINUX_RUNNER waits.
        self.assertEqual(writer.writes, [("MACOS_RUNNER_PR", "glaeda-std-xcode-26.6")])

    def test_a_record_on_hosted_ubuntu_moves_to_the_blacksmith_failover(self) -> None:
        # Written by the switch before 2026-10-27 (Linux failed over to GitHub-hosted Ubuntu).
        record = {"since": ago(60), "probe": "blacksmith-4vcpu-ubuntu-2404", "changed": {
            "LINUX_RUNNER": {"before": "blacksmith-4vcpu-ubuntu-2404", "after": "ubuntu-24.04"},
            "CI_TRUSTED_RUNNER": {"before": None, "after": "ubuntu-24.04"},
            "MACOS_RUNNER_PR": {"before": "blacksmith-6vcpu-macos-26", "after": "glaeda-std-xcode-26.6"}}}
        # LINUX_RUNNER still at the old failover; CI_TRUSTED_RUNNER changed by hand since.
        current = {"LINUX_RUNNER": "ubuntu-24.04", "CI_TRUSTED_RUNNER": "blacksmith-4vcpu-ubuntu-2404"}
        failover = switch.toward_started({"LINUX_RUNNER": switch.LINUX_FAILOVER}, ["blacksmith-16vcpu-ubuntu-2404"])
        migrated, moves = switch.migrate_hosted_linux(record, current, failover)
        saved = migrated["changed"]
        self.assertEqual(saved["LINUX_RUNNER"], {"before": "blacksmith-4vcpu-ubuntu-2404",
                                                 "after": "blacksmith-16vcpu-ubuntu-2404", "was": "ubuntu-24.04"})
        self.assertEqual(saved["CI_TRUSTED_RUNNER"], {"before": None, "after": "ubuntu-24.04"})
        self.assertEqual([(m.name, m.value) for m in moves], [("LINUX_RUNNER", "blacksmith-16vcpu-ubuntu-2404")])
        # Turning overflow back on then restores from the migrated record.
        restores = {item.name: item for item in switch.plan_on(
            {"changed": saved}, {"LINUX_RUNNER": "blacksmith-16vcpu-ubuntu-2404"})}
        self.assertEqual(restores["LINUX_RUNNER"].value, "blacksmith-4vcpu-ubuntu-2404")
        self.assertFalse(restores["LINUX_RUNNER"].skipped)

    def test_a_hosted_ubuntu_record_never_moves_onto_a_stalled_size(self) -> None:
        # Review of this change: with both 16 and 32 vCPU stalled, migrating onto 16 vCPU moves nothing.
        record = {"since": ago(60), "probe": "blacksmith-4vcpu-ubuntu-2404", "changed": {
            "LINUX_RUNNER": {"before": "blacksmith-4vcpu-ubuntu-2404", "after": "ubuntu-24.04"}}}
        env = {"VAR_CI_CLOUD_OVERFLOW_SAVED": json.dumps(record), "VAR_LINUX_RUNNER": "ubuntu-24.04",
               "VAR_CMUX_CI_XCODE_APP_PR": PIN}
        writer = FakeSwitch()
        code, out, _ = run_main(env, FakeActions(probe_job(0)), writer)
        self.assertEqual(code, 0)
        self.assertIn("outcome=stalled", out)
        self.assertEqual(writer.writes, [])
        # Without the switch token there is nothing to write either, so it does not fail.
        code, _, _ = run_main(env, FakeActions(probe_job(0)), None)
        self.assertEqual(code, 0)

    def test_a_legacy_partial_switch_never_resumes_onto_hosted_ubuntu(self) -> None:
        record = {"since": ago(60), "probe": "blacksmith-4vcpu-ubuntu-2404", "changed": {
            "LINUX_RUNNER": {"before": "blacksmith-4vcpu-ubuntu-2404", "after": "ubuntu-24.04"}}}
        env = {"VAR_CI_CLOUD_OVERFLOW_SAVED": json.dumps(record),
               "VAR_LINUX_RUNNER": "blacksmith-4vcpu-ubuntu-2404", "VAR_CMUX_CI_XCODE_APP_PR": PIN}
        writer = FakeSwitch()
        run_main(env, FakeActions(probe_job(0)), writer)
        self.assertEqual(writer.writes, [])

    def test_an_interrupted_migration_never_resumes_onto_a_stalled_size(self) -> None:
        # The record was rewritten (after -> 16 vCPU, was -> ubuntu-24.04) but the variable write failed;
        # 16 vCPU has since stalled, so the retry waits for a run where it starts.
        record = {"since": ago(60), "probe": "blacksmith-4vcpu-ubuntu-2404", "changed": {
            "LINUX_RUNNER": {"before": "blacksmith-4vcpu-ubuntu-2404", "after": "blacksmith-16vcpu-ubuntu-2404",
                             "was": "ubuntu-24.04"}}}
        env = {"VAR_CI_CLOUD_OVERFLOW_SAVED": json.dumps(record), "VAR_LINUX_RUNNER": "ubuntu-24.04",
               "VAR_CMUX_CI_XCODE_APP_PR": PIN}
        writer = FakeSwitch()
        run_main(env, FakeActions(probe_job(0)), writer)
        self.assertEqual(writer.writes, [])
        resumes = switch.plan_resume(record, {"LINUX_RUNNER": "ubuntu-24.04"}, ["blacksmith-16vcpu-ubuntu-2404"])
        self.assertEqual([(r.name, r.value, r.skipped) for r in resumes],
                         [("LINUX_RUNNER", "blacksmith-16vcpu-ubuntu-2404", "")])
        restores = switch.plan_on(record, {"LINUX_RUNNER": "ubuntu-24.04"})
        self.assertEqual([(r.name, r.value, r.skipped) for r in restores],
                         [("LINUX_RUNNER", "blacksmith-4vcpu-ubuntu-2404", "")])

    def test_a_linux_failover_names_only_a_size_that_started(self) -> None:
        # Nothing started: the Linux variables are left alone, the macOS ones still fail over.
        self.assertEqual(switch.toward_started({"LINUX_RUNNER": "blacksmith-16vcpu-ubuntu-2404",
                                                "MACOS_RUNNER_PR": "glaeda-std-xcode-26.6"}, []),
                         {"MACOS_RUNNER_PR": "glaeda-std-xcode-26.6"})
        # Only 32 vCPU started: the chain moves on to it.
        self.assertEqual(switch.toward_started({"LINUX_RUNNER": "blacksmith-16vcpu-ubuntu-2404"},
                                               ["blacksmith-32vcpu-ubuntu-2404"]),
                         {"LINUX_RUNNER": "blacksmith-32vcpu-ubuntu-2404"})
        self.assertEqual(switch.toward_started({"LINUX_RUNNER": "blacksmith-16vcpu-ubuntu-2404"},
                                               switch.PROBE_LABELS),
                         {"LINUX_RUNNER": "blacksmith-16vcpu-ubuntu-2404"})
        # The live record's LINUX_RUNNER entry (32 vCPU) is not retried while 32 vCPU did not start.
        record = {"changed": {"LINUX_RUNNER": {"before": "blacksmith-4vcpu-ubuntu-2404",
                                               "after": "blacksmith-32vcpu-ubuntu-2404"}}}
        resumes = switch.plan_resume(record, {"LINUX_RUNNER": "blacksmith-4vcpu-ubuntu-2404"},
                                     ["blacksmith-16vcpu-ubuntu-2404"])
        self.assertTrue(resumes[0].skipped)

    def test_one_stalled_size_changes_nothing(self) -> None:
        stalled = probe_job(6)
        started = {**probe_job(6, runner_name="bs-1", status="in_progress"),
                   "name": switch.probe_job_name(switch.PROBE_LABELS[1])}
        self.assertEqual(switch.probe_set_outcome([stalled, started], switch.PROBE_LABELS, NOW, 5),
                         ("partial", [switch.PROBE_LABELS[0]]))
        self.assertEqual(switch.probe_set_outcome([stalled], switch.PROBE_LABELS, NOW, 5),
                         ("waiting", [switch.PROBE_LABELS[0]]))
        both = [{**stalled, "name": switch.probe_job_name(label)} for label in switch.PROBE_LABELS]
        self.assertEqual(switch.probe_set_outcome(both, switch.PROBE_LABELS, NOW, 5),
                         ("stalled", list(switch.PROBE_LABELS)))
        up = [{**started, "name": switch.probe_job_name(label)} for label in switch.PROBE_LABELS]
        self.assertEqual(switch.probe_set_outcome(up, switch.PROBE_LABELS, NOW, 5), ("started", []))
        # Review of this change: 16 vCPU starting while 32 vCPU stalls must not clear the record,
        # since fast-checks falls back to 32 vCPU without it.
        record = {"since": ago(60), "probe": "blacksmith-4vcpu-ubuntu-2404", "changed": {
            "MACOS_RUNNER_PR": {"before": "blacksmith-6vcpu-macos-26", "after": "glaeda-std-xcode-26.6"}}}
        env = {"VAR_CI_CLOUD_OVERFLOW_SAVED": json.dumps(record), "VAR_MACOS_RUNNER_PR": "glaeda-std-xcode-26.6",
               "VAR_CMUX_CI_XCODE_APP_PR": PIN}
        writer = FakeSwitch()
        code, out, _ = run_main(env, FakeActions([stalled, started]), writer)
        self.assertEqual((code, writer.writes), (0, []))
        self.assertIn("outcome=partial", out)
        # Nor does it turn overflow off when there is no record.
        writer = FakeSwitch()
        code, out, _ = run_main(BLACKSMITH_STEADY, FakeActions([stalled, started]), writer)
        self.assertEqual((code, writer.writes), (0, []))
        # Per-label health is written either way, for the pool reconciler to read.
        self.assertEqual(writer.health[-1]["labels"], {switch.PROBE_LABELS[0]: "stalled",
                                                       switch.PROBE_LABELS[1]: "started"})
        self.assertEqual(writer.health[-1]["run"], "https://github.com/manaflow-ai/cmux/actions/runs/1")
        # Every size started: the record is put back and deleted.
        writer = FakeSwitch()
        code, out, _ = run_main(env, FakeActions(up), writer)
        self.assertIn("outcome=started", out)
        self.assertEqual(writer.writes, [("MACOS_RUNNER_PR", "blacksmith-6vcpu-macos-26"),
                                         ("CI_CLOUD_OVERFLOW_SAVED", None)])

    def test_a_drill_or_dry_run_writes_no_health(self) -> None:
        writer = FakeSwitch()
        run_main({**BLACKSMITH_STEADY, "PROBE_LABEL_DRILL": DRILL}, FakeActions(probe_job(0)), writer)
        run_main(BLACKSMITH_STEADY, FakeActions(probe_job(0)), writer, argv=["--dry-run"])
        self.assertEqual(writer.health, [])

    def test_healthy_with_no_record_writes_nothing(self) -> None:
        writer = FakeSwitch()
        code, _, _ = run_main(BLACKSMITH_STEADY, FakeActions(probe_job(0, runner_name="bs-1")), writer)
        self.assertEqual((code, writer.writes), (0, []))

    def test_no_switch_token_fails_loudly_and_writes_nothing(self) -> None:
        actions = FakeActions(probe_job(0))
        code, out, summary = run_main(BLACKSMITH_STEADY, actions, None)
        self.assertEqual(code, 1)
        self.assertIn("outcome=stalled", out)
        self.assertIn("MACOS_RUNNER_PR -> glaeda-std-xcode-26.6", summary)
        self.assertNotIn("LINUX_RUNNER ->", summary)
        self.assertEqual(actions.calls, [])

    def test_dry_run_changes_nothing(self) -> None:
        stuck = {"id": 7, "status": "queued", "event": "push", "name": "CI", "run_attempt": 1,
                 "created_at": ago(40)}
        actions = FakeActions(probe_job(0), [stuck], {7: [
            {"status": "queued", "labels": ["blacksmith-4vcpu-ubuntu-2404"], "created_at": ago(35)}]})
        writer = FakeSwitch()
        code, _, summary = run_main(BLACKSMITH_STEADY, actions, writer, argv=["--dry-run"])
        self.assertEqual((code, writer.writes, actions.calls), (0, [], []))
        self.assertIn("would set", summary)

    def test_a_drill_never_writes(self) -> None:
        writer = FakeSwitch()
        env = {**BLACKSMITH_STEADY, "PROBE_LABEL_DRILL": "blacksmith-0vcpu-no-such-label"}
        code, out, summary = run_main(env, FakeActions(probe_job(0)), writer)
        self.assertEqual((code, writer.writes), (0, []))
        self.assertIn("outcome=stalled", out)
        self.assertIn("would set", summary)

    def test_a_drill_reports_failovers_without_the_app_token(self) -> None:
        env = {**BLACKSMITH_STEADY, "PROBE_LABEL_DRILL": "blacksmith-0vcpu-no-such-label"}
        code, out, summary = run_main(env, FakeActions(probe_job(0)), None)
        self.assertEqual(code, 0)
        self.assertIn("outcome=stalled", out)
        self.assertIn("MACOS_RUNNER_PR: would set glaeda-std-xcode-26.6", summary)
        # The drill's label did not start, so no Linux size is known to serve.
        self.assertNotIn("LINUX_RUNNER: would set", summary)
        self.assertNotIn("no switch token", summary)

    def test_runner_values_come_from_the_block(self) -> None:
        values = switch.current_values({"CMUX_CI_RUNNER_VARIABLES": "LINUX_RUNNER=ubuntu-24.04\nMACOS_RUNNER_PR=\n"},
                                       ["LINUX_RUNNER", "MACOS_RUNNER_PR"])
        self.assertEqual(values, {"LINUX_RUNNER": "ubuntu-24.04", "MACOS_RUNNER_PR": None})

    def test_an_unreadable_record_fails_without_writing(self) -> None:
        writer = FakeSwitch()
        code, _, _ = run_main({**BLACKSMITH_STEADY, "VAR_CI_CLOUD_OVERFLOW_SAVED": "{"},
                              FakeActions(probe_job(0)), writer)
        self.assertEqual((code, writer.writes), (1, []))


class WorkflowTests(unittest.TestCase):
    text = WORKFLOW.read_text(encoding="utf-8")

    def test_probe_matrix_restates_the_probe_set(self) -> None:
        document = yaml.safe_load(self.text)
        probe = document["jobs"]["probe"]
        self.assertEqual(probe["name"], f"{switch.PROBE_JOB} (${{{{ matrix.label }}}})")
        self.assertEqual(switch.probe_job_name("x"), f"{switch.PROBE_JOB} (x)")
        self.assertIs(probe["strategy"]["fail-fast"], False)
        matrix = probe["strategy"]["matrix"]["label"]
        listed = json.loads(re.search(r"\|\| '(\[.*?\])'", matrix).group(1))
        self.assertEqual(tuple(listed), switch.PROBE_LABELS)
        self.assertTrue(probe["runs-on"].endswith("|| matrix.label }}"))
        # Unless every probe started, the run ends itself, so a queued probe frees the group.
        self.assertIn("if: always() && steps.switch.outputs.outcome != 'started'", self.text)

    def test_watch_runs_off_blacksmith_and_passes_every_switched_variable(self) -> None:
        # Never GitHub-hosted Ubuntu: on 2026-10-27 the watch queued 94 minutes there behind the
        # switch's own failover and held the concurrency group, so no later run decided anything.
        runs_on = re.search(r"name: Watch the probe and switch overflow\n(?:.*\n)*?\s+runs-on: (.*)", self.text).group(1)
        self.assertNotIn("ubuntu-24.04", runs_on)
        self.assertNotIn("ubuntu-latest", runs_on)
        self.assertNotIn("github-hosted-required", runs_on)
        # Blacksmith macOS: never a size the probes ask for, so it never queues behind them.
        self.assertEqual(runs_on, "blacksmith-6vcpu-macos-26")
        names = set(switch.SWITCHED_VARIABLES) | {switch.RECORD_VARIABLE, switch.OVERRIDES_VARIABLE,
                                                  "CMUX_CI_XCODE_APP_PR"}
        for name in names:
            passed = (f"VAR_{name}: ${{{{ vars.{name} }}}}" in self.text
                      or f"            {name}=${{{{ vars.{name} }}}}\n" in self.text)
            self.assertTrue(passed, name)
        self.assertIn("force-cancel", self.text)

    def test_watch_uses_existing_route_app_credentials(self) -> None:
        self.assertIn("vars.GLAEDA_ROUTE_APP_ID", self.text)
        self.assertIn("secrets.GLAEDA_ROUTE_APP_KEY", self.text)
        self.assertNotIn("CI_OVERFLOW_SWITCH_APP_ID", self.text)
        self.assertNotIn("CI_OVERFLOW_SWITCH_APP_KEY", self.text)
        self.assertNotIn("environment: ci-overflow-switch", self.text)

    def test_never_reads_a_lane_switch(self) -> None:
        code = "\n".join(line for line in self.text.splitlines() if not line.lstrip().startswith("#"))
        for name in LANE_SWITCHES:
            self.assertNotIn(name, code)

    def test_every_overridable_variable_is_passed(self) -> None:
        for name in switch.OVERRIDABLE_VARIABLES:
            self.assertIn(f"            {name}=${{{{ vars.{name} }}}}\n", self.text)

    def test_a_drill_probes_its_label_and_is_always_a_dry_run(self) -> None:
        self.assertIn("inputs.probe_label != '' && format('[\"{0}\"]', inputs.probe_label) ||", self.text)
        self.assertIn("(inputs.dry_run || inputs.probe_label != '')", self.text)


class RepoVariableCheckTests(unittest.TestCase):
    def env(self, **extra: str) -> dict[str, str]:
        return {"CMUX_CI_RUNNER_VARIABLES": "MACOS_RUNNER_PR=glaeda-std-xcode-26.6\nLINUX_RUNNER=ubuntu-24.04\n",
                "CI_OWNED_POOL_SLOTS": "", "CMUX_CI_XCODE_APP_PR": PIN, **extra}

    def test_a_signing_variable_the_drift_policy_accepts_is_still_reported(self) -> None:
        env = {"CMUX_CI_RUNNER_VARIABLES": "MACOS_RUNNER_26=warp-macos-15-arm64-6x\n", "CI_OWNED_POOL_SLOTS": "",
               "CMUX_CI_XCODE_APP_PR": PIN}
        self.assertTrue(any(p.startswith("MACOS_RUNNER_26=") and "signing jobs" in p for p in check.problems(env)))
        env["CMUX_CI_RUNNER_VARIABLES"] = "MACOS_RUNNER_26=blacksmith-6vcpu-macos-26\n"
        self.assertFalse(any(p.startswith("MACOS_RUNNER_26=") for p in check.problems(env)))

    def test_a_trusted_runner_its_readers_reject_is_drift(self) -> None:
        def env(trusted: str) -> dict[str, str]:
            return {"CMUX_CI_RUNNER_VARIABLES": f"CI_TRUSTED_RUNNER={trusted}\n", "CI_OWNED_POOL_SLOTS": "",
                    "CMUX_CI_XCODE_APP_PR": PIN}
        self.assertTrue(any("CI_TRUSTED_RUNNER" in p for p in check.problems(env("blacksmith-16vcpu-ubuntu-2404"))))
        self.assertFalse(any("CI_TRUSTED_RUNNER" in p for p in check.problems(env("blacksmith-2vcpu-ubuntu-2404"))))

    def test_an_owned_label_is_drift_without_the_record(self) -> None:
        self.assertTrue(check.problems(self.env()))

    def test_the_switch_failover_is_expected_while_the_record_exists(self) -> None:
        record = {"changed": {"MACOS_RUNNER_PR": {"before": None, "after": "glaeda-std-xcode-26.6"}}}
        self.assertEqual(check.problems(self.env(CI_CLOUD_OVERFLOW_SAVED=json.dumps(record))), [])
        other = {"changed": {"MACOS_RUNNER_PR": {"before": None, "after": "glaeda-light-xcode-26.6"}}}
        self.assertTrue(check.problems(self.env(CI_CLOUD_OVERFLOW_SAVED=json.dumps(other))))
        self.assertTrue(check.problems(self.env(CI_CLOUD_OVERFLOW_SAVED="not json")))

    def test_a_record_never_excuses_a_reused_machine_in_a_signing_variable(self) -> None:
        record = {"changed": {"MACOS_RUNNER_26": {"before": None, "after": "glaeda-std-xcode-26.6"}}}
        env = self.env(CI_CLOUD_OVERFLOW_SAVED=json.dumps(record),
                       CMUX_CI_RUNNER_VARIABLES="MACOS_RUNNER_26=glaeda-std-xcode-26.6\n")
        self.assertTrue(any("MACOS_RUNNER_26" in p for p in check.problems(env)))


if __name__ == "__main__":
    unittest.main()
