#!/usr/bin/env python3
"""Behavioral contracts for the pure mixed-workload experiment driver."""

from __future__ import annotations

from dataclasses import FrozenInstanceError
import importlib.util
import json
from pathlib import Path
import sys
from typing import Any

import pytest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "perf_mixed_workload_driver.py"
spec = importlib.util.spec_from_file_location("perf_mixed_workload_driver", SCRIPT)
assert spec is not None and spec.loader is not None
perf_driver = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = perf_driver
spec.loader.exec_module(perf_driver)

BASELINE_SHA = "0123456789abcdef0123456789abcdef01234567"
CANDIDATE_SHA = "fedcba9876543210fedcba9876543210fedcba98"
BASELINE = None
CANDIDATE = None


def _variants() -> tuple[Any, Any]:
    return (
        perf_driver.VariantConfig(
            variant="A",
            sha=BASELINE_SHA,
            tag="perf-baseline",
            app_path="/apps/cmux DEV perf-baseline.app",
        ),
        perf_driver.VariantConfig(
            variant="B",
            sha=CANDIDATE_SHA,
            tag="perf-candidate",
            app_path="/apps/cmux DEV perf-candidate.app",
        ),
    )


def _record(
    scenario_id: str,
    order: str,
    repetition: int,
    variant: str,
    metrics: dict[str, float],
    *,
    warmup: bool = False,
) -> Any:
    scenario_kind, load = scenario_id.split("-", 1)
    sha = BASELINE_SHA if variant == "A" else CANDIDATE_SHA
    return perf_driver.ExperimentRecord(
        scenario_id=scenario_id,
        kind=scenario_kind,
        load=load,
        order=order,
        repetition=repetition,
        warmup=warmup,
        variant=variant,
        sha=sha,
        metrics=metrics,
        cleanup={"removed": 1},
    )


def _paired_records(
    scenario_id: str,
    metric_values: dict[str, tuple[float, float]],
) -> list[Any]:
    records = []
    for order in ("AB", "BA"):
        for repetition in range(1, 4):
            for variant in order:
                records.append(
                    _record(
                        scenario_id,
                        order,
                        repetition,
                        variant,
                        {
                            metric: values[0 if variant == "A" else 1]
                            for metric, values in metric_values.items()
                        },
                    )
                )
    return records


def test_variant_and_experiment_records_are_immutable_and_json_friendly() -> None:
    baseline, _ = _variants()
    record = _record(
        "terminal-heavy",
        "AB",
        1,
        "A",
        {"steady_full_tree_cpu_percent": 42.5},
    )

    with pytest.raises(FrozenInstanceError):
        baseline.tag = "changed"
    with pytest.raises(TypeError):
        record.metrics["steady_full_tree_cpu_percent"] = 1.0

    assert json.loads(json.dumps(baseline.to_dict())) == {
        "variant": "A",
        "sha": BASELINE_SHA,
        "tag": "perf-baseline",
        "app_path": "/apps/cmux DEV perf-baseline.app",
    }
    assert json.loads(json.dumps(record.to_dict()))["metrics"] == {
        "steady_full_tree_cpu_percent": 42.5
    }


