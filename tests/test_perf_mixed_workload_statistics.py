#!/usr/bin/env python3
"""Behavioral contracts for mixed-workload benchmark statistics and gates."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "perf_mixed_workload_statistics.py"
spec = importlib.util.spec_from_file_location("perf_mixed_workload_statistics", SCRIPT)
assert spec is not None and spec.loader is not None
perf_statistics = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = perf_statistics
spec.loader.exec_module(perf_statistics)

ABS_TOL = 1e-12
REL_TOL = 1e-12


def _field(record: Any, name: str) -> Any:
    if isinstance(record, dict):
        return record[name]
    return getattr(record, name)


def _assert_close(actual: float, expected: float) -> None:
    assert abs(actual - expected) <= max(ABS_TOL, REL_TOL * abs(expected))


def _assert_float_list(actual: Any, expected: list[float]) -> None:
    assert len(actual) == len(expected)
    for actual_value, expected_value in zip(actual, expected, strict=True):
        _assert_close(actual_value, expected_value)


def test_sample_summary_reports_deterministic_median_iqr_mad_count_and_raw_values() -> None:
    # Repeated quartile values make the expected IQR independent of percentile
    # interpolation conventions. MAD is the unscaled median absolute deviation.
    samples = [9.0, 1.0, 9.0, 1.0, 5.0, 9.0, 1.0, 9.0, 1.0]

    summary = perf_statistics.summarize_samples(samples)

    assert _field(summary, "sample_count") == 9
    assert list(_field(summary, "raw_values")) == samples
    _assert_close(_field(summary, "median"), 5.0)
    _assert_close(_field(summary, "iqr"), 8.0)
    _assert_close(_field(summary, "mad"), 4.0)


def test_lower_is_better_comparison_reports_paired_deltas_and_oriented_effect() -> None:
    comparison = perf_statistics.compare_paired_samples(
        baseline_values=[10.0, 20.0, 30.0],
        candidate_values=[5.0, 15.0, 25.0],
        direction="lower_is_better",
    )

    # Deltas retain candidate-minus-baseline sign regardless of metric direction.
    _assert_float_list(_field(comparison, "absolute_deltas"), [-5.0, -5.0, -5.0])
    _assert_float_list(
        _field(comparison, "relative_deltas"),
        [-0.5, -0.25, -1.0 / 6.0],
    )
    # Common-language probability compares every candidate value with every
    # baseline value, counting a tie as half a win. The effect is oriented so
    # positive always means the candidate is better: wins minus losses over all
    # cross-sample pairs (equivalently 2 * probability - 1).
    _assert_close(_field(comparison, "probability_candidate_better"), 2.0 / 3.0)
    _assert_close(_field(comparison, "oriented_effect_size"), 1.0 / 3.0)


def test_higher_is_better_comparison_reports_paired_deltas_and_oriented_effect() -> None:
    comparison = perf_statistics.compare_paired_samples(
        baseline_values=[100.0, 200.0, 300.0],
        candidate_values=[150.0, 250.0, 350.0],
        direction="higher_is_better",
    )

    _assert_float_list(_field(comparison, "absolute_deltas"), [50.0, 50.0, 50.0])
    _assert_float_list(
        _field(comparison, "relative_deltas"),
        [0.5, 0.25, 1.0 / 6.0],
    )
    _assert_close(_field(comparison, "probability_candidate_better"), 2.0 / 3.0)
    _assert_close(_field(comparison, "oriented_effect_size"), 1.0 / 3.0)


def test_aggregation_never_pools_scenario_ids_or_ab_ba_orders() -> None:
    records = [
        {
            "scenario_id": "terminal-heavy",
            "order": "AB",
            "metric": "cpu_percent",
            "direction": "lower_is_better",
            "baseline_value": 10.0,
            "candidate_value": 9.0,
        },
        {
            "scenario_id": "terminal-heavy",
            "order": "BA",
            "metric": "cpu_percent",
            "direction": "lower_is_better",
            "baseline_value": 30.0,
            "candidate_value": 27.0,
        },
        {
            "scenario_id": "browser-heavy",
            "order": "AB",
            "metric": "cpu_percent",
            "direction": "lower_is_better",
            "baseline_value": 50.0,
            "candidate_value": 45.0,
        },
        {
            "scenario_id": "terminal-heavy",
            "order": "AB",
            "metric": "cpu_percent",
            "direction": "lower_is_better",
            "baseline_value": 12.0,
            "candidate_value": 11.0,
        },
        {
            "scenario_id": "terminal-heavy",
            "order": "BA",
            "metric": "cpu_percent",
            "direction": "lower_is_better",
            "baseline_value": 32.0,
            "candidate_value": 28.0,
        },
        {
            "scenario_id": "browser-heavy",
            "order": "AB",
            "metric": "cpu_percent",
            "direction": "lower_is_better",
            "baseline_value": 52.0,
            "candidate_value": 46.0,
        },
    ]

    groups = perf_statistics.aggregate_paired_samples(records)
    keyed = {
        (
            _field(group, "scenario_id"),
            _field(group, "order"),
            _field(group, "metric"),
        ): group
        for group in groups
    }

    assert set(keyed) == {
        ("terminal-heavy", "AB", "cpu_percent"),
        ("terminal-heavy", "BA", "cpu_percent"),
        ("browser-heavy", "AB", "cpu_percent"),
    }
    expected_raw_values = {
        ("terminal-heavy", "AB", "cpu_percent"): ([10.0, 12.0], [9.0, 11.0]),
        ("terminal-heavy", "BA", "cpu_percent"): ([30.0, 32.0], [27.0, 28.0]),
        ("browser-heavy", "AB", "cpu_percent"): ([50.0, 52.0], [45.0, 46.0]),
    }
    for key, (expected_baseline, expected_candidate) in expected_raw_values.items():
        group = keyed[key]
        assert _field(group, "sample_count") == 2
        assert list(_field(group, "baseline_values")) == expected_baseline
        assert list(_field(group, "candidate_values")) == expected_candidate


def _assert_gate(
    metric: str,
    baseline_value: float,
    candidate_value: float,
    *,
    expected_threshold: float,
    expected_regression: float,
    expected_passed: bool,
) -> None:
    result = perf_statistics.evaluate_metric_gate(
        metric=metric,
        baseline_value=baseline_value,
        candidate_value=candidate_value,
    )

    assert _field(result, "passed") is expected_passed
    _assert_close(_field(result, "threshold"), expected_threshold)
    _assert_close(_field(result, "relative_regression"), expected_regression)


def test_cpu_gate_passes_at_five_percent_and_fails_above_it() -> None:
    _assert_gate(
        "cpu_percent",
        100.0,
        105.0,
        expected_threshold=0.05,
        expected_regression=0.05,
        expected_passed=True,
    )
    _assert_gate(
        "cpu_percent",
        100.0,
        105.0001,
        expected_threshold=0.05,
        expected_regression=0.050001,
        expected_passed=False,
    )


def test_latency_gate_passes_at_ten_percent_and_fails_above_it() -> None:
    _assert_gate(
        "latency_ms",
        100.0,
        110.0,
        expected_threshold=0.10,
        expected_regression=0.10,
        expected_passed=True,
    )
    _assert_gate(
        "latency_ms",
        100.0,
        110.0001,
        expected_threshold=0.10,
        expected_regression=0.100001,
        expected_passed=False,
    )


def test_throughput_gate_passes_at_five_percent_drop_and_fails_above_it() -> None:
    _assert_gate(
        "throughput_per_second",
        100.0,
        95.0,
        expected_threshold=0.05,
        expected_regression=0.05,
        expected_passed=True,
    )
    _assert_gate(
        "throughput_per_second",
        100.0,
        94.9999,
        expected_threshold=0.05,
        expected_regression=0.050001,
        expected_passed=False,
    )


def test_final_acceptance_requires_browser_heavy_and_mixed_heavy_to_pass() -> None:
    terminal_improves = {
        "passed": True,
        "relative_change": -0.50,
    }
    passing = {
        "passed": True,
        "relative_change": 0.0,
    }
    failing = {
        "passed": False,
        "relative_change": 0.11,
    }

    assert perf_statistics.evaluate_final_acceptance(
        {
            "terminal-heavy": terminal_improves,
            "browser-heavy": failing,
            "mixed-heavy": passing,
        }
    ) is False
    assert perf_statistics.evaluate_final_acceptance(
        {
            "terminal-heavy": terminal_improves,
            "browser-heavy": passing,
            "mixed-heavy": failing,
        }
    ) is False
    assert perf_statistics.evaluate_final_acceptance(
        {
            "terminal-heavy": terminal_improves,
            "browser-heavy": passing,
            "mixed-heavy": passing,
        }
    ) is True


def test_final_acceptance_requires_terminal_heavy_to_pass() -> None:
    passing = {"passed": True, "relative_change": 0.0}
    failing = {"passed": False, "relative_change": 0.06}

    assert perf_statistics.evaluate_final_acceptance(
        {
            "terminal-heavy": failing,
            "browser-heavy": passing,
            "mixed-heavy": passing,
        }
    ) is False
    assert perf_statistics.evaluate_final_acceptance(
        {
            "browser-heavy": passing,
            "mixed-heavy": passing,
        }
    ) is False
