#!/usr/bin/env python3
"""The cloud overflow switch: one Blacksmith probe decides whether overflow goes to Blacksmith."""

from __future__ import annotations

import datetime as dt
import json
import os
import re
import subprocess
import textwrap
import sys
import tempfile
import unittest

import yaml
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# The watch's own selector: the repair one-job JIT label first (no Blacksmith minutes, and it keeps working while the
# probed sizes stall), then its own bounded CI_TRUSTED_RUNNER pick: ephemeral labels only, never a probed size.
REPAIR_LABEL = "cmux-gcp-repair-jit-x64"
SECRET_JIT_LABEL = "cmux-gcp-secret-jit-x64"
WATCH_SELECTOR = (
    "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || "
    "vars.CI_REPAIR_SKIP_FLEET != '1' && '" + REPAIR_LABEL + "' || contains(fromJSON('"
    '["blacksmith-2vcpu-ubuntu-2404","blacksmith-8vcpu-ubuntu-2404","cmux-gcp-secret-jit-x64"]'
    "'), vars.CI_TRUSTED_RUNNER) && vars.CI_TRUSTED_RUNNER || 'blacksmith-2vcpu-ubuntu-2404' }}"
)
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import check_repo_variables as check  # noqa: E402
import cloud_overflow_switch as switch  # noqa: E402
sys.path.insert(0, str(ROOT / "tests"))
from test_ci_fork_runner_routing import (  # noqa: E402
    ADVERSARIAL_VARIABLE_VALUES, evaluate_runs_on, parse_expression, runner_label_errors)
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
            labels = (*switch.HEALTH_LABELS, DRILL)
            return [{**self.probe, "name": switch.probe_job_name(label)} for label in labels] if self.probe else []
        return self.run_jobs.get(run_id, [])

    def runs(self, status: str, event: str | None = None, *, created_before: dt.datetime | None = None) -> list[dict]:
        return [run for run in self.in_flight
                if run.get("status") == status and (event is None or run.get("event") == event)
                and (created_before is None or switch.parse_time(run.get("created_at")) <= created_before)]

    def run(self, run_id: int) -> dict:
        return {"id": run_id, "status": self.status.get(run_id, "in_progress")}

    def force_cancel(self, run_id: int) -> None:
        self.calls.append(("force-cancel", run_id))
        self.status[run_id] = "completed"

    def rerun(self, run_id: int) -> None:
        self.calls.append(("rerun", run_id))


class FakeSwitch:
    """The App token side: variable writes, in order."""

    def __init__(self, variables: dict[str, str] | None = None) -> None:
        self.variables = variables or {}
        self.writes: list[tuple[str, str | None]] = []
        self.health: list[dict] = []  # CI_CLOUD_LABEL_HEALTH, kept apart from the routing writes

    def get_variable(self, name: str) -> str | None:
        return self.variables.get(name)

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


# feat-cmux-next's signing jobs read MACOS_RUNNER_26 (auto-resume-nightly-notarization.yml and friends);
# the switch's workflow checks those workflows out. This stands in for that checkout.
FEAT_WORKFLOWS = tempfile.TemporaryDirectory()
(Path(FEAT_WORKFLOWS.name) / "staple.yml").write_text(
    "on: workflow_dispatch\njobs:\n  staple:\n    environment: release\n"
    "    runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || vars.MACOS_RUNNER_26 || "
    "'blacksmith-6vcpu-macos-26' }}\n    steps:\n      - run: true\n", encoding="utf-8")
os.environ[signing.DIRS_ENV] = FEAT_WORKFLOWS.name


