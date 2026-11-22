#!/usr/bin/env python3
"""Structural contracts for the reusable Linux guard workflow."""

import json
import re
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
GUARD_WORKFLOW = ROOT / ".github" / "workflows" / "ci-guards.yml"
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"

REUSABLE_GUARD_COMMANDS = [
    "python3 tests/test_ci_guard_workflow_structure.py",
    "python3 tests/test_app_host_test_products.py",
    "python3 tests/test_reuse_app_host_products.py",
    "python3 tests/test_e2e_warm_derived_data.py",
    "python3 tests/test_seed_derived_data.py",
    "python3 tests/test_seed_decide.py",
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


def test_agent_chat_uses_a_pinned_local_compiler_and_runs_tests_once() -> None:
    workflow = yaml.safe_load(GUARD_WORKFLOW.read_text(encoding="utf-8"))
    steps = workflow["jobs"]["workflow-guard-tests"]["steps"]
    chat_steps = [step for step in steps if step.get("working-directory") == "agent-chat"]
    assert [step["name"] for step in chat_steps] == [
        "Type-check agent-chat",
        "Run agent-chat unit tests",
    ]
    assert all(step["if"] == "${{ matrix.group == 'preflight' }}" for step in chat_steps)
    assert chat_steps[0]["run"].splitlines() == [
        "bun install --frozen-lockfile",
        "./node_modules/.bin/tsc --noEmit",
    ]
    assert chat_steps[1]["run"] == "bun run test"

    package = json.loads((ROOT / "agent-chat/package.json").read_text(encoding="utf-8"))
    assert re.fullmatch(r"\d+\.\d+\.\d+", package["devDependencies"]["typescript"])
    assert package["scripts"]["check"] == "./node_modules/.bin/tsc --noEmit && bun run test"
def test_ci_group_deduplication_gates_only_the_overlapping_matrix_leg() -> None:
    workflow = yaml.safe_load(GUARD_WORKFLOW.read_text(encoding="utf-8"))
    job = workflow["jobs"]["workflow-guard-tests"]
    assert "exclude" not in job["strategy"]["matrix"]
    steps = job["steps"]
    poll = next(step for step in steps if step.get("name") == "Check independent fast guard result")
    propagate = next(step for step in steps if step.get("name") == "Propagate failed independent fast guard")
    assert poll["if"] == "${{ matrix.group == 'ci' }}"
    assert propagate["if"] == "${{ matrix.group == 'ci' && steps.fast-guard.outputs.state == 'failure' }}"
    assert job["permissions"] == {"contents": "read", "checks": "read"}
    assert poll["run"] == "python3 scripts/ci/fast_guard_status.py"
    ci = yaml.safe_load(CI_WORKFLOW.read_text(encoding="utf-8"))
    assert ci["jobs"]["guards"]["permissions"] == {"contents": "read", "checks": "read"}
    gated = [
        step for step in steps
        if "matrix.group == 'ci'" in str(step.get("if", ""))
        and step.get("name") not in {"Check independent fast guard result", "Propagate failed independent fast guard"}
    ]
    assert gated
    assert all("steps.fast-guard.outputs.skip != 'true'" in step["if"] for step in gated)
    # The unrelated matrix groups must remain runnable without the fast-check
    # result, so they cannot carry the ci-only output condition.
    assert all(
        "steps.fast-guard.outputs.skip" not in str(step.get("if", ""))
        for step in steps
        if "matrix.group == 'preflight'" in str(step.get("if", ""))
        and "matrix.group == 'ci'" not in str(step.get("if", ""))
    )


if __name__ == "__main__":
    for name, value in sorted(globals().items()):
        if name.startswith("test_") and callable(value):
            value()
    print("PASS: reusable guard workflow structure")
