#!/usr/bin/env python3
"""Structural contract for parallel app-host guard ownership."""

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


def test_app_host_groups_are_parallel_and_owned() -> None:
    block = workflow_job_block("workflow-guard-tests")

    assert (
        "group: [preflight, ci, app-host-execution, app-host-process, "
        "app-host-cache, release, quality-sharding, quality-runtime, "
        "quality-determinism]"
    ) in block

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
    for step, group in expected.items():
        marker = (
            f"- name: {step}\n"
            f"        if: ${{{{ matrix.group == '{group}' }}}}"
        )
        assert marker in block, (step, group)

    assert "matrix.group == 'app-host'" not in block


if __name__ == "__main__":
    test_app_host_groups_are_parallel_and_owned()
    print("PASS: app-host guard structure")
