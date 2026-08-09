#!/usr/bin/env python3
"""Generate deterministic -only-testing arguments for cmuxTests shards.

Shards are packed greedily by weight. Weights are measured milliseconds from
scripts/ci/cmux-unit-test-timings.json when present (regenerate it with
scripts/ci/generate_test_timings.py from a green main run's shard logs).
Suites and methods missing from the manifest fall back to a per-test estimate,
so new or renamed tests never break sharding — they just pack less precisely
until the manifest is refreshed.

Each machine shard can additionally be split into selector- and test-bounded
process batches. Every batch is a separate xcodebuild invocation and therefore
a fresh app host, preventing one long-lived XCTest process from retaining
unbounded AppKit/WebKit state while preserving the existing cross-machine shard
balance.
"""

from __future__ import annotations

import argparse
import hashlib
import heapq
import json
import re
import sys
from dataclasses import dataclass, replace
from pathlib import Path


SUITE_RE = re.compile(
    r"^(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?\s+)*"
    r"(?:(?:final|private|fileprivate|internal|public)\s+)*"
    r"(?:class|struct|actor)\s+([A-Za-z_][A-Za-z0-9_]*)\b"
)
EXTENSION_RE = re.compile(r"^extension\s+([A-Za-z_][A-Za-z0-9_]*)\b")
TEST_TOKEN_RE = re.compile(r"(^|\s)(@Test\b|func\s+test[A-Za-z0-9_]*\s*\()")
XCTEST_METHOD_RE = re.compile(
    r"^\s*(?:(?:final|private|fileprivate|internal|public)\s+)*"
    r"func\s+(test[A-Za-z0-9_]*)\s*\("
)
LARGE_SUITE_METHOD_THRESHOLD = 40
DEFAULT_TIMINGS_PATH = Path(__file__).resolve().parent / "cmux-unit-test-timings.json"
FALLBACK_TEST_MS = 200
# Stay below AppKit's observed 100-live-window warning even if CI overrides the
# workflow default; known multi-window lifecycle suites are isolated below.
MAX_PROCESS_TEST_LIMIT = 80
FOCUSED_GATE_SELECTORS = {
    "cmuxTests/BrowserSystemProxyMirrorTests",
    "cmuxTests/CLISSHSessionAttachAnchorTests",
    "cmuxTests/GhosttyOptionAsAltModsTests",
    "cmuxTests/RemoteTmuxMirrorLayoutIdentityTests",
}
# These suites repeatedly exercise window-portal lifecycle cleanup. They remain
# isolated even below the generic represented-test limit so retained AppKit or
# WebKit state from one lifecycle suite cannot cascade into another.
PROCESS_ISOLATED_SUITES = frozenset(
    {
        "cmuxTests/BrowserWindowPortalLifecycleTests",
        "cmuxTests/TerminalOffscreenStartupTests",
        "cmuxTests/TerminalWindowPortalLifecycleTests",
    }
)
# BrowserDeveloperToolsVisibilityPersistenceTests reliably crash-restarts the
# app host on CI runners (its detached-inspector tests kill the host mid-run;
# see the "Restarting after unexpected exit" storms in app-host shard logs on
# main and PR runs alike). Live-WKWebView navigation tests that run behind
# that storm in the same shard time out with thrown errors, which count as
# unexpected failures and fail the shard. Count-based packing happened to
# keep the pair below apart; time-weighted packing co-located them and both
# attempts of https://github.com/manaflow-ai/cmux/pull/7687 failed shard 3
# the same way. Keep each group's suites on different shards.
SEPARATED_SUITES: tuple[frozenset[str], ...] = (
    frozenset(
        {
            "cmuxTests/BrowserDeveloperToolsVisibilityPersistenceTests",
            "cmuxTests/BrowserSessionHistoryRestoreTests",
        }
    ),
)


@dataclass(frozen=True)
class TestSelector:
    identifier: str
    path: str
    line: int
    weight: int
    test_count: int


@dataclass(frozen=True)
class SuiteDeclaration:
    name: str
    path: str
    line: int
    weight: int
    methods: tuple[TestSelector, ...]


