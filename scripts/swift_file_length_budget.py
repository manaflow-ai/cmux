#!/usr/bin/env python3
"""Check cmux-owned Swift file lengths against a checked-in budget."""

from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys


DEFAULT_ROOTS = ("Sources", "CLI", "Packages", "cmuxTests", "cmuxUITests")
DEFAULT_THRESHOLD = 500
IGNORED_PATH_PARTS = (
    "/vendor/",
    "/ghostty/",
    "/homebrew-cmux/",
    "/SourcePackages/",
    "/.ci-source-packages/",
    "/.build/",
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


def git_output(repo_root: pathlib.Path, args: list[str], *, text: bool = True) -> str | bytes:
    completed = subprocess.run(
        ["git", "-C", str(repo_root), *args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=text,
    )
    return completed.stdout


def collect_file_lengths_from_git_ref(
    repo_root: pathlib.Path,
    ref: str,
    roots: tuple[str, ...],
) -> FileLengthBudget:
    output = git_output(
        repo_root,
        ["ls-tree", "-r", "--name-only", ref, "--", *roots],
        text=True,
    )
    budget: FileLengthBudget = {}
    for rel_path in output.splitlines():
        if not rel_path.endswith(".swift"):
            continue
        path = pathlib.Path(rel_path)
        if is_ignored_path(path):
            continue
        blob = git_output(repo_root, ["show", f"{ref}:{rel_path}"], text=False)
        assert isinstance(blob, bytes)
        budget[rel_path] = blob.count(b"\n") + (0 if blob.endswith(b"\n") or not blob else 1)
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


def load_budget_text(label: str, text: str) -> FileLengthBudget:
    budget: FileLengthBudget = {}
    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        line = raw_line.rstrip("\n")
        if not line or line.startswith("#"):
            continue

        parts = line.split("\t", 1)
        if len(parts) != 2:
            raise ValueError(f"{label}:{line_number}: expected max_lines<TAB>relative path")

        count_text, rel_path = parts
        try:
            count = int(count_text)
        except ValueError as exc:
            raise ValueError(f"{label}:{line_number}: invalid line count {count_text!r}") from exc

        if count < 0:
            raise ValueError(f"{label}:{line_number}: line count must be non-negative")
        if rel_path in budget:
            raise ValueError(f"{label}:{line_number}: duplicate entry for {rel_path!r}")
        budget[rel_path] = count
    return budget


def load_budget_from_git_ref(repo_root: pathlib.Path, ref: str, budget_path: pathlib.Path) -> FileLengthBudget:
    rel_path = repo_relative_path(repo_root, budget_path)
    try:
        output = git_output(repo_root, ["show", f"{ref}:{rel_path}"], text=True)
    except subprocess.CalledProcessError as exc:
        stderr = exc.stderr.strip() if isinstance(exc.stderr, str) else ""
        raise ValueError(f"{ref}:{rel_path}: could not read budget file from git ref: {stderr}") from exc
    assert isinstance(output, str)
    return load_budget_text(f"{ref}:{rel_path}", output)


def repo_relative_path(repo_root: pathlib.Path, path: pathlib.Path) -> str:
    resolved = path.resolve(strict=False)
    try:
        return resolved.relative_to(repo_root).as_posix()
    except ValueError as exc:
        raise ValueError(f"{path} must be inside repo root {repo_root}") from exc


def merge_effective_budget(
    allowed: FileLengthBudget,
    baseline_actual: FileLengthBudget,
) -> FileLengthBudget:
    merged = dict(allowed)
    for rel_path, line_count in baseline_actual.items():
        merged[rel_path] = max(merged.get(rel_path, 0), line_count)
    return merged


def reject_budget_increases(current: FileLengthBudget, baseline: FileLengthBudget) -> int:
    increases: list[tuple[str, int, int | None]] = []
    for rel_path, current_count in sorted(current.items()):
        baseline_count = baseline.get(rel_path)
        if baseline_count is None or current_count > baseline_count:
            increases.append((rel_path, current_count, baseline_count))

    if not increases:
        print("Swift file length budget has no increases.")
        return 0

    print("Swift file length budget increases are not allowed in this CI lane.")
    print("")
    for rel_path, current_count, baseline_count in increases:
        if baseline_count is None:
            print(f"new budget entry {rel_path}")
            print(f"   current={current_count} baseline=missing")
        else:
            print(f"+{current_count - baseline_count} budget {rel_path}")
            print(f"   current={current_count} baseline={baseline_count}")
    print("")
    print("Reduce the file or land an explicit budget maintenance change outside the no-growth lane.")
    return 1


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
    parser.add_argument(
        "--baseline-ref",
        help=(
            "git ref whose Swift file lengths are treated as already-existing debt. "
            "Use this in CI to reject only growth introduced by the current ref."
        ),
    )
    parser.add_argument(
        "--reject-budget-increases-from",
        metavar="REF",
        help="fail if the checked-in budget file increases any entry compared with REF",
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

    if args.reject_budget_increases_from:
        try:
            baseline_allowed = load_budget_from_git_ref(
                repo_root,
                args.reject_budget_increases_from,
                budget_path,
            )
        except ValueError as exc:
            print(f"Error reading baseline Swift file length budget: {exc}", file=sys.stderr)
            return 2
        print_file_summary("Baseline Swift file length budget", baseline_allowed)
        if reject_budget_increases(allowed, baseline_allowed) != 0:
            return 1

    effective_allowed = allowed
    if args.baseline_ref:
        try:
            baseline_lengths = collect_file_lengths_from_git_ref(
                repo_root,
                args.baseline_ref,
                tuple(args.roots),
            )
        except subprocess.CalledProcessError as exc:
            stderr = exc.stderr.strip() if isinstance(exc.stderr, str) else ""
            print(
                f"Error reading Swift file lengths from git ref {args.baseline_ref}: {stderr}",
                file=sys.stderr,
            )
            return 2
        baseline_actual = tracked_file_lengths(baseline_lengths, args.threshold)
        print_file_summary(
            f"Baseline Swift files >= {args.threshold} lines at {args.baseline_ref}",
            baseline_actual,
        )
        effective_allowed = merge_effective_budget(allowed, baseline_actual)

    return compare_budget(actual, effective_allowed, args.threshold, file_lengths)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
