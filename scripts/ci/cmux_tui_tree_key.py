#!/usr/bin/env python3
"""Compute the immutable key for a cmux-next cmux-tui publication."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path


REPAIR = "cmuxterm-hq REPAIR.md#cmux-tui-tree-publication"
ROOT = Path(__file__).resolve().parents[2]
INPUTS = ROOT / "scripts/cmux-next/cmux-tui-tree-inputs.txt"


def git(*args: str) -> str:
    return subprocess.check_output(["git", "-C", str(ROOT), *args], text=True).strip()


def tree_key(revision: str) -> str:
    entries: dict[tuple[str, ...], tuple[str, str, str]] = {}
    for raw in INPUTS.read_text(encoding="utf-8").splitlines():
        raw = raw.strip()
        if not raw or raw.startswith("#"):
            continue
        kind, path = raw.split(maxsplit=1)
        parts = tuple(path.split("/"))
        try:
            object_id = git("rev-parse", f"{revision}:{path}")
        except subprocess.CalledProcessError:
            if kind == "gitlink" and path == "ghostty-next":
                continue
            raise RuntimeError(f"{revision} has no {kind} input {path}") from None
        expected_mode = {"tree": "040000", "gitlink": "160000", "blob": "100755"}.get(kind)
        if expected_mode is None:
            raise RuntimeError(f"unknown cmux-tui tree input type {kind!r} for {path}")
        entries[parts] = (expected_mode, {"tree": "tree", "gitlink": "commit", "blob": "blob"}[kind], object_id)

    def make_tree(prefix: tuple[str, ...]) -> str:
        children: dict[str, tuple[str, str, str] | None] = {}
        for path, value in entries.items():
            if path[: len(prefix)] != prefix or len(path) <= len(prefix):
                continue
            name = path[len(prefix)]
            remainder = path[len(prefix) + 1 :]
            if remainder:
                children[name] = None
            else:
                children[name] = value
        lines: list[str] = []
        for name in sorted(children):
            value = children[name]
            if value is None:
                object_id = make_tree(prefix + (name,))
                mode = "040000"
                object_type = "tree"
            else:
                mode, object_type, object_id = value
            lines.append(f"{mode} {object_type} {object_id}\t{name}")
        if not lines:
            raise RuntimeError(f"empty cmux-tui tree input directory {prefix!r}")
        return subprocess.check_output(
            ["git", "-C", str(ROOT), "mktree", "--missing"],
            input=("\n".join(lines) + "\n").encode(),
        ).decode().strip()

    return make_tree(())


def main() -> int:
    revision = sys.argv[1] if len(sys.argv) > 1 else "HEAD"
    if len(sys.argv) > 2:
        print(f"error: usage: {Path(sys.argv[0]).name} [REV]; see {REPAIR}", file=sys.stderr)
        return 2
    try:
        print(tree_key(revision))
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"error: could not compute cmux-tui tree key: {error}; see {REPAIR}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
