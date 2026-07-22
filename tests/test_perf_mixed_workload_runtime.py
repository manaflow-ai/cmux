#!/usr/bin/env python3
"""Behavioral contracts for one mixed-workload benchmark invocation."""

from __future__ import annotations

import copy
import importlib.util
import sys
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlparse

import pytest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "perf_mixed_workload.py"
spec = importlib.util.spec_from_file_location("perf_mixed_workload", SCRIPT)
assert spec is not None and spec.loader is not None
perf_runtime = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = perf_runtime
spec.loader.exec_module(perf_runtime)

SCENARIO_ID = "mixed-realistic"
SHA = "fedcba9876543210fedcba9876543210fedcba98"
REQUESTED_SHAPE = {"terminal_surfaces": 2, "browser_surfaces": 2}
EXPECTED_PROCESS_GROUPS = {"parent_direct", "terminal", "webkit", "full_tree"}
EXPECTED_STEADY_SAMPLES = [
    {
        "sample_index": 0,
        "elapsed_seconds": 0.0,
        "process_attribution": {
            "parent_direct": {"pids": [700], "cpu_percent": 4.0},
            "terminal": {"pids": [710, 711], "cpu_percent": 8.0},
            "webkit": {"pids": [720, 721], "cpu_percent": 12.0},
            "full_tree": {
                "pids": [700, 710, 711, 720, 721],
                "cpu_percent": 24.0,
            },
        },
    },
    {
        "sample_index": 1,
        "elapsed_seconds": 1.0,
        "process_attribution": {
            "parent_direct": {"pids": [700], "cpu_percent": 5.0},
            "terminal": {"pids": [710, 711], "cpu_percent": 9.0},
            "webkit": {"pids": [720, 721], "cpu_percent": 13.0},
            "full_tree": {
                "pids": [700, 710, 711, 720, 721],
                "cpu_percent": 27.0,
            },
        },
    },
]
EXPECTED_CHURN_SAMPLES = [
    {
        "sample_index": 0,
        "elapsed_seconds": 0.25,
        "process_attribution": {
            "parent_direct": {"pids": [700], "cpu_percent": 6.0},
            "terminal": {"pids": [710, 711], "cpu_percent": 14.0},
            "webkit": {"pids": [720, 721], "cpu_percent": 18.0},
            "full_tree": {
                "pids": [700, 710, 711, 720, 721],
                "cpu_percent": 38.0,
            },
        },
    }
]
EXPECTED_LATENCIES_MS = [3.0, 5.0, 7.0, 11.0]
EXPECTED_RENDER_OBSERVATIONS = [
    {"surface_id": "terminal-001", "render_delta": 6},
    {"surface_id": "browser-mixed-realistic-001", "render_delta": 1},
]
EXPECTED_FAILURES = [
    {
        "phase": "churn",
        "operation_index": 3,
        "message": "deterministic synthetic probe miss",
    }
]


def _field(value: Any, name: str) -> Any:
    if isinstance(value, dict):
        return value[name]
    return getattr(value, name)


def _browser_surfaces(plan: Any) -> list[Any]:
    return list(_field(plan, "browser_surfaces"))


def _observed_browsers(plan: Any) -> list[dict[str, str]]:
    return [
        {
            "surface_id": _field(surface, "surface_id"),
            "url": _field(surface, "url"),
            "title": _field(surface, "title"),
            "content_marker": _field(surface, "content_marker"),
        }
        for surface in _browser_surfaces(plan)
    ]


def _expected_churn_operations() -> list[dict[str, Any]]:
    return [
        {
            "operation": "activate",
            "surface_kind": "terminal",
            "surface_id": "terminal-001",
        },
        {
            "operation": "activate",
            "surface_kind": "browser",
            "surface_id": "browser-mixed-realistic-001",
        },
        {
            "operation": "terminal_input",
            "surface_id": "terminal-002",
            "payload": "printf 'cmux-perf-churn:mixed-realistic:terminal-002\\n'",
        },
        {
            "operation": "browser_reload",
            "surface_id": "browser-mixed-realistic-002",
        },
    ]


