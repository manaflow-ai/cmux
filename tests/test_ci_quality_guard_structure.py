#!/usr/bin/env python3
"""Structural contract for parallel quality guard ownership."""

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


def test_quality_groups_are_parallel_and_owned() -> None:
    block = workflow_job_block("workflow-guard-tests")

    assert (
        "group: [preflight, ci, app-host, release, quality-sharding, "
        "quality-runtime, quality-determinism]"
    ) in block

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
    for step, group in expected.items():
        marker = (
            f"- name: {step}\n"
            f"        if: ${{{{ matrix.group == '{group}' }}}}"
        )
        assert marker in block, (step, group)

    assert "matrix.group == 'quality'" not in block


if __name__ == "__main__":
    test_quality_groups_are_parallel_and_owned()
    print("PASS: quality guard structure")
