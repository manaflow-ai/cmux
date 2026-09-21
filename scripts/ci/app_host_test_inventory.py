#!/usr/bin/env python3
"""Normalize Xcode's built app-host test enumeration into stable test/suite IDs."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


TARGET_PREFIX = "cmuxTests/"


def _identifiers(items: object, label: str) -> list[str]:
    if items is None:
        return []
    if not isinstance(items, list):
        raise ValueError(f"{label} must be an array")
    result: list[str] = []
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            raise ValueError(f"{label}[{index}] must be an object")
        identifier = item.get("identifier")
        if not isinstance(identifier, str) or not identifier.strip():
            raise ValueError(f"{label}[{index}] has no identifier")
        result.append(identifier.strip())
    return result


def normalize(payload: object) -> dict[str, object]:
    if not isinstance(payload, dict):
        raise ValueError("enumeration root must be an object")

    errors = payload.get("errors", [])
    if errors:
        if not isinstance(errors, list):
            raise ValueError("enumeration errors must be an array")
        raise ValueError("xcodebuild enumeration reported errors: " + "; ".join(map(str, errors)))

    values = payload.get("values")
    if not isinstance(values, list) or not values:
        raise ValueError("enumeration has no values")

    enabled: set[str] = set()
    disabled: set[str] = set()
    plans: list[str] = []
    for index, value in enumerate(values):
        if not isinstance(value, dict):
            raise ValueError(f"values[{index}] must be an object")
        enabled.update(_identifiers(value.get("enabledTests"), f"values[{index}].enabledTests"))
        disabled.update(_identifiers(value.get("disabledTests"), f"values[{index}].disabledTests"))
        test_plan = value.get("testPlan")
        if isinstance(test_plan, str) and test_plan:
            plans.append(test_plan)

    enabled_cmux = sorted(identifier for identifier in enabled if identifier.startswith(TARGET_PREFIX))
    disabled_cmux = sorted(identifier for identifier in disabled if identifier.startswith(TARGET_PREFIX))
    if not enabled_cmux:
        raise ValueError("built enumeration contains zero enabled cmuxTests tests")

    malformed = [
        identifier
        for identifier in enabled_cmux + disabled_cmux
        if len(identifier.split("/")) < 3
    ]
    if malformed:
        raise ValueError(
            "enumeration contains identifiers without target/suite/test components: "
            + ", ".join(malformed[:10])
        )

    suites = sorted({"/".join(identifier.split("/")[:2]) for identifier in enabled_cmux})
    disabled_suites = sorted({"/".join(identifier.split("/")[:2]) for identifier in disabled_cmux})

    return {
        "schema_version": 1,
        "source": "xcodebuild -enumerate-tests -test-enumeration-style flat -test-enumeration-format json",
        "test_plans": sorted(set(plans)),
        "enabled_test_count": len(enabled_cmux),
        "disabled_test_count": len(disabled_cmux),
        "suite_count": len(suites),
        "disabled_suite_count": len(disabled_suites),
        "enabled_tests": enabled_cmux,
        "disabled_tests": disabled_cmux,
        "suites": suites,
        "disabled_suites": disabled_suites,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("enumeration", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--summary", type=Path)
    parser.add_argument("--print-suites", action="store_true")
    args = parser.parse_args()

    try:
        payload = json.loads(args.enumeration.read_text(encoding="utf-8"))
        report = normalize(payload)
    except (OSError, json.JSONDecodeError, ValueError) as error:
        raise SystemExit(f"invalid app-host test enumeration: {error}")

    encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded, encoding="utf-8")

    line = (
        "Built app-host inventory: "
        f"{report['enabled_test_count']} enabled tests in {report['suite_count']} suites; "
        f"{report['disabled_test_count']} disabled tests in {report['disabled_suite_count']} suites"
    )
    print(line)
    if args.print_suites:
        for suite in report["suites"]:
            print(f"ENUM_SUITE {suite}")

    if args.summary:
        with args.summary.open("a", encoding="utf-8") as handle:
            handle.write("### Built app-host test inventory\n\n")
            handle.write(line + "\n\n")
            handle.write(
                "Inventory source: Xcode compiled-test enumeration for the restored xctestrun, "
                "not source filenames.\n"
            )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
