#!/usr/bin/env python3
"""Pure contracts for the mixed terminal/browser performance experiment."""

from __future__ import annotations

from dataclasses import dataclass
import re
from typing import Any, Mapping


_SHA_RE = re.compile(r"[0-9a-fA-F]{40}\Z")
_LOADS = ("light", "realistic", "heavy")


@dataclass(frozen=True)
class Scenario:
    scenario_id: str
    kind: str
    load: str
    terminal_surfaces: int
    browser_surfaces: int
    aggregate_scrollback_chars: int

    def to_dict(self) -> dict[str, Any]:
        return {
            "scenario_id": self.scenario_id,
            "kind": self.kind,
            "load": self.load,
            "terminal_surfaces": self.terminal_surfaces,
            "browser_surfaces": self.browser_surfaces,
            "aggregate_scrollback_chars": self.aggregate_scrollback_chars,
        }


@dataclass(frozen=True)
class Invocation:
    variant: str
    sha: str
    recreate_process: bool = True
    recreate_fixture: bool = True

    def to_dict(self) -> dict[str, Any]:
        return {
            "variant": self.variant,
            "sha": self.sha,
            "recreate_process": self.recreate_process,
            "recreate_fixture": self.recreate_fixture,
        }


@dataclass(frozen=True)
class RunPlan:
    scenario_id: str
    order: str
    warmup: bool
    repetition: int
    invocations: tuple[Invocation, Invocation]

    def to_dict(self) -> dict[str, Any]:
        return {
            "scenario_id": self.scenario_id,
            "order": self.order,
            "warmup": self.warmup,
            "repetition": self.repetition,
            "invocations": [invocation.to_dict() for invocation in self.invocations],
        }


@dataclass(frozen=True)
class SnapshotShape:
    windows: int
    workspaces: int
    panels: int
    terminals: int
    browsers: int
    markdown: int
    scrollback_chars: int
    status_entries: int
    log_entries: int
    progress_entries: int
    git_entries: int

    def to_dict(self) -> dict[str, int]:
        return {
            "windows": self.windows,
            "workspaces": self.workspaces,
            "panels": self.panels,
            "terminals": self.terminals,
            "browsers": self.browsers,
            "markdown": self.markdown,
            "scrollback_chars": self.scrollback_chars,
            "status_entries": self.status_entries,
            "log_entries": self.log_entries,
            "progress_entries": self.progress_entries,
            "git_entries": self.git_entries,
        }


@dataclass(frozen=True)
class SnapshotExpectation:
    built: bool
    include_scrollback: bool
    persist: bool
    saved: bool
    shape: SnapshotShape

    def to_dict(self) -> dict[str, Any]:
        return {
            "built": self.built,
            "include_scrollback": self.include_scrollback,
            "persist": self.persist,
            "saved": self.saved,
            "shape": self.shape.to_dict(),
        }


def scenario_matrix() -> tuple[Scenario, ...]:
    """Return the fixed benchmark matrix in deterministic kind/load order."""
    surface_counts = {
        "terminal": ((4, 0), (16, 0), (40, 0)),
        "browser": ((0, 1), (0, 4), (0, 12)),
        "mixed": ((2, 1), (8, 4), (20, 12)),
    }
    scrollback_by_load = {
        "light": 100_000,
        "realistic": 1_000_000,
        "heavy": 3_000_000,
    }

    scenarios: list[Scenario] = []
    for kind, counts in surface_counts.items():
        for load, (terminal_surfaces, browser_surfaces) in zip(_LOADS, counts):
            scenarios.append(
                Scenario(
                    scenario_id=f"{kind}-{load}",
                    kind=kind,
                    load=load,
                    terminal_surfaces=terminal_surfaces,
                    browser_surfaces=browser_surfaces,
                    aggregate_scrollback_chars=(
                        scrollback_by_load[load] if terminal_surfaces else 0
                    ),
                )
            )
    return tuple(scenarios)


def _validate_sha(name: str, sha: str) -> None:
    if not isinstance(sha, str) or _SHA_RE.fullmatch(sha) is None:
        raise ValueError(f"{name} must be exactly 40 hexadecimal characters")