def test_execute_experiment_runs_exact_fixed_plan_and_writes_deterministic_outputs(
    tmp_path: Path,
) -> None:
    baseline, candidate = _variants()
    calls: list[tuple[str, str, str, int, bool, str, str, str]] = []

    def run_variant(variant: Any, scenario: Any, run: Any) -> dict[str, Any]:
        calls.append(
            (
                scenario.scenario_id,
                scenario.kind,
                run.order,
                run.repetition,
                run.warmup,
                variant.variant,
                variant.tag,
                variant.app_path,
            )
        )
        value = 100.0 if variant.variant == "A" else 99.0
        return {
            "metrics": {
                metric: value for metric in perf_driver.METRIC_GATES
            },
            "cleanup": {"owned_processes_removed": 1},
        }

    result = perf_driver.execute_experiment(
        baseline=baseline,
        candidate=candidate,
        output_dir=tmp_path,
        run_variant=run_variant,
    )

    assert len(calls) == 144
    assert len(result.records) == 144
    assert sum(not record.warmup for record in result.records) == 108
    assert result.failures == ()
    assert calls[:4] == [
        ("terminal-light", "terminal", "AB", 0, True, "A", "perf-baseline", "/apps/cmux DEV perf-baseline.app"),
        ("terminal-light", "terminal", "AB", 0, True, "B", "perf-candidate", "/apps/cmux DEV perf-candidate.app"),
        ("terminal-light", "terminal", "AB", 1, False, "A", "perf-baseline", "/apps/cmux DEV perf-baseline.app"),
        ("terminal-light", "terminal", "AB", 1, False, "B", "perf-candidate", "/apps/cmux DEV perf-candidate.app"),
    ]
    assert calls[8:12] == [
        ("terminal-light", "terminal", "BA", 0, True, "B", "perf-candidate", "/apps/cmux DEV perf-candidate.app"),
        ("terminal-light", "terminal", "BA", 0, True, "A", "perf-baseline", "/apps/cmux DEV perf-baseline.app"),
        ("terminal-light", "terminal", "BA", 1, False, "B", "perf-candidate", "/apps/cmux DEV perf-candidate.app"),
        ("terminal-light", "terminal", "BA", 1, False, "A", "perf-baseline", "/apps/cmux DEV perf-baseline.app"),
    ]

    assert result.manifest_path == tmp_path / "experiment-manifest.json"
    assert result.analysis_path == tmp_path / "analysis.json"
    manifest = json.loads(result.manifest_path.read_text(encoding="utf-8"))
    analysis = json.loads(result.analysis_path.read_text(encoding="utf-8"))
    assert manifest["schema"] == "cmux.perf.mixed-workload-experiment/v1"
    assert manifest["variants"] == {"A": baseline.to_dict(), "B": candidate.to_dict()}
    assert manifest["plan"] == {
        "scenario_count": 9,
        "order_count": 2,
        "pairs_per_order": 4,
        "warmup_pairs_per_order": 1,
        "measured_pairs_per_order": 3,
        "pair_count": 72,
        "invocation_count": 144,
        "warmup_invocation_count": 36,
        "measured_invocation_count": 108,
    }
    assert len(manifest["raw_paths"]) == 144
    assert manifest["raw_paths"][0] == "raw/001-terminal-light-AB-r0-A.json"
    assert manifest["raw_paths"][-1] == "raw/144-mixed-heavy-BA-r3-A.json"
    assert len(manifest["cleanup_summaries"]) == 144
    assert manifest["failures"] == []
    assert analysis == result.analysis
    assert len(list((tmp_path / "raw").glob("*.json"))) == 144


def test_failures_are_written_and_execution_continues(tmp_path: Path) -> None:
    baseline, candidate = _variants()
    attempted: list[tuple[str, str, int, str]] = []

    def run_variant(variant: Any, scenario: Any, run: Any) -> dict[str, Any]:
        key = (scenario.scenario_id, run.order, run.repetition, variant.variant)
        attempted.append(key)
        if key == ("terminal-light", "AB", 1, "B"):
            error = RuntimeError("synthetic candidate failure")
            error.cleanup = {"owned_processes_removed": 2}
            error.evidence = {"last_process_sample": {"coverage": {"missing_pids": [99]}}}
            raise error
        return {
            "metrics": {"steady_full_tree_cpu_percent": 10.0},
            "cleanup": {"owned_processes_removed": 1},
        }

    result = perf_driver.execute_experiment(
        baseline=baseline,
        candidate=candidate,
        output_dir=tmp_path,
        run_variant=run_variant,
    )

    assert len(attempted) == 144
    assert attempted[-1] == ("mixed-heavy", "BA", 3, "A")
    assert len(result.records) == 143
    assert len(result.failures) == 1
    failure = result.failures[0].to_dict()
    assert failure["scenario_id"] == "terminal-light"
    assert failure["order"] == "AB"
    assert failure["repetition"] == 1
    assert failure["variant"] == "B"
    assert failure["error_type"] == "RuntimeError"
    assert failure["message"] == "synthetic candidate failure"
    assert failure["cleanup"] == {"owned_processes_removed": 2}
    failure_raw = json.loads((tmp_path / failure["raw_path"]).read_text(encoding="utf-8"))
    assert failure_raw["status"] == "failure"
    assert failure_raw["failure"]["message"] == "synthetic candidate failure"
    assert failure_raw["evidence"]["last_process_sample"]["coverage"] == {
        "missing_pids": [99]
    }
    manifest = json.loads((tmp_path / "experiment-manifest.json").read_text())
    assert manifest["failures"] == [failure]


