#!/usr/bin/env python3
"""Check cmux-owned Swift warnings against a checked-in budget."""

from __future__ import annotations

import argparse
import collections
import pathlib
import re
import sys


OWNED_ROOTS = ("Sources", "CLI", "Packages", "cmuxTests", "cmuxUITests")
IGNORED_PATH_PARTS = (
    "/vendor/",
    "/ghostty/",
    "/homebrew-cmux/",
    "/SourcePackages/",
    "/.ci-source-packages/",
)
WARNING_RE = re.compile(
    r"^(?P<path>.+):"
    r"(?P<line>\d+):(?P<column>\d+): warning: (?P<message>.*)$"
)
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
GITHUB_LOG_PREFIX_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z\s+")
SWIFT6_ERROR_SUFFIX = "; this is an error in the Swift 6 language mode"


WarningBudget = collections.Counter[tuple[str, str]]


def is_ignored_path(path: str) -> bool:
    normalized = "/" + path.lstrip("/")
    return any(part in normalized for part in IGNORED_PATH_PARTS)


def is_owned_relative_path(path: str) -> bool:
    return any(path == root or path.startswith(f"{root}/") for root in OWNED_ROOTS)


def fallback_owned_path(path: str) -> str | None:
    parts = pathlib.PurePosixPath(path).parts
    candidates = ["/".join(parts[index:]) for index, part in enumerate(parts) if part in OWNED_ROOTS]
    packages_candidates = [candidate for candidate in candidates if candidate.startswith("Packages/")]
    if packages_candidates:
        return packages_candidates[-1]
    if candidates:
        return candidates[-1]
    return None


def relative_owned_path(raw_path: str, repo_root: pathlib.Path | None = None) -> str | None:
    path = raw_path.strip()
    if is_ignored_path(path):
        return None

    repo_root = repo_root or pathlib.Path.cwd()
    candidate_path = pathlib.Path(path)
    if candidate_path.is_absolute():
        try:
            rel_path = candidate_path.resolve(strict=False).relative_to(repo_root.resolve(strict=False))
        except ValueError:
            pass
        else:
            rel_text = rel_path.as_posix()
            if is_ignored_path(rel_text):
                return None
            if is_owned_relative_path(rel_text):
                return rel_text
            return None

    if is_owned_relative_path(path):
        return path

    fallback = fallback_owned_path(path)
    if fallback is not None and not is_ignored_path(fallback):
        return fallback
    return None


def normalize_message(message: str) -> str:
    normalized = " ".join(message.strip().split())
    while normalized.endswith(SWIFT6_ERROR_SUFFIX):
        normalized = normalized[: -len(SWIFT6_ERROR_SUFFIX)].rstrip()
    normalized = normalized.replace("non-Sendable", "non-sendable")
    normalized = normalized.replace("Non-Sendable", "non-sendable")
    normalized = normalized.replace(
        "@preconcurrency attribute on conformance",
        "'@preconcurrency' on conformance",
    )
    return normalized


def collect_warnings(log_path: pathlib.Path) -> WarningBudget:
    exact_seen: set[tuple[str, str, str, str]] = set()
    budget: WarningBudget = collections.Counter()

    with log_path.open("r", encoding="utf-8", errors="replace") as handle:
        for raw_line in handle:
            line = ANSI_RE.sub("", raw_line.rstrip("\n"))
            line = GITHUB_LOG_PREFIX_RE.sub("", line)
            match = WARNING_RE.match(line)
            if not match:
                continue

            rel_path = relative_owned_path(match.group("path"))
            if rel_path is None:
                continue

            message = normalize_message(match.group("message"))
            exact_key = (rel_path, match.group("line"), match.group("column"), message)
            if exact_key in exact_seen:
                continue
            exact_seen.add(exact_key)
            budget[(rel_path, message)] += 1

    return budget


def load_budget(path: pathlib.Path) -> WarningBudget:
    budget: WarningBudget = collections.Counter()
    with path.open("r", encoding="utf-8") as handle:
        for line_number, raw_line in enumerate(handle, start=1):
            line = raw_line.rstrip("\n")
            if not line or line.startswith("#"):
                continue

            parts = line.split("\t", 2)
            if len(parts) != 3:
                raise ValueError(f"{path}:{line_number}: expected count<TAB>path<TAB>message")

            count_text, rel_path, message = parts
            try:
                count = int(count_text)
            except ValueError as exc:
                raise ValueError(f"{path}:{line_number}: invalid count {count_text!r}") from exc

            if count < 0:
                raise ValueError(f"{path}:{line_number}: count must be non-negative")
            budget[(rel_path, normalize_message(message))] += count
    return budget


def write_budget(path: pathlib.Path, budget: WarningBudget) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        handle.write("# cmux-owned Swift warning budget.\n")
        handle.write("# Format: count<TAB>relative path<TAB>warning message\n")
        handle.write("# Reduce counts when warnings are fixed. CI fails if new warnings exceed this budget.\n")
        for (rel_path, message), count in sorted(budget.items()):
            handle.write(f"{count}\t{rel_path}\t{message}\n")


def print_budget_summary(label: str, budget: WarningBudget) -> None:
    total = sum(budget.values())
    print(f"{label}: {total} warning(s) across {len(budget)} bucket(s)")


def compare_budget(actual: WarningBudget, allowed: WarningBudget) -> int:
    failures: list[tuple[str, str, int, int]] = []
    reductions: list[tuple[str, str, int, int]] = []

    for key in sorted(set(actual) | set(allowed)):
        actual_count = actual.get(key, 0)
        allowed_count = allowed.get(key, 0)
        rel_path, message = key
        if actual_count > allowed_count:
            failures.append((rel_path, message, actual_count, allowed_count))
        elif actual_count < allowed_count:
            reductions.append((rel_path, message, actual_count, allowed_count))

    if failures:
        print("Swift warning budget exceeded.")
        print("")
        for rel_path, message, actual_count, allowed_count in failures:
            delta = actual_count - allowed_count
            print(f"+{delta} {rel_path}: {message}")
            print(f"   actual={actual_count} budget={allowed_count}")
        print("")
        print("Fix the new warnings or refresh the budget only when accepting known debt.")
        return 1

    print("Swift warning budget respected.")
    if reductions:
        print("")
        print("Budget can be reduced:")
        for rel_path, message, actual_count, allowed_count in reductions[:20]:
            delta = allowed_count - actual_count
            print(f"-{delta} {rel_path}: {message}")
            print(f"   actual={actual_count} budget={allowed_count}")
        if len(reductions) > 20:
            print(f"... {len(reductions) - 20} more reduction(s)")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", required=True, type=pathlib.Path, help="xcodebuild output log")
    parser.add_argument(
        "--budget",
        default=pathlib.Path(".github/swift-warning-budget.tsv"),
        type=pathlib.Path,
        help="checked-in warning budget file",
    )
    parser.add_argument(
        "--write-budget",
        action="store_true",
        help="write the current warnings as the budget instead of checking",
    )
    args = parser.parse_args(argv)

    actual = collect_warnings(args.log)
    print_budget_summary("Actual cmux-owned Swift warnings", actual)

    if args.write_budget:
        write_budget(args.budget, actual)
        print(f"Wrote {args.budget}")
        return 0

    if not args.budget.exists():
        print(f"Missing warning budget: {args.budget}", file=sys.stderr)
        return 2

    try:
        allowed = load_budget(args.budget)
    except ValueError as exc:
        print(f"Error reading warning budget: {exc}", file=sys.stderr)
        return 2
    print_budget_summary("Allowed warning budget", allowed)
    return compare_budget(actual, allowed)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
