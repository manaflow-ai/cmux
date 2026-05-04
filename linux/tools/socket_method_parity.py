#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ast
import json
import re
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
LINUX_APP = ROOT / "linux" / "lib" / "cmux_linux" / "app.py"
MACOS_REGISTRY = ROOT / "Packages" / "CMUXCore" / "Sources" / "CMUXCore" / "SocketMethodRegistry.swift"


def python_constant(path: Path, name: str) -> tuple[str, ...]:
    module = ast.parse(path.read_text(encoding="utf-8"))
    for node in module.body:
        if not isinstance(node, ast.Assign):
            continue
        if not any(isinstance(target, ast.Name) and target.id == name for target in node.targets):
            continue
        value = ast.literal_eval(node.value)
        return tuple(str(item) for item in value)
    raise ValueError(f"{name} not found in {path}")


def swift_method_names(path: Path) -> tuple[str, ...]:
    source = path.read_text(encoding="utf-8")
    match = re.search(r"productionMethodNames:\s*\[String\]\s*=\s*\[(.*?)\n\s*\]", source, re.DOTALL)
    if match is None:
        raise ValueError(f"productionMethodNames not found in {path}")
    return tuple(re.findall(r'"([^"]+)"', match.group(1)))


def build_report() -> dict[str, Any]:
    macos_methods = set(swift_method_names(MACOS_REGISTRY))
    linux_methods = set(python_constant(LINUX_APP, "SUPPORTED_METHODS"))
    unsupported = set(python_constant(LINUX_APP, "UNSUPPORTED_METHODS"))
    implemented = linux_methods - unsupported
    macos_only = sorted(macos_methods - linux_methods)
    unsupported_not_declared = sorted(unsupported - linux_methods)
    strict_failures = []
    if macos_only:
        strict_failures.append("macos_only")
    if unsupported_not_declared:
        strict_failures.append("unsupported_not_declared")
    return {
        "counts": {
            "macos_production": len(macos_methods),
            "linux_declared": len(linux_methods),
            "linux_implemented": len(implemented),
            "linux_unsupported": len(unsupported),
        },
        "macos_only": macos_only,
        "linux_only": sorted(linux_methods - macos_methods),
        "unsupported": sorted(unsupported),
        "unsupported_not_declared": unsupported_not_declared,
        "strict_failures": strict_failures,
        "common_implemented": sorted(macos_methods & implemented),
    }


def print_text(report: dict[str, Any]) -> None:
    counts = report["counts"]
    print(
        "socket method parity: "
        f"macOS={counts['macos_production']} "
        f"linux_declared={counts['linux_declared']} "
        f"linux_implemented={counts['linux_implemented']} "
        f"linux_unsupported={counts['linux_unsupported']}"
    )
    for key in ("macos_only", "linux_only", "unsupported", "unsupported_not_declared", "strict_failures"):
        values = report[key]
        print(f"{key}: {len(values)}")
        for value in values:
            print(f"  - {value}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Compare macOS production socket methods with Linux capabilities.")
    parser.add_argument("--json", action="store_true", help="Print machine-readable JSON.")
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Fail when macOS methods are missing from Linux or unsupported methods are not declared.",
    )
    args = parser.parse_args()
    report = build_report()
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print_text(report)
    return 1 if args.strict and report["strict_failures"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
