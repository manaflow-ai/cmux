#!/usr/bin/env python3
"""Count Swift source lines while ignoring blank lines and comments.

This is deliberately a small lexer rather than a regex: URLs and comment-like text inside
string literals must count as source, while merge-tree-only documentation/comment lines must not.
"""

from __future__ import annotations

import argparse
import io
import subprocess
import tarfile
from pathlib import Path


def count_source_lines(text: str) -> int:
    return sum(source_line_flags(text))


def source_line_flags(text: str) -> list[bool]:
    """Per line of `text.split("\\n")`, whether it counts as a source line; their sum is count_source_lines.

    guardrails.py's `app-size` rule reads it to count a push's added and removed lines the way this script
    counts files, so the pre-push rule and check-app-size.sh --base agree on what growth is.
    """
    flags: list[bool] = []
    code_on_line = False
    mode = "normal"
    block_depth = 0
    index = 0

    while index < len(text):
        char = text[index]
        pair = text[index : index + 2]
        triple = text[index : index + 3]

        if mode == "normal":
            if char == "\n":
                flags.append(code_on_line)
                code_on_line = False
            elif pair == "//":
                mode = "line-comment"
                index += 1
            elif pair == "/*":
                mode = "block-comment"
                block_depth = 1
                index += 1
            elif triple == '\"\"\"':
                mode = "multiline-string"
                code_on_line = True
                index += 2
            elif char == '\"':
                mode = "string"
                code_on_line = True
            elif not char.isspace():
                code_on_line = True
        elif mode == "line-comment":
            if char == "\n":
                flags.append(code_on_line)
                code_on_line = False
                mode = "normal"
        elif mode == "block-comment":
            if pair == "/*":
                block_depth += 1
                index += 1
            elif pair == "*/":
                block_depth -= 1
                index += 1
                if block_depth == 0:
                    mode = "normal"
            elif char == "\n":
                flags.append(code_on_line)
                code_on_line = False
        elif mode == "string":
            code_on_line = True
            if char == "\\":
                if text[index + 1 : index + 2] == "\n":
                    flags.append(False)  # an escaped line break joins two lines into one source line
                index += 1
            elif char == '\"':
                mode = "normal"
            elif char == "\n":
                flags.append(True)
                code_on_line = False
        else:  # multiline-string
            code_on_line = True
            if triple == '\"\"\"':
                mode = "normal"
                index += 2
            elif char == "\n":
                flags.append(True)
                code_on_line = False

        index += 1

    flags.append(code_on_line)
    return flags


def working_tree_counts(app: Path) -> dict[str, int]:
    return {str(path.relative_to(app)): count_source_lines(path.read_text()) for path in sorted(app.rglob("*.swift"))}


def working_tree_count(root: Path) -> int:
    return sum(working_tree_counts(root).values())


def git_counts(root: Path, ref: str, prefix: str) -> dict[str, int]:
    archive = subprocess.run(
        ["git", "-C", str(root), "archive", "--format=tar", ref, "--", prefix],
        check=True,
        stdout=subprocess.PIPE,
    )
    counts: dict[str, int] = {}
    with tarfile.open(fileobj=io.BytesIO(archive.stdout), mode="r:") as bundle:
        for member in bundle:
            if member.isfile() and member.name.endswith(".swift"):
                stream = bundle.extractfile(member)
                if stream is not None:
                    counts[member.name[len(prefix) + 1:]] = count_source_lines(stream.read().decode())
    return counts


def git_count(root: Path, ref: str, prefix: str) -> int:
    return sum(git_counts(root, ref, prefix).values())


def grown(root: Path, ref: str, prefix: str) -> list[str]:
    """Every file whose source-line count changed since `ref`, largest growth first:
    `+3 Path.swift (0 -> 3)`. check-app-size prints it when the target grew."""
    base, now = git_counts(root, ref, prefix), working_tree_counts(root / prefix)
    deltas = [(now.get(name, 0) - base.get(name, 0), name) for name in set(base) | set(now)]
    return [f"{delta:+d} {name} ({base.get(name, 0)} -> {now.get(name, 0)})"
            for delta, name in sorted(deltas, key=lambda item: (-item[0], item[1])) if delta]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--git-ref", help="count the Swift files stored at this Git ref")
    parser.add_argument("--grown", metavar="REF", help="list the files whose source-line count changed since REF")
    parser.add_argument("root", nargs="?", default=".")
    args = parser.parse_args()
    root = Path(args.root).resolve()
    prefix = "Packages/macOS/CmuxNext/Sources/CmuxNextApp"
    if args.grown:
        print("\n".join(grown(root, args.grown, prefix)))
        return 0
    total = git_count(root, args.git_ref, prefix) if args.git_ref else working_tree_count(root / prefix)
    print(total)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
