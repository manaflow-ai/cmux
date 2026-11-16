#!/usr/bin/env python3
"""Publish the screen-share-fast goal row from a screen-stream-eval result.

The harness keeps the full evidence in results.json. This file is the small, stable
contract consumed by the goal board: it never turns a one-Mac or missing-comparison
run into a passing two-Mac latency result.
"""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

SCHEMA = "cmux.screen-share-fast/1"
SOURCE_SCHEMA = "cmux.screen-stream-eval/1"
TARGET_P50_MS = 160.0


def _p50(target: dict, input_name: str = "key") -> float | None:
    value = ((target.get("latency") or {}).get(input_name) or {}).get("p50_ms")
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def _comparison(results: dict) -> tuple[str | None, float | None]:
    for name, target in (results.get("targets") or {}).items():
        if name.lower().startswith("apple"):
            value = _p50(target)
            if value is not None:
                return name, value
    return None, None


def publish(source: Path, destination: Path) -> dict:
    raw = source.read_bytes()
    results = json.loads(raw)
    if results.get("schema") != SOURCE_SCHEMA:
        raise ValueError(f"expected {SOURCE_SCHEMA}, got {results.get('schema')!r}")

    run = results.get("run") or {}
    targets = results.get("targets") or {}
    rd = targets.get("rd") or {}
    cmux_p50 = _p50(rd)
    apple_name, apple_p50 = _comparison(results)
    link = str(run.get("link") or "")
    two_mac = link.startswith("lan")
    errors = []
    if not two_mac:
        errors.append("two-Mac link evidence is missing")
    if cmux_p50 is None:
        errors.append("rd key latency p50 is missing")
    if apple_p50 is None:
        errors.append("Apple comparison key latency p50 is missing")
    required = {"rd"}
    if apple_name:
        required.add(apple_name)
    for name, target in targets.items():
        if name not in required:
            continue
        for error in target.get("errors") or []:
            errors.append(f"{name}: {error}")

    complete = not errors
    under_target = cmux_p50 is not None and cmux_p50 <= TARGET_P50_MS
    outcome = "pass" if complete and under_target else "fail" if complete else "unknown"
    probe = {
        "schema": SCHEMA,
        "probe": "screen-share-fast",
        "at": run.get("at"),
        "outcome": outcome,
        "complete": complete,
        "two_mac": two_mac,
        "target_p50_ms": TARGET_P50_MS,
        "metrics": {
            "cmux_key_p50_ms": cmux_p50,
            "apple_target": apple_name,
            "apple_key_p50_ms": apple_p50,
            "under_target": under_target if cmux_p50 is not None else None,
            "motion_fps": {name: (target.get("fps") or {}).get("scroll")
                           for name, target in targets.items()
                           if (target.get("fps") or {}).get("scroll") is not None},
        },
        "run": {
            "host": run.get("host"),
            "viewer": run.get("viewer"),
            "link": run.get("link"),
            "rev": run.get("rev"),
        },
        "errors": errors,
        "source": {
            "schema": SOURCE_SCHEMA,
            "sha256": hashlib.sha256(raw).hexdigest(),
            "path": source.name,
        },
    }
    destination.write_text(json.dumps(probe, indent=2, sort_keys=True) + "\n")
    return probe


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: probe.py RESULTS.json PROBE.json", file=sys.stderr)
        return 2
    try:
        publish(Path(argv[0]), Path(argv[1]))
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"screen-share-fast probe: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