def xctest_methods(
    suite_identifier: str, relative_path: str, start_line: int, body: list[str]
) -> list[TestSelector]:
    return [
        TestSelector(
            identifier=f"{suite_identifier}/{match.group(1)}",
            path=relative_path,
            line=start_line + offset,
            weight=1,
            test_count=1,
        )
        for offset, body_line in enumerate(body)
        if (match := XCTEST_METHOD_RE.match(body_line))
    ]


def discover_selectors(root: Path) -> list[TestSelector]:
    test_root = root / "cmuxTests"
    if not test_root.is_dir():
        raise SystemExit(f"cmuxTests directory not found under {root}")

    declarations: list[SuiteDeclaration] = []
    extension_methods: dict[str, list[TestSelector]] = {}
    for path in sorted(test_root.glob("**/*.swift")):
        relative = path.relative_to(root).as_posix()
        lines = path.read_text(encoding="utf-8").splitlines()
        top_level_declarations: list[tuple[int, str, str]] = []
        for index, line in enumerate(lines, start=1):
            match = SUITE_RE.match(line)
            if match:
                name = match.group(1)
                if name.endswith(("Tests", "UITests")):
                    top_level_declarations.append((index, "suite", name))
                continue

            match = EXTENSION_RE.match(line)
            if match:
                name = match.group(1)
                if name.endswith(("Tests", "UITests")):
                    top_level_declarations.append((index, "extension", name))

        for position, (line_number, kind, name) in enumerate(top_level_declarations):
            next_line = (
                top_level_declarations[position + 1][0]
                if position + 1 < len(top_level_declarations)
                else len(lines) + 1
            )
            body = lines[line_number - 1 : next_line - 1]
            weight = max(1, sum(1 for line in body if TEST_TOKEN_RE.search(line)))
            suite_identifier = f"cmuxTests/{name}"
            methods = xctest_methods(suite_identifier, relative, line_number, body)
            if kind == "extension":
                extension_methods.setdefault(name, []).extend(methods)
                continue

            declarations.append(
                SuiteDeclaration(
                    name=name,
                    path=relative,
                    line=line_number,
                    weight=weight,
                    methods=tuple(methods),
                )
            )

    selectors: list[TestSelector] = []
    declared_suite_names = {declaration.name for declaration in declarations}
    for extension_name in sorted(set(extension_methods) - declared_suite_names):
        locations = ", ".join(
            f"{method.path}:{method.line}" for method in extension_methods[extension_name]
        )
        print(
            f"Extension declares tests for unknown suite cmuxTests/{extension_name}: {locations}",
            file=sys.stderr,
        )
        raise SystemExit(1)

    for declaration in declarations:
        suite_identifier = f"cmuxTests/{declaration.name}"
        extension_selectors = extension_methods.get(declaration.name, [])
        methods = [*declaration.methods, *extension_selectors]
        weight = declaration.weight + len(extension_selectors)

        if suite_identifier in FOCUSED_GATE_SELECTORS:
            continue

        # Very large XCTestCase classes dominate a shard when selected as a
        # whole suite. Split those classes by XCTest method while keeping
        # smaller suites grouped so xcodebuild still has a compact selector
        # list and shared setup inside each suite. Include extension methods in
        # the split so extension-declared regressions remain covered.
        if len(methods) >= LARGE_SUITE_METHOD_THRESHOLD:
            selectors.extend(methods)
            continue

        selectors.append(
            TestSelector(
                identifier=suite_identifier,
                path=declaration.path,
                line=declaration.line,
                weight=weight,
                test_count=weight,
            )
        )

    if not selectors:
        raise SystemExit("No cmuxTests suites found")

    by_identifier: dict[str, list[TestSelector]] = {}
    for selector in selectors:
        by_identifier.setdefault(selector.identifier, []).append(selector)
    duplicates = {name: values for name, values in by_identifier.items() if len(values) > 1}
    if duplicates:
        print("Duplicate cmuxTests selector identifiers:", file=sys.stderr)
        for name, values in sorted(duplicates.items()):
            locations = ", ".join(f"{selector.path}:{selector.line}" for selector in values)
            print(f"  {name}: {locations}", file=sys.stderr)
        raise SystemExit(1)

    return sorted(selectors, key=lambda selector: selector.identifier)