class FakeRuntimeAdapter:
    """Small synchronous seam for process, fixture, sampling, and cleanup I/O."""

    def __init__(self, owned_root: Path, *, invalid_observation: int | None = None):
        self.owned_root = owned_root
        self.invalid_observation = invalid_observation
        self.events: list[Any] = []
        self.plan: Any | None = None
        self.observation_count = 0
        self.stopped = False
        self.cleaned = False

    def clean_state(self) -> None:
        self.events.append("clean_state")

    def launch(self, sha: str) -> None:
        self.events.append(("launch", sha))

    def create_fixture(self, plan: Any) -> None:
        self.events.append("create_fixture")
        self.plan = plan

    def observe_fixture(self) -> dict[str, Any]:
        self.events.append("observe_fixture")
        self.observation_count += 1
        assert self.plan is not None
        browsers = _observed_browsers(self.plan)
        if self.observation_count == self.invalid_observation:
            browsers[0]["title"] = "wrong restored title"
        return {
            "shape": copy.deepcopy(REQUESTED_SHAPE),
            "browsers": browsers,
        }

    def sample_steady(self) -> list[dict[str, Any]]:
        self.events.append("sample_steady")
        return copy.deepcopy(EXPECTED_STEADY_SAMPLES)

    def run_churn(self, operations: list[dict[str, Any]]) -> dict[str, Any]:
        self.events.append(("run_churn", copy.deepcopy(operations)))
        return {
            "samples": copy.deepcopy(EXPECTED_CHURN_SAMPLES),
            "latencies_ms": list(EXPECTED_LATENCIES_MS),
            "throughput_ops_per_second": 16.0,
            "render_observations": copy.deepcopy(EXPECTED_RENDER_OBSERVATIONS),
            "failures": copy.deepcopy(EXPECTED_FAILURES),
        }

    def snapshot(self) -> dict[str, str]:
        self.events.append("snapshot")
        return {"snapshot_id": "owned-mixed-realistic-snapshot"}

    def restore(self, snapshot: dict[str, str]) -> None:
        self.events.append(("restore", copy.deepcopy(snapshot)))

    def stop(self) -> None:
        self.events.append("stop")
        self.stopped = True

    def cleanup_owned(self) -> dict[str, Any]:
        self.events.append("cleanup_owned")
        self.cleaned = True
        return {
            "stopped": self.stopped,
            "owned_state_removed": True,
            "owned_paths": [str(self.owned_root)],
        }


def _run(adapter: FakeRuntimeAdapter, owned_root: Path) -> Any:
    return perf_runtime.run_invocation(
        scenario_id=SCENARIO_ID,
        sha=SHA,
        order="BA",
        repetition=2,
        requested_shape=copy.deepcopy(REQUESTED_SHAPE),
        owned_root=owned_root,
        adapter=adapter,
    )


def test_browser_fixture_plan_is_local_owned_stable_and_exact(tmp_path: Path) -> None:
    owned_root = tmp_path / "owned-fixtures"
    kwargs = {
        "scenario_id": SCENARIO_ID,
        "terminal_count": 2,
        "browser_count": 2,
        "owned_root": owned_root,
    }

    first = perf_runtime.build_browser_fixture_plan(**kwargs)
    second = perf_runtime.build_browser_fixture_plan(**kwargs)

    assert _field(first, "scenario_id") == SCENARIO_ID
    assert _field(first, "terminal_count") == 2
    assert _field(first, "browser_count") == 2
    assert _observed_browsers(first) == _observed_browsers(second)

    surfaces = _browser_surfaces(first)
    assert len(surfaces) == 2
    assert [_field(surface, "surface_id") for surface in surfaces] == [
        "browser-mixed-realistic-001",
        "browser-mixed-realistic-002",
    ]

    for index, surface in enumerate(surfaces, start=1):
        expected_marker = (
            f"cmux-perf:scenario={SCENARIO_ID};surface=browser-{index:03d}"
        )
        expected_title = f"cmux perf {SCENARIO_ID} browser {index:03d}"
        assert _field(surface, "content_marker") == expected_marker
        assert _field(surface, "title") == expected_title

        parsed = urlparse(_field(surface, "url"))
        assert parsed.scheme == "file"
        assert parsed.netloc == ""
        assert parsed.query == ""
        assert parsed.fragment == ""
        fixture_path = Path(unquote(parsed.path)).resolve()
        assert fixture_path.is_relative_to(owned_root.resolve())
        assert fixture_path.is_file()
        html = fixture_path.read_text(encoding="utf-8")
        assert f"<title>{expected_title}</title>" in html
        assert expected_marker in html


