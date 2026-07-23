#!/usr/bin/env python3
"""Paired mixed-workload execution, macOS adapter binding, and analysis.

Pure planning and analysis remain injectable for Linux behavior tests; the CLI
binds them to the tagged cmux runtime adapter on the owned macOS runner.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import importlib.util
import json
import math
import os
import re
from pathlib import Path
import sys
import tempfile
from types import MappingProxyType
from typing import Any, Callable, Iterable, Mapping


def _load_sibling(module_name: str) -> Any:
    existing = sys.modules.get(module_name)
    if existing is not None:
        return existing
    path = Path(__file__).with_name(f"{module_name}.py")
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {module_name} from {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


_contract = _load_sibling("perf_mixed_workload_contract")
_statistics = _load_sibling("perf_mixed_workload_statistics")


METRIC_GATES: Mapping[str, tuple[str, float]] = MappingProxyType(
    {
        "steady_parent_cpu_percent": ("lower_is_better", 0.05),
        "steady_full_tree_cpu_percent": ("lower_is_better", 0.05),
        "steady_terminal_cpu_percent": ("lower_is_better", 0.05),
        "steady_webkit_cpu_percent": ("lower_is_better", 0.05),
        "churn_parent_cpu_percent": ("lower_is_better", 0.05),
        "churn_full_tree_cpu_percent": ("lower_is_better", 0.05),
        "churn_terminal_cpu_percent": ("lower_is_better", 0.05),
        "churn_webkit_cpu_percent": ("lower_is_better", 0.05),
        "browser_latency_ms": ("lower_is_better", 0.10),
        "terminal_throughput_per_second": ("higher_is_better", 0.05),
        "browser_throughput_per_second": ("higher_is_better", 0.05),
        "terminal_render_rate": ("higher_is_better", 0.05),
        "browser_render_rate": ("higher_is_better", 0.05),
    }
)
_REQUIRED_METRICS_BY_KIND: Mapping[str, tuple[str, ...]] = MappingProxyType(
    {
        "terminal": (
            "steady_parent_cpu_percent",
            "steady_full_tree_cpu_percent",
            "steady_terminal_cpu_percent",
            "churn_parent_cpu_percent",
            "churn_full_tree_cpu_percent",
            "churn_terminal_cpu_percent",
            "terminal_throughput_per_second",
            "terminal_render_rate",
        ),
        "browser": (
            "steady_parent_cpu_percent",
            "steady_full_tree_cpu_percent",
            "steady_webkit_cpu_percent",
            "churn_parent_cpu_percent",
            "churn_full_tree_cpu_percent",
            "churn_webkit_cpu_percent",
            "browser_latency_ms",
            "browser_throughput_per_second",
            "browser_render_rate",
        ),
        "mixed": tuple(METRIC_GATES),
    }
)

_SCHEMA = "cmux.perf.mixed-workload-experiment/v1"
_ANALYSIS_SCHEMA = "cmux.perf.mixed-workload-analysis/v1"
_SHA_RE = re.compile(r"[0-9a-fA-F]{40}\Z")


def _plain_json(value: Any) -> Any:
    if hasattr(value, "to_dict"):
        return _plain_json(value.to_dict())
    if isinstance(value, Mapping):
        return {str(key): _plain_json(item) for key, item in value.items()}
    if isinstance(value, (tuple, list)):
        return [_plain_json(item) for item in value]
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    raise ValueError(f"value is not JSON-friendly: {type(value).__name__}")


def _immutable_mapping(value: Mapping[str, Any] | None, *, name: str) -> Mapping[str, Any]:
    if value is None:
        return MappingProxyType({})
    if not isinstance(value, Mapping):
        raise ValueError(f"{name} must be a mapping")
    plain = _plain_json(value)
    if not isinstance(plain, dict):
        raise ValueError(f"{name} must be a mapping")
    return MappingProxyType(plain)


@dataclass(frozen=True, slots=True)
class VariantConfig:
    """One immutable build identity passed to the execution adapter."""

    variant: str
    sha: str
    tag: str
    app_path: str

    def __post_init__(self) -> None:
        if self.variant not in ("A", "B"):
            raise ValueError("variant must be 'A' or 'B'")
        if not isinstance(self.tag, str) or not self.tag:
            raise ValueError("tag must be a nonempty string")
        if not isinstance(self.app_path, str) or not self.app_path:
            raise ValueError("app_path must be a nonempty string")

    def to_dict(self) -> dict[str, str]:
        return {
            "variant": self.variant,
            "sha": self.sha,
            "tag": self.tag,
            "app_path": self.app_path,
        }


@dataclass(frozen=True, slots=True)
class ExperimentRecord:
    """Successful raw observation from one variant invocation."""

    scenario_id: str
    kind: str
    load: str
    order: str
    repetition: int
    warmup: bool
    variant: str
    sha: str
    metrics: Mapping[str, float]
    cleanup: Mapping[str, Any] | None = None

    def __post_init__(self) -> None:
        immutable_metrics = _immutable_mapping(self.metrics, name="metrics")
        for metric, value in immutable_metrics.items():
            if metric not in METRIC_GATES:
                raise ValueError(f"unknown metric: {metric!r}")
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                raise ValueError(f"metric {metric!r} must be a finite number")
            if not math.isfinite(float(value)):
                raise ValueError(f"metric {metric!r} must be a finite number")
        object.__setattr__(self, "metrics", immutable_metrics)
        object.__setattr__(
            self,
            "cleanup",
            _immutable_mapping(self.cleanup, name="cleanup"),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "scenario_id": self.scenario_id,
            "kind": self.kind,
            "load": self.load,
            "order": self.order,
            "repetition": self.repetition,
            "warmup": self.warmup,
            "variant": self.variant,
            "sha": self.sha,
            "metrics": dict(self.metrics),
            "cleanup": _plain_json(self.cleanup),
        }


@dataclass(frozen=True, slots=True)
class InvocationFailure:
    """Retained exception details for one failed invocation."""

    scenario_id: str
    kind: str
    load: str
    order: str
    repetition: int
    warmup: bool
    variant: str
    sha: str
    error_type: str
    message: str
    raw_path: str
    cleanup: Mapping[str, Any] | None = None

    def __post_init__(self) -> None:
        object.__setattr__(
            self,
            "cleanup",
            _immutable_mapping(self.cleanup, name="cleanup"),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "scenario_id": self.scenario_id,
            "kind": self.kind,
            "load": self.load,
            "order": self.order,
            "repetition": self.repetition,
            "warmup": self.warmup,
            "variant": self.variant,
            "sha": self.sha,
            "error_type": self.error_type,
            "message": self.message,
            "raw_path": self.raw_path,
            "cleanup": _plain_json(self.cleanup),
        }


@dataclass(frozen=True, slots=True)
class ExperimentResult:
    """In-memory result plus the two stable machine-output paths."""

    records: tuple[ExperimentRecord, ...]
    failures: tuple[InvocationFailure, ...]
    manifest: Mapping[str, Any]
    analysis: Mapping[str, Any]
    manifest_path: Path
    analysis_path: Path


def _atomic_write_json(path: Path, payload: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(_plain_json(payload), stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


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


def _statistics_metric(metric: str) -> str:
    if metric.endswith("cpu_percent"):
        return "cpu_percent"
    if metric == "browser_latency_ms":
        return "latency_ms"
    return "throughput_per_second"


def _comparison_group(
    scenario_id: str,
    order: str,
    metric: str,
    baseline_values: list[float],
    candidate_values: list[float],
) -> dict[str, Any]:
    direction, threshold = METRIC_GATES[metric]
    comparison = _statistics.compare_paired_samples(
        baseline_values, candidate_values, direction
    )
    baseline_median = comparison.baseline.median
    candidate_median = comparison.candidate.median
    gate = _statistics.evaluate_metric_gate(
        _statistics_metric(metric), baseline_median, candidate_median
    ).to_dict()
    gate["metric"] = metric
    # These are predeclared by this driver; retaining them explicitly prevents a
    # generic statistics name from leaking into machine output.
    gate["direction"] = direction
    gate["threshold"] = threshold
    return {
        "scenario_id": scenario_id,
        "order": order,
        "metric": metric,
        "direction": direction,
        "sample_count": len(baseline_values),
        "comparison": comparison.to_dict(),
        "gate": gate,
    }


def analyze_experiment(
    records: Iterable[Mapping[str, Any] | ExperimentRecord],
) -> dict[str, Any]:
    """Analyze complete measured pairs without pooling scenario or order strata."""
    if isinstance(records, (str, bytes)):
        raise ValueError("records must be an iterable of experiment records")
    input_records = tuple(records)

    scenarios = {
        scenario.scenario_id: scenario for scenario in _contract.scenario_matrix()
    }
    variant_shas: dict[str, set[str]] = {"A": set(), "B": set()}
    paired: dict[tuple[str, str, int], dict[str, Mapping[str, Any] | object]] = {}
    for record in input_records:
        scenario_id = _record_field(record, "scenario_id")
        scenario = scenarios.get(scenario_id)
        if scenario is None:
            raise ValueError(f"unknown scenario_id: {scenario_id!r}")
        if (
            _record_field(record, "kind") != scenario.kind
            or _record_field(record, "load") != scenario.load
        ):
            raise ValueError(f"record scenario metadata does not match {scenario_id}")

        order = _record_field(record, "order")
        repetition = _record_field(record, "repetition")
        variant = _record_field(record, "variant")
        warmup = _record_field(record, "warmup")
        sha = _record_field(record, "sha")
        if order not in ("AB", "BA") or variant not in ("A", "B"):
            raise ValueError("record order and variant must use AB/BA and A/B")
        if type(warmup) is not bool:
            raise ValueError("record warmup must be a boolean")
        if type(repetition) is not int:
            raise ValueError("record repetition must be an integer")
        if warmup:
            if repetition != 0:
                raise ValueError("warmup repetition must be zero")
        elif repetition not in (1, 2, 3):
            raise ValueError("measured repetition must be one of 1, 2, or 3")
        if not isinstance(sha, str) or _SHA_RE.fullmatch(sha) is None:
            raise ValueError("record sha must be exactly 40 hexadecimal characters")
        variant_shas[variant].add(sha.lower())

        if warmup:
            continue
        key = (scenario_id, order, repetition)
        variants = paired.setdefault(key, {})
        if variant in variants:
            raise ValueError(f"duplicate record for {key!r} variant {variant}")
        variants[variant] = record

    if any(len(shas) > 1 for shas in variant_shas.values()):
        raise ValueError("each benchmark variant must use exactly one SHA")
    if variant_shas["A"] and variant_shas["A"] == variant_shas["B"]:
        raise ValueError("baseline and candidate require distinct build SHAs")

    grouped_values: dict[tuple[str, str, str], tuple[list[float], list[float]]] = {}
    for (scenario_id, order, repetition), variants in sorted(
        paired.items(), key=lambda item: (item[0][0], item[0][1], item[0][2])
    ):
        del repetition
        if set(variants) != {"A", "B"}:
            continue
        baseline_metrics = _record_field(variants["A"], "metrics")
        candidate_metrics = _record_field(variants["B"], "metrics")
        if not isinstance(baseline_metrics, Mapping) or not isinstance(
            candidate_metrics, Mapping
        ):
            raise ValueError("record metrics must be mappings")
        for metric in METRIC_GATES:
            if metric not in baseline_metrics or metric not in candidate_metrics:
                continue
            values = grouped_values.setdefault(
                (scenario_id, order, metric), ([], [])
            )
            values[0].append(float(baseline_metrics[metric]))
            values[1].append(float(candidate_metrics[metric]))

    scenario_order = {
        scenario.scenario_id: index
        for index, scenario in enumerate(_contract.scenario_matrix())
    }
    metric_order = {metric: index for index, metric in enumerate(METRIC_GATES)}
    group_items = sorted(
        grouped_values.items(),
        key=lambda item: (
            scenario_order.get(item[0][0], len(scenario_order)),
            0 if item[0][1] == "AB" else 1,
            metric_order[item[0][2]],
        ),
    )
    groups = [
        _comparison_group(scenario_id, order, metric, baseline, candidate)
        for (scenario_id, order, metric), (baseline, candidate) in group_items
    ]

    scenarios: list[dict[str, Any]] = []
    proven: list[str] = []
    inconclusive: list[str] = []
    regressed: list[str] = []
    for scenario in _contract.scenario_matrix():
        scenario_groups = [
            group for group in groups if group["scenario_id"] == scenario.scenario_id
        ]
        has_failed_gate = any(
            group["gate"]["passed"] is not True for group in scenario_groups
        )
        groups_by_key = {
            (group["order"], group["metric"]): group for group in scenario_groups
        }
        missing_groups = [
            f"{order}:{metric}"
            for order in ("AB", "BA")
            for metric in _REQUIRED_METRICS_BY_KIND[scenario.kind]
            if (group := groups_by_key.get((order, metric))) is None
            or group["sample_count"] != 3
        ]
        has_incomplete_group = bool(missing_groups)
        cpu_improvement = any(
            group["metric"].endswith("cpu_percent")
            and group["gate"]["passed"] is True
            and group["comparison"]["candidate"]["median"]
            < group["comparison"]["baseline"]["median"]
            and group["comparison"]["oriented_effect_size"] > 0.0
            for group in scenario_groups
        )
        if has_failed_gate:
            conclusion = "regressed"
            regressed.append(scenario.scenario_id)
        elif cpu_improvement and not has_incomplete_group:
            conclusion = "proven"
            proven.append(scenario.scenario_id)
        else:
            conclusion = "inconclusive"
            inconclusive.append(scenario.scenario_id)
        scenarios.append(
            {
                "scenario_id": scenario.scenario_id,
                "kind": scenario.kind,
                "load": scenario.load,
                "conclusion": conclusion,
                "group_count": len(scenario_groups),
                "complete": not has_incomplete_group,
                "missing_groups": missing_groups,
                "failed_gates": [
                    f'{group["order"]}:{group["metric"]}'
                    for group in scenario_groups
                    if group["gate"]["passed"] is not True
                ],
            }
        )

    complete_matrix = all(scenario["complete"] for scenario in scenarios)
    any_gate_failed = any(group["gate"]["passed"] is not True for group in groups)
    final_acceptance = (
        complete_matrix and "terminal-heavy" in proven and not any_gate_failed
    )
    return {
        "schema": _ANALYSIS_SCHEMA,
        "predeclared_gates": {
            metric: {
                "direction": direction,
                "max_relative_regression": threshold,
            }
            for metric, (direction, threshold) in METRIC_GATES.items()
        },
        "groups": groups,
        "scenarios": scenarios,
        "proven": proven,
        "inconclusive": inconclusive,
        "regressed": regressed,
        "final_acceptance": final_acceptance,
    }


def _validate_variants(
    baseline: VariantConfig, candidate: VariantConfig
) -> dict[str, VariantConfig]:
    if not isinstance(baseline, VariantConfig) or not isinstance(
        candidate, VariantConfig
    ):
        raise ValueError("baseline and candidate must be VariantConfig values")
    if baseline.variant != "A" or candidate.variant != "B":
        raise ValueError("baseline must be variant A and candidate must be variant B")
    # The contract builder performs the authoritative SHA format/distinctness
    # validation before any adapter side effects occur.
    _contract.build_experiment_plan(baseline.sha, candidate.sha)
    return {"A": baseline, "B": candidate}


def execute_experiment(
    *,
    baseline: VariantConfig,
    candidate: VariantConfig,
    output_dir: Path | str,
    run_variant: Callable[[VariantConfig, Any, Any], Mapping[str, Any]],
) -> ExperimentResult:
    """Execute all 144 invocations, retain raw outcomes, analyze, and persist."""
    variants = _validate_variants(baseline, candidate)
    if not callable(run_variant):
        raise ValueError("run_variant must be callable")
    root = Path(output_dir)
    raw_root = root / "raw"
    raw_root.mkdir(parents=True, exist_ok=True)

    scenarios = {scenario.scenario_id: scenario for scenario in _contract.scenario_matrix()}
    plan = _contract.build_experiment_plan(baseline.sha, candidate.sha)
    records: list[ExperimentRecord] = []
    failures: list[InvocationFailure] = []
    raw_paths: list[str] = []
    cleanup_summaries: list[dict[str, Any]] = []

    invocation_index = 0
    for run in plan:
        scenario = scenarios[run.scenario_id]
        for planned_invocation in run.invocations:
            invocation_index += 1
            variant = variants[planned_invocation.variant]
            raw_path = (
                Path("raw")
                / (
                    f"{invocation_index:03d}-{scenario.scenario_id}-{run.order}"
                    f"-r{run.repetition}-{variant.variant}.json"
                )
            )
            raw_paths.append(raw_path.as_posix())
            try:
                outcome = run_variant(variant, scenario, run)
                if not isinstance(outcome, Mapping):
                    raise ValueError("run_variant must return a mapping")
                metrics = outcome.get("metrics")
                cleanup = outcome.get("cleanup", {})
                evidence = outcome.get("evidence", {})
                if not isinstance(evidence, Mapping):
                    raise ValueError("run_variant evidence must be a mapping")
                if not isinstance(metrics, Mapping):
                    raise ValueError("run_variant result must contain a metrics mapping")
                record = ExperimentRecord(
                    scenario_id=scenario.scenario_id,
                    kind=scenario.kind,
                    load=scenario.load,
                    order=run.order,
                    repetition=run.repetition,
                    warmup=run.warmup,
                    variant=variant.variant,
                    sha=variant.sha,
                    metrics=metrics,
                    cleanup=cleanup,
                )
                records.append(record)
                cleanup_summary = {
                    "raw_path": raw_path.as_posix(),
                    "status": "success",
                    "cleanup": _plain_json(record.cleanup),
                }
                cleanup_summaries.append(cleanup_summary)
                _atomic_write_json(
                    root / raw_path,
                    {
                        "status": "success",
                        **record.to_dict(),
                        "evidence": _plain_json(evidence),
                    },
                )
            except Exception as error:
                cleanup = getattr(error, "cleanup", {})
                evidence = getattr(error, "evidence", {})
                if not isinstance(evidence, Mapping):
                    evidence = {"serialization_error": "exception evidence was not a mapping"}
                failure = InvocationFailure(
                    scenario_id=scenario.scenario_id,
                    kind=scenario.kind,
                    load=scenario.load,
                    order=run.order,
                    repetition=run.repetition,
                    warmup=run.warmup,
                    variant=variant.variant,
                    sha=variant.sha,
                    error_type=type(error).__name__,
                    message=str(error),
                    raw_path=raw_path.as_posix(),
                    cleanup=cleanup,
                )
                failures.append(failure)
                cleanup_summaries.append(
                    {
                        "raw_path": raw_path.as_posix(),
                        "status": "failure",
                        "cleanup": _plain_json(failure.cleanup),
                    }
                )
                _atomic_write_json(
                    root / raw_path,
                    {
                        "status": "failure",
                        "failure": failure.to_dict(),
                        "evidence": _plain_json(evidence),
                    },
                )

    analysis = analyze_experiment(records)
    manifest: dict[str, Any] = {
        "schema": _SCHEMA,
        "variants": {
            "A": baseline.to_dict(),
            "B": candidate.to_dict(),
        },
        "plan": {
            "scenario_count": 9,
            "order_count": 2,
            "pairs_per_order": 4,
            "warmup_pairs_per_order": 1,
            "measured_pairs_per_order": 3,
            "pair_count": len(plan),
            "invocation_count": len(plan) * 2,
            "warmup_invocation_count": sum(run.warmup for run in plan) * 2,
            "measured_invocation_count": sum(not run.warmup for run in plan) * 2,
        },
        "scenarios": [
            scenario.to_dict() for scenario in _contract.scenario_matrix()
        ],
        "raw_paths": raw_paths,
        "successful_record_count": len(records),
        "failures": [failure.to_dict() for failure in failures],
        "cleanup_summaries": cleanup_summaries,
    }
    manifest_path = root / "experiment-manifest.json"
    analysis_path = root / "analysis.json"
    _atomic_write_json(manifest_path, manifest)
    _atomic_write_json(analysis_path, analysis)
    return ExperimentResult(
        records=tuple(records),
        failures=tuple(failures),
        manifest=manifest,
        analysis=analysis,
        manifest_path=manifest_path,
        analysis_path=analysis_path,
    )


def parse_cli_args(argv: list[str] | None = None) -> argparse.Namespace:
    """Parse the fixed experiment CLI without permitting plan drift."""

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-sha", required=True)
    parser.add_argument("--baseline-tag", required=True)
    parser.add_argument("--baseline-app", required=True)
    parser.add_argument("--candidate-sha", required=True)
    parser.add_argument("--candidate-tag", required=True)
    parser.add_argument("--candidate-app", required=True)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--warmups", required=True, type=int)
    parser.add_argument("--repetitions", required=True, type=int)
    args = parser.parse_args(argv)
    if args.warmups != 1:
        raise ValueError("the fixed experiment requires exactly one warmup pair")
    if args.repetitions != 3:
        raise ValueError("the fixed experiment requires exactly three measured pairs")
    _contract.build_experiment_plan(args.baseline_sha, args.candidate_sha)
    return args


def _invocation_result_evidence(result: Any) -> dict[str, Any]:
    fields = (
        "requested_shape",
        "observed_shape",
        "steady_samples",
        "churn_samples",
        "latencies_ms",
        "throughput_ops_per_second",
        "render_observations",
        "failures",
        "cleanup",
    )
    return {name: _plain_json(getattr(result, name)) for name in fields}


def _scenario_timing(scenario: Any) -> dict[str, float]:
    workload_duration_s = 5.0
    measurement_duration_s = {
        "browser-heavy": 15.0,
        "mixed-heavy": 12.0,
    }.get(getattr(scenario, "scenario_id", None), 5.0)
    return {
        "churn_duration_s": workload_duration_s,
        "churn_measurement_duration_s": measurement_duration_s,
        "profile_duration_s": measurement_duration_s,
    }


def build_platform_run_variant(
    *,
    output_root: Path | str,
    adapter_module: Any | None = None,
    runtime_module: Any | None = None,
) -> Callable[[VariantConfig, Any, Any], Mapping[str, Any]]:
    """Bind the pure paired driver to the tagged macOS runtime adapter."""

    adapter_api = adapter_module or _load_sibling("perf_cmux_adapter")
    runtime_api = runtime_module or _load_sibling("perf_mixed_workload")
    root = Path(output_root)

    def run_variant(variant: VariantConfig, scenario: Any, run: Any) -> Mapping[str, Any]:
        invocation_root = root / "invocations" / (
            f"{scenario.scenario_id}-{run.order}-r{run.repetition}-{variant.variant}"
        )
        config = adapter_api.AdapterConfig(
            sha=variant.sha,
            tag=variant.tag,
            app_path=variant.app_path,
            scenario=scenario,
            output_root=invocation_root,
            warmup=run.warmup,
            profile_enabled=not run.warmup and run.repetition == 1,
            **_scenario_timing(scenario),
        )
        adapter = adapter_api.CmuxRuntimeAdapter(config)
        try:
            result = runtime_api.run_invocation(
                scenario_id=scenario.scenario_id,
                sha=variant.sha,
                order=run.order,
                repetition=run.repetition,
                requested_shape={
                    "terminal_surfaces": scenario.terminal_surfaces,
                    "browser_surfaces": scenario.browser_surfaces,
                },
                owned_root=invocation_root,
                adapter=adapter,
            )
            if getattr(result, "failures", None):
                failure = RuntimeError("adapter recorded workload failures")
                failure.cleanup = _plain_json(result.cleanup)
                failure.evidence = _plain_json(adapter.raw_details)
                raise failure
        except Exception as error:
            if not hasattr(error, "cleanup"):
                error.cleanup = _plain_json(
                    getattr(adapter, "raw_details", {}).get("cleanup", {})
                )
            if not hasattr(error, "evidence"):
                error.evidence = _plain_json(getattr(adapter, "raw_details", {}))
            raise

        evidence = _plain_json(adapter.raw_details)
        evidence["invocation_result"] = _invocation_result_evidence(result)
        return {
            "metrics": adapter_api.extract_metrics(result, adapter.raw_details),
            "cleanup": result.cleanup,
            "evidence": evidence,
        }

    return run_variant


def run_cli_experiment(args: argparse.Namespace) -> ExperimentResult:
    baseline = VariantConfig(
        variant="A",
        sha=args.baseline_sha,
        tag=args.baseline_tag,
        app_path=args.baseline_app,
    )
    candidate = VariantConfig(
        variant="B",
        sha=args.candidate_sha,
        tag=args.candidate_tag,
        app_path=args.candidate_app,
    )
    return execute_experiment(
        baseline=baseline,
        candidate=candidate,
        output_dir=args.output_dir,
        run_variant=build_platform_run_variant(output_root=args.output_dir),
    )


def main(argv: list[str] | None = None) -> int:
    result = run_cli_experiment(parse_cli_args(argv))
    return 0 if not result.failures and result.analysis["final_acceptance"] is True else 1


__all__ = [
    "METRIC_GATES",
    "ExperimentRecord",
    "ExperimentResult",
    "InvocationFailure",
    "VariantConfig",
    "build_platform_run_variant",
    "analyze_experiment",
    "execute_experiment",
    "main",
    "parse_cli_args",
    "run_cli_experiment",
]


if __name__ == "__main__":
    raise SystemExit(main())