def test_analysis_excludes_warmups_and_keeps_ab_ba_metric_strata_separate() -> None:
    records = [
        _record(
            "terminal-heavy",
            order,
            0,
            variant,
            {"steady_full_tree_cpu_percent": 9999.0 if variant == "A" else 1.0},
            warmup=True,
        )
        for order in ("AB", "BA")
        for variant in order
    ]
    for order, baseline_values, candidate_values in (
        ("AB", (10.0, 20.0, 30.0), (9.0, 18.0, 27.0)),
        ("BA", (40.0, 50.0, 60.0), (38.0, 47.0, 55.0)),
    ):
        for repetition, (a_value, b_value) in enumerate(
            zip(baseline_values, candidate_values, strict=True), start=1
        ):
            for variant in order:
                records.append(
                    _record(
                        "terminal-heavy",
                        order,
                        repetition,
                        variant,
                        {
                            "steady_full_tree_cpu_percent": (
                                a_value if variant == "A" else b_value
                            )
                        },
                    )
                )

    analysis = perf_driver.analyze_experiment(records)
    groups = {
        (group["scenario_id"], group["order"], group["metric"]): group
        for group in analysis["groups"]
    }
    assert set(groups) == {
        ("terminal-heavy", "AB", "steady_full_tree_cpu_percent"),
        ("terminal-heavy", "BA", "steady_full_tree_cpu_percent"),
    }
    ab = groups[("terminal-heavy", "AB", "steady_full_tree_cpu_percent")]
    ba = groups[("terminal-heavy", "BA", "steady_full_tree_cpu_percent")]
    assert ab["comparison"]["baseline"]["raw_values"] == [10.0, 20.0, 30.0]
    assert ab["comparison"]["candidate"]["raw_values"] == [9.0, 18.0, 27.0]
    assert ba["comparison"]["baseline"]["raw_values"] == [40.0, 50.0, 60.0]
    assert ba["comparison"]["candidate"]["raw_values"] == [38.0, 47.0, 55.0]
    assert ab["comparison"]["baseline"]["median"] == 20.0
    assert ab["comparison"]["baseline"]["iqr"] == 20.0
    assert ab["comparison"]["baseline"]["mad"] == 10.0
    assert ab["comparison"]["absolute_deltas"] == [-1.0, -2.0, -3.0]
    assert ab["comparison"]["probability_candidate_better"] > 0.5
    assert ab["comparison"]["oriented_effect_size"] > 0.0
    assert ab["gate"]["direction"] == "lower_is_better"
    assert ab["gate"]["threshold"] == 0.05
    assert ab["gate"]["passed"] is True