def load_timings(path: Path) -> dict | None:
    if not path.is_file():
        return None
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"Ignoring unreadable timings manifest {path}: {error}", file=sys.stderr)
        return None
    if (
        not isinstance(manifest, dict)
        or not isinstance(manifest.get("suites"), dict)
        or not isinstance(manifest.get("methods"), dict)
    ):
        print(f"Ignoring malformed timings manifest {path}", file=sys.stderr)
        return None
    return manifest


def reweight_selectors(
    selectors: list[TestSelector], timings: dict | None
) -> tuple[list[TestSelector], int]:
    """Return selectors with weights in measured milliseconds.

    Without a manifest every weight becomes test_count * FALLBACK_TEST_MS — a
    constant scaling of the count weights, which packs identically to the old
    count-based behavior. Returns (selectors, measured_count).
    """
    suites = timings.get("suites", {}) if timings else {}
    methods = timings.get("methods", {}) if timings else {}
    fallback_ms = timings.get("default_test_ms", FALLBACK_TEST_MS) if timings else FALLBACK_TEST_MS

    methods_per_suite: dict[str, int] = {}
    for selector in selectors:
        parts = selector.identifier.split("/")
        if len(parts) == 3:
            methods_per_suite[parts[1]] = methods_per_suite.get(parts[1], 0) + 1

    reweighted: list[TestSelector] = []
    measured = 0
    for selector in selectors:
        parts = selector.identifier.split("/")
        if len(parts) == 3:
            _, suite, method = parts
            ms = methods.get(f"{suite}/{method}")
            if ms is None and suite in suites:
                ms = suites[suite] / methods_per_suite[suite]
            if ms is None:
                ms = fallback_ms
            else:
                measured += 1
        else:
            suite = parts[1]
            ms = suites.get(suite)
            if ms is None:
                ms = selector.weight * fallback_ms
            else:
                measured += 1
        reweighted.append(replace(selector, weight=max(1, int(ms))))
    return reweighted, measured


def shard_selectors(
    selectors: list[TestSelector], shard_index: int, shard_total: int
) -> list[TestSelector]:
    if shard_total < 1:
        raise SystemExit("--shard-total must be >= 1")
    if shard_index < 1 or shard_index > shard_total:
        raise SystemExit("--shard-index must be between 1 and --shard-total")

    group_by_suite: dict[str, int] = {}
    for group_index, group in enumerate(SEPARATED_SUITES):
        for suite in group:
            group_by_suite[suite] = group_index

    buckets: list[list[TestSelector]] = [[] for _ in range(shard_total)]
    bucket_weights = [0 for _ in range(shard_total)]
    # Which separated suites each bucket already holds, as (group, suite).
    bucket_separated: list[set[tuple[int, str]]] = [set() for _ in range(shard_total)]
    ordered = sorted(
        selectors,
        key=lambda selector: (
            -selector.weight,
            hashlib.sha256(selector.identifier.encode("utf-8")).hexdigest(),
            selector.identifier,
        ),
    )
    for selector in ordered:
        suite = "/".join(selector.identifier.split("/")[:2])
        group_index = group_by_suite.get(suite)
        candidates = list(range(shard_total))
        if group_index is not None:
            allowed = [
                index
                for index in candidates
                if all(
                    held_suite == suite
                    for held_group, held_suite in bucket_separated[index]
                    if held_group == group_index
                )
            ]
            # With more group members than shards, separation is impossible;
            # fall back to plain min-weight packing for the overflow.
            if allowed:
                candidates = allowed
        bucket_index = min(candidates, key=lambda index: (bucket_weights[index], index))
        if group_index is not None:
            bucket_separated[bucket_index].add((group_index, suite))
        buckets[bucket_index].append(selector)
        bucket_weights[bucket_index] += selector.weight

    return sorted(buckets[shard_index - 1], key=lambda selector: selector.identifier)


