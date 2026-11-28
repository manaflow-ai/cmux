#!/usr/bin/env python3
"""Select trusted Web complexity scope without executing candidate code."""

from __future__ import annotations

import argparse
import re
import stat
import subprocess
import sys
from pathlib import Path

SOURCE_SUFFIXES = (".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".mts", ".cts")
EXCLUDED_WEB_PREFIXES = (
    ".next/",
    "coverage/",
    "db/migrations/",
    "e2e/",
    "node_modules/",
    "out/",
    "public/",
    "scripts/",
    "tests/",
    "tools/",
)
BASELINE_FILE = "web/oxlint-complexity-baseline.txt"
FULL_SCAN_PATHS = {
    ".github/workflows/web-complexity.yml",
    ".github/workflows/web-complexity-trusted.yml",
    "scripts/ci/scope-web-complexity.py",
    "scripts/ci/web_complexity_scope.py",
    "web/.oxlintrc.json",
    "web/bun.lock",
    "web/bunfig.toml",
    BASELINE_FILE,
    "web/package.json",
    "web/scripts/check-complexity.mjs",
}
FINGERPRINT_PATTERN = re.compile(r"^[0-9a-f]{64}$")


class ScopeError(RuntimeError):
    pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--base-baseline", required=True)
    parser.add_argument("--selected-output", required=True)
    parser.add_argument("--github-output")
    return parser.parse_args()


def validate_repo_path(raw: bytes) -> str:
    try:
        value = raw.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise ScopeError("git returned a changed path that is not valid UTF-8") from error
    if not value or value.startswith("/") or "\x00" in value:
        raise ScopeError("git returned an invalid changed path")
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise ScopeError("git returned a changed path with unsupported control characters")
    parts = value.split("/")
    if any(part in {"", ".", ".."} for part in parts):
        raise ScopeError("git returned an ambiguous changed path")
    return value


def production_source(repo_path: str) -> bool:
    if not repo_path.startswith("web/"):
        return False
    web_path = repo_path[len("web/") :]
    if web_path.startswith("-"):
        raise ScopeError("production Web paths beginning with '-' are unsupported")
    return web_path.endswith(SOURCE_SUFFIXES) and not any(
        web_path.startswith(prefix) for prefix in EXCLUDED_WEB_PREFIXES
    )


def changed_paths(repo_root: Path, base: str, head: str) -> list[tuple[str, str, str | None]]:
    result = subprocess.run(
        [
            "git",
            "diff",
            "--name-status",
            "-z",
            "--find-renames",
            "--no-ext-diff",
            "--no-textconv",
            base,
            head,
            "--",
        ],
        cwd=repo_root,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise ScopeError(f"git diff failed{': ' + detail if detail else ''}")
    fields = result.stdout.split(b"\0")
    if fields and fields[-1] == b"":
        fields.pop()

    changes: list[tuple[str, str, str | None]] = []
    index = 0
    while index < len(fields):
        status_field = fields[index]
        index += 1
        if not status_field:
            raise ScopeError("git diff returned an empty status")
        try:
            status = status_field.decode("ascii", errors="strict")
        except UnicodeDecodeError as error:
            raise ScopeError("git diff returned a non-ASCII status") from error
        kind = status[:1]
        if kind in {"R", "C"}:
            if index + 1 >= len(fields):
                raise ScopeError("git diff returned a truncated rename or copy")
            old_path = validate_repo_path(fields[index])
            new_path = validate_repo_path(fields[index + 1])
            index += 2
            changes.append((status, old_path, new_path))
        elif kind in {"A", "D", "M", "T", "U", "X", "B"}:
            if index >= len(fields):
                raise ScopeError("git diff returned a truncated changed path")
            repo_path = validate_repo_path(fields[index])
            index += 1
            changes.append((status, repo_path, None))
        else:
            raise ScopeError(f"git diff returned unsupported status {status!r}")
    return changes



def production_file_count(repo_root: Path, head: str) -> int:
    result = subprocess.run(
        ["git", "ls-tree", "-r", "-z", "--name-only", head, "--", "web"],
        cwd=repo_root,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise ScopeError(f"git ls-tree failed{': ' + detail if detail else ''}")
    fields = result.stdout.split(b"\0")
    if fields and fields[-1] == b"":
        fields.pop()
    return sum(1 for raw in fields if production_source(validate_repo_path(raw)))


def baseline_paths_from_text(text: str, label: str) -> set[str]:
    entries: set[str] = set()
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) < 3 or not fields[0] or not FINGERPRINT_PATTERN.fullmatch(fields[1]):
            raise ScopeError(f"{label} contains an invalid entry")
        entries.add(fields[0])
    return entries


def baseline_paths(filename: Path) -> set[str]:
    try:
        text = filename.read_text(encoding="utf-8")
    except OSError as error:
        raise ScopeError(f"could not read trusted baseline: {error}") from error
    return baseline_paths_from_text(text, "trusted baseline")


def candidate_baseline_paths(repo_root: Path, head: str) -> set[str]:
    result = subprocess.run(
        ["git", "show", f"{head}:{BASELINE_FILE}"],
        cwd=repo_root,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise ScopeError(f"candidate baseline is unavailable{': ' + detail if detail else ''}")
    try:
        text = result.stdout.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise ScopeError("candidate baseline is not valid UTF-8") from error
    return baseline_paths_from_text(text, "candidate baseline")


def ensure_regular_candidate_file(repo_root: Path, repo_path: str) -> None:
    candidate = repo_root / repo_path
    try:
        mode = candidate.lstat().st_mode
    except OSError as error:
        raise ScopeError(f"selected candidate file is unavailable: {error}") from error
    if not stat.S_ISREG(mode):
        raise ScopeError("selected candidate path must be a regular file")


def classify(
    repo_root: Path,
    changes: list[tuple[str, str, str | None]],
    grandfathered: set[str],
    candidate_grandfathered: set[str],
) -> tuple[str, list[str], int]:
    changed: set[str] = set()
    touched_production: set[str] = set()
    selected: set[str] = set()
    removed_production: set[str] = set()

    for status, first, second in changes:
        kind = status[:1]
        old_path = first
        new_path = second if kind in {"R", "C"} else first
        changed.add(old_path)
        if second is not None:
            changed.add(second)

        old_is_production = production_source(old_path)
        new_is_production = production_source(new_path)

        if old_is_production:
            touched_production.add(old_path)
        if new_is_production:
            touched_production.add(new_path)

        if kind == "D" and old_is_production:
            removed_production.add(old_path)
        elif kind == "R" and old_is_production and old_path != new_path:
            removed_production.add(old_path)

        if kind != "D" and new_is_production:
            ensure_regular_candidate_file(repo_root, new_path)
            selected.add(new_path)

        if kind != "D" and new_path in FULL_SCAN_PATHS:
            ensure_regular_candidate_file(repo_root, new_path)

    stale_deleted = [
        repo_path
        for repo_path in removed_production
        if repo_path[len("web/") :] in grandfathered
        and repo_path[len("web/") :] in candidate_grandfathered
    ]
    if stale_deleted:
        raise ScopeError(
            "deleted or renamed production source still has a grandfathered baseline entry; "
            "remove the stale baseline entry in the same change"
        )

    if changed & FULL_SCAN_PATHS:
        return "full", [], len(touched_production)

    if touched_production:
        return "changed", sorted(selected), len(touched_production)
    return "skip", [], 0


def write_selected(filename: Path, selected: list[str]) -> None:
    filename.parent.mkdir(parents=True, exist_ok=True)
    with filename.open("wb") as handle:
        for repo_path in selected:
            handle.write(repo_path.encode("utf-8"))
            handle.write(b"\0")


def write_outputs(filename: str | None, mode: str, selected_count: int, touched_count: int) -> None:
    if not filename:
        return
    try:
        with open(filename, "a", encoding="utf-8") as handle:
            handle.write(f"mode={mode}\n")
            handle.write(f"selected_count={selected_count}\n")
            handle.write(f"touched_count={touched_count}\n")
    except OSError as error:
        raise ScopeError(f"could not write GitHub output: {error}") from error


def main() -> int:
    args = parse_args()
    repo_root = Path(args.repo_root).resolve()
    selected_output = Path(args.selected_output).resolve()
    try:
        if not re.fullmatch(r"[0-9a-f]{40}", args.base) or not re.fullmatch(r"[0-9a-f]{40}", args.head):
            raise ScopeError("base and head must be full 40-character commit SHAs")
        changes = changed_paths(repo_root, args.base, args.head)
        grandfathered = baseline_paths(Path(args.base_baseline).resolve())
        candidate_grandfathered = candidate_baseline_paths(repo_root, args.head)
        mode, selected, touched_count = classify(
            repo_root, changes, grandfathered, candidate_grandfathered
        )
        selected_count = production_file_count(repo_root, args.head) if mode == "full" else len(selected)
        write_selected(selected_output, selected)
        write_outputs(args.github_output, mode, selected_count, touched_count)
    except (OSError, ScopeError) as error:
        print(f"complexity scope: {error}", file=sys.stderr)
        return 2

    print(
        "complexity scope: "
        f"mode={mode} touched_production={touched_count} selected_files={selected_count}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
