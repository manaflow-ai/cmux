#!/usr/bin/env python3
"""Structural contract for the reusable source-lint guard lane."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GUARD_WORKFLOW = ROOT / ".github" / "workflows" / "ci-guards.yml"


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


def test_source_lint_matrix_runs_independent_slow_scans_in_parallel() -> None:
    block = workflow_job_block("workflow-guard-source-lints")

    assert "name: workflow-guard-source-lints / ${{ matrix.group }}" in block
    assert "group: [sidebar-layout, dispatch-ownership]" in block
    assert (
        "- name: Validate sidebar lazy-layout guard\n"
        "        if: ${{ matrix.group == 'sidebar-layout' }}"
    ) in block
    assert (
        "- name: Initialize Bonsplit for deferred-work ownership guard\n"
        "        if: ${{ matrix.group == 'dispatch-ownership' }}"
    ) in block
    assert (
        "- name: Validate stored DispatchWorkItem ownership\n"
        "        if: ${{ matrix.group == 'dispatch-ownership' }}"
    ) in block


if __name__ == "__main__":
    test_source_lint_matrix_runs_independent_slow_scans_in_parallel()
    print("PASS: source-lint guard workflow structure")
