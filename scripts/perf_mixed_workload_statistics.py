#!/usr/bin/env python3
"""Pure statistics and acceptance gates for mixed-workload benchmarks."""

from __future__ import annotations

from dataclasses import dataclass
import math
from numbers import Real
from statistics import median
from typing import Any, Iterable, Mapping


_DIRECTIONS = frozenset(("lower_is_better", "higher_is_better"))
_METRIC_GATES = {
    "cpu_percent": ("lower_is_better", 0.05),
    "latency_ms": ("lower_is_better", 0.10),
    "throughput_per_second": ("higher_is_better", 0.05),
}
_REQUIRED_ACCEPTANCE_SCENARIOS = ("terminal-heavy", "browser-heavy", "mixed-heavy")


@dataclass(frozen=True)
class SampleSummary:
    """Robust descriptive statistics plus the samples in observation order."""

    raw_values: tuple[float, ...]
    sample_count: int
    median: float
    iqr: float
    mad: float

    def to_dict(self) -> dict[str, Any]:
        return {
            "raw_values": list(self.raw_values),
            "sample_count": self.sample_count,
            "median": self.median,
            "iqr": self.iqr,
            "mad": self.mad,
        }


@dataclass(frozen=True)
class PairedSampleComparison:
    """Paired changes and a direction-oriented cross-sample effect."""

    direction: str
    baseline: SampleSummary
    candidate: SampleSummary
    absolute_deltas: tuple[float, ...]
    relative_deltas: tuple[float, ...]
    probability_candidate_better: float
    oriented_effect_size: float

    @property
    def sample_count(self) -> int:
        return len(self.absolute_deltas)

    def to_dict(self) -> dict[str, Any]:
        return {
            "direction": self.direction,
            "baseline": self.baseline.to_dict(),
            "candidate": self.candidate.to_dict(),
            "sample_count": self.sample_count,
            "absolute_deltas": list(self.absolute_deltas),
            "relative_deltas": list(self.relative_deltas),
            "probability_candidate_better": self.probability_candidate_better,
            "oriented_effect_size": self.oriented_effect_size,
        }


@dataclass(frozen=True)
class PairedSampleGroup:
    """One scenario, order, and metric stratum of paired observations."""

    scenario_id: str
    order: str
    metric: str
    direction: str
    baseline_values: tuple[float, ...]
    candidate_values: tuple[float, ...]
    comparison: PairedSampleComparison

    @property
    def sample_count(self) -> int:
        return len(self.baseline_values)

    def to_dict(self) -> dict[str, Any]:
        return {
            "scenario_id": self.scenario_id,
            "order": self.order,
            "metric": self.metric,
            "direction": self.direction,
            "sample_count": self.sample_count,
            "baseline_values": list(self.baseline_values),
            "candidate_values": list(self.candidate_values),
            "comparison": self.comparison.to_dict(),
        }


@dataclass(frozen=True)
class MetricGate:
    """Maximum permitted regression for one benchmark metric."""

    metric: str
    direction: str
    baseline_value: float
    candidate_value: float
    threshold: float
    relative_change: float
    relative_regression: float
    passed: bool

    def to_dict(self) -> dict[str, Any]:
        return {
            "metric": self.metric,
            "direction": self.direction,
            "baseline_value": self.baseline_value,
            "candidate_value": self.candidate_value,
            "threshold": self.threshold,
            "relative_change": self.relative_change,
            "relative_regression": self.relative_regression,
            "passed": self.passed,
        }


def _finite_values(values: Iterable[float], *, name: str) -> tuple[float, ...]:
    if isinstance(values, (str, bytes)):
        raise ValueError(f"{name} must be a nonempty iterable of finite numbers")

    try:
        raw_values = tuple(values)
    except TypeError as error:
        raise ValueError(f"{name} must be a nonempty iterable of finite numbers") from error

    if not raw_values:
        raise ValueError(f"{name} must not be empty")

    converted: list[float] = []
    for value in raw_values:
        if isinstance(value, bool) or not isinstance(value, Real):
            raise ValueError(f"{name} must contain only finite numbers")
        converted_value = float(value)
        if not math.isfinite(converted_value):
            raise ValueError(f"{name} must contain only finite numbers")
        converted.append(converted_value)
    return tuple(converted)


