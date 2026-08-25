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
    r"(?:class|struct|actor|enum)\s+([A-Za-z_][A-Za-z0-9_]*)\b"
)
EXTENSION_RE = re.compile(r"^extension\s+([A-Za-z_][A-Za-z0-9_]*)\b")
TYPE_DECLARATION_RE = re.compile(
    r"^\s*(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?\s+)*"
    r"(?:(?:final|private|fileprivate|internal|public)\s+)*"
    r"(?:class|struct|actor|enum)\s+([A-Za-z_][A-Za-z0-9_]*)\b"
)
SWIFT_TEST_ATTRIBUTE_RE = re.compile(r"(?<![A-Za-z0-9_])@Test\b")
SWIFT_SUITE_ATTRIBUTE_RE = re.compile(r"(?<![A-Za-z0-9_])@Suite\b")
FUNCTION_DECLARATION_RE = re.compile(r"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\b")
XCTEST_METHOD_RE = re.compile(
    r"^\s*(?:(?:final|private|fileprivate|internal|public)\s+)*"
    r"func\s+(test[A-Za-z0-9_]*)\s*\("
)
LARGE_SUITE_METHOD_THRESHOLD = 40
TEST_SUITE_SUFFIXES = ("Tests", "UITests", "Suites")
DEFAULT_TIMINGS_PATH = Path(__file__).resolve().parent / "cmux-unit-test-timings.json"
FALLBACK_TEST_MS = 200
# Stay below AppKit's observed 100-live-window warning even if CI overrides the
# workflow default; known multi-window lifecycle suites are isolated below.
MAX_PROCESS_TEST_LIMIT = 80
FOCUSED_GATE_SELECTORS = {
    "cmuxTests/BrowserSystemProxyMirrorTests",
    "cmuxTests/CLISSHSessionAttachAnchorTests",
    "cmuxTests/GhosttyTerminalViewVisibilityPolicyTests",
    "cmuxTests/GhosttyOptionAsAltModsTests",
    "cmuxTests/RemoteTmuxMirrorLayoutIdentityTests",
    "cmuxTests/SidebarWorkspaceSwitchLayoutFaultTests",
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
    # None means Swift Testing expands this selector from a runtime expression.
    # Bounded process-batch generation rejects such selectors because their
    # represented work cannot be proven to fit the hard app-host lifetime cap.
    test_count: int | None


@dataclass(frozen=True)
class SuiteFragment:
    path: str
    line: int
    methods: tuple[TestSelector, ...]
    all_methods: tuple[TestSelector, ...]
    contains_nested_suites: bool


@dataclass(frozen=True)
class SuiteDeclaration:
    name: str
    fragment: SuiteFragment


def exact_test_count(selectors: list[TestSelector]) -> int | None:
    """Return a complete execution count, or None if any expansion is runtime-only."""
    counts = [selector.test_count for selector in selectors]
    if any(count is None for count in counts):
        return None
    return max(1, sum(count for count in counts if count is not None))


def mask_swift_noncode(source: str) -> str:
    """Mask comments and string contents while preserving offsets and syntax."""
    masked = ["\n" if character == "\n" else " " for character in source]
    index = 0
    length = len(source)
    while index < length:
        if source.startswith("//", index):
            newline = source.find("\n", index + 2)
            index = length if newline < 0 else newline
            continue

        if source.startswith("/*", index):
            depth = 1
            index += 2
            while index < length and depth:
                if source.startswith("/*", index):
                    depth += 1
                    index += 2
                elif source.startswith("*/", index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
            continue

        raw_hashes = 0
        quote_index = index
        if source[index] == "#":
            while quote_index < length and source[quote_index] == "#":
                raw_hashes += 1
                quote_index += 1
            if quote_index >= length or source[quote_index] != '"':
                masked[index] = source[index]
                index += 1
                continue
        elif source[index] != '"':
            masked[index] = source[index]
            index += 1
            continue

        triple_quoted = source.startswith('"""', quote_index)
        opening_length = 3 if triple_quoted else 1
        closing = ('"""' if triple_quoted else '"') + ("#" * raw_hashes)
        masked[index] = '"'
        index = quote_index + opening_length
        while index < length:
            if source.startswith(closing, index):
                index += len(closing)
                break
            if raw_hashes == 0 and source[index] == "\\":
                index = min(length, index + 2)
                continue
            index += 1

    return "".join(masked)


def matching_delimiter(source: str, start: int, opening: str, closing: str) -> int | None:
    """Return the matching delimiter offset in already-masked Swift source."""
    depth = 0
    for index in range(start, len(source)):
        character = source[index]
        if character == opening:
            depth += 1
        elif character == closing:
            depth -= 1
            if depth == 0:
                return index
    return None


def array_literal_count(source: str, start: int) -> tuple[int, int] | None:
    """Count top-level elements in a masked Swift array literal."""
    closing = matching_delimiter(source, start, "[", "]")
    if closing is None:
        return None

    stack: list[str] = []
    pairs = {")": "(", "]": "[", "}": "{"}
    segment_has_code = False
    count = 0
    for character in source[start + 1 : closing]:
        if character in "([{":
            stack.append(character)
            segment_has_code = True
        elif character in ")]}" and stack and stack[-1] == pairs[character]:
            stack.pop()
            segment_has_code = True
        elif character == "," and not stack:
            if segment_has_code:
                count += 1
                segment_has_code = False
        elif not character.isspace():
            segment_has_code = True
    if segment_has_code:
        count += 1
    return count, closing + 1


def member_collection_counts(source: str) -> dict[str, int]:
    """Return exact counts for declaration-level constant array literals."""
    declaration = re.compile(
        r"(?m)^[ \t]{0,4}"
        r"(?:(?:private|fileprivate|internal|public|package|static|class|final)\s+)*"
        r"let\s+([A-Za-z_][A-Za-z0-9_]*)"
        r"(?:\s*:[^=\n]+)?\s*=\s*\["
    )
    counts: dict[str, int] = {}
    for match in declaration.finditer(source):
        result = array_literal_count(source, match.end() - 1)
        if result is not None:
            counts[match.group(1)] = result[0]
    return counts


def top_level_slices(source: str, start: int, end: int) -> list[tuple[int, int]]:
    """Split a masked expression range at top-level commas."""
    slices: list[tuple[int, int]] = []
    stack: list[str] = []
    pairs = {")": "(", "]": "[", "}": "{"}
    item_start = start
    for index in range(start, end):
        character = source[index]
        if character in "([{":
            stack.append(character)
        elif character in ")]}" and stack and stack[-1] == pairs[character]:
            stack.pop()
        elif character == "," and not stack:
            slices.append((item_start, index))
            item_start = index + 1
    slices.append((item_start, end))
    return slices


def collection_expression_count(
    source: str, start: int, end: int, named_counts: dict[str, int]
) -> tuple[int, int] | None:
    """Count a provably finite collection expression used by @Test."""
    while start < end and source[start].isspace():
        start += 1
    if start >= end:
        return None

    if source[start] == "[":
        return array_literal_count(source[:end], start)

    zip_match = re.match(r"zip\s*\(", source[start:end])
    if zip_match:
        opening = start + zip_match.end() - 1
        closing = matching_delimiter(source[:end], opening, "(", ")")
        if closing is None:
            return None
        arguments = top_level_slices(source, opening + 1, closing)
        if len(arguments) != 2:
            return None
        counts: list[int] = []
        for argument_start, argument_end in arguments:
            result = collection_expression_count(
                source, argument_start, argument_end, named_counts
            )
            if result is None or source[result[1] : argument_end].strip():
                return None
            counts.append(result[0])
        return min(counts), closing + 1

    identifier_match = re.match(
        r"(?:Self\s*\.\s*)?([A-Za-z_][A-Za-z0-9_]*)\b",
        source[start:end],
    )
    if identifier_match and identifier_match.group(1) in named_counts:
        return named_counts[identifier_match.group(1)], start + identifier_match.end()
    return None


def has_only_optional_type_cast(source: str) -> bool:
    """Return whether an expression suffix is empty or a simple `as Type` cast."""
    suffix = source.strip()
    if not suffix:
        return True
    return re.fullmatch(r"as\s+[A-Za-z0-9_?.<>, ()\[\]:]+", suffix) is not None


def argument_collections_count(
    source: str, start: int, end: int, named_counts: dict[str, int]
) -> int | None:
    """Count the Cartesian product of statically known @Test collections."""
    collection_ranges = top_level_slices(source, start, end)
    if not collection_ranges:
        return None

    case_count = 1
    for collection_start, collection_end in collection_ranges:
        result = collection_expression_count(
            source, collection_start, collection_end, named_counts
        )
        if result is None or not has_only_optional_type_cast(
            source[result[1] : collection_end]
        ):
            return None
        case_count *= result[0]
    return max(1, case_count)


def swift_test_case_count(
    source: str, attribute_start: int, named_counts: dict[str, int]
) -> int | None:
    """Return an exact @Test case count, or None for runtime expansion."""
    position = attribute_start + len("@Test")
    while position < len(source) and source[position].isspace():
        position += 1
    if position >= len(source) or source[position] != "(":
        return 1

    closing = matching_delimiter(source, position, "(", ")")
    if closing is None:
        return None
    contents_start = position + 1
    contents = source[contents_start:closing]
    arguments_match = re.search(r"\barguments\s*:", contents)
    if arguments_match is None:
        return 1

    expression_start = contents_start + arguments_match.end()
    return argument_collections_count(
        source, expression_start, closing, named_counts
    )


def test_methods(
    suite_identifier: str,
    relative_path: str,
    start_line: int,
    body: str,
    *,
    direct_only: bool,
) -> list[TestSelector]:
    """Return XCTest and Swift Testing methods from one suite fragment."""
    methods: list[TestSelector] = []
    source = body
    masked_source = mask_swift_noncode(source)
    body_lines = source.split("\n")
    masked_lines = masked_source.split("\n")
    named_counts = member_collection_counts(masked_source)
    pending_swift_test = False
    pending_test_count: int | None = 1
    pending_line = 0
    absolute_offset = 0
    for offset, (body_line, masked_line) in enumerate(zip(body_lines, masked_lines)):
        indentation = len(body_line) - len(body_line.lstrip(" \t"))
        if direct_only and indentation > 4:
            absolute_offset += len(body_line) + 1
            continue

        attribute_match = SWIFT_TEST_ATTRIBUTE_RE.search(masked_line)
        if attribute_match:
            pending_swift_test = True
            pending_test_count = swift_test_case_count(
                masked_source,
                absolute_offset + attribute_match.start(),
                named_counts,
            )
            pending_line = start_line + offset

        swift_test_match = (
            FUNCTION_DECLARATION_RE.search(masked_line)
            if pending_swift_test
            else None
        )
        xctest_match = XCTEST_METHOD_RE.match(masked_line)
        method_match = swift_test_match or xctest_match
        if method_match is None:
            absolute_offset += len(body_line) + 1
            continue

        methods.append(
            TestSelector(
                identifier=f"{suite_identifier}/{method_match.group(1)}",
                path=relative_path,
                line=start_line + offset,
                weight=1,
                test_count=pending_test_count if swift_test_match else 1,
            )
        )
        pending_swift_test = False
        pending_test_count = 1
        absolute_offset += len(body_line) + 1

    if pending_swift_test:
        raise SystemExit(
            f"Could not find function declaration for @Test at "
            f"{relative_path}:{pending_line}"
        )
    return methods


def contains_nested_test_suite(body: str) -> bool:
    """Return whether a suite fragment declares a recursively selected suite."""
    masked_body = mask_swift_noncode(body)
    first_line = masked_body.split("\n", 1)[0]
    owner = TYPE_DECLARATION_RE.match(first_line) or EXTENSION_RE.match(first_line)
    if owner is None:
        return False
    opening = masked_body.find("{", owner.end())
    if opening < 0:
        return False
    closing = matching_delimiter(masked_body, opening, "{", "}")
    if closing is None:
        return False

    depth = 0
    pending_suite_attribute_depth: int | None = None
    for line in masked_body[opening + 1 : closing].split("\n"):
        declaration = TYPE_DECLARATION_RE.match(line)
        has_suite_attribute = SWIFT_SUITE_ATTRIBUTE_RE.search(line) is not None
        if declaration is not None:
            if (
                declaration.group(1).endswith(TEST_SUITE_SUFFIXES)
                or has_suite_attribute
                or pending_suite_attribute_depth == depth
            ):
                return True
            pending_suite_attribute_depth = None
        elif has_suite_attribute:
            pending_suite_attribute_depth = depth

        depth += line.count("{") - line.count("}")
    return False


def discover_selectors(root: Path) -> list[TestSelector]:
    test_root = root / "cmuxTests"
    if not test_root.is_dir():
        raise SystemExit(f"cmuxTests directory not found under {root}")

    declarations: list[SuiteDeclaration] = []
    extension_fragments: dict[str, list[SuiteFragment]] = {}
    for path in sorted(test_root.glob("**/*.swift")):
        relative = path.relative_to(root).as_posix()
        lines = path.read_text(encoding="utf-8").splitlines()
        top_level_declarations: list[tuple[int, str, str]] = []
        for index, line in enumerate(lines, start=1):
            match = SUITE_RE.match(line)
            if match:
                name = match.group(1)
                if name.endswith(TEST_SUITE_SUFFIXES):
                    top_level_declarations.append((index, "suite", name))
                continue

            match = EXTENSION_RE.match(line)
            if match:
                name = match.group(1)
                if name.endswith(TEST_SUITE_SUFFIXES):
                    top_level_declarations.append((index, "extension", name))

        for position, (line_number, kind, name) in enumerate(top_level_declarations):
            next_line = (
                top_level_declarations[position + 1][0]
                if position + 1 < len(top_level_declarations)
                else len(lines) + 1
            )
            body = "\n".join(lines[line_number - 1 : next_line - 1])
            suite_identifier = f"cmuxTests/{name}"
            methods = test_methods(
                suite_identifier,
                relative,
                line_number,
                body,
                direct_only=True,
            )
            nested_suites = contains_nested_test_suite(body)
            all_methods = (
                test_methods(
                    suite_identifier,
                    relative,
                    line_number,
                    body,
                    direct_only=False,
                )
                if nested_suites
                else methods
            )
            fragment = SuiteFragment(
                path=relative,
                line=line_number,
                methods=tuple(methods),
                all_methods=tuple(all_methods),
                contains_nested_suites=nested_suites,
            )
            if kind == "extension":
                extension_fragments.setdefault(name, []).append(fragment)
                continue

            declarations.append(
                SuiteDeclaration(
                    name=name,
                    fragment=fragment,
                )
            )

    selectors: list[TestSelector] = []
    declared_suite_names = {declaration.name for declaration in declarations}
    for extension_name in sorted(set(extension_fragments) - declared_suite_names):
        locations = ", ".join(
            f"{fragment.path}:{fragment.line}"
            for fragment in extension_fragments[extension_name]
        )
        print(
            f"Extension declares tests for unknown suite cmuxTests/{extension_name}: {locations}",
            file=sys.stderr,
        )
        raise SystemExit(1)

    for declaration in declarations:
        suite_identifier = f"cmuxTests/{declaration.name}"
        fragments = [
            declaration.fragment,
            *extension_fragments.get(declaration.name, []),
        ]
        has_nested_suites = any(
            fragment.contains_nested_suites for fragment in fragments
        )
        methods = [
            method
            for fragment in fragments
            for method in (
                fragment.all_methods if has_nested_suites else fragment.methods
            )
        ]
        test_count = exact_test_count(methods)

        if suite_identifier in FOCUSED_GATE_SELECTORS:
            continue

        # Selecting an umbrella suite recursively selects its nested suites and
        # preserves suite-level traits such as `.serialized`. Never rewrite its
        # descendants as methods on the outer type: those selectors do not
        # exist and silently skip tests. The exact descendant count still
        # participates in the process limit below.
        if has_nested_suites:
            selectors.append(
                TestSelector(
                    identifier=suite_identifier,
                    path=declaration.fragment.path,
                    line=declaration.fragment.line,
                    weight=(
                        test_count
                        if test_count is not None
                        else max(1, len(methods))
                    ),
                    test_count=test_count,
                )
            )
            continue

        # Very large suites dominate a shard when selected as a whole. Split by
        # method when either declared methods or expanded cases cross the
        # threshold. Runtime-expanded parameter collections also split so
        # bounded batching can reject the precise selector instead of treating
        # the entire suite as uncountable.
        if (
            len(methods) >= LARGE_SUITE_METHOD_THRESHOLD
            or test_count is None
            or test_count >= LARGE_SUITE_METHOD_THRESHOLD
        ):
            selectors.extend(methods)
            continue

        selectors.append(
            TestSelector(
                identifier=suite_identifier,
                path=declaration.fragment.path,
                line=declaration.fragment.line,
                weight=test_count,
                test_count=test_count,
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
        fallback_count = (
            selector.test_count
            if selector.test_count is not None
            else MAX_PROCESS_TEST_LIMIT
        )
        if len(parts) == 3:
            _, suite, method = parts
            ms = methods.get(f"{suite}/{method}")
            if ms is None and suite in suites:
                ms = suites[suite] / methods_per_suite[suite]
        else:
            suite = parts[1]
            ms = suites.get(suite)
        if ms is None:
            ms = fallback_count * fallback_ms
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

    runtime_expanded = [
        selector for selector in selectors if selector.test_count is None
    ]
    if runtime_expanded:
        selector = min(runtime_expanded, key=lambda item: item.identifier)
        raise SystemExit(
            f"Selector {selector.identifier} has a runtime-expanded test count; "
            f"--batch-test-limit {maximum_tests} requires a statically countable "
            "@Test(arguments:) collection"
        )

    oversized = [
        selector
        for selector in selectors
        if selector.test_count is not None and selector.test_count > maximum_tests
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
            (
                sum(
                    selector.test_count
                    for selector in items
                    if selector.test_count is not None
                )
                + maximum_tests
                - 1
            )
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
            -(selector.test_count or 0),
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
        selector_test_count = selector.test_count or 0
        batch_remaining_tests[batch_index] -= selector_test_count
        if (
            len(batches[batch_index]) < maximum_selectors
            and batch_remaining_tests[batch_index] > 0
        ):
            if batch_remaining_tests[batch_index] >= selector_test_count:
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


def represented_test_summary(selectors: list[TestSelector]) -> str:
    """Describe known executions and any runtime-expanded selectors."""
    known_tests = sum(
        selector.test_count
        for selector in selectors
        if selector.test_count is not None
    )
    runtime_expanded = sum(
        1 for selector in selectors if selector.test_count is None
    )
    if runtime_expanded:
        return (
            f"{known_tests} known tests plus {runtime_expanded} "
            "runtime-expanded selectors with unknown case counts"
        )
    return f"{known_tests} tests"


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
        represented_tests = represented_test_summary(selectors)
        source = args.timings if timings else "none (count-based fallback)"
        print(
            f"Discovered {len(selectors)} cmuxTests selectors "
            f"({suite_selectors} suites, {method_selectors} methods) "
            f"representing {represented_tests}; "
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
    total_tests = represented_test_summary(selected)
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
            batch_tests = represented_test_summary(batch)
            print(
                f"  Batch {batch_index}/{len(batches)}: {len(batch)} selectors / "
                f"{batch_tests}, "
                f"est {batch_weight / 60000:.1f} min serial, args {batch_path}"
            )
        print(
            f"Shard {args.shard_index}/{args.shard_total}: "
            f"{len(selected)} selectors / {total_tests} in "
            f"{len(batches)} process batches, "
            f"est {total_weight / 60000:.1f} min serial"
        )
        return 0

    write_output(args.output, selected)
    print(
        f"Shard {args.shard_index}/{args.shard_total}: "
        f"{len(selected)} selectors / {total_tests}, "
        f"est {total_weight / 60000:.1f} min serial, args {args.output}"
    )
    for selector in selected:
        print(f"  {selector.identifier} ({selector.weight}) {selector.path}:{selector.line}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
