#!/usr/bin/env python3
"""Compute the immutable key for a cmux-next cmux-tui publication."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path


REPAIR = "cmuxterm-hq REPAIR.md#cmux-tui-tree-publication"
ROOT = Path(__file__).resolve().parents[2]
INPUTS = ROOT / "scripts/cmux-next/cmux-tui-tree-inputs.txt"
# v2 excludes the classic ghostty gitlink and non-runtime cmux-tui/docs.
# v2-legacy preserves the pre-docs v2 algorithm; v1 also hashes ghostty.
# Consumers read v2, v2-legacy, then v1 so immutable old artifacts stay valid.
KEY_VERSIONS = ("v1", "v2", "v2-legacy")
V1_ONLY_INPUTS = frozenset({("gitlink", "ghostty")})
# In a partial clone a missing object is fetched from the promisor remote, one
# fetch per lookup; a revision the checkout lacks pegged a Mac for 19 minutes
# (2026-10-20). Every object read stays local and bounded.
GIT_ENV = {**os.environ, "GIT_NO_LAZY_FETCH": "1"}
GIT_TIMEOUT_SECONDS = 60


def git(*args: str) -> str:
    # stderr stays quiet: an absent optional input is an expected miss, and any
    # other failure is raised as CalledProcessError and reported by main().
    return subprocess.check_output(
        ["git", "-C", str(ROOT), *args],
        text=True,
        stderr=subprocess.DEVNULL,
        env=GIT_ENV,
        timeout=GIT_TIMEOUT_SECONDS,
    ).strip()


def tree_key(revision: str, version: str = "v2") -> str:
    if version not in KEY_VERSIONS:
        raise RuntimeError(f"unknown cmux-tui tree key version {version!r}")
    try:
        git("cat-file", "-e", f"{revision}^{{commit}}")
    except subprocess.CalledProcessError:
        raise RuntimeError(f"{revision} is not a commit in this checkout; fetch it first") from None
    entries: dict[tuple[str, ...], tuple[str, str, str]] = {}
    for raw in INPUTS.read_text(encoding="utf-8").splitlines():
        raw = raw.strip()
        if not raw or raw.startswith("#"):
            continue
        kind, path = raw.split(maxsplit=1)
        if version != "v1" and (kind, path) in V1_ONLY_INPUTS:
            continue
        parts = tuple(path.split("/"))
        try:
            object_id = git("rev-parse", f"{revision}:{path}")
        except subprocess.CalledProcessError:
            # Embedded-file blobs (cx-t3e5) and ghostty-next may be absent at a
            # revision; an absent input is left out of that revision's key.
            if (kind == "gitlink" and path == "ghostty-next") or (kind == "blob" and path != "scripts/cmux-next/build-layout-reducer-ffi.sh"):
                continue
            raise RuntimeError(f"{revision} has no {kind} input {path}") from None
        expected_mode = {"tree": "040000", "gitlink": "160000", "blob": "100755"}.get(kind)
        if expected_mode is None:
            raise RuntimeError(f"unknown cmux-tui tree input type {kind!r} for {path}")
        if version == "v2" and kind == "tree" and path == "cmux-tui":
            # Remove only the docs entry from the immediate workspace tree.
            # This needs no parent history and keeps all other subtrees opaque.
            raw_entries = subprocess.check_output(
                ["git", "-C", str(ROOT), "ls-tree", "-z", f"{revision}:{path}"],
                env=GIT_ENV, timeout=GIT_TIMEOUT_SECONDS,
            )
            runtime_entries = [entry for entry in raw_entries.split(b"\0")
                               if entry and entry.split(b"\t", 1)[1] != b"docs"]
            object_id = subprocess.check_output(
                ["git", "-C", str(ROOT), "mktree", "-z", "--missing"],
                input=b"".join(entry + b"\0" for entry in runtime_entries),
                env=GIT_ENV, timeout=GIT_TIMEOUT_SECONDS,
            ).decode().strip()
            entries[parts] = ("040000", "tree", object_id)
            continue
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
            env=GIT_ENV,
            timeout=GIT_TIMEOUT_SECONDS,
        ).decode().strip()

    return make_tree(())


def main() -> int:
    args = sys.argv[1:]
    version = "v2"
    if args[:1] == ["--version"]:
        if len(args) < 2 or args[1] not in KEY_VERSIONS:
            print(f"error: --version takes one of {', '.join(KEY_VERSIONS)}; see {REPAIR}", file=sys.stderr)
            return 2
        version, args = args[1], args[2:]
    if len(args) > 1:
        print(f"error: usage: {Path(sys.argv[0]).name} [--version v1|v2|v2-legacy] [REV]; see {REPAIR}", file=sys.stderr)
        return 2
    revision = args[0] if args else "HEAD"
    try:
        print(tree_key(revision, version))
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"error: could not compute cmux-tui tree key: {error}; see {REPAIR}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
