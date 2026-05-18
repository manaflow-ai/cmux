#!/usr/bin/env python3
"""Check cmux-owned Swift file lengths against a checked-in budget."""

from __future__ import annotations

import argparse
import pathlib
import sys


DEFAULT_ROOTS = ("Sources", "CLI", "Packages", "cmuxTests", "cmuxUITests")
DEFAULT_THRESHOLD = 500
IGNORED_PATH_PARTS = (
    "/vendor/",
    "/ghostty/",
    "/homebrew-cmux/",
    "/SourcePackages/",
    "/.ci-source-packages/",
)


FileLengthBudget = dict[str, int]


def is_ignored_path(path: pathlib.Path) -> bool:
    normalized = "/" + path.as_posix().lstrip("/")
    return any(part in normalized for part in IGNORED_PATH_PARTS)


def count_lines(path: pathlib.Path) -> int:
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        return sum(1 for _ in handle)


def collect_file_lengths(repo_root: pathlib.Path, roots: tuple[str, ...]) -> FileLengthBudget:
    budget: FileLengthBudget = {}
    for root in roots:
        root_path = repo_root / root
        if not root_path.exists():
            continue

        for path in sorted(root_path.rglob("*.swift")):
            rel_path = path.relative_to(repo_root)
            if is_ignored_path(rel_path):
                continue
            budget[rel_path.as_posix()] = count_lines(path)
    return budget


def tracked_file_lengths(file_lengths: FileLengthBudget, threshold: int) -> FileLengthBudget:
    return {
        rel_path: line_count
        for rel_path, line_count in file_lengths.items()
        if line_count >= threshold
    }


def load_budget(path: pathlib.Path) -> FileLengthBudget:
    budget: FileLengthBudget = {}
    with path.open("r", encoding="utf-8") as handle:
        for line_number, raw_line in enumerate(handle, start=1):
            line = raw_line.rstrip("\n")
            if not line or line.startswith("#"):
                continue

            parts = line.split("\t", 1)
            if len(parts) != 2:
                raise ValueError(f"{path}:{line_number}: expected max_lines<TAB>relative path")

            count_text, rel_path = parts
            try:
                count = int(count_text)
            except ValueError as exc:
                raise ValueError(f"{path}:{line_number}: invalid line count {count_text!r}") from exc

            if count < 0:
                raise ValueError(f"{path}:{line_number}: line count must be non-negative")
            if rel_path in budget:
                raise ValueError(f"{path}:{line_number}: duplicate entry for {rel_path!r}")
            budget[rel_path] = count
    return budget


def write_budget(path: pathlib.Path, budget: FileLengthBudget) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        handle.write("# cmux-owned Swift file length budget.\n")
        handle.write("# Format: max_lines<TAB>relative path\n")
        handle.write("# Reduce counts as files shrink. CI fails if tracked files exceed this budget.\n")
        for rel_path, line_count in sorted(budget.items(), key=lambda item: (-item[1], item[0])):
            handle.write(f"{line_count}\t{rel_path}\n")


def print_file_summary(label: str, file_lengths: FileLengthBudget) -> None:
    total = sum(file_lengths.values())
    print(f"{label}: {total} line(s) across {len(file_lengths)} Swift file(s)")


def compare_budget(
    actual: FileLengthBudget,
    allowed: FileLengthBudget,
    threshold: int,
    all_file_lengths: FileLengthBudget,
) -> int:
    failures: list[tuple[str, int, int | None]] = []
    reductions: list[tuple[str, int, int]] = []

    for rel_path in sorted(set(actual) | set(allowed)):
        actual_count = actual.get(rel_path, all_file_lengths.get(rel_path, 0))
        allowed_count = allowed.get(rel_path)
        if allowed_count is None and actual_count >= threshold:
            failures.append((rel_path, actual_count, None))
        elif allowed_count is not None and actual_count > allowed_count:
            failures.append((rel_path, actual_count, allowed_count))
        elif rel_path in allowed and actual_count < allowed_count:
            reductions.append((rel_path, actual_count, allowed_count))

    if failures:
        print("Swift file length budget exceeded.")
        print("")
        for rel_path, actual_count, allowed_count in sorted(
            failures,
            key=lambda item: ((item[2] if item[2] is not None else threshold) - item[1], item[0]),
        ):
            comparison_count = allowed_count if allowed_count is not None else threshold
            delta = actual_count - comparison_count
            if allowed_count is None:
                prefix = f"+{delta}" if delta > 0 else "new"
                print(f"{prefix} {rel_path}")
                print(f"   actual={actual_count} budget=untracked threshold={threshold}")
            else:
                print(f"+{delta} {rel_path}")
                print(f"   actual={actual_count} budget={allowed_count}")
        print("")
        print("Split the file, reduce the new growth, or refresh the budget only when accepting known debt.")
        return 1

    print("Swift file length budget respected.")
    if reductions:
        print("")
        print("Budget can be reduced:")
        for rel_path, actual_count, allowed_count in sorted(
            reductions,
            key=lambda item: (item[2] - item[1], item[0]),
            reverse=True,
        )[:20]:
            delta = allowed_count - actual_count
            print(f"-{delta} {rel_path}")
            print(f"   actual={actual_count} budget={allowed_count}")
        if len(reductions) > 20:
            print(f"... {len(reductions) - 20} more reduction(s)")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repo-root",
        default=pathlib.Path.cwd(),
        type=pathlib.Path,
        help="repository root to scan",
    )
    parser.add_argument(
        "--budget",
        default=pathlib.Path(".github/swift-file-length-budget.tsv"),
        type=pathlib.Path,
        help="checked-in file length budget",
    )
    parser.add_argument(
        "--threshold",
        default=DEFAULT_THRESHOLD,
        type=int,
        help="minimum line count tracked by the budget",
    )
    parser.add_argument(
        "--roots",
        nargs="+",
        default=list(DEFAULT_ROOTS),
        help="repo-relative roots to scan",
    )
    parser.add_argument(
        "--write-budget",
        action="store_true",
        help="write the current file lengths as the budget instead of checking",
    )
    args = parser.parse_args(argv)

    if args.threshold < 1:
        print("--threshold must be at least 1", file=sys.stderr)
        return 2

    repo_root = args.repo_root.resolve(strict=False)
    budget_path = args.budget if args.budget.is_absolute() else repo_root / args.budget
    file_lengths = collect_file_lengths(repo_root, tuple(args.roots))
    actual = tracked_file_lengths(file_lengths, args.threshold)
    print_file_summary("All scanned cmux-owned Swift files", file_lengths)
    print_file_summary(f"Tracked Swift files >= {args.threshold} lines", actual)

    if args.write_budget:
        write_budget(budget_path, actual)
        print(f"Wrote {budget_path}")
        return 0

    if not budget_path.exists():
        print(f"Missing Swift file length budget: {budget_path}", file=sys.stderr)
        return 2

    try:
        allowed = load_budget(budget_path)
    except ValueError as exc:
        print(f"Error reading Swift file length budget: {exc}", file=sys.stderr)
        return 2
    print_file_summary("Allowed Swift file length budget", allowed)
    return compare_budget(actual, allowed, args.threshold, file_lengths)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
