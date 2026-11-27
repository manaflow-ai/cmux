#!/usr/bin/env python3
"""Keep a focused `-only-testing:` selector from silently matching nothing.

A Swift Testing method is named with its call suffix: `Suite/method()`, or
`Suite/method(label:)` when it is parameterized. `Suite/method` without the
suffix matches no test, and xcodebuild then reports zero executed tests and
exits 0. XCTest accepts either spelling, and the built inventory spells XCTest
methods with `()` too, so appending the suffix the inventory records is always
safe.

Three uses share one resolver:

- `resolve` rewrites selectors against the built test inventory (the same
  enumeration `app_host_result_accounting.py inventory` writes), before any
  test runs.
- `check-executed` is the backstop after the run: every selector must have
  produced at least one typed xcresult Test Case, or the run fails naming it.
- `dispatch-focused-test.py` imports `source_inventory` to catch the mistake
  before it spends a compile, from the Swift source of the named suite.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import re
import sys
from pathlib import Path
from typing import Iterable

HERE = Path(__file__).resolve().parent


def _load(name: str, path: Path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    # Dataclasses resolve their module through sys.modules while executing.
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


accounting = _load("app_host_result_accounting", HERE / "app_host_result_accounting.py")
shard = _load("cmux_unit_test_shard", HERE / "cmux_unit_test_shard.py")
source_mask = _load("swift_source_mask", HERE.parent / "swift_source_mask.py")

TARGETS = ("cmuxTests/", "cmuxUITests/")
CALL_SUFFIX_RE = re.compile(r"\([^()]*\)$")
FUNC_RE = re.compile(r"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(")
TEST_ATTRIBUTE_RE = re.compile(r"@Test\b")


class SelectorError(ValueError):
    """A selector that cannot be run as written and cannot be repaired."""


class AmbiguousSelector(SelectorError):
    """A method name several declarations share, with different suffixes."""


class UnknownSelector(SelectorError):
    """A selector that names nothing in the inventory."""


def split_target(selector: str) -> tuple[str, str]:
    """Split `cmuxTests/Suite/method` into its target prefix and test path."""
    selector = selector.strip()
    for target in TARGETS:
        if selector.startswith(target):
            return target, selector[len(target):]
    return "", selector


def bare_name(piece: str) -> str:
    """`method(label:)` -> `method`."""
    return CALL_SUFFIX_RE.sub("", piece)


def resolve_selector(inventory: set[str], selector: str) -> tuple[str, str | None]:
    """Return the selector to pass to xcodebuild and a note when it changed.

    Raises SelectorError when the selector names nothing in the inventory, or
    names a method whose call suffix cannot be chosen without guessing.
    """
    prefix, path = split_target(selector)
    identifier = accounting.canonical_identifier(path)
    if identifier in inventory:
        return selector, None
    if any(test.startswith(identifier + "/") for test in inventory):
        return selector, None

    parent, _, leaf = identifier.rpartition("/")
    candidates = sorted(
        test for test in inventory
        if test.rpartition("/")[0] == parent
        and bare_name(test.rpartition("/")[2]) == bare_name(leaf)
    ) if parent else []
    if len(candidates) == 1:
        resolved = prefix + candidates[0]
        return resolved, (
            f"{selector} names no test exactly; running {resolved}, the name "
            "the test inventory records. A Swift Testing method matches only "
            "with its call suffix: Suite/method() or Suite/method(label:)."
        )
    if candidates:
        raise AmbiguousSelector(
            f"{selector} is ambiguous; name one of: "
            + ", ".join(prefix + candidate for candidate in candidates)
        )
    raise UnknownSelector(
        f"{selector} matches no built test. Name a suite (Suite), an XCTest "
        "method (Suite/testName), or a Swift Testing method with its call "
        "suffix (Suite/method() or Suite/method(label:))."
    )


def resolve_selectors(
    inventory: set[str], selectors: Iterable[str]
) -> tuple[list[str], list[str], list[str]]:
    """Resolve every selector, collecting all errors rather than the first."""
    resolved: list[str] = []
    notices: list[str] = []
    errors: list[str] = []
    for selector in selectors:
        try:
            value, notice = resolve_selector(inventory, selector)
        except SelectorError as error:
            errors.append(str(error))
            continue
        resolved.append(value)
        if notice:
            notices.append(notice)
    return resolved, notices, errors


def executed_counts(executed: set[str], selectors: Iterable[str]) -> dict[str, int]:
    """How many executed Test Cases each selector accounts for."""
    # Results may or may not carry the target; selectors are compared without.
    index = accounting.inventory_selector_index(
        {split_target(identifier)[1] for identifier in executed}
    )
    counts: dict[str, int] = {}
    for selector in selectors:
        _, path = split_target(selector)
        key = accounting.comparable_identifier(accounting.canonical_identifier(path))
        counts[selector] = len(index.get(key, set()))
    return counts


def _balanced(text: str, start: int) -> int:
    """Index just past the `)` that closes the `(` at `start`."""
    depth = 0
    for index in range(start, len(text)):
        if text[index] == "(":
            depth += 1
        elif text[index] == ")":
            depth -= 1
            if depth == 0:
                return index + 1
    return len(text)


def _labels(parameters: str) -> str:
    """Swift argument labels for a parameter clause, e.g. `a:_:`."""
    parameters = parameters.replace("->", "  ")
    pieces: list[str] = []
    depth = 0
    current = ""
    for char in parameters:
        if char in "([<":
            depth += 1
        elif char in ")]>":
            depth -= 1
        if char == "," and depth == 0:
            pieces.append(current)
            current = ""
        else:
            current += char
    pieces.append(current)
    labels = []
    for piece in pieces:
        head = piece.split(":", 1)[0].split()
        if head:
            labels.append(head[0] + ":")
    return "".join(labels)


def source_inventory(root: Path, suite: str) -> set[str]:
    """Test identifiers the Swift source declares for one top-level suite.

    This reads the same top-level declarations the unit-test sharder does, so
    it sees a suite and its extensions. It is a local, pre-build hint: the
    built inventory the workflow enumerates stays the authority.
    """
    tests: set[str] = set()
    test_root = root / "cmuxTests"
    if not test_root.is_dir():
        return tests
    declaration = re.compile(
        r"^(?:[^\n]*\s)?(?:class|struct|actor|enum|extension)\s+"
        + re.escape(suite) + r"\b",
        re.MULTILINE,
    )
    for path in sorted(test_root.glob("**/*.swift")):
        try:
            source = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        if not declaration.search(source):
            continue
        masked = source_mask.mask_swift_source(source)
        lines = masked.splitlines(keepends=True)
        offsets = [0]
        for line in lines:
            offsets.append(offsets[-1] + len(line))
        tops = []
        for number, line in enumerate(lines):
            match = shard.SUITE_RE.match(line) or shard.EXTENSION_RE.match(line)
            if match:
                tops.append((offsets[number], match.group(1)))
        for position, (start, name) in enumerate(tops):
            if name != suite:
                continue
            end = tops[position + 1][0] if position + 1 < len(tops) else len(masked)
            body = masked[start:end]
            for function in FUNC_RE.finditer(body):
                open_paren = function.end() - 1
                close = _balanced(body, open_paren)
                parameters = body[open_paren + 1:close - 1]
                boundary = max(body.rfind("{", 0, function.start()),
                               body.rfind("}", 0, function.start()))
                attributes = body[boundary + 1:function.start()]
                method = function.group(1)
                labels = _labels(parameters)
                if TEST_ATTRIBUTE_RE.search(attributes):
                    tests.add(f"{suite}/{method}({labels})")
                elif method.startswith("test") and not labels:
                    tests.add(f"{suite}/{method}()")
    return tests


def _split_csv(value: str) -> list[str]:
    return [entry.strip() for entry in value.split(",") if entry.strip()]


def _typed_results(paths: Iterable[str]) -> tuple[set[str], list[str]]:
    executed: set[str] = set()
    unusable: list[str] = []
    for raw in paths:
        path = Path(raw)
        try:
            results = accounting.parse_xcresult_tests(accounting.load_json(path))
        except (OSError, ValueError):
            unusable.append(str(path))
            continue
        executed.update(results)
    return executed, unusable


def command_resolve(args: argparse.Namespace) -> int:
    inventory = accounting.load_inventory(args.inventory)
    resolved, notices, errors = resolve_selectors(inventory, _split_csv(args.selectors))
    for notice in notices:
        print(f"::notice::{notice}", file=sys.stderr)
    for error in errors:
        print(f"::error::{error}", file=sys.stderr)
    if errors or not resolved:
        return 1
    print(",".join(resolved))
    return 0


def command_check_executed(args: argparse.Namespace) -> int:
    selectors = _split_csv(args.selectors)
    executed, unusable = _typed_results(args.tests_json)
    for path in unusable:
        print(f"::warning::unreadable typed xcresult JSON: {path}", file=sys.stderr)
    if not executed and len(unusable) == len(args.tests_json):
        print(
            "::warning::no typed xcresult test results; only the aggregate "
            "executed-count guard applies to this run",
            file=sys.stderr,
        )
        return 3
    failed = False
    for selector, count in executed_counts(executed, selectors).items():
        if count:
            print(f"{selector}: {count} test(s) executed")
            continue
        failed = True
        print(
            f"::error::{selector} executed zero tests. A Swift Testing method "
            "needs its call suffix (Suite/method() or Suite/method(label:)); "
            "otherwise check the suite and method names.",
            file=sys.stderr,
        )
    return 1 if failed else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    resolve = commands.add_parser("resolve")
    resolve.add_argument("--inventory", type=Path, required=True)
    resolve.add_argument("--selectors", required=True, help="comma-separated")
    check = commands.add_parser("check-executed")
    check.add_argument("--selectors", required=True, help="comma-separated")
    check.add_argument("--tests-json", nargs="+", required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "resolve":
            return command_resolve(args)
        return command_check_executed(args)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"::error::{error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
