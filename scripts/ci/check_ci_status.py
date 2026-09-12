#!/usr/bin/env python3
"""Validate the route-aware CI status contract."""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections.abc import Mapping
from typing import Any


ROUTE_NAMES = ("macos", "web", "agent_session_web")

# A job can be selected by more than one route. In particular, the diff
# sidecar checks both macOS and web changes.
ROUTE_JOBS: dict[str, tuple[str, ...]] = {
    "app-host-unit-tests": ("macos",),
    "tests-build-and-lag": ("macos",),
    "swift-package-tests": ("macos",),
    "release-build": ("macos",),
    "web-typecheck": ("web",),
    "react-apps-check": ("web",),
    "diff-sidecar-check": ("macos", "web"),
    "web-db-migrations": ("web",),
    "agent-session-web-resources": ("agent_session_web",),
}

COMMON_REQUIRED = (
    "changes",
    "workflow-guard-tests",
    "ghosttykit-release-check",
)

ALWAYS_REQUIRED = COMMON_REQUIRED + (
    "linux-preflight",
    "tests",
)

PREFLIGHT_REQUIRED = COMMON_REQUIRED

PREFLIGHT_ROUTE_JOBS = (
    "web-typecheck",
    "react-apps-check",
    "diff-sidecar-check",
    "web-db-migrations",
    "agent-session-web-resources",
)

AGGREGATE_ROUTE_JOBS = tuple(ROUTE_JOBS)

PHASE_CONTRACTS = {
    "preflight": (PREFLIGHT_REQUIRED, PREFLIGHT_ROUTE_JOBS),
    "aggregate": (ALWAYS_REQUIRED, AGGREGATE_ROUTE_JOBS),
}


def _job_result(needs: Mapping[str, Any], name: str, failures: list[str]) -> str | None:
    value = needs.get(name)
    if not isinstance(value, Mapping):
        failures.append(f"{name}: missing job result")
        return None
    result = value.get("result")
    if not isinstance(result, str):
        failures.append(f"{name}: missing job result")
        return None
    return result


def _route_outputs(needs: Mapping[str, Any], failures: list[str]) -> Mapping[str, Any]:
    changes = needs.get("changes")
    if not isinstance(changes, Mapping):
        failures.append("changes: missing job result")
        return {}
    outputs = changes.get("outputs")
    if not isinstance(outputs, Mapping):
        failures.append("changes: missing route outputs")
        return {}
    for route in ROUTE_NAMES:
        if outputs.get(route) not in {"true", "false"}:
            failures.append(f"changes.outputs.{route}: expected true or false")
    return outputs


def _expected_jobs(phase: str) -> tuple[str, ...]:
    required, route_jobs = PHASE_CONTRACTS[phase]
    return required + route_jobs


def _validate_job_set(
    needs: Mapping[str, Any], expected: set[str], failures: list[str]
) -> None:
    for name in sorted(expected - set(needs)):
        failures.append(f"{name}: missing job result")
    for name in sorted(set(needs) - expected):
        failures.append(f"{name}: unexpected job in CI contract")


def _validate_required_jobs(
    needs: Mapping[str, Any], names: tuple[str, ...], failures: list[str]
) -> None:
    for name in names:
        result = _job_result(needs, name, failures)
        if result is not None and result != "success":
            failures.append(f"{name}: expected success, got {result}")


def _validate_route_jobs(
    needs: Mapping[str, Any],
    outputs: Mapping[str, Any],
    names: tuple[str, ...],
    failures: list[str],
) -> None:
    for name in names:
        result = _job_result(needs, name, failures)
        if result is None:
            continue
        routes = ROUTE_JOBS[name]
        selected = any(outputs.get(route) == "true" for route in routes)
        if selected and result != "success":
            route_label = " or ".join(routes)
            failures.append(f"{name}: required for route {route_label}, got {result}")
        elif not selected and result not in {"success", "skipped"}:
            failures.append(f"{name}: unexpected result for inactive route, got {result}")


def validate_needs(needs: Mapping[str, Any], *, phase: str = "aggregate") -> list[str]:
    """Return contract violations for a serialized GitHub ``needs`` object."""

    if phase not in {"preflight", "aggregate"}:
        raise ValueError(f"unsupported phase: {phase}")
    failures: list[str] = []

    if not isinstance(needs, Mapping):
        return ["needs: expected an object"]

    required, route_jobs = PHASE_CONTRACTS[phase]
    expected_set = set(_expected_jobs(phase))
    _validate_job_set(needs, expected_set, failures)

    outputs = _route_outputs(needs, failures)
    _validate_required_jobs(needs, required, failures)
    _validate_route_jobs(needs, outputs, route_jobs, failures)

    return failures


def _load_needs(raw: str | None) -> Mapping[str, Any]:
    if not raw:
        raise ValueError("CI_NEEDS is empty")
    value = json.loads(raw)
    if not isinstance(value, Mapping):
        raise ValueError("CI_NEEDS must be a JSON object")
    return value


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--phase",
        choices=("preflight", "aggregate"),
        default="aggregate",
        help="Which CI dependency set to validate.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        needs = _load_needs(os.environ.get("CI_NEEDS"))
    except (json.JSONDecodeError, ValueError) as error:
        print(f"CI status contract input error: {error}", file=sys.stderr)
        return 2

    failures = validate_needs(needs, phase=args.phase)
    if failures:
        print(f"CI status contract failed ({args.phase}):", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    print(f"CI status contract passed ({args.phase}).")
    for name in sorted(needs):
        result = needs[name].get("result") if isinstance(needs[name], Mapping) else None
        print(f"{name}: {result}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