def test_predeclared_metric_directions_and_thresholds_are_complete() -> None:
    assert dict(perf_driver.METRIC_GATES) == {
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


def test_scenario_conclusions_and_final_acceptance_do_not_pool_workloads() -> None:
    records: list[Any] = []
    terminal_metrics = {
        metric: (100.0, 100.0)
        for metric in perf_driver._REQUIRED_METRICS_BY_KIND["terminal"]
    }
    terminal_metrics["steady_full_tree_cpu_percent"] = (100.0, 90.0)
    records.extend(_paired_records("terminal-heavy", terminal_metrics))

    browser_metrics = {
        metric: (100.0, 100.0)
        for metric in perf_driver._REQUIRED_METRICS_BY_KIND["browser"]
    }
    browser_metrics["browser_latency_ms"] = (100.0, 111.0)
    records.extend(_paired_records("browser-heavy", browser_metrics))

    records.extend(
        _paired_records(
            "mixed-heavy",
            {metric: (100.0, 100.0) for metric in perf_driver.METRIC_GATES},
        )
    )

    analysis = perf_driver.analyze_experiment(records)
    conclusions = {
        item["scenario_id"]: item["conclusion"]
        for item in analysis["scenarios"]
    }
    assert conclusions["terminal-heavy"] == "proven"
    assert conclusions["browser-heavy"] == "regressed"
    assert conclusions["mixed-heavy"] == "inconclusive"
    assert analysis["proven"] == ["terminal-heavy"]
    assert analysis["regressed"] == ["browser-heavy"]
    assert "mixed-heavy" in analysis["inconclusive"]
    assert analysis["final_acceptance"] is False

    no_browser_regression = [
        record
        for record in records
        if not (
            record.scenario_id == "browser-heavy"
            and "browser_latency_ms" in record.metrics
        )
    ]
    passing = perf_driver.analyze_experiment(no_browser_regression)
    passing_conclusions = {
        item["scenario_id"]: item["conclusion"]
        for item in passing["scenarios"]
    }
    assert passing_conclusions["browser-heavy"] == "inconclusive"
    assert passing_conclusions["mixed-heavy"] == "inconclusive"
    assert passing["final_acceptance"] is False
    assert passing["proven"] == ["terminal-heavy"]


def test_success_raw_file_retains_complete_adapter_evidence(tmp_path: Path) -> None:
    baseline, candidate = _variants()

    def run_variant(variant: Any, scenario: Any, run: Any) -> dict[str, Any]:
        return {
            "metrics": {"steady_full_tree_cpu_percent": 1.0},
            "cleanup": {"removed": True},
            "evidence": {
                "requested_shape": {
                    "terminal_surfaces": scenario.terminal_surfaces,
                    "browser_surfaces": scenario.browser_surfaces,
                },
                "raw_samples": [{"full_tree": {"pids": [10, 11], "cpu_percent": 1.0}}],
                "order": run.order,
                "variant": variant.variant,
            },
        }

    perf_driver.execute_experiment(
        baseline=baseline,
        candidate=candidate,
        output_dir=tmp_path,
        run_variant=run_variant,
    )

    first = json.loads(
        (tmp_path / "raw" / "001-terminal-light-AB-r0-A.json").read_text(
            encoding="utf-8"
        )
    )
    assert first["evidence"]["requested_shape"] == {
        "terminal_surfaces": 4,
        "browser_surfaces": 0,
    }
    assert first["evidence"]["raw_samples"][0]["full_tree"]["pids"] == [10, 11]


def test_cli_contract_requires_exact_fixed_repetition_plan(tmp_path: Path) -> None:
    required = [
        "--baseline-sha",
        BASELINE_SHA,
        "--baseline-tag",
        "perf-baseline",
        "--baseline-app",
        "/apps/baseline.app",
        "--candidate-sha",
        CANDIDATE_SHA,
        "--candidate-tag",
        "perf-candidate",
        "--candidate-app",
        "/apps/candidate.app",
        "--output-dir",
        str(tmp_path),
        "--warmups",
        "1",
        "--repetitions",
        "3",
    ]

    parsed = perf_driver.parse_cli_args(required)
    assert parsed.baseline_sha == BASELINE_SHA
    assert parsed.candidate_sha == CANDIDATE_SHA
    assert parsed.output_dir == tmp_path

    bad_warmups = required.copy()
    bad_warmups[bad_warmups.index("1")] = "0"
    with pytest.raises(ValueError, match="exactly one warmup"):
        perf_driver.parse_cli_args(bad_warmups)

    bad_repetitions = required.copy()
    bad_repetitions[bad_repetitions.index("3")] = "2"
    with pytest.raises(ValueError, match="exactly three measured"):
        perf_driver.parse_cli_args(bad_repetitions)


def test_analysis_rejects_records_outside_fixed_measured_plan() -> None:
    records = [
        _record(
            "terminal-light",
            "AB",
            4,
            variant,
            {"steady_full_tree_cpu_percent": 1.0},
        )
        for variant in "AB"
    ]

    with pytest.raises(ValueError, match="measured repetition"):
        perf_driver.analyze_experiment(records)


def test_analysis_rejects_inconsistent_build_and_scenario_identity() -> None:
    baseline = _record(
        "terminal-light",
        "AB",
        1,
        "A",
        {"steady_full_tree_cpu_percent": 1.0},
    ).to_dict()
    candidate = _record(
        "terminal-light",
        "AB",
        1,
        "B",
        {"steady_full_tree_cpu_percent": 1.0},
    ).to_dict()

    wrong_scenario = dict(candidate)
    wrong_scenario["kind"] = "browser"
    with pytest.raises(ValueError, match="scenario metadata"):
        perf_driver.analyze_experiment([baseline, wrong_scenario])

    wrong_build = dict(candidate)
    wrong_build["sha"] = BASELINE_SHA
    with pytest.raises(ValueError, match="distinct build SHAs"):
        perf_driver.analyze_experiment([baseline, wrong_build])

    second_baseline = dict(baseline)
    second_baseline["scenario_id"] = "terminal-realistic"
    second_baseline["load"] = "realistic"
    second_baseline["sha"] = "a" * 40
    with pytest.raises(ValueError, match="one SHA"):
        perf_driver.analyze_experiment([baseline, second_baseline, candidate])


def test_final_acceptance_requires_every_scenario_metric_and_order() -> None:
    metrics_by_kind = {
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
        "mixed": tuple(perf_driver.METRIC_GATES),
    }
    complete: list[Any] = []
    for scenario in perf_driver._contract.scenario_matrix():
        values = {metric: (100.0, 100.0) for metric in metrics_by_kind[scenario.kind]}
        if scenario.scenario_id == "terminal-heavy":
            values["steady_full_tree_cpu_percent"] = (100.0, 90.0)
        complete.extend(_paired_records(scenario.scenario_id, values))

    accepted = perf_driver.analyze_experiment(complete)
    assert accepted["final_acceptance"] is True

    one_group_missing = [
        record
        for record in complete
        if not (
            record.scenario_id == "browser-light"
            and record.order == "BA"
            and "browser_render_rate" in record.metrics
        )
    ]
    rejected = perf_driver.analyze_experiment(one_group_missing)
    assert rejected["final_acceptance"] is False
    browser_light = next(
        item for item in rejected["scenarios"] if item["scenario_id"] == "browser-light"
    )
    assert browser_light["complete"] is False
    assert "BA:browser_render_rate" in browser_light["missing_groups"]


def test_platform_bridge_passes_exact_variant_scenario_and_profile_scope(
    tmp_path: Path,
) -> None:
    baseline, _ = _variants()
    captured_configs: list[dict[str, Any]] = []

    class FakeConfig:
        def __init__(self, **values: Any) -> None:
            captured_configs.append(values)

    class FakeAdapter:
        def __init__(self, cfg: Any) -> None:
            self.raw_details = {
                "fixture": {"exact": True},
                "profiles": [{"role": "parent", "pid": 100}],
            }

    class FakeAdapterModule:
        AdapterConfig = FakeConfig
        CmuxRuntimeAdapter = FakeAdapter

        @staticmethod
        def extract_metrics(result: Any, details: Any) -> dict[str, float]:
            assert details["fixture"] == {"exact": True}
            return {"steady_full_tree_cpu_percent": 4.0}

    calls: list[dict[str, Any]] = []

    class FakeRuntimeModule:
        @staticmethod
        def run_invocation(**kwargs: Any) -> Any:
            calls.append(kwargs)
            return type(
                "Result",
                (),
                {
                    "cleanup": {"owned": True},
                    "requested_shape": kwargs["requested_shape"],
                    "observed_shape": kwargs["requested_shape"],
                    "steady_samples": [],
                    "churn_samples": [],
                    "latencies_ms": [],
                    "throughput_ops_per_second": {},
                    "render_observations": [],
                    "failures": [],
                },
            )()

    bridge = perf_driver.build_platform_run_variant(
        output_root=tmp_path,
        adapter_module=FakeAdapterModule,
        runtime_module=FakeRuntimeModule,
    )
    scenario_value = perf_driver._contract.scenario_matrix()[0]
    run = perf_driver._contract.build_experiment_plan(BASELINE_SHA, CANDIDATE_SHA)[1]
    outcome = bridge(baseline, scenario_value, run)

    assert captured_configs == [
        {
            "sha": BASELINE_SHA,
            "tag": "perf-baseline",
            "app_path": "/apps/cmux DEV perf-baseline.app",
            "scenario": scenario_value,
            "output_root": tmp_path / "invocations" / "terminal-light-AB-r1-A",
            "warmup": False,
            "profile_enabled": True,
        }
    ]
    assert calls[0]["scenario_id"] == "terminal-light"
    assert calls[0]["sha"] == BASELINE_SHA
    assert calls[0]["order"] == "AB"
    assert calls[0]["repetition"] == 1
    assert calls[0]["requested_shape"] == {
        "terminal_surfaces": 4,
        "browser_surfaces": 0,
    }
    assert calls[0]["owned_root"] == captured_configs[0]["output_root"]
    assert isinstance(calls[0]["adapter"], FakeAdapter)
    assert outcome["metrics"] == {"steady_full_tree_cpu_percent": 4.0}
    assert outcome["cleanup"] == {"owned": True}
    assert outcome["evidence"]["profiles"] == [{"role": "parent", "pid": 100}]


def test_platform_bridge_rejects_recorded_churn_failures(tmp_path: Path) -> None:
    baseline, _ = _variants()

    class FakeAdapter:
        raw_details = {"churn": {"failures": [{"phase": "profile_churn"}]}}

        def __init__(self, config: Any) -> None:
            del config

    class FakeAdapterModule:
        AdapterConfig = lambda **values: values
        CmuxRuntimeAdapter = FakeAdapter
        extract_metrics = staticmethod(lambda result, details: {})

    class FakeRuntimeModule:
        @staticmethod
        def run_invocation(**kwargs: Any) -> Any:
            del kwargs
            return type(
                "Result",
                (),
                {
                    "failures": [{"phase": "profile_churn"}],
                    "cleanup": {"owned": True},
                },
            )()

    bridge = perf_driver.build_platform_run_variant(
        output_root=tmp_path,
        adapter_module=FakeAdapterModule,
        runtime_module=FakeRuntimeModule,
    )
    scenario_value = perf_driver._contract.scenario_matrix()[0]
    run = perf_driver._contract.build_experiment_plan(BASELINE_SHA, CANDIDATE_SHA)[1]

    with pytest.raises(RuntimeError, match="recorded workload failures") as caught:
        bridge(baseline, scenario_value, run)
    assert caught.value.cleanup == {"owned": True}
    assert caught.value.evidence["churn"]["failures"] == [
        {"phase": "profile_churn"}
    ]
