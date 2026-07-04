#!/usr/bin/env python3
"""Check cmux-owned Swift file lengths against a checked-in budget."""

from __future__ import annotations

import argparse
import os
import pathlib
import subprocess
import sys


DEFAULT_ROOTS = ("Sources", "CLI", "Packages", "cmuxTests", "cmuxUITests")
DEFAULT_THRESHOLD = 500
IGNORED_PATH_PARTS = (
    "/vendor/",
    "/ghostty/",
    "/homebrew-cmux/",
    "/.build/",
    "/SourcePackages/",
    "/.ci-source-packages/",
)


FileLengthBudget = dict[str, int]


def is_ignored_path(path: pathlib.Path) -> bool:
    normalized = "/" + path.as_posix().lstrip("/")
    return any(part in normalized for part in IGNORED_PATH_PARTS)


def is_scanned_path(path: pathlib.Path, roots: tuple[str, ...]) -> bool:
    normalized = path.as_posix()
    for root in roots:
        normalized_root = pathlib.Path(os.path.normpath(root)).as_posix()
        if normalized_root == ".":
            return True
        if normalized == normalized_root or normalized.startswith(f"{normalized_root}/"):
            return True
    return False


def count_lines(path: pathlib.Path) -> int:
    count = 0
    saw_content = False
    last_byte = b""

    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            saw_content = True
            count += chunk.count(b"\n")
            last_byte = chunk[-1:]

    if not saw_content:
        return 0
    if last_byte != b"\n":
        count += 1
    return count


def count_lines_in_bytes(content: bytes) -> int:
    count = 0
    if not content:
        return 0
    for offset in range(0, len(content), 1024 * 1024):
        count += content[offset : offset + 1024 * 1024].count(b"\n")
    if content[-1:] != b"\n":
        count += 1
    return count


def collect_file_lengths(repo_root: pathlib.Path, roots: tuple[str, ...]) -> FileLengthBudget:
    budget: FileLengthBudget = {}
    for root in roots:
        root_path = repo_root / root
        if not root_path.exists():
            continue

        for dirpath, dirnames, filenames in os.walk(root_path):
            dirnames[:] = sorted(
                dirname
                for dirname in dirnames
                if not is_ignored_path(pathlib.Path(dirpath, dirname).relative_to(repo_root))
            )
            for filename in sorted(filenames):
                if not filename.endswith(".swift"):
                    continue
                path = pathlib.Path(dirpath) / filename
                rel_path = path.relative_to(repo_root)
                if is_ignored_path(rel_path):
                    continue
                budget[rel_path.as_posix()] = count_lines(path)
    return budget


def collect_file_lengths_for_paths(
    repo_root: pathlib.Path,
    roots: tuple[str, ...],
    paths: list[str],
) -> FileLengthBudget:
    budget: FileLengthBudget = {}
    for raw_path in paths:
        path = pathlib.Path(raw_path)
        if path.is_absolute():
            try:
                rel_path = path.resolve(strict=False).relative_to(repo_root)
            except ValueError:
                continue
        else:
            rel_path = pathlib.Path(os.path.normpath(raw_path))
            if rel_path.is_absolute() or rel_path.parts[:1] == ("..",):
                continue
            path = repo_root / rel_path

        if rel_path.suffix != ".swift":
            continue
        if not is_scanned_path(rel_path, roots) or is_ignored_path(rel_path):
            continue
        if not path.is_file():
            continue

        budget[rel_path.as_posix()] = count_lines(path)
    return budget


def collect_staged_file_lengths(repo_root: pathlib.Path, roots: tuple[str, ...]) -> FileLengthBudget:
    result = subprocess.run(
        [
            "git",
            "-C",
            str(repo_root),
            "diff",
            "--cached",
            "--name-only",
            "--diff-filter=ACMR",
            "-z",
            "--",
            "*.swift",
        ],
        check=True,
        stdout=subprocess.PIPE,
    )

    budget: FileLengthBudget = {}
    paths = [path for path in result.stdout.decode("utf-8", errors="surrogateescape").split("\0") if path]
    for raw_path in paths:
        rel_path = pathlib.Path(os.path.normpath(raw_path))
        if rel_path.suffix != ".swift":
            continue
        if not is_scanned_path(rel_path, roots) or is_ignored_path(rel_path):
            continue

        blob = subprocess.run(
            ["git", "-C", str(repo_root), "show", f":{rel_path.as_posix()}"],
            check=True,
            stdout=subprocess.PIPE,
        ).stdout
        budget[rel_path.as_posix()] = count_lines_in_bytes(blob)
    return budget


def collect_index_file_lengths(repo_root: pathlib.Path, roots: tuple[str, ...]) -> FileLengthBudget:
    result = subprocess.run(
        [
            "git",
            "-C",
            str(repo_root),
            "ls-files",
            "-z",
            "--",
            "*.swift",
        ],
        check=True,
        stdout=subprocess.PIPE,
    )

    budget: FileLengthBudget = {}
    paths = [path for path in result.stdout.decode("utf-8", errors="surrogateescape").split("\0") if path]
    for raw_path in paths:
        rel_path = pathlib.Path(os.path.normpath(raw_path))
        if rel_path.suffix != ".swift":
            continue
        if not is_scanned_path(rel_path, roots) or is_ignored_path(rel_path):
            continue

        blob = subprocess.run(
            ["git", "-C", str(repo_root), "show", f":{rel_path.as_posix()}"],
            check=True,
            stdout=subprocess.PIPE,
        ).stdout
        budget[rel_path.as_posix()] = count_lines_in_bytes(blob)
    return budget