@pytest.mark.parametrize("field", ["surface_id", "url", "title", "content_marker"])
def test_browser_observations_must_match_every_planned_identity_field(
    tmp_path: Path,
    field: str,
) -> None:
    plan = perf_runtime.build_browser_fixture_plan(
        scenario_id=SCENARIO_ID,
        terminal_count=2,
        browser_count=2,
        owned_root=tmp_path / "owned-fixtures",
    )
    observations = _observed_browsers(plan)

    assert perf_runtime.validate_browser_observations(plan, observations) is None

    mismatched = copy.deepcopy(observations)
    mismatched[0][field] = f"wrong-{field}"
    with pytest.raises(ValueError):
        perf_runtime.validate_browser_observations(plan, mismatched)


def test_one_invocation_orders_lifecycle_and_retains_raw_observations(
    tmp_path: Path,
) -> None:
    owned_root = tmp_path / "owned-run"
    adapter = FakeRuntimeAdapter(owned_root)

    result = _run(adapter, owned_root)

    expected_snapshot = {"snapshot_id": "owned-mixed-realistic-snapshot"}
    assert adapter.events == [
        "clean_state",
        ("launch", SHA),
        "create_fixture",
        "observe_fixture",
        "sample_steady",
        ("run_churn", _expected_churn_operations()),
        "snapshot",
        ("restore", expected_snapshot),
        "observe_fixture",
        "stop",
        "cleanup_owned",
    ]
    assert adapter.observation_count == 2

    assert _field(result, "scenario_id") == SCENARIO_ID
    assert _field(result, "sha") == SHA
    assert _field(result, "order") == "BA"
    assert _field(result, "repetition") == 2
    assert _field(result, "requested_shape") == REQUESTED_SHAPE
    assert _field(result, "observed_shape") == REQUESTED_SHAPE

    steady_samples = _field(result, "steady_samples")
    churn_samples = _field(result, "churn_samples")
    assert steady_samples == EXPECTED_STEADY_SAMPLES
    assert churn_samples == EXPECTED_CHURN_SAMPLES
    for sample in [*steady_samples, *churn_samples]:
        assert set(sample["process_attribution"]) == EXPECTED_PROCESS_GROUPS

    assert _field(result, "latencies_ms") == EXPECTED_LATENCIES_MS
    assert _field(result, "throughput_ops_per_second") == 16.0
    assert _field(result, "render_observations") == EXPECTED_RENDER_OBSERVATIONS
    assert _field(result, "failures") == EXPECTED_FAILURES
    assert _field(result, "cleanup") == {
        "stopped": True,
        "owned_state_removed": True,
        "owned_paths": [str(owned_root)],
    }


@pytest.mark.parametrize("invalid_observation", [1, 2])
def test_fixture_validation_failure_still_stops_and_cleans_owned_state(
    tmp_path: Path,
    invalid_observation: int,
) -> None:
    owned_root = tmp_path / "owned-failing-run"
    adapter = FakeRuntimeAdapter(
        owned_root,
        invalid_observation=invalid_observation,
    )

    with pytest.raises(ValueError):
        _run(adapter, owned_root)

    expected_events: list[Any] = [
        "clean_state",
        ("launch", SHA),
        "create_fixture",
        "observe_fixture",
    ]
    if invalid_observation == 2:
        expected_events.extend(
            [
                "sample_steady",
                ("run_churn", _expected_churn_operations()),
                "snapshot",
                ("restore", {"snapshot_id": "owned-mixed-realistic-snapshot"}),
                "observe_fixture",
            ]
        )
    expected_events.extend(["stop", "cleanup_owned"])

    assert adapter.events == expected_events
    assert adapter.stopped is True
    assert adapter.cleaned is True
