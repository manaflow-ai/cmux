"""One row schema for every bench (cmux-bench/v1).

A run is a list of rows. Each row is one metric of one run:

    {
      "schema": "cmux-bench/v1",
      "run_id": "20261116T0412Z-launch-3f2a9c1d",   # one id per run, shared by its rows
      "bench": "launch",                             # registered bench name
      "metric": "dock_to_main_ms",                   # stable within a bench
      "value": 412.0,                                # the number compare reads (the median when n > 1)
      "unit": "ms",                                  # ms, s, MB, KB, kbps, fps, %, count, mW, bytes
      "better": "lower",                             # lower | higher | none (how compare judges a delta)
      "p50": 412.0, "p95": 530.0, "n": 5,           # when the metric has samples; else null
      "labels": {"arm": "cmux"},                     # extra dimensions (arm, target, component, ...)
      "build": {"channel": "nightly", "version": "0.80.0-next.123", "sha": "abc..."},
      "host": {"name": "cmux20-bench", "role": "fleet", "os": "macOS 27.0", "chip": "Apple M6"},
      "harness": {"name": "scripts/measure/launch-ready.sh", "version": "launch@2+3a731ce"},
      "timestamp": "2026-11-16T04:12:09Z"
    }

A metric is identified by (bench, metric, labels). Two runs compare row by row on that key.
"""
from __future__ import annotations

import datetime as _dt
import math
import secrets
import statistics
from typing import Any, Iterable

SCHEMA = "cmux-bench/v1"
UNITS = {"ms", "s", "us", "MB", "KB", "GB", "bytes", "kbps", "Mbps", "fps", "%", "count", "mW", "W", "per_s", "x"}
BETTER = {"lower", "higher", "none"}
CHANNELS = {"nightly", "DEV", "sha", "release", "local", "other"}
ROLES = {"fleet", "local-readonly", "anywhere"}


class SchemaError(ValueError):
    pass


def now_iso() -> str:
    return _dt.datetime.now(_dt.timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def new_run_id(bench: str) -> str:
    # Milliseconds in the id: runs recorded in the same second (imports) still sort in the order they were made.
    now = _dt.datetime.now(_dt.timezone.utc)
    stamp = now.strftime("%Y%m%dT%H%M%S") + f"{now.microsecond // 1000:03d}Z"
    return f"{stamp}-{bench}-{secrets.token_hex(4)}"


def percentile(samples: list[float], q: float) -> float:
    """Nearest-rank-with-interpolation percentile (q in 0..100), as numpy's default."""
    xs = sorted(samples)
    if not xs:
        raise ValueError("no samples")
    if len(xs) == 1:
        return float(xs[0])
    pos = (len(xs) - 1) * q / 100.0
    lo, hi = math.floor(pos), math.ceil(pos)
    return float(xs[lo] + (xs[hi] - xs[lo]) * (pos - lo))


def summarize(samples: Iterable[float]) -> dict[str, Any]:
    xs = [float(x) for x in samples]
    return {"value": statistics.median(xs), "p50": percentile(xs, 50), "p95": percentile(xs, 95), "n": len(xs)}


def label_key(labels: dict[str, Any] | None) -> str:
    if not labels:
        return ""
    return ",".join(f"{k}={labels[k]}" for k in sorted(labels))


def metric_key(row: dict[str, Any]) -> tuple[str, str, str]:
    return (row["bench"], row["metric"], label_key(row.get("labels")))


def validate(row: dict[str, Any]) -> dict[str, Any]:
    """Raise SchemaError when a row is not a cmux-bench/v1 row; return it otherwise."""
    def need(cond: bool, msg: str) -> None:
        if not cond:
            raise SchemaError(f"{row.get('bench', '?')}/{row.get('metric', '?')}: {msg}")

    need(row.get("schema") == SCHEMA, f"schema must be {SCHEMA}")
    for field in ("run_id", "bench", "metric", "unit", "timestamp"):
        need(isinstance(row.get(field), str) and row[field] != "", f"{field} must be a non-empty string")
    need(isinstance(row.get("value"), (int, float)) and not isinstance(row["value"], bool), "value must be a number")
    need(math.isfinite(float(row["value"])), "value must be finite")
    need(row["unit"] in UNITS, f"unit {row['unit']!r} is not one of {sorted(UNITS)}")
    need(row.get("better") in BETTER, f"better must be one of {sorted(BETTER)}")
    for q in ("p50", "p95"):
        need(row.get(q) is None or isinstance(row[q], (int, float)), f"{q} must be a number or null")
    need(row.get("n") is None or (isinstance(row["n"], int) and row["n"] >= 1), "n must be a positive int or null")
    need(isinstance(row.get("labels", {}), dict), "labels must be an object")
    build = row.get("build")
    need(isinstance(build, dict) and build.get("channel") in CHANNELS, f"build.channel must be one of {sorted(CHANNELS)}")
    host = row.get("host")
    need(isinstance(host, dict) and isinstance(host.get("name"), str) and host.get("role") in ROLES,
         f"host needs a name and a role in {sorted(ROLES)}")
    harness = row.get("harness")
    need(isinstance(harness, dict) and harness.get("name") and harness.get("version"), "harness needs name and version")
    return row