def tracked_file_lengths(file_lengths: FileLengthBudget, threshold: int) -> FileLengthBudget:
    return {
        rel_path: line_count
        for rel_path, line_count in file_lengths.items()
        if line_count >= threshold
    }


def load_budget(path: pathlib.Path) -> FileLengthBudget:
    with path.open("r", encoding="utf-8") as handle:
        return parse_budget_lines(str(path), handle)


def parse_budget_lines(source: str, lines) -> FileLengthBudget:
    budget: FileLengthBudget = {}
    for line_number, raw_line in enumerate(lines, start=1):
        line = raw_line.rstrip("\n")
        if not line or line.startswith("#"):
            continue

        parts = line.split("\t", 1)
        if len(parts) != 2:
            raise ValueError(f"{source}:{line_number}: expected max_lines<TAB>relative path")

        count_text, rel_path = parts
        try:
            count = int(count_text)
        except ValueError as exc:
            raise ValueError(f"{source}:{line_number}: invalid line count {count_text!r}") from exc

        if count < 0:
            raise ValueError(f"{source}:{line_number}: line count must be non-negative")
        if rel_path in budget:
            raise ValueError(f"{source}:{line_number}: duplicate entry for {rel_path!r}")
        budget[rel_path] = count
    return budget


def load_staged_budget(repo_root: pathlib.Path, budget_path: pathlib.Path) -> FileLengthBudget:
    try:
        rel_path = budget_path.resolve(strict=False).relative_to(repo_root)
    except ValueError:
        return load_budget(budget_path)

    source = f":{rel_path.as_posix()}"
    result = subprocess.run(
        ["git", "-C", str(repo_root), "show", source],
        check=True,
        stdout=subprocess.PIPE,
    )
    text = result.stdout.decode("utf-8", errors="replace")
    return parse_budget_lines(source, text.splitlines())


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
    checked_paths: set[str] | None = None,
) -> int:
    failures: list[tuple[str, int, int | None]] = []
    reductions: list[tuple[str, int, int]] = []

    compared_paths = set(actual) | set(allowed)
    if checked_paths is not None:
        compared_paths &= checked_paths

    for rel_path in sorted(compared_paths):
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
        "--paths",
        nargs="+",
        help="optional repo-relative or absolute paths to check instead of scanning every root",
    )
    parser.add_argument(
        "--staged",
        action="store_true",
        help="check staged Swift files from the git index instead of scanning every root",
    )
    parser.add_argument(
        "--index",
        action="store_true",
        help="check every tracked Swift file from the git index instead of the working tree",
    )
    args = parser.parse_args(argv)

    if args.threshold < 1:
        print("--threshold must be at least 1", file=sys.stderr)
        return 2
    if args.write_budget and args.paths is not None:
        print("--write-budget cannot be combined with --paths", file=sys.stderr)
        return 2
    if args.write_budget and args.staged:
        print("--write-budget cannot be combined with --staged", file=sys.stderr)
        return 2
    if args.write_budget and args.index:
        print("--write-budget cannot be combined with --index", file=sys.stderr)
        return 2
    if args.paths is not None and args.staged:
        print("--paths cannot be combined with --staged", file=sys.stderr)
        return 2
    if args.paths is not None and args.index:
        print("--paths cannot be combined with --index", file=sys.stderr)
        return 2
    if args.staged and args.index:
        print("--staged cannot be combined with --index", file=sys.stderr)
        return 2

    repo_root = args.repo_root.resolve(strict=False)
    budget_path = args.budget if args.budget.is_absolute() else repo_root / args.budget
    roots = tuple(args.roots)
    checked_paths: set[str] | None = None
    if args.staged:
        try:
            file_lengths = collect_staged_file_lengths(repo_root, roots)
        except subprocess.CalledProcessError as exc:
            print(f"Error reading staged Swift files: {exc}", file=sys.stderr)
            return 2
        checked_paths = set(file_lengths)
    elif args.index:
        try:
            file_lengths = collect_index_file_lengths(repo_root, roots)
        except subprocess.CalledProcessError as exc:
            print(f"Error reading index Swift files: {exc}", file=sys.stderr)
            return 2
    elif args.paths is None:
        file_lengths = collect_file_lengths(repo_root, roots)
    else:
        file_lengths = collect_file_lengths_for_paths(repo_root, roots, args.paths)
        checked_paths = set(file_lengths)
    actual = tracked_file_lengths(file_lengths, args.threshold)
    print_file_summary("All scanned cmux-owned Swift files", file_lengths)
    print_file_summary(f"Tracked Swift files >= {args.threshold} lines", actual)
    if checked_paths is not None and not checked_paths:
        if args.paths is not None:
            print("--paths did not resolve to any cmux-owned Swift files", file=sys.stderr)
            return 2
        print("Swift file length budget respected.")
        return 0

    if args.write_budget:
        write_budget(budget_path, actual)
        print(f"Wrote {budget_path}")
        return 0

    if not args.staged and not budget_path.exists():
        print(f"Missing Swift file length budget: {budget_path}", file=sys.stderr)
        return 2

    try:
        if args.staged:
            allowed = load_staged_budget(repo_root, budget_path)
        else:
            allowed = load_budget(budget_path)
    except ValueError as exc:
        print(f"Error reading Swift file length budget: {exc}", file=sys.stderr)
        return 2
    except subprocess.CalledProcessError as exc:
        print(f"Error reading staged Swift file length budget: {exc}", file=sys.stderr)
        return 2
    print_file_summary("Allowed Swift file length budget", allowed)
    return compare_budget(actual, allowed, args.threshold, file_lengths, checked_paths)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
