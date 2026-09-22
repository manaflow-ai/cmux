#!/usr/bin/env python3
"""Structural contract for parallel app-host guard ownership."""

from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
GUARD_WORKFLOW = ROOT / ".github" / "workflows" / "ci-guards.yml"
MATRIX_GROUPS = "${{ fromJSON(inputs.linux_guard_test_groups) }}"


def workflow_guard_job() -> dict:
    workflow = yaml.safe_load(GUARD_WORKFLOW.read_text(encoding="utf-8"))
    return workflow["jobs"]["workflow-guard-tests"]


def test_app_host_groups_are_parallel_and_owned() -> None:
    job = workflow_guard_job()
    assert job["strategy"]["matrix"]["group"] == MATRIX_GROUPS

    expected = {
        "Validate unit-test SwiftPM retry guard": "app-host-execution",
        "Validate Swift Testing suite timeout guard": "app-host-execution",
        "Validate xcodebuild noninteractive crash prompt guard": "app-host-execution",
        "Validate xcodebuild failure diagnostics": "app-host-execution",
        "Validate pipe-safe CI capture": "app-host-execution",
        "Validate focused test launcher": "app-host-execution",
        "Validate app-host xcodebuild retry guard": "app-host-execution",
        "Validate app-host xcodebuild attempt budget": "app-host-execution",
        "Validate app-host test failure classification": "app-host-process",
        "Validate app-host failure census": "app-host-process",
        "Validate app-host user configuration isolation": "app-host-process",
        "Validate app-host identity and cleanup confirmation": "app-host-process",
        "Validate app-host process receipts": "app-host-process",
        "Validate isolated app-host home cleanup": "app-host-process",
        "Validate Xcode SourcePackages cache sanitizer": "app-host-cache",
        "Validate local build cache preflight": "app-host-cache",
        "Validate Xcode compilation cache pruning": "app-host-cache",
        "Validate cmux scheme test configuration": "app-host-cache",
        "Validate selected iOS test execution guard": "app-host-cache",
    }
    steps = job["steps"]
    for name, group in expected.items():
        matches = [step for step in steps if step.get("name") == name]
        assert len(matches) == 1, (name, len(matches))
        assert matches[0].get("if") == f"${{{{ matrix.group == '{group}' }}}}", (
            name,
            matches[0].get("if"),
        )

    assert all(step.get("if") != "${{ matrix.group == 'app-host' }}" for step in steps)


if __name__ == "__main__":
    test_app_host_groups_are_parallel_and_owned()
    print("PASS: app-host guard structure")
