#!/usr/bin/env python3
"""Merge cmux NEXT stress scenario JSON and prepare a readable report.

The bench drivers write one JSON object per scenario. This command keeps the
scenario files immutable and emits a report, Markdown summary, and an issue
queue suitable for the fleet/HQ posting helpers. It has no GitHub side effects.
"""
from __future__ import annotations

import argparse
import json
import math
import pathlib
import sys
from dataclasses import dataclass
from typing import Any

DEFAULT_METRICS = (
    "frame_rate",
    "input_to_paint_ms.p50",
    "input_to_paint_ms.p95",
    "input_to_paint_ms.p99",
    "main_thread_hangs",
    "cpu_pct",
    "rss_mb",
    "disk_growth_mb",
    "recovery_ms",
)
LOWER_IS_BETTER = {
    "input_to_paint_ms",
    "main_thread_hangs",
    "cpu_pct",
    "rss_mb",
    "disk_growth_mb",
    "recovery_ms",
}


@dataclass(frozen=True)
class Row:
    scenario: str
    metric: str
    value: float
    baseline: float | None
    delta_pct: float | None
    status: str
    recovered: Any
    source: str

    def as_dict(self) -> dict[str, Any]:
        return {
            "scenario": self.scenario,
            "metric": self.metric,
            "value": self.value,
            "baseline": self.baseline,
            "delta_pct": self.delta_pct,
            "status": self.status,
            "recovered": self.recovered,
            "source": self.source,
        }