def process_batches(
    selectors: list[TestSelector], maximum_selectors: int, maximum_tests: int
) -> list[list[TestSelector]]:
    """Pack one shard into timing-balanced processes with hard work limits."""
    if maximum_selectors < 1:
        raise SystemExit("--batch-selector-limit must be >= 1")
    if maximum_tests < 1:
        raise SystemExit("--batch-test-limit must be >= 1")
    if maximum_tests > MAX_PROCESS_TEST_LIMIT:
        raise SystemExit(f"--batch-test-limit must be <= {MAX_PROCESS_TEST_LIMIT}")

    oversized = [
        selector for selector in selectors if selector.test_count > maximum_tests
    ]
    if oversized:
        selector = min(oversized, key=lambda item: item.identifier)
        raise SystemExit(
            f"Selector {selector.identifier} represents {selector.test_count} tests, "
            f"exceeding --batch-test-limit {maximum_tests}; split the suite selector"
        )

    resource_isolated = [
        selector
        for selector in selectors
        if "/".join(selector.identifier.split("/")[:2]) in PROCESS_ISOLATED_SUITES
    ]
    resource_isolated_identifiers = {
        selector.identifier for selector in resource_isolated
    }
    packable = [
        selector
        for selector in selectors
        if selector.identifier not in resource_isolated_identifiers
    ]

    def required_batch_count(items: list[TestSelector]) -> int:
        if not items:
            return 0
        return max(
            (len(items) + maximum_selectors - 1) // maximum_selectors,
            (sum(selector.test_count for selector in items) + maximum_tests - 1)
            // maximum_tests,
        )

    provisional_batch_count = required_batch_count(packable)
    total_packable_weight = sum(selector.weight for selector in packable)
    dominant = [
        selector
        for selector in packable
        if selector.weight * provisional_batch_count > total_packable_weight
    ]
    dominant_identifiers = {selector.identifier for selector in dominant}
    isolated = [*resource_isolated, *dominant]
    shared = [
        selector
        for selector in packable
        if selector.identifier not in dominant_identifiers
    ]
    shared_batch_count = required_batch_count(shared)

    batches: list[list[TestSelector]] = [
        *([selector] for selector in isolated),
        *([] for _ in range(shared_batch_count)),
    ]
    first_shared_index = len(isolated)
    batch_remaining_tests = [0 for _ in isolated] + [
        maximum_tests for _ in range(shared_batch_count)
    ]
    eligible_batches = [(0, index) for index in range(first_shared_index, len(batches))]
    heapq.heapify(eligible_batches)
    parked_batches: list[tuple[int, int, int]] = []
    ordered = sorted(
        shared,
        key=lambda selector: (
            -selector.test_count,
            -selector.weight,
            hashlib.sha256(selector.identifier.encode("utf-8")).hexdigest(),
            selector.identifier,
        ),
    )
    for selector in ordered:
        while parked_batches and -parked_batches[0][0] >= selector.test_count:
            _, batch_weight, batch_index = heapq.heappop(parked_batches)
            heapq.heappush(eligible_batches, (batch_weight, batch_index))

        if not eligible_batches:
            batch_index = len(batches)
            batches.append([])
            batch_remaining_tests.append(maximum_tests)
            heapq.heappush(eligible_batches, (0, batch_index))

        batch_weight, batch_index = heapq.heappop(eligible_batches)
        batches[batch_index].append(selector)
        batch_weight += selector.weight
        batch_remaining_tests[batch_index] -= selector.test_count
        if (
            len(batches[batch_index]) < maximum_selectors
            and batch_remaining_tests[batch_index] > 0
        ):
            if batch_remaining_tests[batch_index] >= selector.test_count:
                heapq.heappush(eligible_batches, (batch_weight, batch_index))
            else:
                heapq.heappush(
                    parked_batches,
                    (-batch_remaining_tests[batch_index], batch_weight, batch_index),
                )

    return [
        sorted(batch, key=lambda selector: selector.identifier) for batch in batches
    ]


