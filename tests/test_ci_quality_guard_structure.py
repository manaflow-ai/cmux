#!/usr/bin/env python3
"""Structural contract for parallel quality guard ownership."""

from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
GUARD_WORKFLOW = ROOT / ".github" / "workflows" / "ci-guards.yml"
MATRIX_GROUPS = "${{ fromJSON(inputs.linux_guard_test_groups) }}"


def workflow_guard_job() -> dict:
    workflow = yaml.safe_load(GUARD_WORKFLOW.read_text(encoding="utf-8"))
    return workflow["jobs"]["workflow-guard-tests"]


def test_quality_groups_are_parallel_and_owned() -> None:
    job = workflow_guard_job()
    assert job["strategy"]["matrix"]["group"] == MATRIX_GROUPS

    expected = {
        "Validate cmuxTests sharding": "quality-sharding",
        "Validate test compilation cache seeding": "quality-sharding",
        "Validate bundled-resource incremental outputs": "quality-runtime",
        "Validate virtual display lock": "quality-runtime",
        "Validate auxiliary window close shortcut lint": "quality-determinism",
        "Validate bash shell integration job control": "quality-determinism",
        "Validate focused Dock shortcut routing guard": "quality-determinism",
        "Validate bash prompt bootstrap composes with user PROMPT_COMMAND (starship)": "quality-determinism",
        "Validate test determinism gate": "quality-determinism",
    }
    steps = job["steps"]
    for name, group in expected.items():
        matches = [step for step in steps if step.get("name") == name]
        assert len(matches) == 1, (name, len(matches))
        assert matches[0].get("if") == f"${{{{ matrix.group == '{group}' }}}}", (
            name,
            matches[0].get("if"),
        )

    assert all(step.get("if") != "${{ matrix.group == 'quality' }}" for step in steps)


if __name__ == "__main__":
    test_quality_groups_are_parallel_and_owned()
    print("PASS: quality guard structure")