class SigningDerivationTests(unittest.TestCase):
    def write(self, directory: Path, name: str, text: str) -> None:
        (directory / name).write_text(text, encoding="utf-8")

    def test_derives_runs_on_variables_of_signing_jobs_only(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write(root, "a.yml", (
                "on: push\njobs:\n"
                "  sign:\n    runs-on: ${{ vars.MACOS_RUNNER_PR || 'blacksmith-6vcpu-macos-26' }}\n"
                "    steps:\n      - run: echo ${{ secrets.APPLE_CERTIFICATE_BASE64 }}\n"
                "  publish:\n    environment: release-next\n"
                "    runs-on: ${{ vars.CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-4vcpu-ubuntu-2404' || vars['Linux_Runner'] }}\n"
                "    steps:\n      - run: true\n"
                "  test:\n    runs-on: ${{ vars.MACOS_RUNNER_15 || 'blacksmith-6vcpu-macos-15' }}\n"
                "    steps:\n      - run: echo ${{ secrets.CODECOV_TOKEN }}\n"))
            self.assertEqual(signing.derive([root]), {"MACOS_RUNNER_PR", "LINUX_RUNNER"})

    def test_a_missing_directory_fails_closed(self) -> None:
        env = {signing.DIRS_ENV: "/nonexistent/workflows"}
        self.assertIsNone(signing.signing_variables(env))
        self.assertTrue(signing.is_signing_variable("MACOS_RUNNER_PR", env))
        self.assertFalse(signing.allowed_value("MACOS_RUNNER_IOS", "glaeda-ios-sim", env))
        self.assertTrue(signing.allowed_value("CI_LIGHT_LANE_RUNNER", "glaeda-side-light-xcode-26.6", env))

    def test_this_tree_and_feat_together(self) -> None:
        derived = signing.signing_variables()
        # main: every job with a secret runs on a fixed label or the bounded LINUX_RUNNER selector
        # (test_ci_fork_runner_routing.py), so no signing job reads MACOS_RUNNER_15 any more; the
        # stand-in feat-cmux-next workflow reads MACOS_RUNNER_26.
        self.assertIn("MACOS_RUNNER_26", derived)
        self.assertNotIn("MACOS_RUNNER_15", derived)

    def test_the_switch_and_checker_read_feat_cmux_next(self) -> None:
        for name in ("ci-cloud-overflow-probe.yml", "ci-repo-variables.yml"):
            text = (ROOT / ".github" / "workflows" / name).read_text(encoding="utf-8")
            self.assertIn("ref: feat-cmux-next", text, name)
            self.assertIn(f"{signing.DIRS_ENV}: .signing-workflows/feat-cmux-next/.github/workflows", text, name)

    def test_a_derived_variable_never_gets_an_owned_failover(self) -> None:
        values, _ = switch.failover_values(PIN, "")
        for name in signing.signing_variables():
            if name in values:
                self.assertTrue(signing.ephemeral_label(values[name]), (name, values[name]))
        self.assertNotIn("MACOS_RUNNER_26", values)
        # No signing job reads MACOS_RUNNER_15 now, so it fails over to the owned std pool like _PR.
        self.assertEqual(values["MACOS_RUNNER_15"], "glaeda-std-xcode-26.6")
        self.assertEqual(values["MACOS_RUNNER_PR"], "glaeda-std-xcode-26.6")


class FailoverTests(unittest.TestCase):
    def test_failover_is_derived_from_the_lane_pin(self) -> None:
        values, problems = switch.failover_values(PIN, "")
        self.assertEqual(problems, [])
        # Another Blacksmith Linux size, never GitHub-hosted Ubuntu (Leo, 2026-10-27).
        self.assertEqual(values["LINUX_RUNNER"], "blacksmith-16vcpu-ubuntu-2404")
        # The merge-gating checks' readers accept only the 2 and 4 vCPU Blacksmith labels.
        self.assertEqual(values["CI_TRUSTED_RUNNER"], "blacksmith-2vcpu-ubuntu-2404")
        for name in switch.STD_VARIABLES:
            if signing.is_signing_variable(name):
                self.assertNotIn(name, values)  # a signing job reads it (read from the workflows)
            else:
                self.assertEqual(values[name], "glaeda-std-xcode-26.6")
        self.assertEqual(values["MACOS_RUNNER_DISPLAY"], "glaeda-gui-std-xcode-26.6")
        self.assertEqual(values["MACOS_RUNNER_IOS"], "glaeda-ios-sim")
        self.assertEqual(values["CI_PAID_MACOS_OVERFLOW"], "1")
        # Moving the pin moves the failover: nothing names 26.6 itself.
        moved, _ = switch.failover_values("/Applications/Xcode_27.0.app", "")
        self.assertEqual(moved["MACOS_RUNNER_PR"], "glaeda-std-xcode-27.0")

    def test_the_sdk_15_lane_has_no_owned_failover(self) -> None:
        # swift-package-tests builds the Release helper against an SDK 15 Xcode on a
        # full suite; the minis have none, so the std pool fails it at once
        # ("No Xcode.app found under /Applications with macOS SDK major 15").
        values, _ = switch.failover_values(PIN, "")
        self.assertNotIn("MACOS_RUNNER_DUAL_XCODE", values)
        changed = switch.plan_off({"MACOS_RUNNER_DUAL_XCODE": "blacksmith-6vcpu-macos-15"}, values)
        self.assertNotIn("MACOS_RUNNER_DUAL_XCODE", changed)
        # A record written before this still restores it.
        self.assertIn("MACOS_RUNNER_DUAL_XCODE", switch.SWITCHED_VARIABLES)

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
            "MACOS_RUNNER_DUAL_XCODE": "glaeda-side-std-xcode-26.6", "MACOS_RUNNER_26_LARGE": "",
            "MACOS_RUNNER_26": "blacksmith-12vcpu-macos-26", "CI_CLOUD_OVERFLOW_SAVED": "x",
            "CI_PR_POOL_OWNED": "0", "MACOS_RUNNER_PR": "macos-15"}))
        self.assertEqual(values["MACOS_RUNNER_DUAL_XCODE"], "glaeda-side-std-xcode-26.6")
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
        # CI_TRUSTED_RUNNER's readers accept the 2 and 4 vCPU labels and the one-job GCP JIT label.
        values, problems = switch.failover_values(PIN, json.dumps({"CI_TRUSTED_RUNNER": "blacksmith-16vcpu-ubuntu-2404"}))
        self.assertEqual(values["CI_TRUSTED_RUNNER"], "blacksmith-2vcpu-ubuntu-2404")
        self.assertEqual(len(problems), 1)
        values, problems = switch.failover_values(PIN, json.dumps({"CI_TRUSTED_RUNNER": "glaeda-std-xcode-26.6"}))
        self.assertEqual((values["CI_TRUSTED_RUNNER"], len(problems)), ("blacksmith-2vcpu-ubuntu-2404", 1))
        values, problems = switch.failover_values(PIN, json.dumps({"CI_TRUSTED_RUNNER": "blacksmith-4vcpu-ubuntu-2404"}))
        self.assertEqual((values["CI_TRUSTED_RUNNER"], problems), ("blacksmith-4vcpu-ubuntu-2404", []))
        values, problems = switch.failover_values(PIN, json.dumps({"CI_TRUSTED_RUNNER": SECRET_JIT_LABEL}))
        self.assertEqual((values["CI_TRUSTED_RUNNER"], problems), (SECRET_JIT_LABEL, []))

    def test_trusted_runner_on_the_gcp_jit_label_never_follows_probe_health(self) -> None:
        # Leo, 2026-11-19, on Blacksmith: "stop ... relying on it". No probe asks for the one-job GCP JIT label and
        # a Blacksmith outage does not stall it: the switch never moves CI_TRUSTED_RUNNER off it, keeps an override
        # to it, and puts a recorded value of it back whichever Blacksmith sizes started.
        failover = {"LINUX_RUNNER": switch.LINUX_FAILOVER, "CI_TRUSTED_RUNNER": switch.TRUSTED_FAILOVER}
        self.assertNotIn("CI_TRUSTED_RUNNER", switch.plan_off({"CI_TRUSTED_RUNNER": SECRET_JIT_LABEL}, failover))
        kept = switch.toward_started({"CI_TRUSTED_RUNNER": SECRET_JIT_LABEL}, [])
        self.assertEqual(kept, {"CI_TRUSTED_RUNNER": SECRET_JIT_LABEL})
        # LINUX_RUNNER is not the trusted variable: the label earns it no pass.
        self.assertEqual(switch.toward_started({"LINUX_RUNNER": SECRET_JIT_LABEL}, []), {})
        record = {"changed": {"CI_TRUSTED_RUNNER": {"before": SECRET_JIT_LABEL,
                                                    "after": "blacksmith-2vcpu-ubuntu-2404"}}}
        restores = switch.plan_on(record, {"CI_TRUSTED_RUNNER": "blacksmith-2vcpu-ubuntu-2404"},
                                  ["blacksmith-16vcpu-ubuntu-2404"])
        self.assertEqual(restores, [switch.Restore("CI_TRUSTED_RUNNER", SECRET_JIT_LABEL)])
        record = {"changed": {"CI_TRUSTED_RUNNER": {"before": None, "after": SECRET_JIT_LABEL}}}
        resumes = switch.plan_resume(record, {"CI_TRUSTED_RUNNER": None}, [], failover)
        self.assertEqual([(item.name, item.value, item.skipped) for item in resumes],
                         [("CI_TRUSTED_RUNNER", SECRET_JIT_LABEL, "")])

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
        # Read from the workflows: this tree's signing jobs, and the feat-cmux-next one the fixture stands in for.
        derived = signing.signing_variables()
        self.assertIn("MACOS_RUNNER_26", derived)
        self.assertIn("LINUX_RUNNER", derived)
        self.assertNotIn("CI_CLOUD_OVERFLOW_SAVED", derived)

    def test_no_failover_names_a_reused_machine_for_a_signing_variable(self) -> None:
        overrides = ("", json.dumps({"MACOS_RUNNER_26": "glaeda-std-xcode-26.6",
                                     "LINUX_RUNNER": "cmux-linux-owned"}))
        for pin in self.PINS:
            for override in overrides:
                values, problems = switch.failover_values(pin, override)
                for name in signing.signing_variables():
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
            "MACOS_RUNNER_DUAL_XCODE": None,  # unset: its readers fall back to Blacksmith
            "MACOS_RUNNER_26": "macos-26",  # someone chose GitHub-hosted: left alone
            "MACOS_RUNNER_IOS": "glaeda-ios-sim",  # already at its failover: not recorded
            "CI_PAID_MACOS_OVERFLOW": None,
        }, failover)
        self.assertEqual(changed["LINUX_RUNNER"], {"before": "blacksmith-4vcpu-ubuntu-2404",
                                                   "after": "blacksmith-16vcpu-ubuntu-2404"})
        # No owned pool carries the SDK 15 Xcode swift-package-tests' Release helper needs: left unset.
        self.assertNotIn("MACOS_RUNNER_DUAL_XCODE", changed)
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
        self.assertEqual(switch.PROBE_LABELS, ("blacksmith-4vcpu-ubuntu-2404", "blacksmith-16vcpu-ubuntu-2404"))

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
        # With no Linux size serving, a Linux job has nowhere to go; a macOS one still moves to the owned pool.
        self.assertIsNone(switch.stuck_job(on_failover, NOW, 5, linux_moves=False))
        on_mac = [{"status": "queued", "labels": ["blacksmith-6vcpu-macos-26"], "created_at": ago(30)}]
        self.assertIsNotNone(switch.stuck_job(on_mac, NOW, 5, linux_moves=False))
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
        queued = [{"status": "queued", "labels": ["blacksmith-6vcpu-macos-26"], "created_at": ago(35)}]
        linux = {"id": 9, "status": "queued", "event": "pull_request", "name": "CI", "run_attempt": 1,
                 "created_at": ago(35)}
        on_linux = [{"status": "queued", "labels": ["blacksmith-4vcpu-ubuntu-2404"], "created_at": ago(35)}]
        actions = FakeActions(probe_job(0), [stuck, merge, linux], {7: queued, 8: queued, 9: on_linux})
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
        # Run 9 waits on Blacksmith Linux, and no Linux size started: a re-run would land on the same
        # label, so it is left alone instead of being cancelled on every scheduled run.
        self.assertEqual(actions.calls, [("force-cancel", 7), ("rerun", 7)])
        self.assertIn("merge_group run", summary)

    def test_a_started_probe_restores_and_deletes_the_record(self) -> None:
        record = {"since": ago(60), "probe": "blacksmith-32vcpu-ubuntu-2404", "changed": {
            "LINUX_RUNNER": {"before": "blacksmith-32vcpu-ubuntu-2404", "after": "blacksmith-16vcpu-ubuntu-2404"},
            "CI_PAID_MACOS_OVERFLOW": {"before": None, "after": "1"},
            "MACOS_RUNNER_PR": {"before": "blacksmith-6vcpu-macos-26", "after": "glaeda-std-xcode-26.6"}}}
        env = {"VAR_CI_CLOUD_OVERFLOW_SAVED": json.dumps(record), "VAR_LINUX_RUNNER": "blacksmith-16vcpu-ubuntu-2404",
               "VAR_CI_PAID_MACOS_OVERFLOW": "1", "VAR_MACOS_RUNNER_PR": "macos-26",
               "VAR_CMUX_CI_XCODE_APP_PR": PIN}
        actions, writer = FakeActions(probe_job(0, status="in_progress", runner_name="bs-1")), FakeSwitch()
        code, out, summary = run_main(env, actions, writer)
        self.assertEqual(code, 0)
        self.assertIn("outcome=started", out)
        # Review of this change: 32 vCPU is no longer probed and may still be stalled, so LINUX_RUNNER stays
        # on the 16 vCPU size whose probe started rather than going back to a label nobody watches.
        self.assertEqual(writer.writes, [("CI_PAID_MACOS_OVERFLOW", None), ("CI_CLOUD_OVERFLOW_SAVED", None)])
        self.assertIn("stays blacksmith-16vcpu-ubuntu-2404; its value before, blacksmith-32vcpu-ubuntu-2404", summary)
        self.assertIn("left alone", summary)
        # A before that is a probed size goes back as before.
        restores = switch.plan_on({"changed": {"LINUX_RUNNER": {
            "before": "blacksmith-4vcpu-ubuntu-2404", "after": "blacksmith-16vcpu-ubuntu-2404"}}},
            {"LINUX_RUNNER": "blacksmith-16vcpu-ubuntu-2404"}, switch.PROBE_LABELS)
        self.assertEqual([(r.name, r.value, r.skipped) for r in restores],
                         [("LINUX_RUNNER", "blacksmith-4vcpu-ubuntu-2404", "")])
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

    def test_a_stalled_record_never_replays_a_variable_with_no_failover(self) -> None:
        # 2026-11-16: the record holds MACOS_RUNNER_DUAL_XCODE -> the std pool, which has no SDK 15
        # Xcode. Put back by hand to its recorded before, the next stalled probe must not re-apply it.
        record = {"since": ago(60), "probe": "blacksmith-4vcpu-ubuntu-2404", "changed": {
            "MACOS_RUNNER_DUAL_XCODE": {"before": None, "after": "glaeda-std-xcode-26.6"},
            "MACOS_RUNNER_PR": {"before": "blacksmith-6vcpu-macos-26", "after": "glaeda-std-xcode-26.6"}}}
        env = {"VAR_CI_CLOUD_OVERFLOW_SAVED": json.dumps(record),
               "VAR_MACOS_RUNNER_PR": "blacksmith-6vcpu-macos-26", "VAR_CMUX_CI_XCODE_APP_PR": PIN}
        writer = FakeSwitch()
        code, _, summary = run_main(env, FakeActions(probe_job(0)), writer)
        self.assertEqual(code, 0)
        self.assertEqual(writer.writes, [("MACOS_RUNNER_PR", "glaeda-std-xcode-26.6")])
        self.assertIn("MACOS_RUNNER_DUAL_XCODE: no failover", summary)
        # The record still restores it once Blacksmith serves.
        restores = {r.name: r for r in switch.plan_on(record, {"MACOS_RUNNER_DUAL_XCODE": "glaeda-std-xcode-26.6"})}
        self.assertEqual((restores["MACOS_RUNNER_DUAL_XCODE"].value, restores["MACOS_RUNNER_DUAL_XCODE"].skipped),
                         (None, ""))

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
        # Only 4 vCPU started: the chain moves on to it.
        self.assertEqual(switch.toward_started({"LINUX_RUNNER": "blacksmith-16vcpu-ubuntu-2404"},
                                               ["blacksmith-4vcpu-ubuntu-2404"]),
                         {"LINUX_RUNNER": "blacksmith-4vcpu-ubuntu-2404"})
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
        # Every size but the first starts.
        rest = [{**started, "name": switch.probe_job_name(label)} for label in switch.PROBE_LABELS[1:]]
        self.assertEqual(switch.probe_set_outcome([stalled, *rest], switch.PROBE_LABELS, NOW, 5),
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
        code, out, _ = run_main(env, FakeActions([stalled, *rest]), writer)
        self.assertEqual((code, writer.writes), (0, []))
        self.assertIn("outcome=partial", out)
        # Nor does it turn overflow off when there is no record.
        writer = FakeSwitch()
        code, out, _ = run_main(BLACKSMITH_STEADY, FakeActions([stalled, *rest]), writer)
        self.assertEqual((code, writer.writes), (0, []))
        # Per-label health is written either way, for the pool reconciler to read.
        self.assertEqual(writer.health[-1]["labels"], {switch.PROBE_LABELS[0]: "stalled",
                                                       **{label: "started" for label in switch.PROBE_LABELS[1:]}})
        self.assertEqual(writer.health[-1]["run"], "https://github.com/manaflow-ai/cmux/actions/runs/1")
        # Every size started: the record is put back and deleted.
        writer = FakeSwitch()
        code, out, _ = run_main(env, FakeActions(up), writer)
        self.assertIn("outcome=started", out)
        self.assertEqual(writer.writes, [("MACOS_RUNNER_PR", "blacksmith-6vcpu-macos-26"),
                                         ("CI_CLOUD_OVERFLOW_SAVED", None)])

    def test_health_only_probes_report_but_never_decide(self) -> None:
        # 2026-11-18: 32 vCPU started nothing from about 23:12Z while RUNNER_POOLS kept linux_16 and linux_32
        # on it, because no probe asked for it. The extra sizes are probed for CI_CLOUD_LABEL_HEALTH only:
        # the overflow decision still reads PROBE_LABELS alone.
        started = {**probe_job(6, runner_name="bs-1", status="in_progress")}
        stalled = probe_job(6)
        extra = [label for label in switch.HEALTH_LABELS if label not in switch.PROBE_LABELS]
        self.assertIn("blacksmith-32vcpu-ubuntu-2404", extra)
        jobs = [{**started, "name": switch.probe_job_name(label)} for label in switch.PROBE_LABELS]
        jobs += [{**(stalled if label == "blacksmith-32vcpu-ubuntu-2404" else started),
                  "name": switch.probe_job_name(label)} for label in extra]
        record = {"since": ago(60), "probe": "blacksmith-4vcpu-ubuntu-2404", "changed": {
            "MACOS_RUNNER_PR": {"before": "blacksmith-6vcpu-macos-26", "after": "glaeda-std-xcode-26.6"}}}
        env = {"VAR_CI_CLOUD_OVERFLOW_SAVED": json.dumps(record), "VAR_MACOS_RUNNER_PR": "glaeda-std-xcode-26.6",
               "VAR_CMUX_CI_XCODE_APP_PR": PIN}
        writer = FakeSwitch()
        code, out, _ = run_main(env, FakeActions(jobs), writer)
        self.assertEqual(code, 0)
        # The decision probes all started: overflow comes back on, whatever 32 vCPU does.
        self.assertIn("outcome=started", out)
        self.assertEqual(writer.writes, [("MACOS_RUNNER_PR", "blacksmith-6vcpu-macos-26"),
                                         ("CI_CLOUD_OVERFLOW_SAVED", None)])
        self.assertEqual(writer.health[-1]["labels"]["blacksmith-32vcpu-ubuntu-2404"], "stalled")
        self.assertEqual(writer.health[-1]["labels"]["blacksmith-8vcpu-ubuntu-2404"], "started")
        # A probe is still queued, so the run must end itself and free the concurrency group.
        self.assertIn("all_started=false", out)
        writer = FakeSwitch()
        _, out, _ = run_main(env, FakeActions([{**job, **started, "name": job["name"]} for job in jobs]), writer)
        self.assertIn("all_started=true", out)
        self.assertEqual(set(writer.health[-1]["labels"]), set(switch.HEALTH_LABELS))
        # A health-only probe that never shows up decides nothing and is left out of the health.
        writer = FakeSwitch()
        _, out, _ = run_main(env, FakeActions(jobs[:len(switch.PROBE_LABELS)]), writer)
        self.assertIn("outcome=started", out)
        self.assertIn("all_started=false", out)
        self.assertEqual(set(writer.health[-1]["labels"]), set(switch.PROBE_LABELS))

    def test_a_partial_result_writes_nothing_but_health(self) -> None:
        # Review at 437df955 and edbbce33: per-size moves belong to the RUNNER_POOLS reconciler, which
        # reads CI_CLOUD_LABEL_HEALTH. The switch neither flips nor writes a record on a partial result.
        stalled = probe_job(6)
        started = {**probe_job(6, runner_name="bs-1", status="in_progress"),
                   "name": switch.probe_job_name(switch.PROBE_LABELS[1])}
        rest = [{**started, "name": switch.probe_job_name(label)} for label in switch.PROBE_LABELS[1:]]
        env = {"VAR_LINUX_RUNNER": "blacksmith-4vcpu-ubuntu-2404", "VAR_MACOS_RUNNER_PR": "blacksmith-6vcpu-macos-26",
               "VAR_CMUX_CI_XCODE_APP_PR": PIN}
        writer = FakeSwitch()
        code, out, _ = run_main(env, FakeActions([stalled, *rest]), writer)
        self.assertEqual((code, writer.writes), (0, []))
        self.assertIn("outcome=partial", out)
        self.assertEqual(writer.health[-1]["labels"][switch.PROBE_LABELS[0]], "stalled")

    def test_a_restore_goes_back_only_onto_a_size_that_started(self) -> None:
        # Review at 437df955: a legacy CI_TRUSTED_RUNNER record (before a size that is not probed).
        record = {"changed": {
            "CI_TRUSTED_RUNNER": {"before": "blacksmith-2vcpu-ubuntu-2404", "after": "blacksmith-4vcpu-ubuntu-2404"},
            "LINUX_RUNNER": {"before": None, "after": "blacksmith-16vcpu-ubuntu-2404"},
            "MACOS_RUNNER_PR": {"before": "blacksmith-6vcpu-macos-26", "after": "glaeda-std-xcode-26.6"},
            "MACOS_RUNNER_15": {"before": "macos-15", "after": "glaeda-std-xcode-26.6"}}}
        current = {"CI_TRUSTED_RUNNER": "blacksmith-4vcpu-ubuntu-2404", "LINUX_RUNNER": "blacksmith-16vcpu-ubuntu-2404",
                   "MACOS_RUNNER_PR": "glaeda-std-xcode-26.6", "MACOS_RUNNER_15": "glaeda-std-xcode-26.6"}
        restores = {r.name: r for r in switch.plan_on(record, current, switch.PROBE_LABELS)}
        self.assertTrue(restores["CI_TRUSTED_RUNNER"].skipped)
        self.assertTrue(restores["LINUX_RUNNER"].skipped)  # unset falls back to an unprobed literal
        self.assertFalse(restores["MACOS_RUNNER_PR"].skipped)
        self.assertTrue(restores["MACOS_RUNNER_15"].skipped)  # GitHub-hosted is never put back

    def test_a_recovered_legacy_hosted_record_never_leaves_linux_on_hosted(self) -> None:
        # Review at cd797966: before was the unprobed 4 vCPU, after GitHub-hosted Ubuntu. Every size starts,
        # the record is deleted, and LINUX_RUNNER must not stay on hosted Ubuntu.
        record = {"since": ago(60), "probe": "blacksmith-4vcpu-ubuntu-2404", "changed": {
            "LINUX_RUNNER": {"before": "blacksmith-4vcpu-ubuntu-2404", "after": "ubuntu-24.04"},
            "CI_TRUSTED_RUNNER": {"before": None, "after": "ubuntu-24.04"}}}
        started = probe_job(0, status="in_progress", runner_name="bs-1")
        up = [{**started, "name": switch.probe_job_name(label)} for label in switch.PROBE_LABELS]
        env = {"VAR_CI_CLOUD_OVERFLOW_SAVED": json.dumps(record), "VAR_LINUX_RUNNER": "ubuntu-24.04",
               "VAR_CI_TRUSTED_RUNNER": "ubuntu-24.04", "VAR_CMUX_CI_XCODE_APP_PR": PIN}
        writer = FakeSwitch()
        code, out, _ = run_main(env, FakeActions(up), writer)
        self.assertEqual(code, 0)
        self.assertIn("outcome=started", out)
        self.assertEqual(writer.writes, [("CI_TRUSTED_RUNNER", None),
                                         ("LINUX_RUNNER", switch.PROBE_LABELS[0]),
                                         ("CI_CLOUD_OVERFLOW_SAVED", None)])
        # Even an entry changed by hand to hosted Ubuntu since is moved, not left behind.
        restores = {r.name: r for r in switch.plan_on(
            {"changed": {"LINUX_RUNNER": {"before": None, "after": "blacksmith-16vcpu-ubuntu-2404"}}},
            {"LINUX_RUNNER": "ubuntu-24.04"}, switch.PROBE_LABELS)}
        self.assertEqual((restores["LINUX_RUNNER"].value, restores["LINUX_RUNNER"].skipped),
                         (switch.PROBE_LABELS[0], ""))

    def test_no_code_path_writes_a_hosted_label(self) -> None:
        # Leo, 2026-10-28: "most of what GitHub has is hilariously slow. We can't be using them."
        self.assertFalse(hasattr(switch, "HOSTED_LINUX"))
        hosted = re.compile(r"^(ubuntu-|macos-|windows-)")
        stalled = probe_job(6)
        started = {**probe_job(6, runner_name="bs-1", status="in_progress"),
                   "name": switch.probe_job_name(switch.PROBE_LABELS[1])}
        up = [{**started, "name": switch.probe_job_name(label)} for label in switch.PROBE_LABELS]
        legacy = {"since": ago(60), "probe": "blacksmith-4vcpu-ubuntu-2404", "changed": {
            "LINUX_RUNNER": {"before": "ubuntu-24.04", "after": "ubuntu-24.04"},
            "CI_TRUSTED_RUNNER": {"before": "ubuntu-24.04", "after": "blacksmith-2vcpu-ubuntu-2404"},
            "MACOS_RUNNER_15": {"before": "macos-15", "after": "glaeda-std-xcode-26.6"}}}
        envs = [BLACKSMITH_STEADY, {"VAR_CMUX_CI_XCODE_APP_PR": PIN},
                {**BLACKSMITH_STEADY, "VAR_CI_CLOUD_FAILOVER": json.dumps({"LINUX_RUNNER": "ubuntu-24.04",
                                                                          "MACOS_RUNNER_15": "macos-15"})},
                {"VAR_CI_CLOUD_OVERFLOW_SAVED": json.dumps(legacy), "VAR_LINUX_RUNNER": "ubuntu-24.04",
                 "VAR_CI_TRUSTED_RUNNER": "blacksmith-2vcpu-ubuntu-2404",
                 "VAR_MACOS_RUNNER_15": "glaeda-std-xcode-26.6", "VAR_CMUX_CI_XCODE_APP_PR": PIN},
                {"VAR_LINUX_RUNNER": "blacksmith-32vcpu-ubuntu-2404", "VAR_CMUX_CI_XCODE_APP_PR": PIN}]
        for env in envs:
            for probes in (probe_job(0), [stalled, started], up):
                writer = FakeSwitch()
                run_main(env, FakeActions(probes), writer)
                for name, value in writer.writes:
                    if name == switch.RECORD_VARIABLE or value is None:
                        continue
                    self.assertFalse(hosted.match(value.lower()), (env, name, value))

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



class PythonDependencyTests(unittest.TestCase):
    def test_watch_bootstraps_yaml_in_a_job_local_environment(self) -> None:
        # Execute the workflow's actual shell command with a clean Python stand-in:
        # it cannot import YAML until the pinned installation has completed.
        workflow = yaml.safe_load(WORKFLOW.read_text())
        step = next(step for step in workflow["jobs"]["watch"]["steps"] if step.get("id") == "switch")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            binaries = root / "bin"
            binaries.mkdir()
            fake = binaries / "python3"
            fake.write_text(f"#!{sys.executable}\n" + textwrap.dedent("""\
                import json, os, pathlib, sys
                root = pathlib.Path(os.environ['PYTHON_FIXTURE_ROOT'])
                args = sys.argv[1:]
                with (root / 'events').open('a') as out:
                    out.write(json.dumps([sys.executable, *args]) + '\\n')
                if args == ['-c', 'import yaml']:
                    raise SystemExit(0 if (root / 'installed').exists() else 1)
                if args[:2] == ['-m', 'venv']:
                    target = pathlib.Path(args[2]) / 'bin' / 'python'
                    target.parent.mkdir(parents=True)
                    target.write_text(pathlib.Path(__file__).read_text())
                    target.chmod(0o755)
                elif args[:3] == ['-m', 'pip', 'install']:
                    if 'PyYAML==6.0.3' not in args:
                        raise SystemExit('expected pinned PyYAML')
                    (root / 'installed').touch()
                elif args == ['scripts/ci/cloud_overflow_switch.py']:
                    if not (root / 'installed').exists():
                        raise SystemExit("ModuleNotFoundError: No module named 'yaml'")
                    (root / 'executed').touch()
                else:
                    raise SystemExit('unexpected python call: ' + repr(args))
                """))
            fake.chmod(0o755)
            result = subprocess.run(['bash', '-euo', 'pipefail', '-c', step['run']], cwd=ROOT,
                                    env={**os.environ, 'PATH': f'{binaries}:{os.environ["PATH"]}',
                                         'RUNNER_TEMP': str(root / 'runner'), 'PYTHON_FIXTURE_ROOT': str(root),
                                         'GITHUB_PATH': str(root / 'github-path')},
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue((root / 'executed').exists())
            self.assertTrue((root / 'installed').exists())


class DeadLabelRescueTests(unittest.TestCase):
    """2026-11-18: 4, 8 and 16 vCPU marked dead, 2 and 32 vCPU serving; the tree owners stayed queued."""

    # As runner_pools.py leaves it: every Linux pool moved off its dead member; macos_26 still on a
    # dead label (no other size of its image is live), so a re-run would come back to it.
    POOLS = {"_dead": {"blacksmith-16vcpu-ubuntu-2404": "2026-09-29T11:00:00Z",
                       "blacksmith-4vcpu-ubuntu-2404": "2026-09-29T11:00:00Z",
                       "blacksmith-6vcpu-macos-26": "2026-09-29T11:00:00Z"},
             "_spill": {"linux": {"from": "blacksmith-4vcpu-ubuntu-2404", "running": 3}},
             "linux": "blacksmith-2vcpu-ubuntu-2404", "linux_16": "blacksmith-32vcpu-ubuntu-2404",
             "linux_4": "blacksmith-2vcpu-ubuntu-2404", "macos_26": "blacksmith-6vcpu-macos-26"}
    DEAD_16 = {"status": "queued", "runner_name": None, "created_at": ago(45),
               "labels": ["blacksmith-16vcpu-ubuntu-2404"], "name": "build"}

    def stranded(self) -> FakeActions:
        runs = [{"id": 10, "status": "queued", "event": "push", "name": "cmux-tui artifacts",
                 "created_at": ago(90), "run_attempt": 1},
                {"id": 11, "status": "queued", "event": "pull_request", "name": "CI", "created_at": ago(60)},
                {"id": 12, "status": "in_progress", "event": "push", "name": "CI", "created_at": ago(50)},
                {"id": 13, "status": "queued", "event": "push", "name": "Publish docs", "created_at": ago(40)},
                {"id": 14, "status": "queued", "event": "push", "name": "Nightly signing", "created_at": ago(40)},
                {"id": 15, "status": "queued", "event": "push", "name": "Cloud VM image promote",
                 "created_at": ago(40)},
                {"id": 16, "status": "queued", "event": "push", "name": "CI", "created_at": ago(40),
                 "run_attempt": 2}]
        dead = self.DEAD_16
        jobs = {10: [dead],
                # macos_26 still names its dead label: a re-run comes back to it.
                11: [{**dead, "labels": ["blacksmith-6vcpu-macos-26"]}],
                # Queued on a live size: waiting its turn, not stranded.
                12: [{**dead, "labels": ["blacksmith-2vcpu-ubuntu-2404"]}],
                13: [dead], 14: [dead], 15: [dead],
                # Already re-run once (by this step or by hand): its runs-on may name the dead label.
                16: [dead]}
        return FakeActions(None, runs, jobs)

    def rescue(self, actions: FakeActions, pools: dict | None = None, **env: str) -> str:
        writer = FakeSwitch({"RUNNER_POOLS": json.dumps(pools or self.POOLS)})
        code, _, summary = run_main({"GH_TOKEN": "t", **env}, actions, writer, argv=["--rescue-dead"])
        self.assertEqual(code, 0)
        self.assertEqual(writer.writes, [])
        return summary

    def test_dead_labels_are_the_marked_ones_no_pool_names(self) -> None:
        self.assertEqual(switch.dead_labels(self.POOLS),
                         {"blacksmith-16vcpu-ubuntu-2404", "blacksmith-4vcpu-ubuntu-2404"})
        self.assertEqual(switch.dead_labels({"_dead": "x"}), set())
        self.assertEqual(switch.dead_labels({}), set())

    def test_reruns_the_cancelled_jobs_of_runs_stranded_on_a_dead_label_once(self) -> None:
        actions = self.stranded()
        summary = self.rescue(actions)
        # Only the cancelled jobs re-run: jobs that already passed keep their result.
        self.assertEqual(actions.calls, [("force-cancel", 10), ("rerun", 10)])
        # Protected (publish, signing, promotion) and already re-run runs leave before the window is cut.
        for run in actions.in_flight:
            reason = switch.protected_reason(run, dead=True)
            self.assertEqual(bool(reason), run["id"] in (13, 14, 15, 16), run)
        self.assertNotIn("run 13", summary)

    def test_protected_and_retried_runs_never_fill_the_window(self) -> None:
        retried = [{"id": 100 + n, "status": "queued", "event": "push", "name": "CI", "created_at": ago(300 - n),
                    "run_attempt": 2} for n in range(switch.MAX_RUN_LISTINGS + 5)]
        fresh = {"id": 500, "status": "queued", "event": "push", "name": "cmux-tui artifacts", "created_at": ago(20)}
        jobs = {run["id"]: [self.DEAD_16] for run in [*retried, fresh]}
        actions = FakeActions(None, [*retried, fresh], jobs)
        self.rescue(actions)
        self.assertEqual(actions.calls, [("force-cancel", 500), ("rerun", 500)])

    def test_a_macos_label_is_never_rescued(self) -> None:
        # MACOS_RUNNER_* variables, which no pool step moves, can still name it.
        self.assertNotIn("blacksmith-6vcpu-macos-26",
                         switch.dead_labels({"_dead": {"blacksmith-6vcpu-macos-26": "x"}, "macos_26": "other"}))

    def test_a_read_timeout_is_a_failed_call(self) -> None:
        api = switch.GitHub("t", "o/r")
        def boom(*_: object) -> None:
            raise TimeoutError("read timed out")
        api._send = boom  # type: ignore[method-assign]
        with self.assertRaises(RuntimeError):
            api.run(1)

    def test_a_dry_run_bad_value_or_no_dead_label_touch_nothing(self) -> None:
        actions = self.stranded()
        self.rescue(actions, DRY_RUN="true")
        # No dead mark and every label a pool can point at still named by one: nothing is stranded.
        every = {f"p{n}": label for n, label in enumerate(switch.HEALTH_LABELS)}
        self.rescue(actions, {**self.POOLS, "_dead": {}, **every})
        writer = FakeSwitch({"RUNNER_POOLS": "not json"})
        self.assertEqual(run_main({"GH_TOKEN": "t"}, actions, writer, argv=["--rescue-dead"])[0], 0)
        self.assertEqual(actions.calls, [])

    def test_only_a_live_pool_read_may_cancel(self) -> None:
        # The job-start value predates the pools step: it may describe a pass (dry run), never cancel.
        actions = self.stranded()
        start = {"GH_TOKEN": "t", "RUNNER_POOLS": json.dumps(self.POOLS)}
        _, _, summary = run_main(start, actions, None, argv=["--rescue-dead"])
        self.assertEqual(actions.calls, [])
        self.assertIn("no live RUNNER_POOLS read", summary)
        _, _, summary = run_main({**start, "DRY_RUN": "true"}, actions, None, argv=["--rescue-dead"])
        self.assertEqual(actions.calls, [])
        self.assertIn("run 10 (cmux-tui artifacts, push)", summary)
        # A variable the API says is unset is a live read of nothing, not a fallback.
        writer = FakeSwitch({})
        run_main(start, actions, writer, argv=["--rescue-dead"])
        self.assertEqual(actions.calls, [])

    def test_a_run_mid_publish_is_left_alone(self) -> None:
        actions = self.stranded()
        actions.run_jobs[10] = [self.DEAD_16, {"name": "publish to R2", "status": "in_progress", "labels": []}]
        summary = self.rescue(actions)
        self.assertEqual(actions.calls, [])
        self.assertIn("`publish to R2` is running", summary)

    def test_a_run_that_changed_since_the_listing_is_left_alone(self) -> None:
        actions = self.stranded()
        actions.run = lambda run_id: {"id": run_id, "status": "queued", "run_attempt": 2}  # type: ignore[method-assign]
        summary = self.rescue(actions)
        self.assertEqual(actions.calls, [])
        self.assertIn("run 10: changed since it was listed", summary)

    def test_a_lost_cancel_answer_reruns_only_a_cancelled_run(self) -> None:
        for conclusion, expected in (("cancelled", [("rerun", 10)]), ("success", [])):
            actions = self.stranded()
            state = {"status": "queued"}
            actions.run = lambda run_id, state=state: {"id": run_id, **state}  # type: ignore[method-assign]
            def lost(run_id: int, state: dict = state, conclusion: str = conclusion) -> None:
                state.update(status="completed", conclusion=conclusion)
                raise RuntimeError(f"POST /actions/runs/{run_id}/force-cancel failed (TimeoutError)")
            actions.force_cancel = lost  # type: ignore[method-assign]
            self.rescue(actions)
            self.assertEqual(actions.calls, expected, conclusion)
        refused = self.stranded()
        def no(run_id: int) -> None:
            raise RuntimeError(f"POST /actions/runs/{run_id}/force-cancel failed (409)")
        refused.force_cancel = no  # type: ignore[method-assign]
        summary = self.rescue(refused)
        self.assertEqual(refused.calls, [])
        self.assertIn("force-cancel refused", summary)

    def test_pull_request_runs_keep_a_share_of_the_window(self) -> None:
        live = {**self.DEAD_16, "labels": ["blacksmith-2vcpu-ubuntu-2404"]}
        pushes = [{"id": 100 + n, "status": "queued", "event": "push", "name": "CI", "created_at": ago(300 - n)}
                  for n in range(switch.MAX_RUN_LISTINGS + 5)]
        pr = {"id": 700, "status": "queued", "event": "pull_request", "name": "CI", "created_at": ago(10)}
        jobs = {run["id"]: [live] for run in pushes}
        jobs[700] = [self.DEAD_16]
        actions = FakeActions(None, [*pushes, pr], jobs)
        self.rescue(actions)
        self.assertEqual(actions.calls, [("force-cancel", 700), ("rerun", 700)])

    def test_a_truncated_body_is_a_failed_call(self) -> None:
        import http.client
        api = switch.GitHub("t", "o/r")
        def cut(*_: object) -> None:
            raise http.client.IncompleteRead(b"{", 10)
        api._send = cut  # type: ignore[method-assign]
        with self.assertRaises(RuntimeError):
            api.run(1)

    def test_the_overflow_rescue_keeps_oldest_first_and_whole_reruns(self) -> None:
        # The all-stalled rescue is unchanged: no push-first order, a whole re-run, attempt 2 still moves.
        runs = [{"id": 20, "status": "queued", "event": "push", "name": "CI", "created_at": ago(30)},
                {"id": 21, "status": "queued", "event": "pull_request", "name": "CI", "created_at": ago(80),
                 "run_attempt": 2}]
        actions = FakeActions(None, runs, {20: [self.DEAD_16], 21: [self.DEAD_16]})
        clock = Clock()
        lines = switch.rescue_stuck_runs(actions, own_run_id=1, minutes=5, now=clock.now, sleep=clock.sleep,
                                         log=lambda _: None, dry_run=False)
        self.assertEqual(actions.calls, [("force-cancel", 21), ("force-cancel", 20), ("rerun", 21), ("rerun", 20)])
        self.assertTrue(any("run 21" in line for line in lines))
        logged: list[str] = []
        switch.rescue_stuck_runs(FakeActions(None, runs, {20: [self.DEAD_16]}), own_run_id=1, minutes=5,
                                 now=clock.now, sleep=clock.sleep, log=logged.append, dry_run=False)
        self.assertEqual(logged, [])  # the overflow rescue's output is unchanged

    def test_a_label_a_move_left_strands_its_jobs_too(self) -> None:
        # 2026-11-19: linux spilled to 16 vCPU and came back to 4, linux_16 moved to 8 vCPU; 16 vCPU carries no dead
        # mark, and cmux#45502's `changes` (run 44476854382) sat queued there from 07:04Z.
        pools = {"_dead": {}, "linux": "blacksmith-4vcpu-ubuntu-2404", "linux_16": "blacksmith-8vcpu-ubuntu-2404",
                 "linux_4": "blacksmith-4vcpu-ubuntu-2404", "linux_32": "blacksmith-32vcpu-ubuntu-2404",
                 "linux_2": "blacksmith-2vcpu-ubuntu-2404"}
        self.assertEqual(switch.stranded_labels(pools, minutes=5),
                         {"blacksmith-16vcpu-ubuntu-2404": switch.MOVED_MINUTES})
        # A raw runner variable that names it keeps it routed: a re-run would come back to it.
        self.assertEqual(switch.stranded_labels(pools, {"blacksmith-16vcpu-ubuntu-2404"}), {})
        # An unset or empty value names no pool: nothing reads as left.
        self.assertEqual(switch.stranded_labels({}), {})
        self.assertEqual(switch.stranded_labels({"_dead": {}}), {})
        # A dead mark keeps the probe's wait; a label a pool names is never stranded.
        self.assertEqual(switch.stranded_labels(self.POOLS, minutes=5),
                         {"blacksmith-16vcpu-ubuntu-2404": 5, "blacksmith-4vcpu-ubuntu-2404": 5,
                          "blacksmith-8vcpu-ubuntu-2404": switch.MOVED_MINUTES})
        changes = {**self.DEAD_16, "name": "changes", "created_at": ago(360)}
        fresh = {**self.DEAD_16, "created_at": ago(10)}
        runs = [{"id": 44476854382, "status": "queued", "event": "pull_request", "name": "cmux-tui spec inventory",
                 "created_at": ago(360)},
                {"id": 31, "status": "queued", "event": "pull_request", "name": "CI", "created_at": ago(10)}]
        actions = FakeActions(None, runs, {44476854382: [changes], 31: [fresh]})
        summary = self.rescue(actions, pools)
        self.assertEqual(actions.calls, [("force-cancel", 44476854382), ("rerun", 44476854382)])
        self.assertIn("blacksmith-16vcpu-ubuntu-2404 (30+ min)", summary)
        # Named by a raw runner variable: nothing moves.
        actions = FakeActions(None, runs, {44476854382: [changes], 31: [fresh]})
        self.rescue(actions, pools, RAW_RUNNER_VARIABLES="LINUX_BUILD_RUNNER=blacksmith-16vcpu-ubuntu-2404\nX=\n")
        self.assertEqual(actions.calls, [])

    def test_a_run_stranded_for_hours_is_listed_past_the_newest_page(self) -> None:
        pools = {"_dead": {}, "linux": "blacksmith-4vcpu-ubuntu-2404", "linux_16": "blacksmith-8vcpu-ubuntu-2404"}
        old = {"id": 900, "status": "queued", "event": "pull_request", "name": "CI", "created_at": ago(360)}
        actions = FakeActions(None, [old], {900: [{**self.DEAD_16, "created_at": ago(360)}]})
        newest_only = actions.runs
        # The newest page holds only newer runs; the old one is listed by the created-before slices alone.
        actions.runs = lambda status, event=None, *, created_before=None: (  # type: ignore[method-assign]
            newest_only(status, event, created_before=created_before) if created_before else [])
        self.rescue(actions, pools)
        self.assertEqual(actions.calls, [("force-cancel", 900), ("rerun", 900)])

    def test_the_rescue_step_reads_every_raw_runner_variable(self) -> None:
        sys.path.insert(0, str(ROOT / "scripts" / "ci"))
        import runner_pools  # noqa: E402
        step = WORKFLOW.read_text(encoding="utf-8").split("- name: Re-run runs stranded on a dead label", 1)[1]
        step = step.split("- name:", 1)[0]
        listed = set(re.findall(r"^\s+([A-Z0-9_]+)=\$\{\{ vars\.\1 \}\}$", step, re.MULTILINE))
        self.assertEqual(listed, {*runner_pools.RAW_LABEL_VARS, *runner_pools.MIRRORS})

    def test_the_workflow_runs_it_after_the_pools_step(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        pools = text.index("- name: Point the runner pools at live members")
        rescue = text.index("- name: Re-run runs stranded on a dead label")
        end = text.index("- name: End this run's stuck probe")
        self.assertLess(pools, rescue)
        self.assertLess(rescue, end)
        self.assertIn("cloud_overflow_switch.py --rescue-dead", text[rescue:end])
        self.assertIn("steps.pools.outcome == 'success'", text[rescue:end])


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
        # Every x64 Linux size a pool can point at, decision probes first (HEALTH_LABELS).
        self.assertEqual(tuple(listed), switch.HEALTH_LABELS)
        self.assertTrue(probe["runs-on"].endswith("|| matrix.label }}"))
        # Unless every probe started, the run ends itself, so a queued probe frees the group.
        self.assertIn("if: always() && steps.switch.outputs.all_started != 'true'", self.text)

    def test_watch_runs_off_blacksmith_and_passes_every_switched_variable(self) -> None:
        # Its own bounded selector, never a single label: on 2026-11-03 the literal
        # blacksmith-6vcpu-macos-26 was dead and the watch queued 19 minutes (run 41688532704),
        # so the hosted light rescue it carries ran every 20-25 minutes (cmuxterm-hq#6671).
        runs_on = re.search(r"name: Watch the probe and switch overflow\n(?:.*\n)*?\s+runs-on: (.*)", self.text).group(1)
        runs_on, _, comment = runs_on.partition(" # ")
        self.assertEqual(runs_on, WATCH_SELECTOR)
        self.assertTrue(comment.startswith("ephemeral-required:"), comment)
        self.assertEqual(runner_label_errors(runs_on), [])
        # Whatever CI_TRUSTED_RUNNER holds (unset, a stray value, a probed size the switch's
        # alternate failover may write, hosted Ubuntu set by hand), the watch never takes a size
        # the probes ask for, so it never queues beside a stalled probe and holds the group
        # (2026-10-28), and never GitHub-hosted Ubuntu: on 2026-10-27 the watch queued 94 minutes
        # there behind the switch's own failover.
        tree = parse_expression(runs_on[3:-2])
        values = {"", *ADVERSARIAL_VARIABLE_VALUES, *switch.PROBE_LABELS, switch.TRUSTED_FAILOVER,
                  *switch.ALTERNATE_FAILOVERS.values(), "blacksmith-2vcpu-ubuntu-2404",
                  "blacksmith-8vcpu-ubuntu-2404", "blacksmith-32vcpu-ubuntu-2404"}
        for value in sorted(values):
            # The repair label leads, whatever CI_TRUSTED_RUNNER holds; CI_REPAIR_SKIP_FLEET=1 leaves the pick.
            self.assertEqual(evaluate_runs_on(tree, {"github.repository_owner": "manaflow-ai",
                                                     "vars.CI_REPAIR_SKIP_FLEET": "",
                                                     "vars.CI_TRUSTED_RUNNER": value}), REPAIR_LABEL)
            label = evaluate_runs_on(tree, {"github.repository_owner": "manaflow-ai",
                                            "vars.CI_REPAIR_SKIP_FLEET": "1",
                                            "vars.CI_TRUSTED_RUNNER": value})
            with self.subTest(CI_TRUSTED_RUNNER=value):
                self.assertNotIn(label, switch.PROBE_LABELS)
                self.assertIn(label, {"blacksmith-2vcpu-ubuntu-2404", "blacksmith-8vcpu-ubuntu-2404"})
        names = set(switch.SWITCHED_VARIABLES) | {switch.RECORD_VARIABLE, switch.OVERRIDES_VARIABLE,
                                                  "CMUX_CI_XCODE_APP_PR"}
        for name in names:
            passed = (f"VAR_{name}: ${{{{ vars.{name} }}}}" in self.text
                      or f"            {name}=${{{{ vars.{name} }}}}\n" in self.text)
            self.assertTrue(passed, name)
        self.assertIn("force-cancel", self.text)

    def test_the_job_with_the_variable_write_key_runs_on_a_literal_ephemeral_label(self) -> None:
        # The watch mints the GLAEDA_ROUTE_APP_KEY token that writes repository variables. #27022 let
        # CI_CONTROL_RUNNER pick its runner, an owned (reused) Mac for one, so a variable could put that
        # key on a machine where it outlives the job. Only a literal ephemeral label, or the trusted
        # selector whose expression bounds CI_TRUSTED_RUNNER to ephemeral labels, may carry it.
        for name, job in yaml.safe_load(self.text)["jobs"].items():
            if "secrets." not in json.dumps(job) and "create-github-app-token" not in json.dumps(job):
                continue
            if job["runs-on"] == WATCH_SELECTOR:
                continue
            self.assertNotIn("${{", job["runs-on"], name)
            self.assertTrue(job["runs-on"].startswith(switch.CLOUD_PREFIX), name)

    def test_no_job_that_ci_control_runner_moves_holds_a_secret(self) -> None:
        # CI_CONTROL_RUNNER may name a reused machine, so the control jobs it moves hold only their
        # job-scoped GITHUB_TOKEN: no secret, and no App token minted from one.
        moved = []
        for path in sorted(WORKFLOW.parent.glob("*.y*ml")):
            for name, job in (yaml.safe_load(path.read_text(encoding="utf-8")).get("jobs") or {}).items():
                if "CI_CONTROL_RUNNER" not in str(job.get("runs-on", "")):
                    continue
                moved.append(f"{path.name}:{name}")
                self.assertNotIn("secrets.", json.dumps(job), f"{path.name}:{name}")
                self.assertNotIn("create-github-app-token", json.dumps(job), f"{path.name}:{name}")
        self.assertIn("nightly-next-tick.yml:request", moved)

    def test_one_fixed_group_so_two_watches_never_write_at_once(self) -> None:
        # The switch's variable writes and record delete are separate calls; a group keyed by anything a
        # run can change (a variable, an input) would let two watches interleave them.
        group = re.search(r"(?m)^concurrency:\n  group: (.*)$", self.text).group(1)
        self.assertEqual(group, "ci-cloud-overflow-probe")
        self.assertIn("  cancel-in-progress: false\n", self.text)

    def test_watch_uses_existing_route_app_credentials(self) -> None:
        self.assertIn("vars.GLAEDA_ROUTE_APP_ID", self.text)
        self.assertIn("secrets.GLAEDA_ROUTE_APP_KEY", self.text)
        self.assertNotIn("CI_OVERFLOW_SWITCH_APP_ID", self.text)
        self.assertNotIn("CI_OVERFLOW_SWITCH_APP_KEY", self.text)
        self.assertNotIn("environment: ci-overflow-switch", self.text)

    def test_never_reads_a_lane_switch(self) -> None:
        # The switch never reads or changes a lane switch. One exception, read-only and outside the switch: the
        # pools step hands CI_OWNED_POOL_SLOTS to expected_wait.py, which judges an owned family's expected wait
        # by its slots (cmuxterm-hq#16113 step 3) and never writes it.
        [pools] = [step for step in yaml.safe_load(self.text)["jobs"]["watch"]["steps"] if step.get("id") == "pools"]
        self.assertEqual(pools["env"].get("CI_OWNED_POOL_SLOTS"), "${{ vars.CI_OWNED_POOL_SLOTS }}")
        slots_line = "          CI_OWNED_POOL_SLOTS: ${{ vars.CI_OWNED_POOL_SLOTS }}"
        self.assertEqual(self.text.splitlines().count(slots_line), 1)
        code = "\n".join(line for line in self.text.splitlines()
                         if not line.lstrip().startswith("#") and line != slots_line)
        for name in LANE_SWITCHES:
            self.assertNotIn(name, code)

    def test_every_overridable_variable_is_passed(self) -> None:
        for name in switch.OVERRIDABLE_VARIABLES:
            self.assertIn(f"            {name}=${{{{ vars.{name} }}}}\n", self.text)

    def test_a_drill_probes_its_label_and_is_always_a_dry_run(self) -> None:
        self.assertIn("inputs.probe_label != '' && format('[\"{0}\"]', inputs.probe_label) ||", self.text)
        self.assertIn("(inputs.dry_run || inputs.probe_label != '')", self.text)


class RepoVariableCheckTests(unittest.TestCase):
    # A label the drift policy refuses in MACOS_RUNNER_PR (a side lane's); an owned pull request pool label
    # (glaeda-std-xcode-26.6) is no drift there, record or not.
    REFUSED = "glaeda-side-std-xcode-26.6"

    def env(self, label: str = REFUSED, **extra: str) -> dict[str, str]:
        return {"CMUX_CI_RUNNER_VARIABLES": f"MACOS_RUNNER_PR={label}\nLINUX_RUNNER=ubuntu-24.04\n",
                "CI_OWNED_POOL_SLOTS": "", "CMUX_CI_XCODE_APP_PR": PIN, **extra}

    def test_an_owned_pull_request_pool_is_no_drift_without_the_record(self) -> None:
        self.assertEqual(check.problems(self.env("glaeda-std-xcode-26.6")), [])

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
        self.assertFalse(any("CI_TRUSTED_RUNNER" in p for p in check.problems(env(SECRET_JIT_LABEL))))
        self.assertTrue(any("CI_TRUSTED_RUNNER" in p for p in check.problems(env("cmux-gcp-lane-x64"))))

    def test_an_owned_label_is_drift_without_the_record(self) -> None:
        self.assertTrue(check.problems(self.env()))

    def test_the_switch_failover_is_expected_while_the_record_exists(self) -> None:
        record = {"changed": {"MACOS_RUNNER_PR": {"before": None, "after": self.REFUSED}}}
        self.assertEqual(check.problems(self.env(CI_CLOUD_OVERFLOW_SAVED=json.dumps(record))), [])
        other = {"changed": {"MACOS_RUNNER_PR": {"before": None, "after": "glaeda-light-xcode-26.6"}}}
        self.assertTrue(check.problems(self.env(CI_CLOUD_OVERFLOW_SAVED=json.dumps(other))))
        self.assertTrue(check.problems(self.env(CI_CLOUD_OVERFLOW_SAVED="not json")))

    def test_a_record_never_excuses_a_reused_machine_in_a_signing_variable(self) -> None:
        record = {"changed": {"MACOS_RUNNER_26": {"before": None, "after": "glaeda-std-xcode-26.6"}}}
        env = self.env(CI_CLOUD_OVERFLOW_SAVED=json.dumps(record),
                       CMUX_CI_RUNNER_VARIABLES="MACOS_RUNNER_26=glaeda-std-xcode-26.6\n")
        self.assertTrue(any("MACOS_RUNNER_26" in p for p in check.problems(env)))


class ReadTokenTests(unittest.TestCase):
    """The watch's reads go out on cmux-bot's token, its writes and refused reads on the workflow token."""

    def client(self, refuse: int | None = None) -> tuple[switch.GitHub, list[tuple[str, str, str]]]:
        import urllib.error
        api = switch.GitHub("bot", "manaflow-ai/cmux", "workflow")
        sent: list[tuple[str, str, str]] = []

        def send(method: str, path: str, data: bytes | None, token: str) -> dict:
            sent.append((method, path.split("?")[0], token))
            if refuse is not None and token == "bot":
                raise urllib.error.HTTPError(path, refuse, "refused", {}, None)  # type: ignore[arg-type]
            return {"jobs": [], "workflow_runs": []}

        api._send = send  # type: ignore[method-assign]
        return api, sent

    def test_reads_use_the_bot_and_writes_the_workflow_token(self) -> None:
        api, sent = self.client()
        api.jobs(7, 1)
        api.runs("queued")
        api.force_cancel(8)
        api.rerun(8)
        self.assertEqual([token for *_, token in sent], ["bot", "bot", "workflow", "workflow"])

    def test_a_refused_read_is_not_asked_again_on_the_workflow_token(self) -> None:
        # The workflow token can never read a variable: its 403 hid the first refusal's cause.
        for code in (401, 403, 404, 429):
            api, sent = self.client(refuse=code)
            with self.assertRaises(switch.GitHubError) as caught:
                api.jobs(7, 1)
            self.assertEqual(caught.exception.status, code)
            self.assertEqual([token for *_, token in sent], ["bot"], code)

    def test_a_refusal_names_githubs_message_and_the_rate_limit(self) -> None:
        import email.message
        import io
        import urllib.error
        headers = email.message.Message()
        headers["x-ratelimit-remaining"] = "0"
        headers["x-ratelimit-resource"] = "core"
        headers["x-ratelimit-reset"] = "1795575600"  # 2026-11-25T03:00:00Z
        body = io.BytesIO(json.dumps({"message": "API rate limit exceeded for installation ID 1."}).encode())
        api = switch.GitHub("only", "manaflow-ai/cmux")

        def send(method: str, path: str, data: bytes | None, token: str) -> dict:
            raise urllib.error.HTTPError(path, 403, "Forbidden", headers, body)

        api._send = send  # type: ignore[method-assign]
        with self.assertRaises(switch.GitHubError) as caught:
            api.get_variable("RUNNER_POOLS")
        self.assertEqual(str(caught.exception),
                         "GET /actions/variables/RUNNER_POOLS failed (403: API rate limit exceeded for installation "
                         "ID 1.; rate limit 0 left (resource core), resets 03:00:00Z)")

    def test_a_missing_variable_still_reads_as_unset(self) -> None:
        api, _ = self.client(refuse=404)
        api.token = "bot"
        self.assertIsNone(api.get_variable("CI_CLOUD_OVERFLOW_SAVED"))

    def test_without_a_fallback_everything_uses_the_one_token(self) -> None:
        api = switch.GitHub("only", "manaflow-ai/cmux")
        sent: list[str] = []
        api._send = lambda method, path, data, token: sent.append(token) or {}  # type: ignore[method-assign]
        api.request("GET", "/actions/runs/1")
        api.request("POST", "/actions/runs/1/rerun")
        self.assertEqual(sent, ["only", "only"])

    def test_the_watch_reads_as_cmux_bot_with_the_workflow_token_as_fallback(self) -> None:
        steps = yaml.safe_load(WORKFLOW.read_text())["jobs"]["watch"]["steps"]
        [mint] = [s for s in steps if s.get("id") == "cmux-bot-token"]
        self.assertEqual(mint["with"]["app-id"], "${{ vars.CMUX_BOT_APP_ID }}")
        self.assertEqual(mint["with"]["private-key"], "${{ secrets.CMUX_BOT_APP_KEY }}")
        # Read-only: the bot token can never cancel, re-run or write a variable.
        self.assertEqual({k: v for k, v in mint["with"].items() if k.startswith("permission-")},
                         {"permission-actions": "read"})
        self.assertTrue(mint["continue-on-error"])
        [step] = [s for s in steps if s.get("id") == "switch"]
        # Under the cmux-bot budget floor the switch reads on the workflow token (scripts/ci/app_spend_mark.py).
        self.assertEqual(step["env"]["GH_TOKEN"], "${{ steps.app-spend.outputs.low != 'true' && "
                                                  "steps.cmux-bot-token.outputs.token || github.token }}")
        self.assertEqual(step["env"]["GH_FALLBACK_TOKEN"], "${{ github.token }}")
        self.assertEqual(step["env"]["SWITCH_TOKEN"], "${{ steps.switch-token.outputs.token }}")
        self.assertNotIn("GLAEDA_ROUTE", step["env"]["GH_TOKEN"])
        self.assertLess(steps.index(mint), steps.index(step))


    def test_the_pools_step_reads_online_runners_with_a_read_only_administration_token(self) -> None:
        steps = yaml.safe_load(WORKFLOW.read_text())["jobs"]["watch"]["steps"]
        [mint] = [s for s in steps if s.get("id") == "runners-token"]
        self.assertEqual({k: v for k, v in mint["with"].items() if k.startswith("permission-")},
                         {"permission-administration": "read"})
        self.assertEqual(mint["with"]["repositories"], "${{ github.event.repository.name }}")
        self.assertTrue(mint["continue-on-error"])
        [pools] = [s for s in steps if s.get("id") == "pools"]
        self.assertEqual(pools["env"]["RUNNER_ADMISSION_RUNNERS_TOKEN"], "${{ steps.runners-token.outputs.token }}")
        self.assertLess(steps.index(mint), steps.index(pools))
        for other in steps:
            if other is not pools:
                self.assertNotIn("runners-token", json.dumps(other.get("env", {})), other.get("name"))
        [spill] = [s for s in steps if s.get("id") == "spill-tooling"]
        self.assertIn("f95bc766b1fc840ab8817e4d9bb61348a2084b07", spill["with"]["ref"])


if __name__ == "__main__":
    unittest.main()