def build_experiment_plan(
    baseline_sha: str,
    candidate_sha: str,
) -> tuple[RunPlan, ...]:
    """Build warmup plus three measured repetitions for both AB/BA orders."""
    _validate_sha("baseline_sha", baseline_sha)
    _validate_sha("candidate_sha", candidate_sha)
    if baseline_sha.casefold() == candidate_sha.casefold():
        raise ValueError("baseline_sha and candidate_sha must identify distinct commits")

    variants = {
        "A": Invocation("A", baseline_sha),
        "B": Invocation("B", candidate_sha),
    }
    runs: list[RunPlan] = []
    for scenario in scenario_matrix():
        for order in ("AB", "BA"):
            invocations = (variants[order[0]], variants[order[1]])
            for repetition in range(4):
                runs.append(
                    RunPlan(
                        scenario_id=scenario.scenario_id,
                        order=order,
                        warmup=repetition == 0,
                        repetition=repetition,
                        invocations=invocations,
                    )
                )
    return tuple(runs)


def _scenario_field(scenario: Scenario | Mapping[str, Any], name: str) -> Any:
    if isinstance(scenario, Scenario):
        return getattr(scenario, name)
    if isinstance(scenario, Mapping):
        try:
            return scenario[name]
        except KeyError as error:
            raise ValueError(f"scenario is missing {name!r}") from error
    raise ValueError("scenario must be a Scenario or mapping")


def expected_snapshot(
    scenario: Scenario | Mapping[str, Any],
) -> SnapshotExpectation:
    """Return the exact persisted fixture shape for one scenario."""
    terminals = _scenario_field(scenario, "terminal_surfaces")
    browsers = _scenario_field(scenario, "browser_surfaces")
    scrollback_chars = _scenario_field(scenario, "aggregate_scrollback_chars")
    for name, value in (
        ("terminal_surfaces", terminals),
        ("browser_surfaces", browsers),
        ("aggregate_scrollback_chars", scrollback_chars),
    ):
        if type(value) is not int or value < 0:
            raise ValueError(f"scenario {name} must be a non-negative integer")

    return SnapshotExpectation(
        built=True,
        include_scrollback=True,
        persist=True,
        saved=True,
        shape=SnapshotShape(
            windows=1,
            workspaces=1,
            panels=terminals + browsers,
            terminals=terminals,
            browsers=browsers,
            markdown=0,
            scrollback_chars=scrollback_chars,
            status_entries=0,
            log_entries=0,
            progress_entries=0,
            git_entries=0,
        ),
    )


def _strict_snapshot_dict(snapshot: SnapshotExpectation | Mapping[str, Any]) -> dict[str, Any]:
    if isinstance(snapshot, SnapshotExpectation):
        return snapshot.to_dict()
    if not isinstance(snapshot, Mapping):
        raise ValueError("snapshot must be a SnapshotExpectation or mapping")

    expected_top_keys = {"built", "include_scrollback", "persist", "saved", "shape"}
    if set(snapshot.keys()) != expected_top_keys:
        raise ValueError("snapshot fields do not match the expected contract")
    shape = snapshot["shape"]
    if not isinstance(shape, Mapping):
        raise ValueError("snapshot shape must be a mapping")
    expected_shape_keys = set(SnapshotShape.__dataclass_fields__)
    if set(shape.keys()) != expected_shape_keys:
        raise ValueError("snapshot shape fields do not match the expected contract")

    return {
        "built": snapshot["built"],
        "include_scrollback": snapshot["include_scrollback"],
        "persist": snapshot["persist"],
        "saved": snapshot["saved"],
        "shape": {key: shape[key] for key in SnapshotShape.__dataclass_fields__},
    }


def validate_snapshot(
    scenario: Scenario | Mapping[str, Any],
    snapshot: SnapshotExpectation | Mapping[str, Any],
) -> None:
    """Reject any flag, field, type, or fixture-shape deviation."""
    actual = _strict_snapshot_dict(snapshot)
    expected = expected_snapshot(scenario).to_dict()

    for flag in ("built", "include_scrollback", "persist", "saved"):
        if type(actual[flag]) is not bool or actual[flag] is not expected[flag]:
            raise ValueError(f"snapshot flag {flag!r} does not match the contract")

    actual_shape = actual["shape"]
    expected_shape = expected["shape"]
    for field, expected_value in expected_shape.items():
        actual_value = actual_shape[field]
        if type(actual_value) is not int or actual_value != expected_value:
            raise ValueError(f"snapshot shape field {field!r} does not match the contract")
