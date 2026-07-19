#!/usr/bin/env python3
"""Check cmux-owned Swift file lengths against a checked-in budget."""

from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys


DEFAULT_ROOTS = ("Sources", "CLI", "Packages", "cmuxTests", "cmuxUITests")
DEFAULT_THRESHOLD = 500
DEFAULT_INCIDENTAL_GROWTH = 25
DEFAULT_HARD_CAP = 900
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


def is_in_roots(rel_path: str, roots: tuple[str, ...]) -> bool:
    return any(rel_path == root or rel_path.startswith(f"{root}/") for root in roots)


def count_blob_lines(content: bytes) -> int:
    return content.count(b"\n") + (0 if content.endswith(b"\n") or not content else 1)


def list_tree_swift_paths(repo_root: pathlib.Path, tree: str, roots: tuple[str, ...]) -> list[str]:
    result = subprocess.run(
        ["git", "-C", str(repo_root), "ls-tree", "-r", "--name-only", "-z", tree],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.decode("utf-8", errors="replace").strip())

    paths: list[str] = []
    for raw_path in result.stdout.split(b"\0"):
        if not raw_path:
            continue
        rel_path = raw_path.decode("utf-8", errors="surrogateescape")
        if not rel_path.endswith(".swift"):
            continue
        if not is_in_roots(rel_path, roots):
            continue
        if is_ignored_path(pathlib.Path(rel_path)):
            continue
        paths.append(rel_path)
    return sorted(paths)


