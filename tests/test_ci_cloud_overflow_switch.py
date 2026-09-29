#!/usr/bin/env python3
"""The cloud overflow switch: one Blacksmith probe decides whether overflow goes to Blacksmith."""

from __future__ import annotations

import datetime as dt
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import check_repo_variables as check  # noqa: E402
import cloud_overflow_switch as switch  # noqa: E402

WORKFLOW = ROOT / ".github" / "workflows" / "ci-cloud-overflow-probe.yml"
PIN = "/Applications/Xcode_26.6.app"
NOW = dt.datetime(2026, 9, 29, 12, 0, tzinfo=dt.timezone.utc)
LANE_SWITCHES = ("CI_PR_POOL_OWNED", "CI_E2E_OWNED_UI", "CI_IOS_OWNED", "CI_OWNED_POOL_RESCUE",
                 "CI_PR_POOL_OVERFLOW", "CI_PR_POOL_ORDER", "CI_OWNED_POOL_SLOTS")


def ago(minutes: float) -> str:
    return switch.iso(NOW - dt.timedelta(minutes=minutes))


def probe_job(minutes: float, **extra: object) -> dict:
    return {"name": switch.PROBE_JOB, "status": "queued", "created_at": ago(minutes),
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
            return [self.probe] if self.probe else []
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

    def set_variable(self, name: str, value: str) -> None:
        self.writes.append((name, value))

    def delete_variable(self, name: str) -> None:
        self.writes.append((name, None))


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
        self.assertEqual(values["LINUX_RUNNER"], "ubuntu-24.04")
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
        self.assertFalse(any(switch.cloud_label(value) for value in values.values()))

    def test_overrides_replace_drop_and_refuse(self) -> None:
        values, problems = switch.failover_values(PIN, json.dumps({
            "MACOS_RUNNER_15": "macos-15", "MACOS_RUNNER_26_LARGE": "",
            "MACOS_RUNNER_26": "blacksmith-12vcpu-macos-26", "CI_CLOUD_OVERFLOW_SAVED": "x",
            "CI_PR_POOL_OWNED": "0"}))
        self.assertEqual(values["MACOS_RUNNER_15"], "macos-15")
        self.assertNotIn("MACOS_RUNNER_26_LARGE", values)
        self.assertEqual(values["MACOS_RUNNER_26"], "glaeda-std-xcode-26.6")
        self.assertEqual(len(problems), 3)
        self.assertNotIn("CI_PR_POOL_OWNED", values)
        _, problems = switch.failover_values(PIN, "[1]")
        self.assertEqual(len(problems), 1)

    def test_no_pin_leaves_macos_alone(self) -> None:
        values, problems = switch.failover_values("", "")
        self.assertEqual(values, {"LINUX_RUNNER": "ubuntu-24.04"})
        self.assertEqual(len(problems), 1)


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
                                                   "after": "ubuntu-24.04"})
        self.assertEqual(changed["MACOS_RUNNER_15"], {"before": None, "after": "glaeda-std-xcode-26.6"})
        self.assertEqual(changed["CI_PAID_MACOS_OVERFLOW"], {"before": None, "after": "1"})
        self.assertNotIn("MACOS_RUNNER_26", changed)
        self.assertNotIn("MACOS_RUNNER_IOS", changed)

    def test_on_restores_deletes_and_leaves_a_hand_edit(self) -> None:
        record = {"changed": {
            "LINUX_RUNNER": {"before": "blacksmith-4vcpu-ubuntu-2404", "after": "ubuntu-24.04"},
            "CI_PAID_MACOS_OVERFLOW": {"before": None, "after": "1"},
            "MACOS_RUNNER_PR": {"before": "blacksmith-6vcpu-macos-26", "after": "glaeda-std-xcode-26.6"},
        }}
        restores = {item.name: item for item in switch.plan_on(record, {
            "LINUX_RUNNER": "ubuntu-24.04", "CI_PAID_MACOS_OVERFLOW": "1", "MACOS_RUNNER_PR": "macos-26"})}
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

    def test_probe_label_prefers_the_record(self) -> None:
        self.assertEqual(switch.probe_label({"probe": "blacksmith-8vcpu-ubuntu-2404"}, "ubuntu-24.04"),
                         "blacksmith-8vcpu-ubuntu-2404")
        self.assertEqual(switch.probe_label(None, "ubuntu-24.04"), switch.DEFAULT_PROBE_LABEL)
        self.assertEqual(switch.probe_label(None, "blacksmith-2vcpu-ubuntu-2404"), "blacksmith-2vcpu-ubuntu-2404")

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
        self.assertEqual(record["probe"], "blacksmith-4vcpu-ubuntu-2404")
        self.assertEqual(record["changed"]["LINUX_RUNNER"]["before"], "blacksmith-4vcpu-ubuntu-2404")
        written = dict(writer.writes[1:])
        self.assertEqual(written["LINUX_RUNNER"], "ubuntu-24.04")
        self.assertEqual(written["MACOS_RUNNER_PR"], "glaeda-std-xcode-26.6")
        self.assertEqual(written["CI_PAID_MACOS_OVERFLOW"], "1")
        for name in LANE_SWITCHES:
            self.assertNotIn(name, written)
        self.assertEqual(actions.calls, [("force-cancel", 7), ("rerun", 7)])
        self.assertIn("merge_group run", summary)

    def test_a_started_probe_restores_and_deletes_the_record(self) -> None:
        record = {"since": ago(60), "probe": "blacksmith-4vcpu-ubuntu-2404", "changed": {
            "LINUX_RUNNER": {"before": "blacksmith-4vcpu-ubuntu-2404", "after": "ubuntu-24.04"},
            "CI_PAID_MACOS_OVERFLOW": {"before": None, "after": "1"},
            "MACOS_RUNNER_PR": {"before": "blacksmith-6vcpu-macos-26", "after": "glaeda-std-xcode-26.6"}}}
        env = {"VAR_CI_CLOUD_OVERFLOW_SAVED": json.dumps(record), "VAR_LINUX_RUNNER": "ubuntu-24.04",
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

    def test_healthy_with_no_record_writes_nothing(self) -> None:
        writer = FakeSwitch()
        code, _, _ = run_main(BLACKSMITH_STEADY, FakeActions(probe_job(0, runner_name="bs-1")), writer)
        self.assertEqual((code, writer.writes), (0, []))

    def test_no_switch_token_fails_loudly_and_writes_nothing(self) -> None:
        actions = FakeActions(probe_job(0))
        code, out, summary = run_main(BLACKSMITH_STEADY, actions, None)
        self.assertEqual(code, 1)
        self.assertIn("outcome=stalled", out)
        self.assertIn("LINUX_RUNNER -> ubuntu-24.04", summary)
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

    def test_probe_restates_probe_label(self) -> None:
        runs_on = re.search(r"name: Blacksmith probe\n(?:.*\n)*?\s+runs-on: (.*)", self.text).group(1)
        self.assertIn("vars.CI_CLOUD_OVERFLOW_SAVED", runs_on)
        self.assertIn(f"'{switch.DEFAULT_PROBE_LABEL}'", runs_on)
        self.assertIn(f"name: {switch.PROBE_JOB}\n", self.text)

    def test_watch_runs_off_blacksmith_and_passes_every_switched_variable(self) -> None:
        self.assertIn("runs-on: ubuntu-24.04 # github-hosted-required:", self.text)
        names = set(switch.SWITCHED_VARIABLES) | {switch.RECORD_VARIABLE, switch.OVERRIDES_VARIABLE,
                                                  "CMUX_CI_XCODE_APP_PR"}
        for name in names:
            passed = (f"VAR_{name}: ${{{{ vars.{name} }}}}" in self.text
                      or f"            {name}=${{{{ vars.{name} }}}}\n" in self.text)
            self.assertTrue(passed, name)
        self.assertIn("force-cancel", self.text)

    def test_never_reads_a_lane_switch(self) -> None:
        code = "\n".join(line for line in self.text.splitlines() if not line.lstrip().startswith("#"))
        for name in LANE_SWITCHES:
            self.assertNotIn(name, code)

    def test_every_overridable_variable_is_passed(self) -> None:
        for name in switch.OVERRIDABLE_VARIABLES:
            self.assertIn(f"            {name}=${{{{ vars.{name} }}}}\n", self.text)

    def test_a_drill_probes_its_label_and_is_always_a_dry_run(self) -> None:
        self.assertIn("inputs.probe_label != '' && inputs.probe_label ||", self.text)
        self.assertIn("(inputs.dry_run || inputs.probe_label != '')", self.text)


class RepoVariableCheckTests(unittest.TestCase):
    def env(self, **extra: str) -> dict[str, str]:
        return {"CMUX_CI_RUNNER_VARIABLES": "MACOS_RUNNER_PR=glaeda-std-xcode-26.6\nLINUX_RUNNER=ubuntu-24.04\n",
                "CI_OWNED_POOL_SLOTS": "", "CMUX_CI_XCODE_APP_PR": PIN, **extra}

    def test_an_owned_label_is_drift_without_the_record(self) -> None:
        self.assertTrue(check.problems(self.env()))

    def test_the_switch_failover_is_expected_while_the_record_exists(self) -> None:
        record = {"changed": {"MACOS_RUNNER_PR": {"before": None, "after": "glaeda-std-xcode-26.6"}}}
        self.assertEqual(check.problems(self.env(CI_CLOUD_OVERFLOW_SAVED=json.dumps(record))), [])
        other = {"changed": {"MACOS_RUNNER_PR": {"before": None, "after": "glaeda-light-xcode-26.6"}}}
        self.assertTrue(check.problems(self.env(CI_CLOUD_OVERFLOW_SAVED=json.dumps(other))))
        self.assertTrue(check.problems(self.env(CI_CLOUD_OVERFLOW_SAVED="not json")))


if __name__ == "__main__":
    unittest.main()
