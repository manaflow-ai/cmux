#!/usr/bin/env python3
"""Normalize cmux NEXT stress measurements into one JSON and Markdown report.

Each existing stress driver writes its own result shape.  This command is the
small adapter shared by the fleet runner and the report publisher.  It never
starts the app or changes a measurement.  Inputs may be one JSON object, a
list, or an object containing ``scenarios``, ``results``, ``rows`` or
``measurements``.

Examples::

    stress-report.py --input-dir results --output report.json \
      --markdown report.md --sha "$GITHUB_SHA" --host cmux20-bench
    stress-report.py chats.json terminals.json --output report.json

The canonical row contains frame rate, input-to-paint p50/p95/p99, main-thread
hangs, CPU, RSS, disk growth and recovery. Missing values stay null and are
listed in ``missing_metrics`` so a partial driver cannot look like a passing
measurement.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
import pathlib
import sys
from typing import Any, Iterable


METRICS = (
    "frame_rate_fps",
    "input_to_paint_p50_ms",
    "input_to_paint_p95_ms",
    "input_to_paint_p99_ms",
    "main_thread_hangs",
    "cpu_percent",
    "rss_mb",
    "disk_growth_mb",
    "recovered",
)


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def number(value: Any) -> float | int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)) and math.isfinite(value):
        return value
    if isinstance(value, str):
        try:
            parsed = float(value.strip().rstrip("%"))
        except ValueError:
            return None
        if math.isfinite(parsed):
            return int(parsed) if parsed.is_integer() else parsed
    return None


def first(mapping: dict[str, Any], paths: Iterable[str]) -> Any:
    for path in paths:
        value: Any = mapping
        for part in path.split("."):
            if not isinstance(value, dict) or part not in value:
                value = None
                break
            value = value[part]
        if value is not None:
            return value
    return None


def percentile(mapping: dict[str, Any], aliases: Iterable[str], requested: str) -> float | int | None:
    value = first(mapping, aliases)
    if isinstance(value, dict):
        value = first(value, (requested, f"{requested}_ms", "value", "ms"))
    return number(value)


def bytes_to_mb(value: Any) -> float | int | None:
    parsed = number(value)
    if parsed is None:
        return None
    return round(parsed / (1024 * 1024), 3)


def nested_size_mb(value: Any) -> float | int | None:
    if isinstance(value, dict):
        megabytes = first(value, ("mb", "megabytes", "value"))
        if megabytes is not None:
            return number(megabytes)
        value = first(value, ("bytes", "byte_count"))
    return bytes_to_mb(value)


def metric_value(row: dict[str, Any], metric: str) -> Any:
    if metric == "frame_rate_fps":
        value = first(row, ("frame_rate_fps", "fps", "frame_rate", "refresh_rate", "frames_per_second"))
        if isinstance(value, dict):
            value = first(value, ("mean", "avg", "average", "value", "fps"))
        parsed = number(value)
        if parsed is not None:
            return parsed
        interval = first(row, ("frame_interval_ms", "frame_intervals_ms", "frame_time_ms"))
        if isinstance(interval, list):
            values = [number(item) for item in interval]
            values = [item for item in values if item is not None and item > 0]
            interval = sum(values) / len(values) if values else None
        interval = number(interval)
        return round(1000 / interval, 3) if interval and interval > 0 else None
    if metric.startswith("input_to_paint_"):
        percentile_name = metric.rsplit("_", 2)[-2]
        return percentile(
            row,
            (metric, "input_to_paint", "input_paint", "key_to_paint", "key_to_frame", "latency", "latency_ms"),
            percentile_name,
        )
    if metric == "main_thread_hangs":
        value = first(row, ("main_thread_hangs", "main_thread.hangs", "debug.hangs", "hangs", "hang_count"))
        if isinstance(value, dict):
            value = first(value, ("count", "total", "value"))
        if isinstance(value, list):
            value = len(value)
        return number(value)
    if metric == "cpu_percent":
        value = first(row, ("cpu_percent", "cpu_pct", "cpu", "resources.cpu", "resource.cpu"))
        if isinstance(value, dict):
            value = first(value, ("mean", "avg", "average", "percent", "pct", "value"))
        return number(value)
    if metric == "rss_mb":
        value = first(row, ("rss_mb", "memory.rss_mb", "resources.rss_mb"))
        if value is not None:
            return number(value) if not isinstance(value, dict) else nested_size_mb(value)
        return nested_size_mb(first(row, ("rss_bytes", "memory.rss_bytes", "resources.rss_bytes", "pss_bytes")))
    if metric == "disk_growth_mb":
        value = first(row, ("disk_growth_mb", "disk.growth_mb", "disk_growth"))
        if value is not None:
            return number(value) if not isinstance(value, dict) else nested_size_mb(value)
        return nested_size_mb(first(row, ("disk_growth_bytes", "disk.growth_bytes", "disk_delta_bytes")))
    if metric == "recovered":
        value = first(row, ("recovered", "recovery", "recovery_after_load", "recovery.after_load"))
        if isinstance(value, dict):
            value = first(value, ("recovered", "ok", "passed", "after_load"))
        if isinstance(value, bool):
            return value
        if isinstance(value, str) and value.lower() in ("true", "false"):
            return value.lower() == "true"
        return None
    return None


def records(payload: Any, source: str) -> list[dict[str, Any]]:
    if isinstance(payload, list):
        return [dict(item, _source=source) for item in payload if isinstance(item, dict)]
    if not isinstance(payload, dict):
        return []
    for key in ("scenarios", "results", "measurements"):
        value = payload.get(key)
        if isinstance(value, list):
            return [dict(item, _source=source) for item in value if isinstance(item, dict)]
        if isinstance(value, dict):
            result = []
            for name, item in value.items():
                if isinstance(item, dict):
                    result.append(dict(item, scenario=item.get("scenario", name), _source=source))
            if result:
                return result
    rows = payload.get("rows")
    if isinstance(rows, dict):
        result = []
        for name, item in rows.items():
            if isinstance(item, dict):
                result.append(dict(item, scenario=item.get("scenario", name), _source=source))
        return result
    return [dict(payload, _source=source)]


def load_inputs(paths: list[str], input_dir: str | None) -> list[dict[str, Any]]:
    names = list(paths)
    if input_dir:
        names.extend(str(path) for path in sorted(pathlib.Path(input_dir).glob("*.json")))
    if not names:
        names = ["-"]
    result: list[dict[str, Any]] = []
    for name in names:
        text = sys.stdin.read() if name == "-" else pathlib.Path(name).read_text(encoding="utf-8")
        try:
            payload = json.loads(text)
        except json.JSONDecodeError as exc:
            raise SystemExit(f"invalid JSON in {name}: {exc}") from exc
        result.extend(records(payload, name))
    return result


def scenario_name(row: dict[str, Any], source: str, index: int) -> str:
    value = first(row, ("scenario", "name", "id", "case", "angle"))
    return str(value) if value is not None else f"{pathlib.Path(source).stem}:{index + 1}"


def normalize(row: dict[str, Any], source: str, index: int, baseline: dict[str, dict[str, Any]]) -> dict[str, Any]:
    scenario = scenario_name(row, source, index)
    values = {metric: metric_value(row, metric) for metric in METRICS}
    missing = [metric for metric, value in values.items() if value is None]
    status = first(row, ("status", "outcome"))
    if status is None and isinstance(row.get("ok"), bool):
        status = "pass" if row["ok"] else "fail"
    if status is None:
        status = "pass" if not first(row, ("error", "errors")) else "error"
    normalized = {
        "scenario": scenario,
        "status": str(status),
        "source": source,
        **values,
        "missing_metrics": missing,
    }
    reference = baseline.get(scenario)
    if reference:
        deltas: dict[str, float] = {}
        for metric in METRICS:
            current = number(values.get(metric))
            previous = number(reference.get(metric))
            if current is None or previous in (None, 0):
                continue
            if metric == "frame_rate_fps":
                deltas[metric] = round((previous - current) / abs(previous) * 100, 2)
            elif metric != "recovered":
                deltas[metric] = round((current - previous) / abs(previous) * 100, 2)
        if deltas:
            normalized["baseline_delta_percent"] = deltas
    return normalized


def problem(row: dict[str, Any], frame_floor: float, latency_ceiling: float) -> dict[str, Any] | None:
    reasons: list[str] = []
    score = 0.0
    if row["status"].lower() not in ("pass", "ok", "success", "complete"):
        reasons.append(f"status={row['status']}")
        score += 1000
    if row["recovered"] is False:
        reasons.append("did not recover after load")
        score += 500
    if number(row["main_thread_hangs"]) and row["main_thread_hangs"] > 0:
        reasons.append(f"{row['main_thread_hangs']} main-thread hang(s)")
        score += 400 + min(float(row["main_thread_hangs"]), 100)
    p95 = number(row["input_to_paint_p95_ms"])
    if p95 is not None and p95 > latency_ceiling:
        reasons.append(f"input-to-paint p95 {p95:g} ms")
        score += p95
    fps = number(row["frame_rate_fps"])
    if fps is not None and fps < frame_floor:
        reasons.append(f"frame rate {fps:g} fps")
        score += (frame_floor - fps) * 5
    deltas = row.get("baseline_delta_percent", {})
    for metric, delta in deltas.items():
        if delta > 10:
            reasons.append(f"{metric} +{delta:g}% vs baseline")
            score += delta
    if not reasons:
        return None
    return {"scenario": row["scenario"], "score": round(score, 2), "reasons": reasons, "source": row["source"]}


def display(value: Any, suffix: str = "") -> str:
    if value is None:
        return "—"
    if isinstance(value, float):
        return f"{value:g}{suffix}"
    return f"{value}{suffix}"


def markdown(report: dict[str, Any]) -> str:
    lines = [
        "# cmux NEXT stress report",
        "",
        f"Measured commit `{report['metadata'].get('sha') or 'unknown'}` on "
        f"`{report['metadata'].get('host') or 'unknown host'}`.",
        "",
        "| Scenario | FPS | Input→paint p50/p95/p99 (ms) | Hangs | CPU | RSS (MB) | Disk Δ (MB) | Recovery | Status |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |",
    ]
    for row in report["scenarios"]:
        latency = "/".join(display(row[f"input_to_paint_{p}_ms"]) for p in ("p50", "p95", "p99"))
        lines.append(
            f"| {row['scenario']} | {display(row['frame_rate_fps'])} | {latency} | "
            f"{display(row['main_thread_hangs'])} | {display(row['cpu_percent'], '%')} | "
            f"{display(row['rss_mb'])} | {display(row['disk_growth_mb'])} | "
            f"{display(row['recovered'])} | {row['status']} |"
        )
    lines.extend(["", "## Top problems", ""])
    if report["top_problems"]:
        for item in report["top_problems"]:
            lines.append(f"- **{item['scenario']}** ({item['score']:g}) — {'; '.join(item['reasons'])}")
    else:
        lines.append("No threshold or recovery problems were detected.")
    lines.append("")
    return "\n".join(lines)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs", nargs="*", help="JSON result files, or - for stdin")
    parser.add_argument("--input-dir", help="read all top-level JSON files in this directory")
    parser.add_argument("--output", required=True, help="normalized JSON report path")
    parser.add_argument("--markdown", help="Markdown report path")
    parser.add_argument("--baseline", help="prior normalized report for percentage deltas")
    parser.add_argument("--sha", default=os.environ.get("GITHUB_SHA"))
    parser.add_argument("--host", default=os.environ.get("RUNNER_NAME") or os.environ.get("HOSTNAME"))
    parser.add_argument("--nightly", help="nightly or app build identifier")
    parser.add_argument("--frame-floor", type=float, default=30.0)
    parser.add_argument("--latency-ceiling", type=float, default=100.0)
    parser.add_argument("--top", type=int, default=5)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    baseline_rows: dict[str, dict[str, Any]] = {}
    if args.baseline:
        baseline_payload = json.loads(pathlib.Path(args.baseline).read_text(encoding="utf-8"))
        for row in baseline_payload.get("scenarios", []):
            if isinstance(row, dict) and row.get("scenario"):
                baseline_rows[str(row["scenario"])] = row
    raw_rows = load_inputs(args.inputs, args.input_dir)
    scenarios = [
        normalize(row, row.pop("_source", "input"), index, baseline_rows)
        for index, row in enumerate(raw_rows)
    ]
    problems = [item for row in scenarios if (item := problem(row, args.frame_floor, args.latency_ceiling))]
    problems.sort(key=lambda item: item["score"], reverse=True)
    report = {
        "schema_version": 1,
        "generated_at": now_iso(),
        "metadata": {"sha": args.sha, "host": args.host, "nightly": args.nightly},
        "scenarios": scenarios,
        "top_problems": problems[: max(args.top, 0)],
    }
    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if args.markdown:
        markdown_path = pathlib.Path(args.markdown)
        markdown_path.parent.mkdir(parents=True, exist_ok=True)
        markdown_path.write_text(markdown(report), encoding="utf-8")
    print(json.dumps({"scenarios": len(scenarios), "top_problems": len(report["top_problems"]), "output": str(output)}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