def _finite_value(value: float, *, name: str) -> float:
    return _finite_values((value,), name=name)[0]


def _validate_direction(direction: str) -> None:
    if direction not in _DIRECTIONS:
        raise ValueError(
            "direction must be 'lower_is_better' or 'higher_is_better'"
        )


def _relative_delta(candidate: float, baseline: float) -> float:
    """Return a finite relative delta, saturating zero-to-nonzero transitions."""
    if baseline == 0.0:
        if candidate == 0.0:
            return 0.0
        return 1.0 if candidate > 0.0 else -1.0
    return (candidate - baseline) / baseline



def _quartiles(sorted_values: tuple[float, ...]) -> tuple[float, float]:
    """Return Tukey hinges, excluding the center observation for odd counts."""
    count = len(sorted_values)
    if count == 1:
        return sorted_values[0], sorted_values[0]

    midpoint = count // 2
    lower = sorted_values[:midpoint]
    upper = sorted_values[-midpoint:]
    return float(median(lower)), float(median(upper))


def summarize_samples(values: Iterable[float]) -> SampleSummary:
    """Summarize finite samples without changing their observation order."""
    raw_values = _finite_values(values, name="values")
    sorted_values = tuple(sorted(raw_values))
    center = float(median(sorted_values))
    first_quartile, third_quartile = _quartiles(sorted_values)
    deviations = tuple(abs(value - center) for value in raw_values)
    return SampleSummary(
        raw_values=raw_values,
        sample_count=len(raw_values),
        median=center,
        iqr=third_quartile - first_quartile,
        mad=float(median(deviations)),
    )


def compare_paired_samples(
    baseline_values: Iterable[float],
    candidate_values: Iterable[float],
    direction: str,
) -> PairedSampleComparison:
    """Compare matched observations and compute a common-language effect."""
    _validate_direction(direction)
    baseline = _finite_values(baseline_values, name="baseline_values")
    candidate = _finite_values(candidate_values, name="candidate_values")
    if len(baseline) != len(candidate):
        raise ValueError("baseline_values and candidate_values must have matching lengths")
    if any(value < 0.0 for value in (*baseline, *candidate)):
        raise ValueError("sample values must be nonnegative")

    absolute_deltas = tuple(
        candidate_value - baseline_value
        for baseline_value, candidate_value in zip(baseline, candidate, strict=True)
    )
    relative_deltas = tuple(
        _relative_delta(candidate_value, baseline_value)
        for baseline_value, candidate_value in zip(baseline, candidate, strict=True)
    )

    wins = 0.0
    for candidate_value in candidate:
        for baseline_value in baseline:
            if candidate_value == baseline_value:
                wins += 0.5
            elif (
                direction == "lower_is_better" and candidate_value < baseline_value
            ) or (
                direction == "higher_is_better" and candidate_value > baseline_value
            ):
                wins += 1.0
    probability_candidate_better = wins / (len(baseline) * len(candidate))

    return PairedSampleComparison(
        direction=direction,
        baseline=summarize_samples(baseline),
        candidate=summarize_samples(candidate),
        absolute_deltas=absolute_deltas,
        relative_deltas=relative_deltas,
        probability_candidate_better=probability_candidate_better,
        oriented_effect_size=2.0 * probability_candidate_better - 1.0,
    )


def _record_field(record: Mapping[str, Any] | object, name: str) -> Any:
    if isinstance(record, Mapping):
        try:
            return record[name]
        except KeyError as error:
            raise ValueError(f"record is missing {name!r}") from error
    try:
        return getattr(record, name)
    except AttributeError as error:
        raise ValueError(f"record is missing {name!r}") from error


