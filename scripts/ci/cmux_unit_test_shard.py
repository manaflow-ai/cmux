#!/usr/bin/env python3
"""Generate deterministic -only-testing arguments for cmuxTests shards.

Shards are packed greedily by weight. Weights are measured milliseconds from
scripts/ci/cmux-unit-test-timings.json when present (regenerate it with
scripts/ci/generate_test_timings.py from a green main run's shard logs).
Suites and methods missing from the manifest fall back to a per-test estimate,
so new or renamed tests never break sharding — they just pack less precisely
until the manifest is refreshed.
"""

from __future__ import annotations

import argparse
import hashlib
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
FOCUSED_GATE_SELECTORS = {
    "cmuxTests/BrowserSystemProxyMirrorTests",
    "cmuxTests/CLISSHSessionAttachAnchorTests",
    "cmuxTests/GhosttyOptionAsAltModsTests",
    "cmuxTests/RemoteTmuxMirrorLayoutIdentityTests",
}
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
        source = args.timings if timings else "none (count-based fallback)"
        print(
            f"Discovered {len(selectors)} cmuxTests selectors "
            f"({suite_selectors} suites, {method_selectors} methods); "
            f"timings: {source}, {measured}/{len(selectors)} measured"
        )
        return 0

    if args.list:
        for selector in selectors:
            print(f"{selector.identifier}\t{selector.weight}\t{selector.path}:{selector.line}")
        return 0

    if args.shard_index is None or args.shard_total is None or args.output is None:
        parser.error("--shard-index, --shard-total, and --output are required unless --list or --validate is used")

    selected = shard_selectors(selectors, args.shard_index, args.shard_total)
    if not selected:
        raise SystemExit(f"Shard {args.shard_index}/{args.shard_total} is empty")

    write_output(args.output, selected)
    total_weight = sum(selector.weight for selector in selected)
    print(
        f"Shard {args.shard_index}/{args.shard_total}: "
        f"{len(selected)} selectors, est {total_weight / 60000:.1f} min serial, args {args.output}"
    )
    for selector in selected:
        print(f"  {selector.identifier} ({selector.weight}) {selector.path}:{selector.line}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