def write_output(path: Path, selectors: list[TestSelector]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "".join(f"-only-testing:{selector.identifier}\n" for selector in selectors),
        encoding="utf-8",
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--shard-index", type=int)
    parser.add_argument("--shard-total", type=int)
    parser.add_argument("--output", type=Path)
    parser.add_argument(
        "--batch-size",
        "--batch-selector-limit",
        dest="batch_selector_limit",
        type=int,
    )
    parser.add_argument("--batch-test-limit", type=int)
    parser.add_argument("--batch-output-directory", type=Path)
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--validate", action="store_true")
    parser.add_argument("--timings", type=Path, default=DEFAULT_TIMINGS_PATH)
    args = parser.parse_args()

    selectors = discover_selectors(args.root)
    timings = load_timings(args.timings)
    selectors, measured = reweight_selectors(selectors, timings)

    if args.validate:
        suite_selectors = sum(1 for selector in selectors if selector.identifier.count("/") == 1)
        method_selectors = len(selectors) - suite_selectors
        represented_tests = sum(selector.test_count for selector in selectors)
        source = args.timings if timings else "none (count-based fallback)"
        print(
            f"Discovered {len(selectors)} cmuxTests selectors "
            f"({suite_selectors} suites, {method_selectors} methods) "
            f"representing {represented_tests} tests; "
            f"timings: {source}, {measured}/{len(selectors)} measured"
        )
        return 0

    if args.list:
        for selector in selectors:
            print(f"{selector.identifier}\t{selector.weight}\t{selector.path}:{selector.line}")
        return 0

    if args.shard_index is None or args.shard_total is None:
        parser.error("--shard-index and --shard-total are required unless --list or --validate is used")
    if args.output is not None and args.batch_output_directory is not None:
        parser.error("--output and --batch-output-directory are mutually exclusive")
    if args.batch_output_directory is None and args.output is None:
        parser.error("--output or --batch-output-directory is required")
    if args.batch_output_directory is not None and (
        args.batch_selector_limit is None or args.batch_test_limit is None
    ):
        parser.error(
            "--batch-selector-limit and --batch-test-limit are required with "
            "--batch-output-directory"
        )
    if args.batch_output_directory is None and (
        args.batch_selector_limit is not None or args.batch_test_limit is not None
    ):
        parser.error(
            "--batch-selector-limit and --batch-test-limit require "
            "--batch-output-directory"
        )

    selected = shard_selectors(selectors, args.shard_index, args.shard_total)
    if not selected:
        raise SystemExit(f"Shard {args.shard_index}/{args.shard_total} is empty")

    total_weight = sum(selector.weight for selector in selected)
    total_tests = sum(selector.test_count for selector in selected)
    if args.batch_output_directory is not None:
        batches = process_batches(
            selected,
            args.batch_selector_limit,
            args.batch_test_limit,
        )
        args.batch_output_directory.mkdir(parents=True, exist_ok=True)
        existing_batch = next(args.batch_output_directory.glob("batch-*.args"), None)
        if existing_batch is not None:
            raise SystemExit(
                "Batch output directory already contains process batches: "
                f"{existing_batch}"
            )
        for batch_index, batch in enumerate(batches, start=1):
            batch_path = args.batch_output_directory / f"batch-{batch_index:03d}.args"
            write_output(batch_path, batch)
            batch_weight = sum(selector.weight for selector in batch)
            batch_tests = sum(selector.test_count for selector in batch)
            print(
                f"  Batch {batch_index}/{len(batches)}: {len(batch)} selectors / "
                f"{batch_tests} tests, "
                f"est {batch_weight / 60000:.1f} min serial, args {batch_path}"
            )
        print(
            f"Shard {args.shard_index}/{args.shard_total}: "
            f"{len(selected)} selectors / {total_tests} tests in "
            f"{len(batches)} process batches, "
            f"est {total_weight / 60000:.1f} min serial"
        )
        return 0

    write_output(args.output, selected)
    print(
        f"Shard {args.shard_index}/{args.shard_total}: "
        f"{len(selected)} selectors / {total_tests} tests, "
        f"est {total_weight / 60000:.1f} min serial, args {args.output}"
    )
    for selector in selected:
        print(f"  {selector.identifier} ({selector.weight}) {selector.path}:{selector.line}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
