#!/usr/bin/env python3
"""Every CI job that can start an acpmux daemon gives it a home of the job's own.

On a mini the runner user's ~/.acpmux is the host's own acpmux daemon, which
launchd keeps running. On 2026-10-26 the `cmux-next swift test` job on cmux12s
ran tests that resolve the app's acpmux from the process environment; with no
ACPMUX_HOME they resolved ~/.acpmux, handed the host daemon (pid 11252) off at
22:49:08Z, and cycled short-lived daemons there until the run ended.

A job that runs cmux NEXT's Swift tests (the only Swift package that starts
acpmux: AcpmuxEnvironment), acpmux's or cmux-tui's daemon tests, or the acpmux
CLI against a daemon must therefore, before its first such step, export
ACPMUX_HOME=$RUNNER_TEMP/acpmux-home and an empty ACPMUX_SOCKET (a socket wins
over the home, and empty counts as unset), and after its last one, in an
always() step, end that home's daemon and agents with `env -u ACPMUX_SOCKET
acpmux daemon shutdown --end-agents` and delete the home, so a failed or
cancelled job cleans up too.
In the tests themselves, AcpmuxEnvironment refuses the account's ~/.acpmux in
a test process (AcpmuxEnvironment+TestGuard.swift).

Jobs that launch a built cmux NEXT app (benches, the crash gate, media tours)
are not in this rule: the app is a tagged DEV build, whose acpmux home is its
own build home (~/.acpmux/builds/<key>, BuildIdentity), never ~/.acpmux, and a
tour runs a base and a head app side by side that one shared job home would
make hand each other's daemon off.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
CMUX_NEXT_PACKAGE = "Packages/macOS/CmuxNext"

# What in a step's `run:` starts or reaches an acpmux daemon on the runner.
LAUNCHES = (
    # cmux NEXT's Swift tests, and the scripts that run them.
    re.compile(r"swift-test-with-hang-sampler\.sh"),
    re.compile(r"fast-tier\.py\b[^\n]*--kind swift"),
    re.compile(r"(?:check-action-surfaces|check-settings-exports|regenerate-[a-z-]+-exports|base-autofix-[a-z-]+-exports)\.sh"),
    re.compile(r"car_guards\.py\b[^\n]*--where mac"),
    re.compile(r"package-test-lane\.sh run"),
    # acpmux's and cmux-tui's daemon tests (cmux-tui-artifacts.yml "cargo test cmux_next_").
    re.compile(r"cmux-next-daemon-test-packages\.sh"),
    # The acpmux CLI against a daemon.
    re.compile(r"\bacpmux(?:\.exe)?\"?\s+(?:daemon\s+(?:run|start|restart)|new|ls|send|status|wait|attach)\b"),
)
SWIFT_TEST = re.compile(r"\bswift test\b")
HOME_EXPORT = re.compile(r'ACPMUX_HOME=\$(?:RUNNER_TEMP|\{RUNNER_TEMP\})/acpmux-home["\']?\s*>>\s*"?\$GITHUB_ENV')
# ACPMUX_SOCKET wins over the home (acpmux config::socket_path): an inherited one is another
# home's daemon. Empty counts as unset everywhere (Swift, Rust).
SOCKET_CLEAR = re.compile(r'ACPMUX_SOCKET=["\']?\s*>>\s*"?\$GITHUB_ENV')
SHUTDOWN = "daemon shutdown --end-agents"


def launches(step: dict) -> bool:
    run = str(step.get("run") or "")
    if any(pattern.search(run) for pattern in LAUNCHES):
        return True
    in_package = str(step.get("working-directory") or "").rstrip("/") == CMUX_NEXT_PACKAGE or CMUX_NEXT_PACKAGE in run
    return in_package and bool(SWIFT_TEST.search(run))


def is_start(step: dict) -> bool:
    run = str(step.get("run") or "")
    return bool(HOME_EXPORT.search(run) and SOCKET_CLEAR.search(run))


def is_stop(step: dict) -> bool:
    run = str(step.get("run") or "")
    return (SHUTDOWN in run and "env -u ACPMUX_SOCKET" in run and "rm -rf" in run and "acpmux-home" in run
            and "always()" in str(step.get("if") or "").replace(" ", ""))


def condition(step: dict) -> str:
    return re.sub(r"\s+", "", str(step.get("if") or "")).removeprefix("${{").removesuffix("}}")


def runs_before_every_launch(start: dict, launching: list[dict]) -> bool:
    """An unconditional start, or one whose condition every launching step also requires (the
    daemon-test job's `steps.current.outputs.stale != 'true'`: a superseded run launches nothing)."""
    gate = condition(start)
    return not gate or all(gate in condition(step) for step in launching)


def job_failures(where: str, job: dict) -> list[str]:
    steps = [step for step in job.get("steps") or [] if isinstance(step, dict)]
    launching = [index for index, step in enumerate(steps) if launches(step)]
    if not launching:
        return []
    first, last = launching[0], launching[-1]
    named = steps[first].get("name") or f"step {first + 1}"
    failures = []
    starts = [index for index, step in enumerate(steps) if is_start(step)]
    if not any(index < first and runs_before_every_launch(steps[index], [steps[i] for i in launching])
               for index in starts):
        failures.append(f"{where}: '{named}' can start acpmux, but no step before it that runs whenever they do "
                        "exports ACPMUX_HOME=$RUNNER_TEMP/acpmux-home and an empty ACPMUX_SOCKET to $GITHUB_ENV")
    if not any(index > last and is_stop(step) for index, step in enumerate(steps)):
        failures.append(f"{where}: no always() step after its last acpmux step runs `env -u ACPMUX_SOCKET "
                        f"acpmux {SHUTDOWN}` for $RUNNER_TEMP/acpmux-home and deletes it")
    return failures


def workflow_jobs():
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        document = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        for name, job in (document.get("jobs") or {}).items():
            if isinstance(job, dict):
                yield f"{path.name}:{name}", job


def failures() -> list[str]:
    found = []
    for where, job in workflow_jobs():
        found += job_failures(where, job)
    return found


START = {"name": "Give this job its own acpmux home",
         "run": 'home="$RUNNER_TEMP/acpmux-home"\nrm -rf "$home" && mkdir -m 700 "$home"\n'
                'echo "ACPMUX_HOME=$RUNNER_TEMP/acpmux-home" >> "$GITHUB_ENV"\necho "ACPMUX_SOCKET=" >> "$GITHUB_ENV"\n'}
STOP = {"name": "Stop this job's acpmux daemons and remove its home", "if": "${{ always() }}",
        "run": 'home="$RUNNER_TEMP/acpmux-home"\n'
               'env -u ACPMUX_SOCKET ACPMUX_HOME="$home" acpmux daemon shutdown --end-agents || true\nrm -rf "$home"\n'}
TEST = {"name": "Run package tests", "working-directory": CMUX_NEXT_PACKAGE,
        "run": "../../../scripts/cmux-next/swift-test-with-hang-sampler.sh --skip-build"}


class AcpmuxJobHomeTests(unittest.TestCase):
    def test_every_job_that_can_start_acpmux_has_its_own_home(self) -> None:
        self.assertEqual(failures(), [])

    def test_the_rule_reaches_the_swift_test_job(self) -> None:
        jobs = {where for where, job in workflow_jobs() if any(launches(step) for step in job.get("steps") or [])}
        for required in ("cmux-next.yml:swift-test", "cmux-next.yml:daemon-test",
                         "cmux-tui-artifacts.yml:cmux-next-daemon-tests"):
            self.assertIn(required, jobs)

    def test_a_job_without_its_own_home_fails(self) -> None:
        self.assertEqual(len(job_failures("w:j", {"steps": [TEST]})), 2)
        self.assertEqual(len(job_failures("w:j", {"steps": [TEST, STOP]})), 1)
        self.assertEqual(len(job_failures("w:j", {"steps": [START, TEST]})), 1)
        # Too late, or skipped by a condition.
        self.assertEqual(len(job_failures("w:j", {"steps": [TEST, START, STOP]})), 1)
        self.assertEqual(len(job_failures("w:j", {"steps": [dict(START, **{"if": "x"}), TEST, STOP]})), 1)
        gated = dict(TEST, **{"if": "steps.current.outputs.stale != 'true'"})
        self.assertEqual(len(job_failures("w:j", {"steps": [dict(START, **{"if": "x"}), gated, STOP]})), 1)
        # A stop that does not run after a failure or a cancel.
        self.assertEqual(len(job_failures("w:j", {"steps": [START, TEST, {**STOP, "if": "success()"}]})), 1)
        # An inherited ACPMUX_SOCKET left in place: the job's steps, or its shutdown, reach that daemon.
        keeps_socket = dict(START, run=START["run"].replace('echo "ACPMUX_SOCKET=" >> "$GITHUB_ENV"\n', ""))
        self.assertEqual(len(job_failures("w:j", {"steps": [keeps_socket, TEST, STOP]})), 1)
        stops_by_socket = dict(STOP, run=STOP["run"].replace("env -u ACPMUX_SOCKET ", ""))
        self.assertEqual(len(job_failures("w:j", {"steps": [START, TEST, stops_by_socket]})), 1)

    def test_a_job_with_its_own_home_passes(self) -> None:
        self.assertEqual(job_failures("w:j", {"steps": [START, TEST, STOP]}), [])
        swift_test = {"run": "swift test --package-path Packages/macOS/CmuxNext --filter X"}
        self.assertEqual(job_failures("w:j", {"steps": [START, swift_test, STOP]}), [])
        # A start gated like every launching step: a run that skips them needs no home.
        stale = "steps.current.outputs.stale != 'true'"
        self.assertEqual(job_failures("w:j", {"steps": [dict(START, **{"if": stale}), dict(TEST, **{"if": stale}),
                                                        dict(STOP, **{"if": f"${{{{ always() && {stale} }}}}"})]}), [])

    def test_the_fleet_package_lane_gives_its_tests_a_home_of_their_own(self) -> None:
        # A fleet step (`cmux-ci run --script scripts/ci/package-test-lane.sh`) runs on a mini
        # outside this job, so the lane itself makes a home when it was given none.
        lane = (ROOT / "scripts" / "ci" / "package-test-lane.sh").read_text(encoding="utf-8")
        setup = lane[lane.index("end_own_acpmux_home() {"):lane.rindex('case "$phase" in')]
        self.assertIn("  suite|packages|run)\n    if [ -z \"${ACPMUX_HOME:-}\" ]; then", setup)
        self.assertIn('export ACPMUX_HOME="$own_acpmux_home" ACPMUX_SOCKET=', setup)
        self.assertIn("trap 'status=$?; end_own_acpmux_home; exit \"$status\"' EXIT", setup)
        self.assertIn(f'env -u ACPMUX_SOCKET ACPMUX_HOME="$own_acpmux_home" "$acpmux" {SHUTDOWN}', setup)
        self.assertIn('rm -rf "$own_acpmux_home"', setup)

    def test_other_swift_packages_are_not_acpmux(self) -> None:
        self.assertFalse(launches({"run": "swift test --package-path Packages/Shared/CmuxVNC"}))
        self.assertTrue(launches({"run": "swift test --skip-build", "working-directory": CMUX_NEXT_PACKAGE}))
        self.assertTrue(launches({"run": "acpmux daemon run --ready-fd 3"}))
        self.assertFalse(launches({"run": "acpmux --version"}))


if __name__ == "__main__":
    unittest.main(argv=sys.argv[:1] + sys.argv[1:], verbosity=2)
