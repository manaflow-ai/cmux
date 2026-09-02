#!/usr/bin/env python3
"""Behavior tests for the trusted CI status validator."""

from __future__ import annotations

import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "ci" / "check_ci_status.py"
spec = importlib.util.spec_from_file_location("check_ci_status", HELPER)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


ROUTE_JOBS = tuple(module.ROUTE_JOBS)
COMMON = tuple(module.COMMON_REQUIRED)


def needs(outputs: dict[str, str], *, results: dict[str, str] | None = None) -> dict[str, object]:
    results = results or {}
    names = COMMON + ("linux-preflight", "tests") + ROUTE_JOBS
    return {
        name: {
            "result": results.get(
                name,
                "success"
                if name in COMMON or name in {"linux-preflight", "tests"}
                else "skipped",
            ),
            "outputs": outputs if name == "changes" else {},
        }
        for name in names
    }


ALL_FALSE = {route: "false" for route in module.ROUTE_NAMES}


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
