#!/usr/bin/env python3
"""Generate cmux-unit XCTest plans.

The shard plans are checked in so Xcode and xcodebuild own the selected test
sets. This helper keeps the class lists deterministic when test classes change.
"""

from __future__ import annotations

import json
import pathlib
import re
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
TESTS_DIR = ROOT / "cmuxTests"
SHARD_COUNT = 4

APP_TARGET = {
    "containerPath": "container:cmux.xcodeproj",
    "identifier": "A5001050",
    "name": "cmux",
}

TEST_TARGET = {
    "containerPath": "container:cmux.xcodeproj",
    "identifier": "F1000004A1B2C3D4E5F60718",
    "name": "cmuxTests",
}

SKIPPED_TESTS = [
    # Existing CI skip preserved from the pre-sharded xcodebuild invocation.
    "AppDelegateShortcutRoutingTests/testCmdWClosesWindowWhenClosingLastSurfaceInLastWorkspace()",
    # Temporary skip while fix-ci-grok-notification-hang addresses the CI hang.
    "CLINotifyProcessIntegrationRegressionTests/testNotificationCLIActionsMutateSocketStateAndListExtendedFields()",
]

CLASS_DECL_RE = re.compile(
    r"(?m)^\s*(?:final\s+)?class\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*XCTestCase\b"
)
TOP_LEVEL_DECL_RE = re.compile(
    r"(?m)^\s*(?:(?:final\s+)?class|extension)\s+([A-Za-z_][A-Za-z0-9_]*)\b"
)
TEST_METHOD_RE = re.compile(r"(?m)^\s*(?:@\S[^\n]*\n\s*)*func\s+test[A-Za-z0-9_]*\s*\(")


def stable_id(name: str) -> str:
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"cmux-unit-test-plan:{name}")).upper()


def discover_classes() -> dict[str, int]:
    files = sorted(TESTS_DIR.glob("*.swift"))
    class_names: set[str] = set()
    for path in files:
        text = path.read_text(encoding="utf-8")
        class_names.update(match.group(1) for match in CLASS_DECL_RE.finditer(text))

    counts = {name: 0 for name in class_names}
    for path in files:
        text = path.read_text(encoding="utf-8")
        declarations = list(TOP_LEVEL_DECL_RE.finditer(text))
        for index, match in enumerate(declarations):
            name = match.group(1)
            if name not in counts:
                continue
            start = match.end()
            end = declarations[index + 1].start() if index + 1 < len(declarations) else len(text)
            counts[name] += len(TEST_METHOD_RE.findall(text[start:end]))

    return counts


def assign_shards(class_counts: dict[str, int]) -> list[list[str]]:
    shards: list[list[str]] = [[] for _ in range(SHARD_COUNT)]
    weights = [0 for _ in range(SHARD_COUNT)]
    for name, count in sorted(class_counts.items(), key=lambda item: (-item[1], item[0])):
        shard_index = min(range(SHARD_COUNT), key=lambda index: (weights[index], index))
        shards[shard_index].append(name)
        weights[shard_index] += count
    return [sorted(shard) for shard in shards]


def make_plan(name: str, selected_tests: list[str] | None = None) -> dict[str, object]:
    target: dict[str, object] = {
        "parallelizable": False,
        "skippedTests": SKIPPED_TESTS,
        "target": TEST_TARGET,
    }
    if selected_tests is not None:
        target["selectedTests"] = selected_tests

    return {
        "configurations": [
            {
                "id": stable_id(name),
                "name": "Debug",
                "options": {},
            }
        ],
        "defaultOptions": {
            "environmentVariableEntries": [
                {
                    "key": "SWIFT_BACKTRACE",
                    "value": "enable=no",
                }
            ],
            "targetForVariableExpansion": APP_TARGET,
        },
        "testTargets": [target],
        "version": 1,
    }


def write_plan(path: pathlib.Path, plan: dict[str, object]) -> None:
    path.write_text(json.dumps(plan, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    class_counts = discover_classes()
    if not class_counts:
        raise SystemExit("No XCTestCase classes found")

    write_plan(TESTS_DIR / "cmux-unit.xctestplan", make_plan("cmux-unit"))
    for index, shard in enumerate(assign_shards(class_counts), start=1):
        write_plan(
            TESTS_DIR / f"cmux-unit-shard-{index}.xctestplan",
            make_plan(f"cmux-unit-shard-{index}", selected_tests=shard),
        )


if __name__ == "__main__":
    main()
