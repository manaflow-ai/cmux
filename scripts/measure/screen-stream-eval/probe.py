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
# hq goals/screen-share-fast.md: what a person sees (key to presented frame) at p95, and cmux's
# presented p95 below Apple Screen Sharing's on the same pair.
PRESENTED_TARGET_P95_MS = 100.0


def _p50(target: dict, input_name: str = "key") -> float | None:
    value = ((target.get("latency") or {}).get(input_name) or {}).get("p50_ms")
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def _p95(target: dict, input_name: str = "key") -> float | None:
    value = ((target.get("latency") or {}).get(input_name) or {}).get("p95_ms")
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def _presented(targets: dict, two_mac: bool) -> dict:
    """Key to presented frame for cmux (rd-present) and Apple (Screen Sharing.app, apple-high or
    else apple-standard, whose rows only the presented observer fills), each timed by the same
    `cmux-rd observe` on the viewer Mac. apple-rfb ends at its decode, so it never counts here.
    Additive: `outcome` stays rd's decode row; this block says whether the presented goal is
    met, or why it is unknown."""
    cmux = targets.get("rd-present") or {}
    apple_name = next((n for n in ("apple-high", "apple-standard") if _p95(targets.get(n) or {}) is not None), None)
    apple = targets.get(apple_name) or {} if apple_name else {}
    cmux_p50, cmux_p95 = _p50(cmux), _p95(cmux)
    apple_p50, apple_p95 = _p50(apple), _p95(apple)
    why = []
    if not two_mac:
        why.append("two-Mac link evidence is missing")
    if cmux_p95 is None:
        why.append("rd-present key p95 is missing")
    if apple_p95 is None:
        why.append("Apple presented key p95 is missing")
    why += [f"rd-present: {e}" for e in cmux.get("errors") or []]
    complete = not why
    met = complete and cmux_p95 <= PRESENTED_TARGET_P95_MS and cmux_p95 < apple_p95
    return {
        "outcome": "pass" if met else "fail" if complete else "unknown",
        "target_p95_ms": PRESENTED_TARGET_P95_MS,
        "cmux_key_p50_ms": cmux_p50,
        "cmux_key_p95_ms": cmux_p95,
        "apple_target": apple_name,
        "apple_key_p50_ms": apple_p50,
        "apple_key_p95_ms": apple_p95,
        "cmux_beats_apple_p95": (cmux_p95 < apple_p95) if complete else None,
        "errors": why,
    }


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
            "presented": _presented(targets, two_mac),
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