def aggregate_paired_samples(
    records: Iterable[Mapping[str, Any] | object],
) -> tuple[PairedSampleGroup, ...]:
    """Aggregate observations while retaining scenario and AB/BA strata."""
    if isinstance(records, (str, bytes)):
        raise ValueError("records must be a nonempty iterable")
    try:
        input_records = tuple(records)
    except TypeError as error:
        raise ValueError("records must be a nonempty iterable") from error
    if not input_records:
        raise ValueError("records must not be empty")

    grouped: dict[
        tuple[str, str, str], tuple[str, list[float], list[float]]
    ] = {}
    for record in input_records:
        scenario_id = _record_field(record, "scenario_id")
        order = _record_field(record, "order")
        metric = _record_field(record, "metric")
        direction = _record_field(record, "direction")
        if not isinstance(scenario_id, str) or not scenario_id:
            raise ValueError("record scenario_id must be a nonempty string")
        if order not in ("AB", "BA"):
            raise ValueError("record order must be 'AB' or 'BA'")
        if metric not in _METRIC_GATES:
            raise ValueError(f"unknown metric: {metric!r}")
        _validate_direction(direction)
        expected_direction, _ = _METRIC_GATES[metric]
        if direction != expected_direction:
            raise ValueError(
                f"metric {metric!r} requires direction {expected_direction!r}"
            )
        baseline_value = _finite_value(
            _record_field(record, "baseline_value"), name="baseline_value"
        )
        candidate_value = _finite_value(
            _record_field(record, "candidate_value"), name="candidate_value"
        )
        if baseline_value < 0.0 or candidate_value < 0.0:
            raise ValueError("metric values must be nonnegative")

        key = (scenario_id, order, metric)
        if key not in grouped:
            grouped[key] = (direction, [], [])
        _, baseline_values, candidate_values = grouped[key]
        baseline_values.append(baseline_value)
        candidate_values.append(candidate_value)

    groups: list[PairedSampleGroup] = []
    for (scenario_id, order, metric), (
        direction,
        baseline_values,
        candidate_values,
    ) in grouped.items():
        comparison = compare_paired_samples(
            baseline_values, candidate_values, direction
        )
        groups.append(
            PairedSampleGroup(
                scenario_id=scenario_id,
                order=order,
                metric=metric,
                direction=direction,
                baseline_values=tuple(baseline_values),
                candidate_values=tuple(candidate_values),
                comparison=comparison,
            )
        )
    return tuple(groups)


def evaluate_metric_gate(
    metric: str,
    baseline_value: float,
    candidate_value: float,
) -> MetricGate:
    """Evaluate a metric's candidate result against its regression budget."""
    if metric not in _METRIC_GATES:
        raise ValueError(f"unknown metric: {metric!r}")
    baseline = _finite_value(baseline_value, name="baseline_value")
    candidate = _finite_value(candidate_value, name="candidate_value")
    if baseline < 0.0 or candidate < 0.0:
        raise ValueError("metric values must be nonnegative")

    direction, threshold = _METRIC_GATES[metric]
    relative_change = _relative_delta(candidate, baseline)
    relative_regression = (
        relative_change
        if direction == "lower_is_better"
        else -relative_change
    )
    return MetricGate(
        metric=metric,
        direction=direction,
        baseline_value=baseline,
        candidate_value=candidate,
        threshold=threshold,
        relative_change=relative_change,
        relative_regression=relative_regression,
        passed=relative_regression <= threshold,
    )


def evaluate_final_acceptance(
    scenario_gates: Mapping[str, Mapping[str, Any] | MetricGate],
) -> bool:
    """Require the browser-heavy and mixed-heavy scenario gates to pass."""
    if not isinstance(scenario_gates, Mapping):
        raise ValueError("scenario_gates must be a mapping")

    for scenario_id in _REQUIRED_ACCEPTANCE_SCENARIOS:
        if scenario_id not in scenario_gates:
            return False
        gate = scenario_gates[scenario_id]
        if isinstance(gate, Mapping):
            passed = gate.get("passed")
        else:
            passed = getattr(gate, "passed", None)
        if passed is not True:
            return False
    return True
