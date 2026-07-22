#!/usr/bin/env python3
"""Behavioral contracts for the mixed terminal/browser performance matrix."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "perf_mixed_workload_contract.py"
spec = importlib.util.spec_from_file_location("perf_mixed_workload_contract", SCRIPT)
assert spec is not None and spec.loader is not None
perf_contract = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = perf_contract
spec.loader.exec_module(perf_contract)

BASELINE_SHA = "0123456789abcdef0123456789abcdef01234567"
CANDIDATE_SHA = "fedcba9876543210fedcba9876543210fedcba98"

EXPECTED_SCENARIOS = {
    "terminal-light": {
        "kind": "terminal",
        "load": "light",
        "terminal_surfaces": 4,
        "browser_surfaces": 0,
        "aggregate_scrollback_chars": 100_000,
    },
    "terminal-realistic": {
        "kind": "terminal",
        "load": "realistic",
        "terminal_surfaces": 16,
        "browser_surfaces": 0,
        "aggregate_scrollback_chars": 1_000_000,
    },
    "terminal-heavy": {
        "kind": "terminal",
        "load": "heavy",
        "terminal_surfaces": 40,
        "browser_surfaces": 0,
        "aggregate_scrollback_chars": 3_000_000,
    },
    "browser-light": {
        "kind": "browser",
        "load": "light",
        "terminal_surfaces": 0,
        "browser_surfaces": 1,
        "aggregate_scrollback_chars": 0,
    },
    "browser-realistic": {
        "kind": "browser",
        "load": "realistic",
        "terminal_surfaces": 0,
        "browser_surfaces": 4,
        "aggregate_scrollback_chars": 0,
    },
    "browser-heavy": {
        "kind": "browser",
        "load": "heavy",
        "terminal_surfaces": 0,
        "browser_surfaces": 12,
        "aggregate_scrollback_chars": 0,
    },
    "mixed-light": {
        "kind": "mixed",
        "load": "light",
        "terminal_surfaces": 2,
        "browser_surfaces": 1,
        "aggregate_scrollback_chars": 100_000,
    },
    "mixed-realistic": {
        "kind": "mixed",
        "load": "realistic",
        "terminal_surfaces": 8,
        "browser_surfaces": 4,
        "aggregate_scrollback_chars": 1_000_000,
    },
    "mixed-heavy": {
        "kind": "mixed",
        "load": "heavy",
        "terminal_surfaces": 20,
        "browser_surfaces": 12,
        "aggregate_scrollback_chars": 3_000_000,
    },
}


def _field(record: Any, name: str) -> Any:
    if isinstance(record, dict):
        return record[name]
    return getattr(record, name)


def _scenarios_by_id() -> dict[str, Any]:
    scenarios = perf_contract.scenario_matrix()
    return {_field(scenario, "scenario_id"): scenario for scenario in scenarios}


def _scenario_contract(scenario: Any) -> dict[str, Any]:
    return {
        "kind": _field(scenario, "kind"),
        "load": _field(scenario, "load"),
        "terminal_surfaces": _field(scenario, "terminal_surfaces"),
        "browser_surfaces": _field(scenario, "browser_surfaces"),
        "aggregate_scrollback_chars": _field(scenario, "aggregate_scrollback_chars"),
    }


def _expected_snapshot(scenario: dict[str, Any]) -> dict[str, Any]:
    terminal_count = scenario["terminal_surfaces"]
    browser_count = scenario["browser_surfaces"]
    return {
        "built": True,
        "include_scrollback": True,
        "persist": True,
        "saved": True,
        "shape": {
            "windows": 1,
            "workspaces": 1,
            "panels": terminal_count + browser_count,
            "terminals": terminal_count,
            "browsers": browser_count,
            "markdown": 0,
            "scrollback_chars": scenario["aggregate_scrollback_chars"],
            "status_entries": 0,
            "log_entries": 0,
            "progress_entries": 0,
            "git_entries": 0,
        },
    }


def _snapshot_contract(snapshot: Any) -> dict[str, Any]:
    shape = _field(snapshot, "shape")
    return {
        "built": _field(snapshot, "built"),
        "include_scrollback": _field(snapshot, "include_scrollback"),
        "persist": _field(snapshot, "persist"),
        "saved": _field(snapshot, "saved"),
        "shape": {
            "windows": _field(shape, "windows"),
            "workspaces": _field(shape, "workspaces"),
            "panels": _field(shape, "panels"),
            "terminals": _field(shape, "terminals"),
            "browsers": _field(shape, "browsers"),
            "markdown": _field(shape, "markdown"),
            "scrollback_chars": _field(shape, "scrollback_chars"),
            "status_entries": _field(shape, "status_entries"),
            "log_entries": _field(shape, "log_entries"),
            "progress_entries": _field(shape, "progress_entries"),
            "git_entries": _field(shape, "git_entries"),
        },
    }


def _assert_snapshot_rejected(scenario: Any, snapshot: dict[str, Any]) -> None:
    try:
        perf_contract.validate_snapshot(scenario, snapshot)
    except ValueError:
        return
    raise AssertionError("validate_snapshot accepted an invalid snapshot")


def test_scenario_matrix_has_exact_nine_ids_and_counts() -> None:
    scenarios = _scenarios_by_id()

    assert set(scenarios) == set(EXPECTED_SCENARIOS)
    assert len(scenarios) == 9
    assert {
        scenario_id: _scenario_contract(scenario)
        for scenario_id, scenario in scenarios.items()
    } == EXPECTED_SCENARIOS


def test_experiment_plan_keeps_ab_and_ba_orders_separate() -> None:
    plan = perf_contract.build_experiment_plan(
        baseline_sha=BASELINE_SHA,
        candidate_sha=CANDIDATE_SHA,
    )

    assert len(plan) == 9 * 2 * 4
    for scenario_id in EXPECTED_SCENARIOS:
        scenario_runs = [run for run in plan if _field(run, "scenario_id") == scenario_id]
        assert {_field(run, "order") for run in scenario_runs} == {"AB", "BA"}

        for order, expected_variants in (("AB", ["A", "B"]), ("BA", ["B", "A"])):
            order_runs = [run for run in scenario_runs if _field(run, "order") == order]
            assert len(order_runs) == 4
            assert sum(_field(run, "warmup") is True for run in order_runs) == 1

            warmups = [run for run in order_runs if _field(run, "warmup") is True]
            measured = [run for run in order_runs if _field(run, "warmup") is False]
            assert [_field(run, "repetition") for run in warmups] == [0]
            assert [_field(run, "repetition") for run in measured] == [1, 2, 3]

            for run in order_runs:
                invocations = _field(run, "invocations")
                assert [_field(invocation, "variant") for invocation in invocations] == expected_variants


def test_every_planned_variant_uses_exact_sha_and_recreates_clean_state() -> None:
    plan = perf_contract.build_experiment_plan(
        baseline_sha=BASELINE_SHA,
        candidate_sha=CANDIDATE_SHA,
    )
    expected_shas = {"A": BASELINE_SHA, "B": CANDIDATE_SHA}

    assert len(BASELINE_SHA) == 40
    assert len(CANDIDATE_SHA) == 40
    for run in plan:
        assert len(_field(run, "invocations")) == 2
        for invocation in _field(run, "invocations"):
            variant = _field(invocation, "variant")
            sha = _field(invocation, "sha")
            assert sha == expected_shas[variant]
            assert len(sha) == 40
            assert _field(invocation, "recreate_process") is True
            assert _field(invocation, "recreate_fixture") is True


def test_expected_snapshot_is_exact_for_every_terminal_browser_and_mixed_scenario() -> None:
    scenarios = _scenarios_by_id()

    assert set(scenarios) == set(EXPECTED_SCENARIOS)
    for scenario_id, expected_scenario in EXPECTED_SCENARIOS.items():
        expected = _expected_snapshot(expected_scenario)
        actual = perf_contract.expected_snapshot(scenarios[scenario_id])
        assert _snapshot_contract(actual) == expected
        assert perf_contract.validate_snapshot(scenarios[scenario_id], expected) is None


def test_snapshot_validation_rejects_mismatched_browser_count() -> None:
    scenarios = _scenarios_by_id()
    scenario = scenarios["mixed-realistic"]
    snapshot = _expected_snapshot(EXPECTED_SCENARIOS["mixed-realistic"])
    snapshot["shape"]["browsers"] = 3

    _assert_snapshot_rejected(scenario, snapshot)


def test_snapshot_validation_rejects_any_false_snapshot_flag() -> None:
    scenarios = _scenarios_by_id()
    scenario = scenarios["terminal-light"]

    for flag in ("built", "include_scrollback", "persist", "saved"):
        snapshot = _expected_snapshot(EXPECTED_SCENARIOS["terminal-light"])
        snapshot[flag] = False
        _assert_snapshot_rejected(scenario, snapshot)
