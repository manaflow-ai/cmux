#!/usr/bin/env python3
"""Typed app-host test inventory and known-main failure accounting."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any, Iterable

ALLOWED_CLASSIFICATIONS = {
    "product bug",
    "stale test",
    "test bug",
    "host/display dependency",
    "timeout/hang",
    "crash",
    "unknown",
}

RESULT_PRIORITY = {
    "Failed": 5,
    "unknown": 4,
    "Skipped": 3,
    "Expected Failure": 2,
    "Passed": 1,
}

RESTART_MARKER = "Restarting after unexpected exit, crash, or test timeout"
OUTER_TIMEOUT_RE = re.compile(r"xcodebuild unit-test batch .* timeout after")
IDLE_TIMEOUT_RE = re.compile(r"Idle timed out after .*no test progress", re.IGNORECASE)


def canonical_identifier(value: str) -> str:
    """Normalize Xcode/Test Case identifiers into the receipt namespace."""
    value = value.strip()
    if value.startswith("test://"):
        pieces = [piece for piece in value.split("/") if piece]
        if "cmuxTests" in pieces:
            value = "/".join(pieces[pieces.index("cmuxTests") + 1 :])
        elif len(pieces) >= 2:
            value = "/".join(pieces[-2:])
    if value.startswith("cmuxTests/"):
        value = value[len("cmuxTests/") :]
    if value.startswith("cmuxTests."):
        value = value[len("cmuxTests.") :]
    return value.strip("/")


def comparable_identifier(value: str) -> str:
    """Normalize optional XCTest call suffixes for selector comparison."""
    value = canonical_identifier(value)
    return value[:-2] if value.endswith("()") else value


def selector_value(raw: str) -> str:
    """Normalize an xcodebuild only-testing selector."""
    raw = raw.strip()
    if raw.startswith("-only-testing:"):
        raw = raw[len("-only-testing:") :]
    return canonical_identifier(raw)


def _children(node: dict[str, Any]) -> list[Any]:
    """Return hierarchical Xcode children when the field is well-formed."""
    children = node.get("children")
    return children if isinstance(children, list) else []


def parse_enumeration(data: Any) -> set[str]:
    """Return test identifiers from xcodebuild hierarchical enumeration JSON."""
    tests: set[str] = set()

    def explicit_identifier(node: dict[str, Any]) -> str | None:
        for key in ("identifier", "testIdentifier", "nodeIdentifier"):
            candidate = node.get(key)
            if isinstance(candidate, str) and candidate.strip():
                return canonical_identifier(candidate)
        return None

    def walk(node: Any, path: tuple[str, ...] = ()) -> None:
        if isinstance(node, list):
            for child in node:
                walk(child, path)
            return
        if not isinstance(node, dict):
            return

        children = _children(node)
        identifier = explicit_identifier(node)
        name = node.get("name")
        clean_name = name.strip() if isinstance(name, str) else ""

        if not children and isinstance(node.get("values"), list):
            walk(node["values"], path)
            return

        if not children:
            if identifier and "/" in identifier:
                tests.add(identifier)
                return
            if clean_name:
                if "/" in clean_name:
                    tests.add(canonical_identifier(clean_name))
                    return
                # Hierarchical Xcode enumeration groups plan -> target -> suite
                # -> test. Drop all plan/target ancestors and retain the nearest
                # suite path plus leaf test. Nested Swift Testing suites remain
                # represented because every suite level after cmuxTests is kept.
                pieces = [piece for piece in (*path, clean_name) if piece]
                if "cmuxTests" in pieces:
                    pieces = pieces[pieces.index("cmuxTests") + 1 :]
                elif len(pieces) >= 2:
                    pieces = pieces[-2:]
                if len(pieces) >= 2:
                    tests.add(canonical_identifier("/".join(pieces)))
            return

        next_path = path
        if clean_name:
            next_path = (*path, clean_name)
        for child in children:
            walk(child, next_path)

    walk(data)
    return tests


def parse_xcresult_tests(data: Any) -> dict[str, str]:
    """Return typed Test Case results from xcresulttool test-results tests JSON."""
    results: dict[str, str] = {}

    def record(identifier: str, result: str) -> None:
        identifier = canonical_identifier(identifier)
        if not identifier:
            return
        previous = results.get(identifier)
        if previous is None or RESULT_PRIORITY.get(result, 0) > RESULT_PRIORITY.get(previous, 0):
            results[identifier] = result

    def walk(node: Any) -> None:
        if isinstance(node, list):
            for child in node:
                walk(child)
            return
        if not isinstance(node, dict):
            return

        if node.get("nodeType") == "Test Case":
            identifier = node.get("nodeIdentifier") or node.get("testIdentifier")
            result = node.get("result", "unknown")
            if isinstance(identifier, str) and isinstance(result, str):
                record(identifier, result)

        for value in node.values():
            if isinstance(value, (dict, list)):
                walk(value)

    walk(data)
    return results


def load_json(path: Path) -> Any:
    """Read one UTF-8 JSON document."""
    return json.loads(path.read_text(encoding="utf-8"))


def load_inventory(path: Path) -> set[str]:
    """Load either a normalized inventory receipt or raw Xcode enumeration."""
    data = load_json(path)
    if isinstance(data, dict) and isinstance(data.get("tests"), list):
        return {canonical_identifier(str(item)) for item in data["tests"]}
    return parse_enumeration(data)


def load_selectors(path: Path) -> list[str]:
    """Load normalized non-empty selectors from a line-oriented file."""
    selectors = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line:
            selectors.append(selector_value(line))
    return selectors


def validate_catalog(data: Any) -> dict[str, dict[str, Any]]:
    """Validate and normalize a version-one known-failure catalog."""
    if not isinstance(data, dict) or data.get("version") != 1:
        raise ValueError("known-failure catalog must be an object with version=1")
    tests = data.get("tests")
    if not isinstance(tests, dict):
        raise ValueError("known-failure catalog tests must be an object")

    normalized: dict[str, dict[str, Any]] = {}
    for raw_identifier, metadata in tests.items():
        if not isinstance(raw_identifier, str) or not raw_identifier.strip():
            raise ValueError("known-failure test identifiers must be non-empty strings")
        identifier = canonical_identifier(raw_identifier)
        if identifier in normalized:
            raise ValueError(f"duplicate known-failure identifier after normalization: {identifier}")
        if not isinstance(metadata, dict):
            raise ValueError(f"known-failure metadata for {identifier} must be an object")
        classification = metadata.get("classification")
        if classification not in ALLOWED_CLASSIFICATIONS:
            raise ValueError(
                f"known-failure {identifier} has invalid classification {classification!r}"
            )
        issue = metadata.get("issue")
        if issue is not None and (not isinstance(issue, int) or issue <= 0):
            raise ValueError(f"known-failure {identifier} issue must be a positive integer")
        normalized[identifier] = metadata
    bootstrap_main_sha = data.get("bootstrap_main_sha")
    if normalized:
        if not isinstance(bootstrap_main_sha, str) or not re.fullmatch(
            r"[0-9a-f]{40}", bootstrap_main_sha
        ):
            raise ValueError(
                "non-empty known-failure catalog requires a 40-hex bootstrap_main_sha"
            )
    elif bootstrap_main_sha is not None and (
        not isinstance(bootstrap_main_sha, str)
        or not re.fullmatch(r"[0-9a-f]{40}", bootstrap_main_sha)
    ):
        raise ValueError("bootstrap_main_sha must be null or a 40-hex commit")

    return normalized


def load_catalog(path: Path) -> dict[str, dict[str, Any]]:
    """Read and validate the known-failure catalog."""
    return validate_catalog(load_json(path))


def inventory_selector_index(inventory: set[str]) -> dict[str, set[str]]:
    """Index every built Test Case under each selector prefix it satisfies."""
    index: dict[str, set[str]] = {}
    for identifier in inventory:
        comparable = comparable_identifier(identifier)
        pieces = comparable.split("/")
        for end in range(1, len(pieces) + 1):
            prefix = "/".join(pieces[:end])
            index.setdefault(prefix, set()).add(identifier)
    return index


def selected_inventory(
    inventory: set[str], selectors: Iterable[str]
) -> tuple[set[str], list[str]]:
    """Resolve selectors from one linear-time inventory prefix index."""
    index = inventory_selector_index(inventory)
    selected: set[str] = set()
    missing: list[str] = []
    for selector in selectors:
        normalized = selector_value(selector)
        matches = index.get(comparable_identifier(normalized), set())
        if matches:
            selected.update(matches)
        else:
            missing.append(normalized)
    return selected, missing


def merge_result_files(paths: Iterable[Path]) -> dict[str, str]:
    """Merge typed xcresult files using the strongest observed result."""
    merged: dict[str, str] = {}
    for path in paths:
        parsed = parse_xcresult_tests(load_json(path))
        for identifier, result in parsed.items():
            previous = merged.get(identifier)
            if previous is None or RESULT_PRIORITY.get(result, 0) > RESULT_PRIORITY.get(previous, 0):
                merged[identifier] = result
    return merged


def run_is_complete(log_text: str) -> tuple[bool, str]:
    """Reject explicit interruption evidence; typed inventory proves completion."""
    if RESTART_MARKER in log_text:
        return False, "app host restarted after test execution"
    if OUTER_TIMEOUT_RE.search(log_text):
        return False, "outer batch timeout fired"
    if IDLE_TIMEOUT_RE.search(log_text):
        return False, "xcodebuild idle timeout fired"
    return True, "no interruption marker"


def recorded_failure_diagnostics(
    results: dict[str, str],
    known: dict[str, dict[str, Any]],
) -> list[str]:
    """Name every recorded failure without deciding the run's verdict.

    The ratchet below fails fast: it reports new failures and returns without
    mentioning known ones, because the verdict is already decided. A run that
    is being reported for some other reason wants the opposite -- the complete
    picture, since its verdict does not depend on what this finds.
    """
    failures = {
        identifier for identifier, result in results.items() if result == "Failed"
    }
    new_failures = sorted(failures - set(known))
    known_failures = sorted(failures & set(known))
    messages = [f"RATCHET_NEW_FAILURE {identifier}" for identifier in new_failures]
    messages += [f"RATCHET_KNOWN_FAILURE {identifier}" for identifier in known_failures]
    if messages:
        # Mirror the summary the complete path prints. Without it, a reader
        # scanning shard output for "the accounting ran" sees the same silence
        # here that the missing verdicts themselves used to produce.
        messages.append(
            f"recorded verdicts: {len(new_failures)} new, "
            f"{len(known_failures)} known-main; typed test cases: {len(results)}"
        )
    return messages


def check_run(
    *,
    inventory: set[str],
    selectors: list[str],
    results: dict[str, str],
    known: dict[str, dict[str, Any]],
    log_text: str,
    xcode_status: int,
    changed_suites: bool = False,
) -> tuple[bool, list[str]]:
    """Return the fail-closed verdict and diagnostics for one app-host run.

    ``changed_suites`` marks a PR run of the suites the PR edited. There a
    catalog entry that passes must leave the catalog in the same PR: while it
    stays listed, the run is green whether or not the fix works, which is how
    a fix PR can merge with its target test still failing.
    """
    messages: list[str] = []

    expected_tests, missing_inventory = selected_inventory(inventory, selectors)
    if missing_inventory:
        for selector in missing_inventory:
            messages.append(f"selector matched zero built tests: {selector}")
        return False, messages

    complete, reason = run_is_complete(log_text)
    if not complete:
        messages.append(f"incomplete app-host run: {reason}")
        # A restart or timeout ends the run, not the verdicts recorded before
        # it; same reasoning as the missing-result gate below.
        messages.extend(recorded_failure_diagnostics(results, known))
        return False, messages

    if not results:
        messages.append("typed xcresult contains zero Test Case nodes")
        return False, messages

    missing_execution = sorted(expected_tests - set(results))
    if missing_execution:
        messages.append(
            f"typed xcresult is incomplete: {len(missing_execution)} selected Test Case(s) "
            "have no terminal result"
        )
        for identifier in missing_execution[:20]:
            messages.append(f"missing typed test result: {identifier}")
        if len(missing_execution) > 20:
            messages.append(
                f"... {len(missing_execution) - 20} additional selected Test Case(s) missing"
            )
        # An incomplete result set still carries a verdict for everything that
        # did finish. Naming those costs nothing and is the only way to tell a
        # shard whose remaining tests regressed from one whose remaining tests
        # went green -- without it both print the same "incomplete" line, and a
        # full suite can be red while naming no regression at all.
        messages.extend(recorded_failure_diagnostics(results, known))
        return False, messages

    if xcode_status not in {0, 65}:
        messages.append(f"xcodebuild status {xcode_status} is not ratchetable")
        return False, messages

    terminal_results = {"Passed", "Failed", "Skipped", "Expected Failure"}
    invalid_results = sorted(
        (identifier, result)
        for identifier, result in results.items()
        if result not in terminal_results
    )
    if invalid_results:
        for identifier, result in invalid_results:
            messages.append(
                f"typed Test Case has nonterminal or unknown result: {identifier} ({result})"
            )
        return False, messages

    failures = {identifier for identifier, result in results.items() if result == "Failed"}
    new_failures = sorted(failures - set(known))
    if new_failures:
        for identifier in new_failures:
            messages.append(f"RATCHET_NEW_FAILURE {identifier}")
        return False, messages

    if xcode_status == 65 and not failures:
        messages.append("xcodebuild exited 65 without a typed failed Test Case")
        return False, messages
    if xcode_status == 0 and failures:
        messages.append("xcodebuild exited 0 while typed test failures were present")
        return False, messages

    known_failures = sorted(failures & set(known))
    for identifier in known_failures:
        messages.append(f"RATCHET_KNOWN_FAILURE {identifier}")
    now_passing = sorted(
        identifier for identifier in known if results.get(identifier) == "Passed"
    )
    for identifier in now_passing:
        messages.append(f"RATCHET_KNOWN_NOW_PASSING {identifier}")
    if changed_suites and now_passing:
        messages.append(
            "this PR's selected suites pass tolerated known-main failures; remove them "
            "from scripts/ci/app-host-known-failures.json so the run has to prove the fix"
        )
        return False, messages

    if known_failures:
        messages.append(
            f"known-main failures tolerated: {len(known_failures)}; "
            f"typed test cases: {len(results)}"
        )
    else:
        messages.append(f"typed app-host run passed: {len(results)} test cases")
    return True, messages


def write_inventory(input_path: Path, output_path: Path) -> None:
    """Write a deterministic normalized test-inventory receipt.

    xcodebuild -enumerate-tests exits 0 even when the test runner never
    connected; it then writes only the plan node plus an "errors" list. An
    inventory built from that is empty, and every later step would run against
    a host that cannot run tests, so refuse it here.
    """
    data = load_json(input_path)
    errors = data.get("errors") if isinstance(data, dict) else None
    if errors:
        raise ValueError(
            "test enumeration failed on this runner: " + "; ".join(str(error) for error in errors)
        )
    tests = sorted(parse_enumeration(data))
    if not tests:
        raise ValueError(f"test enumeration found no tests in {input_path}")
    suites = sorted({identifier.split("/", 1)[0] for identifier in tests if "/" in identifier})
    payload = {
        "version": 1,
        "source": str(input_path),
        "test_count": len(tests),
        "suite_count": len(suites),
        "suites": suites,
        "tests": tests,
    }
    output_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"enumerated {len(tests)} tests across {len(suites)} suites")


def command_check_run(args: argparse.Namespace) -> int:
    """Validate one captured app-host run against inventory and ratchet state."""
    inventory = load_inventory(args.inventory)
    selectors = load_selectors(args.selectors)
    known = load_catalog(args.known)
    result_paths = [Path(path) for path in args.tests_json]
    missing_files = [str(path) for path in result_paths if not path.is_file()]
    if missing_files:
        print("missing typed xcresult JSON: " + ", ".join(missing_files), file=sys.stderr)
        return 2
    results = merge_result_files(result_paths)
    log_text = args.log.read_text(encoding="utf-8", errors="replace")
    passed, messages = check_run(
        inventory=inventory,
        selectors=selectors,
        results=results,
        known=known,
        log_text=log_text,
        xcode_status=args.xcode_status,
        changed_suites=args.changed_suites,
    )
    for message in messages:
        print(message, file=sys.stdout if passed else sys.stderr)
    return 0 if passed else 1


def command_catalog_diff(args: argparse.Namespace) -> int:
    """Enforce immutable bootstrap identity and subset-only catalog shrinkage."""
    old_data = load_json(args.base)
    new_data = load_json(args.current)
    old = validate_catalog(old_data)
    new = validate_catalog(new_data)

    old_bootstrap = old_data.get("bootstrap_main_sha") if isinstance(old_data, dict) else None
    new_bootstrap = new_data.get("bootstrap_main_sha") if isinstance(new_data, dict) else None
    if old_bootstrap is not None and new_bootstrap != old_bootstrap:
        print(
            "known-failure catalog bootstrap_main_sha is immutable after bootstrap",
            file=sys.stderr,
        )
        return 1

    additions = sorted(set(new) - set(old))
    if old_bootstrap is None and not old and new_bootstrap is not None:
        # The one permitted growth: an empty, never-bootstrapped catalog takes
        # its census from the main commit validate_catalog just pinned. From
        # then on the SHA is immutable and the set may only shrink.
        print(
            f"known-failure catalog bootstrapped at {new_bootstrap}: {len(new)} tests"
        )
        return 0
    if additions:
        for identifier in additions:
            print(f"known-failure catalog may only shrink: added {identifier}", file=sys.stderr)
        return 1
    print(f"known-failure catalog shrank or stayed equal: {len(old)} -> {len(new)}")
    return 0


def command_validate_catalog(args: argparse.Namespace) -> int:
    """Validate one known-failure catalog document."""
    tests = load_catalog(args.catalog)
    print(f"valid known-failure catalog: {len(tests)} tests")
    return 0


def build_parser() -> argparse.ArgumentParser:
    """Build the accounting command-line parser."""
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    inventory = subparsers.add_parser("inventory")
    inventory.add_argument("enumeration", type=Path)
    inventory.add_argument("--output", type=Path, required=True)

    check = subparsers.add_parser("check-run")
    check.add_argument("--inventory", type=Path, required=True)
    check.add_argument("--selectors", type=Path, required=True)
    check.add_argument("--known", type=Path, required=True)
    check.add_argument("--log", type=Path, required=True)
    check.add_argument("--xcode-status", type=int, required=True)
    check.add_argument("--tests-json", nargs="+", required=True)
    check.add_argument(
        "--changed-suites",
        action="store_true",
        help="fail when a known-failure catalog entry passes (PR changed-suites runs)",
    )

    catalog_diff = subparsers.add_parser("catalog-diff")
    catalog_diff.add_argument("--base", type=Path, required=True)
    catalog_diff.add_argument("--current", type=Path, required=True)

    validate = subparsers.add_parser("validate-catalog")
    validate.add_argument("catalog", type=Path)

    return parser


def main(argv: list[str] | None = None) -> int:
    """Dispatch the selected accounting subcommand."""
    args = build_parser().parse_args(argv)
    try:
        if args.command == "inventory":
            write_inventory(args.enumeration, args.output)
            return 0
        if args.command == "check-run":
            return command_check_run(args)
        if args.command == "catalog-diff":
            return command_catalog_diff(args)
        if args.command == "validate-catalog":
            return command_validate_catalog(args)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(str(error), file=sys.stderr)
        return 2
    raise AssertionError(args.command)


if __name__ == "__main__":
    raise SystemExit(main())
