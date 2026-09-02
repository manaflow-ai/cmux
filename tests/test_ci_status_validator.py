#!/usr/bin/env python3
"""Behavior tests for the trusted CI status validator."""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "ci" / "check_ci_status.py"
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
spec = importlib.util.spec_from_file_location("check_ci_status", HELPER)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


ROUTE_JOBS = tuple(module.ROUTE_JOBS)
COMMON = tuple(module.COMMON_REQUIRED)


def needs(outputs: dict[str, str], *, results: dict[str, str] | None = None) -> dict[str, object]:
    results = results or {}
    route_outputs = dict(outputs)
    names = COMMON + ("linux-preflight", "tests") + ROUTE_JOBS
    return {
        name: {
            "result": results.get(
                name,
                "success"
                if name in COMMON or name in {"linux-preflight", "tests"}
                else "skipped",
            ),
            "outputs": dict(route_outputs) if name == "changes" else {},
        }
        for name in names
    }


ALL_FALSE = {route: "false" for route in module.ROUTE_NAMES}


def _ci_status_script() -> str:
    lines = CI_WORKFLOW.read_text(encoding="utf-8").splitlines()
    in_job = False
    for index, line in enumerate(lines):
        if line == "  ci-status-validator-canary:":
            in_job = True
            continue
        if in_job and line.startswith("  ") and not line.startswith("    ") and line.strip():
            break
        if in_job and line == "      - name: Check serialized routed jobs":
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
    raise AssertionError("ci-status invocation not found")


def run_ci_status(needs_data: dict[str, object]) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as temp_dir:
        helper = Path(temp_dir) / "scripts" / "ci" / "check_ci_status.py"
        helper.parent.mkdir(parents=True)
        shutil.copy2(HELPER, helper)
        return subprocess.run(
            ["bash", "-c", _ci_status_script()],
            cwd=temp_dir,
            env={**os.environ, "CI_NEEDS": json.dumps(needs_data)},
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )


def test_docs_only_allows_inactive_routes_to_skip() -> None:
    assert module.validate_needs(needs(ALL_FALSE)) == []


def test_selected_route_must_succeed() -> None:
    outputs = {**ALL_FALSE, "web": "true"}
    failures = module.validate_needs(
        needs(outputs, results={"web-typecheck": "skipped"})
    )
    assert "web-typecheck: required for route web, got skipped" in failures


def test_shared_route_job_is_required_for_either_route() -> None:
    outputs = {**ALL_FALSE, "macos": "true"}
    failures = module.validate_needs(
        needs(outputs, results={"diff-sidecar-check": "failure"})
    )
    assert "diff-sidecar-check: required for route macos or web, got failure" in failures


def test_inactive_failure_is_not_ignored() -> None:
    failures = module.validate_needs(
        needs(ALL_FALSE, results={"remote-daemon-tests": "failure"})
    )
    assert "remote-daemon-tests: unexpected result for inactive route, got failure" in failures


def test_missing_or_malformed_route_data_fails_closed() -> None:
    malformed = needs(ALL_FALSE)
    del malformed["changes"]["outputs"]["web"]
    failures = module.validate_needs(malformed)
    assert "changes.outputs.web: expected true or false" in failures


def test_workflow_passes_serialized_needs_to_validator() -> None:
    result = run_ci_status(needs(ALL_FALSE))
    assert result.returncode == 0, result.stderr
    assert "CI status contract passed (aggregate)." in result.stdout


def test_workflow_fails_when_serialized_selected_job_is_skipped() -> None:
    outputs = {**ALL_FALSE, "web": "true"}
    result = run_ci_status(needs(outputs, results={"web-typecheck": "skipped"}))
    assert result.returncode != 0
    assert "web-typecheck: required for route web, got skipped" in result.stderr


def test_preflight_requires_selected_linux_routes() -> None:
    outputs = {**ALL_FALSE, "go": "true"}
    failures = module.validate_needs(
        {name: data for name, data in needs(outputs).items() if name not in {"linux-preflight", "tests"}},
        phase="preflight",
    )
    assert "remote-daemon-tests: required for route go, got skipped" in failures


if __name__ == "__main__":
    for name, value in sorted(globals().items()):
        if name.startswith("test_") and callable(value):
            value()
    print("PASS: trusted CI status validator")