def collect_file_lengths_at_ref(repo_root: pathlib.Path, ref: str, roots: tuple[str, ...]) -> FileLengthBudget:
    paths = list_tree_swift_paths(repo_root, ref, roots)
    if not paths:
        return {}

    batch_input = "".join(f"{ref}:{rel_path}\n" for rel_path in paths).encode(
        "utf-8",
        errors="surrogateescape",
    )
    try:
        process = subprocess.run(
            ["git", "-C", str(repo_root), "cat-file", "--batch"],
            input=batch_input,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except OSError as exc:
        raise RuntimeError(str(exc)) from exc

    if process.returncode != 0:
        raise RuntimeError(process.stderr.decode("utf-8", errors="replace").strip())

    budget: FileLengthBudget = {}
    offset = 0
    stdout = process.stdout
    for rel_path in paths:
        header_end = stdout.find(b"\n", offset)
        if header_end == -1:
            raise RuntimeError(f"missing git cat-file header for {rel_path}")
        header = stdout[offset:header_end]
        header_parts = header.split()
        if len(header_parts) == 2 and header_parts[1] == b"missing":
            raise RuntimeError(f"missing object for {ref}:{rel_path}")
        if len(header_parts) != 3:
            raise RuntimeError(f"unexpected git cat-file header for {rel_path}: {header!r}")
        try:
            size = int(header_parts[2])
        except ValueError as exc:
            raise RuntimeError(f"invalid git cat-file size for {rel_path}: {header!r}") from exc
        content_start = header_end + 1
        content_end = content_start + size
        if content_end > len(stdout):
            raise RuntimeError(f"truncated git cat-file content for {rel_path}")
        budget[rel_path] = count_blob_lines(stdout[content_start:content_end])
        offset = content_end
        if offset < len(stdout) and stdout[offset : offset + 1] == b"\n":
            offset += 1
    return budget


def tracked_file_lengths(file_lengths: FileLengthBudget, threshold: int) -> FileLengthBudget:
    return {
        rel_path: line_count
        for rel_path, line_count in file_lengths.items()
        if line_count >= threshold
    }


def count_lines_at_ref(repo_root: pathlib.Path, ref: str, rel_path: str) -> int | None:
    try:
        result = subprocess.run(
            ["git", "-C", str(repo_root), "show", f"{ref}:{rel_path}"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        return None

    if result.returncode != 0:
        return None
    return count_blob_lines(result.stdout)


def parse_budget(text: str, source: str) -> FileLengthBudget:
    budget: FileLengthBudget = {}
    for line_number, raw_line in enumerate(text.splitlines(), start=1):
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


def load_budget(path: pathlib.Path) -> FileLengthBudget:
    return parse_budget(path.read_text(encoding="utf-8"), str(path))


def repo_relative_path(repo_root: pathlib.Path, path: pathlib.Path) -> str | None:
    try:
        return path.resolve(strict=False).relative_to(repo_root).as_posix()
    except ValueError:
        return None


def load_budget_at_ref(repo_root: pathlib.Path, ref: str, rel_path: str) -> FileLengthBudget | None:
    try:
        result = subprocess.run(
            ["git", "-C", str(repo_root), "show", f"{ref}:{rel_path}"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except OSError:
        return None

    if result.returncode != 0:
        return None
    return parse_budget(result.stdout, f"{ref}:{rel_path}")


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


def speculative_merge_tree(repo_root: pathlib.Path, merge_ref: str, merge_head: str) -> str | None:
    try:
        result = subprocess.run(
            ["git", "-C", str(repo_root), "merge-tree", "--write-tree", merge_ref, merge_head],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except OSError as exc:
        print(
            f"Speculative merge of {merge_ref} and {merge_head} could not run; "
            "falling back to working-tree evaluation.",
        )
        print(str(exc), file=sys.stderr)
        return None

    if result.returncode == 0:
        tree = result.stdout.splitlines()[0] if result.stdout.splitlines() else ""
        if tree:
            return tree
        print(
            f"Speculative merge of {merge_ref} and {merge_head} did not produce a tree; "
            "falling back to working-tree evaluation.",
        )
        if result.stderr.strip():
            print(result.stderr.strip(), file=sys.stderr)
        return None

    if result.returncode == 1:
        print(
            f"Speculative merge of {merge_ref} and {merge_head} conflicts; "
            "falling back to working-tree evaluation.",
        )
        return None

    print(
        f"Speculative merge of {merge_ref} and {merge_head} failed; "
        "falling back to working-tree evaluation.",
    )
    if result.stderr.strip():
        print(result.stderr.strip(), file=sys.stderr)
    return None


def compare_budget(
    actual: FileLengthBudget,
    allowed: FileLengthBudget,
    base_allowed: FileLengthBudget | None,
    threshold: int,
    all_file_lengths: FileLengthBudget,
    repo_root: pathlib.Path,
    base_ref: str | None,
    incidental_growth: int,
    hard_cap: int,
) -> int:
    failures: list[tuple[str, int, int | None, str]] = []
    incidental: list[tuple[str, int, int, int]] = []
    reductions: list[tuple[str, int, int]] = []

    for rel_path in sorted(set(actual) | set(allowed)):
        actual_count = actual.get(rel_path, all_file_lengths.get(rel_path, 0))
        allowed_count = allowed.get(rel_path)

        if base_ref and actual_count >= threshold:
            base_count = count_lines_at_ref(repo_root, base_ref, rel_path)
            if base_count is None:
                failures.append((rel_path, actual_count, allowed_count, "new tracked file"))
                continue
            if base_count < threshold:
                failures.append((rel_path, actual_count, allowed_count, "newly tracked file"))
                continue

            base_growth = actual_count - base_count if base_count is not None else None
            if actual_count > hard_cap and base_growth is not None and base_growth > 0:
                failures.append((rel_path, actual_count, allowed_count, f"hard cap {hard_cap}"))
                continue
            if base_growth is not None and base_growth > incidental_growth:
                failures.append(
                    (
                        rel_path,
                        actual_count,
                        allowed_count,
                        f"PR growth +{base_growth} exceeds incidental allowance {incidental_growth}",
                    )
                )
                continue

            if allowed_count is None:
                failures.append((rel_path, actual_count, None, "missing budget entry"))
                continue
            base_allowed_count = base_allowed.get(rel_path) if base_allowed is not None else None
            if (
                base_allowed_count is not None
                and allowed_count < base_allowed_count
                and actual_count > allowed_count
            ):
                failures.append(
                    (
                        rel_path,
                        actual_count,
                        allowed_count,
                        f"budget lowered below actual count (base budget {base_allowed_count})",
                    )
                )
                continue
            if actual_count > allowed_count and base_growth is not None and base_growth > 0:
                incidental.append((rel_path, actual_count, allowed_count, base_growth))
                continue
            if actual_count > allowed_count:
                continue
            if actual_count < allowed_count:
                reductions.append((rel_path, actual_count, allowed_count))
                continue
            continue

        if allowed_count is None and actual_count >= threshold:
            failures.append((rel_path, actual_count, None, "untracked"))
        elif allowed_count is not None and actual_count > allowed_count:
            failures.append((rel_path, actual_count, allowed_count, "exceeds checked-in budget"))
        elif rel_path in allowed and actual_count < allowed_count:
            reductions.append((rel_path, actual_count, allowed_count))

    if failures:
        print("Swift file length budget exceeded.")
        print("")
        for rel_path, actual_count, allowed_count, reason in sorted(
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
            print(f"   reason={reason}")
        print("")
        print("Split the file, reduce the new growth, or refresh the budget only when accepting known debt.")
        return 1

    print("Swift file length budget respected.")
    if incidental:
        print("")
        print("Incidental growth allowed by PR gate:")
        for rel_path, actual_count, allowed_count, base_growth in sorted(
            incidental,
            key=lambda item: (item[3], item[0]),
            reverse=True,
        )[:20]:
            print(f"+{base_growth} {rel_path}")
            print(f"   actual={actual_count} budget={allowed_count} allowance={incidental_growth}")
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
        "--base-ref",
        help="git ref used to allow small PR-local growth in files already over budget",
    )
    parser.add_argument(
        "--merge-ref",
        help="git ref to speculatively merge with --merge-head before evaluating the budget",
    )
    parser.add_argument(
        "--merge-head",
        default="HEAD",
        help="git ref for the PR side of a speculative merge",
    )
    parser.add_argument(
        "--incidental-growth",
        default=DEFAULT_INCIDENTAL_GROWTH,
        type=int,
        help="max lines a PR may add to an existing tracked file without refreshing the budget",
    )
    parser.add_argument(
        "--hard-cap",
        default=DEFAULT_HARD_CAP,
        type=int,
        help="absolute max lines for an existing tracked file, even with incidental PR growth",
    )
    args = parser.parse_args(argv)

    if args.threshold < 1:
        print("--threshold must be at least 1", file=sys.stderr)
        return 2
    if args.incidental_growth < 0:
        print("--incidental-growth must be non-negative", file=sys.stderr)
        return 2
    if args.hard_cap < args.threshold:
        print("--hard-cap must be at least --threshold", file=sys.stderr)
        return 2
    if args.write_budget and args.merge_ref:
        print("--write-budget cannot be used with --merge-ref", file=sys.stderr)
        return 2

    repo_root = args.repo_root.resolve(strict=False)
    budget_path = args.budget if args.budget.is_absolute() else repo_root / args.budget

    merged_tree: str | None = None
    if args.merge_ref:
        merged_tree = speculative_merge_tree(repo_root, args.merge_ref, args.merge_head)

    if merged_tree:
        print(
            f"Evaluating speculative merge of {args.merge_ref} and {args.merge_head} "
            f"(tree {merged_tree})."
        )
        try:
            file_lengths = collect_file_lengths_at_ref(repo_root, merged_tree, tuple(args.roots))
        except RuntimeError as exc:
            print(f"Error reading Swift files from merged tree: {exc}", file=sys.stderr)
            return 2
        actual = tracked_file_lengths(file_lengths, args.threshold)
        print_file_summary("All scanned cmux-owned Swift files", file_lengths)
        print_file_summary(f"Tracked Swift files >= {args.threshold} lines", actual)

        budget_ref_path = repo_relative_path(repo_root, budget_path)
        try:
            allowed = load_budget_at_ref(repo_root, merged_tree, budget_ref_path) if budget_ref_path else None
        except ValueError as exc:
            print(f"Error reading Swift file length budget: {exc}", file=sys.stderr)
            return 2
        if allowed is None:
            print(f"Missing Swift file length budget: {budget_path}", file=sys.stderr)
            return 2
        base_allowed: FileLengthBudget | None = None
        try:
            base_allowed = load_budget_at_ref(repo_root, args.merge_ref, budget_ref_path)
        except ValueError as exc:
            print(f"Error reading base Swift file length budget: {exc}", file=sys.stderr)
            return 2
        print_file_summary("Allowed Swift file length budget", allowed)
        return compare_budget(
            actual,
            allowed,
            base_allowed,
            args.threshold,
            file_lengths,
            repo_root,
            args.merge_ref,
            args.incidental_growth,
            args.hard_cap,
        )

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
    base_allowed: FileLengthBudget | None = None
    if args.base_ref:
        budget_ref_path = repo_relative_path(repo_root, budget_path)
        if budget_ref_path is not None:
            try:
                base_allowed = load_budget_at_ref(repo_root, args.base_ref, budget_ref_path)
            except ValueError as exc:
                print(f"Error reading base Swift file length budget: {exc}", file=sys.stderr)
                return 2
    print_file_summary("Allowed Swift file length budget", allowed)
    return compare_budget(
        actual,
        allowed,
        base_allowed,
        args.threshold,
        file_lengths,
        repo_root,
        args.base_ref,
        args.incidental_growth,
        args.hard_cap,
    )


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
