#!/usr/bin/env python3
"""Normalize xcodebuild's flat built-test enumeration for app-host census runs."""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path
from typing import Any


def load_inventory(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("test enumeration root must be a JSON object")
    return value


def _error_text(value: Any) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        for key in ("message", "description", "error"):
            item = value.get(key)
            if isinstance(item, str):
                return item
    return json.dumps(value, sort_keys=True)


def normalize(document: dict[str, Any], *, required_target: str) -> dict[str, Any]:
    errors = document.get("errors", [])
    if not isinstance(errors, list):
        raise ValueError("test enumeration errors must be a list")
    if errors:
        raise ValueError("xcodebuild test enumeration reported errors: " + "; ".join(_error_text(x) for x in errors))

    values = document.get("values")
    if not isinstance(values, list) or not values:
        raise ValueError("test enumeration has no values")

    enabled: set[str] = set()
    disabled: set[str] = set()
    plans: set[str] = set()
    for value in values:
        if not isinstance(value, dict):
            raise ValueError("test enumeration value must be an object")
        plan = value.get("testPlan")
        if isinstance(plan, str) and plan:
            plans.add(plan)
        for key, destination in (("enabledTests", enabled), ("disabledTests", disabled)):
            tests = value.get(key, [])
            if tests is None:
                tests = []
            if not isinstance(tests, list):
                raise ValueError(f"{key} must be a list")
            for item in tests:
                if not isinstance(item, dict) or not isinstance(item.get("identifier"), str):
                    raise ValueError(f"{key} contains a test without an identifier")
                identifier = item["identifier"].strip()
                if identifier:
                    destination.add(identifier)

    if not enabled:
        raise ValueError("built app-host inventory contains zero enabled tests")

    unexpected = sorted(identifier for identifier in enabled | disabled if not identifier.startswith(required_target + "/"))
    if unexpected:
        raise ValueError(
            f"built app-host inventory contains tests outside {required_target}: "
            + ", ".join(unexpected[:10])
        )

    contradictory = sorted(enabled & disabled)
    if contradictory:
        raise ValueError(
            "built app-host inventory marks tests both enabled and disabled: "
            + ", ".join(contradictory[:10])
        )

    suites = Counter()
    for identifier in enabled:
        parts = identifier.split("/")
        suite = "/".join(parts[:2]) if len(parts) >= 2 else identifier
        suites[suite] += 1

    return {
        "format_version": 1,
        "target": required_target,
        "test_plans": sorted(plans),
        "enabled_test_count": len(enabled),
        "disabled_test_count": len(disabled),
        "suite_count": len(suites),
        "enabled_tests": sorted(enabled),
        "disabled_tests": sorted(disabled),
        "enabled_tests_by_suite": dict(sorted(suites.items())),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--require-target", default="cmuxTests")
    args = parser.parse_args()

    try:
        normalized = normalize(load_inventory(args.input), required_target=args.require_target)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        raise SystemExit(f"invalid app-host test inventory: {exc}") from exc

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(normalized, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(
        "Built app-host inventory: "
        f"{normalized['enabled_test_count']} enabled tests across "
        f"{normalized['suite_count']} suites; "
        f"{normalized['disabled_test_count']} disabled"
    )


if __name__ == "__main__":
    main()
