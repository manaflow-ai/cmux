#!/usr/bin/env python3
"""Structural contracts for the reusable Linux guard workflow."""

from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
GUARD_WORKFLOW = ROOT / ".github" / "workflows" / "ci-guards.yml"

REUSABLE_GUARD_COMMANDS = [
    "python3 tests/test_ci_guard_workflow_structure.py",
    "python3 tests/test_app_host_test_products.py",
    "python3 tests/test_reuse_app_host_products.py",
    "python3 tests/test_e2e_warm_derived_data.py",
    "python3 tests/test_seed_derived_data.py",
    "python3 tests/test_ci_product_publication.py",
]


def workflow_job_block(job_name: str) -> str:
    lines = GUARD_WORKFLOW.read_text(encoding="utf-8").splitlines()
    marker = f"  {job_name}:"
    for index, line in enumerate(lines):
        if line != marker:
            continue
        body = [line]
        for following in lines[index + 1 :]:
            if (
                following.startswith("  ")
                and not following.startswith("    ")
                and following.strip()
            ):
                break
            body.append(following)
        return "\n".join(body)
    raise AssertionError(f"{job_name} job not found")


def test_reusable_guard_structure_step_runs_each_suite_as_separate_command() -> None:
    workflow = yaml.safe_load(GUARD_WORKFLOW.read_text(encoding="utf-8"))
    step = next(
        step
        for step in workflow["jobs"]["workflow-guard-tests"]["steps"]
        if step.get("name") == "Validate reusable guard workflow structure"
    )
    commands = [line.strip() for line in step["run"].splitlines() if line.strip()]

    assert commands == REUSABLE_GUARD_COMMANDS


def test_cli_guard_matrix_runs_independent_slow_contracts_in_parallel() -> None:
    block = workflow_job_block("workflow-guard-cli-scripts")

    assert "name: workflow-guard-cli-scripts / ${{ matrix.group }}" in block
    assert "group: [tui-resolution, profiling]" in block
    assert (
        "- name: Validate cmux-tui client commit resolution\n"
        "        if: ${{ matrix.group == 'tui-resolution' }}"
    ) in block
    assert (
        "- name: Validate cmux profiling support scripts\n"
        "        if: ${{ matrix.group == 'profiling' }}"
    ) in block


if __name__ == "__main__":
    for name, value in sorted(globals().items()):
        if name.startswith("test_") and callable(value):
            value()
    print("PASS: reusable guard workflow structure")
