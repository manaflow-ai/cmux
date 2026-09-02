#!/usr/bin/env python3
"""Behavioral tests for the CI aggregate status contract."""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
AREA_HELPER = ROOT / "scripts" / "ci" / "detect_ci_change_areas.py"

spec = importlib.util.spec_from_file_location("detect_ci_change_areas", AREA_HELPER)
assert spec and spec.loader
areas_module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = areas_module
spec.loader.exec_module(areas_module)


ROUTE_JOBS = {
    "macos": (
        "app-host-unit-tests",
        "tests-build-and-lag",
        "swift-package-tests",
        "release-build",
    ),
    "web": (
        "web-typecheck",
        "react-apps-check",
        "diff-sidecar-check",
        "web-db-migrations",
    ),
    "go": ("remote-daemon-tests",),
    "agent_session_web": ("agent-session-web-resources",),
}

ALWAYS_REQUIRED = (
    "changes",
    "workflow-guard-tests",
    "ghosttykit-release-check",
    "linux-preflight",
    "tests",
)


def workflow_job_step_script(job_name: str, step_name: str) -> str:
    lines = CI_WORKFLOW.read_text(encoding="utf-8").splitlines()
    job_marker = f"  {job_name}:"
    step_marker = f"      - name: {step_name}"
    in_job = False
    for index, line in enumerate(lines):
        if line == job_marker:
            in_job = True
            continue
        if in_job and line.startswith("  ") and not line.startswith("    ") and line.strip():
            break
        if in_job and line == step_marker:
            for run_index in range(index + 1, len(lines)):
                if lines[run_index] == "        run: |":
                    body: list[str] = []
                    for body_line in lines[run_index + 1 :]:
                        if body_line.startswith("          "):
                            body.append(body_line[10:])
                            continue
                        if not body_line.strip():
                            body.append("")
                            continue
                        break
                    return "\n".join(body)
            break
    raise AssertionError(f"{step_name} run block not found in {job_name}")


def _route_outputs(paths: list[str]) -> dict[str, str]:
    areas = areas_module.classify_files(paths)
    return {
        "macos": "true" if areas.macos else "false",
        "web": "true" if areas.web else "false",
        "go": "true" if areas.go else "false",
        "agent_session_web": "true" if areas.agent_session_web else "false",
    }


def _job_routes() -> dict[str, tuple[str, ...]]:
    return {
        job: routes
        for route, jobs in ROUTE_JOBS.items()
        for job in jobs
        for routes in [(route,)]
    } | {"diff-sidecar-check": ("macos", "web")}


def ci_needs(paths: list[str], *, results: dict[str, str] | None = None) -> dict[str, object]:
    outputs = _route_outputs(paths)
    job_routes = _job_routes()
    statuses = {name: "success" for name in ALWAYS_REQUIRED}
    for job, routes in job_routes.items():
        statuses[job] = "success" if any(outputs[route] == "true" for route in routes) else "skipped"
    if results:
        statuses.update(results)
    return {
        name: {"result": result, "outputs": outputs if name == "changes" else {}}
        for name, result in statuses.items()
    }


def run_ci_status(needs: dict[str, object]) -> subprocess.CompletedProcess[str]:
    script = workflow_job_step_script("ci-status", "Check routed CI jobs")
    with tempfile.TemporaryDirectory() as temp_dir:
        trusted_helper = Path(temp_dir) / ".ci-trusted" / "scripts" / "ci" / "check_ci_status.py"
        trusted_helper.parent.mkdir(parents=True)
        shutil.copy2(ROOT / "scripts" / "ci" / "check_ci_status.py", trusted_helper)
        return subprocess.run(
            ["bash", "-c", script],
            cwd=temp_dir,
            env={**os.environ, "CI_NEEDS": json.dumps(needs)},
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )


def run_linux_preflight(needs: dict[str, object]) -> subprocess.CompletedProcess[str]:
    script = workflow_job_step_script("linux-preflight", "Check cheap CI layer before macOS runners")
    with tempfile.TemporaryDirectory() as temp_dir:
        trusted_helper = Path(temp_dir) / ".ci-trusted" / "scripts" / "ci" / "check_ci_status.py"
        trusted_helper.parent.mkdir(parents=True)
        shutil.copy2(ROOT / "scripts" / "ci" / "check_ci_status.py", trusted_helper)
        return subprocess.run(
            ["bash", "-c", script],
            cwd=temp_dir,
            env={**os.environ, "CI_NEEDS": json.dumps(needs)},
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )


def preflight_needs(paths: list[str], *, results: dict[str, str] | None = None) -> dict[str, object]:
    all_needs = ci_needs(paths, results=results)
    names = (
        "changes",
        "workflow-guard-tests",
        "ghosttykit-release-check",
        "remote-daemon-tests",
        "web-typecheck",
        "react-apps-check",
        "diff-sidecar-check",
        "web-db-migrations",
        "agent-session-web-resources",
    )
    return {name: all_needs[name] for name in names}


def test_docs_only_contract_passes() -> None:
    result = run_ci_status(ci_needs(["docs/ci.md", "README.md"]))
    assert result.returncode == 0, result.stderr


def test_macos_contract_passes() -> None:
    result = run_ci_status(ci_needs(["Sources/AppDelegate.swift"]))
    assert result.returncode == 0, result.stderr


def test_web_contract_passes_and_runs_diff_sidecar() -> None:
    needs = ci_needs(["web/app/page.tsx"])
    assert needs["diff-sidecar-check"]["result"] == "success"
    result = run_ci_status(needs)
    assert result.returncode == 0, result.stderr


def test_go_contract_passes() -> None:
    result = run_ci_status(ci_needs(["daemon/remote/main.go"]))
    assert result.returncode == 0, result.stderr


def test_agent_session_contract_passes() -> None:
    result = run_ci_status(ci_needs(["Resources/agent-session-react/index.js"]))
    assert result.returncode == 0, result.stderr


def test_workflow_contract_runs_every_area() -> None:
    needs = ci_needs([".github/workflows/ci.yml"])
    assert all(data["result"] == "success" for name, data in needs.items() if name != "changes")
    result = run_ci_status(needs)
    assert result.returncode == 0, result.stderr


def test_required_route_cannot_be_skipped() -> None:
    cases = {
        "Sources/AppDelegate.swift": ROUTE_JOBS["macos"],
        "web/app/page.tsx": ROUTE_JOBS["web"],
        "daemon/remote/main.go": ROUTE_JOBS["go"],
        "Resources/agent-session-react/index.js": ROUTE_JOBS["agent_session_web"],
    }
    for path, jobs in cases.items():
        for job in jobs:
            result = run_ci_status(ci_needs([path], results={job: "skipped"}))
            assert result.returncode != 0, (path, job, result.stdout, result.stderr)


def test_unexpected_failure_blocks_even_when_route_is_off() -> None:
    result = run_ci_status(
        ci_needs(["docs/ci.md"], results={"remote-daemon-tests": "failure"})
    )
    assert result.returncode != 0


def test_web_route_requires_diff_sidecar_in_preflight() -> None:
    result = run_linux_preflight(
        preflight_needs(["web/app/page.tsx"], results={"diff-sidecar-check": "skipped"})
    )
    assert result.returncode != 0
    assert "diff-sidecar-check: required for route macos or web" in result.stderr


def test_missing_route_output_fails_closed() -> None:
    needs = ci_needs(["docs/ci.md"])
    del needs["changes"]["outputs"]["web"]
    result = run_ci_status(needs)
    assert result.returncode != 0
    assert "changes.outputs.web: expected true or false" in result.stderr


def test_unexpected_dependency_fails_closed() -> None:
    needs = ci_needs(["docs/ci.md"])
    needs["new-ci-job"] = {"result": "success"}
    result = run_ci_status(needs)
    assert result.returncode != 0
    assert "new-ci-job: unexpected job in CI contract" in result.stderr


if __name__ == "__main__":
    for name, value in sorted(globals().items()):
        if name.startswith("test_") and callable(value):
            value()
    print("PASS: CI status contract")