def _number(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    value = float(value)
    return value if math.isfinite(value) else None


def _get_path(obj: dict[str, Any], path: str) -> Any:
    value: Any = obj
    for part in path.split("."):
        if not isinstance(value, dict) or part not in value:
            return None
        value = value[part]
    return value


def _flatten_metrics(obj: dict[str, Any]) -> dict[str, float]:
    """Accept either a ``metrics`` mapping or common top-level metric fields."""
    metrics = obj.get("metrics")
    if not isinstance(metrics, dict):
        metrics = obj
    found: dict[str, float] = {}
    for key, value in metrics.items():
        number = _number(value)
        if number is not None:
            found[str(key)] = number
        elif isinstance(value, dict):
            for child, child_value in value.items():
                child_number = _number(child_value)
                if child_number is not None:
                    found[f"{key}.{child}"] = child_number
    return found


def _load_baseline(path: pathlib.Path | None) -> dict[tuple[str, str], float]:
    if path is None:
        return {}
    with path.open() as handle:
        data = json.load(handle)
    values: dict[tuple[str, str], float] = {}
    entries = data.get("rows") if isinstance(data, dict) else data
    if isinstance(entries, dict):
        for key, value in entries.items():
            if isinstance(key, str) and "/" in key:
                scenario, metric = key.split("/", 1)
                number = _number(value)
                if number is not None:
                    values[(scenario, metric)] = number
    elif isinstance(entries, list):
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            scenario, metric = entry.get("scenario"), entry.get("metric")
            number = _number(entry.get("value", entry.get("baseline")))
            if isinstance(scenario, str) and isinstance(metric, str) and number is not None:
                values[(scenario, metric)] = number
    return values


def _delta(value: float, baseline: float | None) -> float | None:
    if baseline is None or baseline == 0:
        return None
    return (value - baseline) / abs(baseline) * 100.0


def _is_regression(metric: str, value: float, baseline: float | None, threshold: float) -> bool:
    if baseline is None:
        return False
    delta = _delta(value, baseline)
    if delta is None:
        return False
    direction = next((prefix for prefix in LOWER_IS_BETTER if metric == prefix or metric.startswith(prefix + ".")), None)
    return delta > threshold if direction else delta < -threshold


def _read_results(directory: pathlib.Path) -> list[tuple[pathlib.Path, dict[str, Any]]]:
    results = []
    for path in sorted(directory.glob("*.json")):
        if path.name in {"report.json", "issues.json", "baseline.json"}:
            continue
        try:
            with path.open() as handle:
                obj = json.load(handle)
        except (OSError, json.JSONDecodeError) as error:
            print(f"report: skipping {path}: {error}", file=sys.stderr)
            continue
        if isinstance(obj, dict):
            results.append((path, obj))
    return results


def build_rows(results: list[tuple[pathlib.Path, dict[str, Any]]], baseline: dict[tuple[str, str], float], threshold: float) -> list[Row]:
    rows: list[Row] = []
    for path, result in results:
        scenario = str(result.get("scenario") or result.get("angle") or path.stem)
        metrics = _flatten_metrics(result)
        # Recovery can be represented as a boolean or as a nested status object.
        recovered = result.get("recovered")
        if recovered is None and isinstance(result.get("recovery"), dict):
            recovered = result["recovery"].get("recovered")
        for metric, value in sorted(metrics.items()):
            reference = baseline.get((scenario, metric))
            rows.append(Row(scenario, metric, value, reference, _delta(value, reference),
                            "regression" if _is_regression(metric, value, reference, threshold) else "ok",
                            recovered, path.name))
    return rows


def _fmt(value: Any) -> str:
    if value is None:
        return "—"
    if isinstance(value, float):
        return f"{value:.2f}"
    return str(value)


def markdown(rows: list[Row], metadata: dict[str, Any], issues: list[Row]) -> str:
    lines = ["# cmux NEXT stress bench", "", f"- Commit: `{metadata.get('commit', 'unknown')}`",
             f"- Host: `{metadata.get('host', 'unknown')}`", f"- Run: `{metadata.get('run_id', 'unknown')}`", "",
             "| Scenario | Metric | Value | Baseline | Delta | Recovery | Status |", "| --- | --- | ---: | ---: | ---: | --- | --- |"]
    for row in rows:
        delta = "—" if row.delta_pct is None else f"{row.delta_pct:+.1f}%"
        lines.append(f"| {row.scenario} | `{row.metric}` | {_fmt(row.value)} | {_fmt(row.baseline)} | {delta} | {_fmt(row.recovered)} | **{row.status}** |")
    lines += ["", f"Top regressions queued as issues: **{len(issues)}**", ""]
    return "\n".join(lines)


def issue_payload(row: Row, metadata: dict[str, Any]) -> dict[str, Any]:
    title = f"cmux NEXT stress regression: {row.scenario}/{row.metric}"
    delta = "unknown" if row.delta_pct is None else f"{row.delta_pct:+.1f}%"
    body = (f"Stress bench regression detected for `{row.scenario}` / `{row.metric}`.\n\n"
            f"- value: `{row.value}`\n- baseline: `{row.baseline}`\n- delta: `{delta}`\n"
            f"- recovered after load stopped: `{row.recovered}`\n- host: `{metadata.get('host', 'unknown')}`\n"
            f"- commit: `{metadata.get('commit', 'unknown')}`\n- run: `{metadata.get('run_id', 'unknown')}`\n"
            f"- source result: `{row.source}`\n")
    return {"title": title, "body": body, "scenario": row.scenario, "metric": row.metric, "numbers": row.as_dict()}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results-dir", type=pathlib.Path, required=True)
    parser.add_argument("--baseline", type=pathlib.Path)
    parser.add_argument("--output-json", type=pathlib.Path, required=True)
    parser.add_argument("--output-markdown", type=pathlib.Path, required=True)
    parser.add_argument("--issue-output", type=pathlib.Path, required=True)
    parser.add_argument("--commit", default="unknown")
    parser.add_argument("--host", default="unknown")
    parser.add_argument("--run-id", default="unknown")
    parser.add_argument("--threshold-pct", type=float, default=10.0)
    parser.add_argument("--max-issues", type=int, default=5)
    opts = parser.parse_args(argv)
    if opts.threshold_pct < 0 or opts.max_issues < 0:
        parser.error("--threshold-pct and --max-issues must be non-negative")
    baseline = _load_baseline(opts.baseline)
    rows = build_rows(_read_results(opts.results_dir), baseline, opts.threshold_pct)
    regressions = sorted((row for row in rows if row.status == "regression"),
                         key=lambda row: abs(row.delta_pct or 0), reverse=True)[:opts.max_issues]
    metadata = {"commit": opts.commit, "host": opts.host, "run_id": opts.run_id}
    report = {"schema": 1, **metadata, "rows": [row.as_dict() for row in rows],
              "regressions": [row.as_dict() for row in regressions], "issue_count": len(regressions)}
    issues = [issue_payload(row, metadata) for row in regressions]
    for path, value in ((opts.output_json, report), (opts.issue_output, issues)):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    opts.output_markdown.parent.mkdir(parents=True, exist_ok=True)
    opts.output_markdown.write_text(markdown(rows, metadata, regressions) + "\n")
    print(json.dumps({"rows": len(rows), "regressions": len(regressions), "report": str(opts.output_json), "issues": str(opts.issue_output)}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
