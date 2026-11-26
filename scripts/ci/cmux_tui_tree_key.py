#!/usr/bin/env python3
"""Compute the immutable key for a cmux-next cmux-tui publication."""

from __future__ import annotations

import os
import subprocess
import sys
import threading
from pathlib import Path


REPAIR = "cmuxterm-hq REPAIR.md#cmux-tui-tree-publication"
ROOT = Path(__file__).resolve().parents[2]
INPUTS_PATH = "scripts/cmux-next/cmux-tui-tree-inputs.txt"
INPUTS = ROOT / INPUTS_PATH
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


def inputs_text(revision: str) -> str:
    """The inputs list a revision is keyed by: the revision's own, as CI keys it (cmux-tui-artifacts.yml runs
    this script in a checkout of the commit it publishes). A checkout's newer list gave every older commit
    another key, one nothing was published under: #43477 added an input, and hot-apply then found no
    build for any commit before it. A revision without the file, or an INPUTS a caller set (a test's
    fixture), reads INPUTS."""
    if INPUTS == ROOT / INPUTS_PATH:
        try:
            return subprocess.check_output(["git", "-C", str(ROOT), "show", f"{revision}:{INPUTS_PATH}"], text=True,
                                           stderr=subprocess.DEVNULL, env=GIT_ENV, timeout=GIT_TIMEOUT_SECONDS)
        except subprocess.CalledProcessError:
            pass
    return INPUTS.read_text(encoding="utf-8")


def tree_objects(revision: str) -> dict[str, tuple[str, str, str]] | None:
    """Resolve all regular input paths with one tree walk.

    The key input list is read for every tree-key lookup, and callers invoke
    this script repeatedly while routing a build. Resolving each path with a
    separate ``git rev-parse`` made that cost grow linearly with the list. A
    recursive tree listing gives the same object ids in one process. The
    root listing retains top-level gitlinks, which ``ls-tree -r`` omits.
    ``None`` keeps the per-path fallback for partial checkouts whose tree
    cannot be listed in one pass.
    """
    try:
        listings = [
            subprocess.check_output(
                ["git", "-C", str(ROOT), "ls-tree", "-z", "--full-tree", revision],
                env=GIT_ENV,
                timeout=GIT_TIMEOUT_SECONDS,
            ),
            subprocess.check_output(
                ["git", "-C", str(ROOT), "ls-tree", "-z", "-r", "--full-tree", revision],
                env=GIT_ENV,
                timeout=GIT_TIMEOUT_SECONDS,
            ),
            subprocess.check_output(
                ["git", "-C", str(ROOT), "ls-tree", "-z", "-d", "-r", "--full-tree", revision],
                env=GIT_ENV,
                timeout=GIT_TIMEOUT_SECONDS,
            ),
        ]
    except subprocess.SubprocessError:
        return None

    resolved: dict[str, tuple[str, str, str]] = {}
    for listing in listings:
        for record in listing.split(b"\0"):
            if not record:
                continue
            header, path = record.split(b"\t", 1)
            mode, object_type, object_id = header.decode("ascii").split()
            resolved[path.decode("utf-8")] = (mode, object_type, object_id)
    return resolved


def tree_key(revision: str, version: str = "v2") -> str:
    if version not in KEY_VERSIONS:
        raise RuntimeError(f"unknown cmux-tui tree key version {version!r}")
    try:
        git("cat-file", "-e", f"{revision}^{{commit}}")
    except subprocess.CalledProcessError:
        raise RuntimeError(f"{revision} is not a commit in this checkout; fetch it first") from None
    entries: dict[tuple[str, ...], tuple[str, str, str]] = {}
    resolved_objects = tree_objects(revision)
    for raw in inputs_text(revision).splitlines():
        raw = raw.strip()
        if not raw or raw.startswith("#"):
            continue
        kind, path = raw.split(maxsplit=1)
        if version != "v1" and (kind, path) in V1_ONLY_INPUTS:
            continue
        parts = tuple(path.split("/"))
        resolved = resolved_objects.get(path) if resolved_objects is not None else None
        if resolved is not None:
            object_id = resolved[2]
        else:
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

    # One `git mktree --batch` writes every directory of the key, children first: a
    # `git mktree` process per directory was about 90 spawns and 1 s per key, and the
    # nightly's fallback search keys each of up to 300 commits three ways (run
    # 45243747211 spent 296 s there, on the path to the signer).
    mktree = subprocess.Popen(
        ["git", "-C", str(ROOT), "mktree", "--batch", "--missing"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=GIT_ENV,
    )
    # Its reads block on git's answer, so one deadline bounds the whole batch: a git that never
    # answers (a fake reading stdin to its end hung tests 60 s each) is killed, readline then
    # returns nothing and the key fails fast instead of waiting.
    watchdog = threading.Timer(GIT_TIMEOUT_SECONDS, mktree.kill)
    watchdog.daemon = True
    watchdog.start()
    try:
        return _make_tree((), entries, mktree)
    finally:
        watchdog.cancel()
        if mktree.stdin is not None:
            mktree.stdin.close()
        try:
            mktree.wait(timeout=GIT_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            mktree.kill()
            mktree.wait()


def _write_tree(mktree: subprocess.Popen[bytes], lines: list[str]) -> str:
    assert mktree.stdin is not None and mktree.stdout is not None
    mktree.stdin.write(("\n".join(lines) + "\n\n").encode())
    mktree.stdin.flush()
    object_id = mktree.stdout.readline().decode().strip()
    if len(object_id) != 40 or mktree.poll() is not None:
        raise RuntimeError(f"git mktree --batch wrote no tree (exit {mktree.poll()})")
    return object_id


def _make_tree(
    prefix: tuple[str, ...], entries: dict[tuple[str, ...], tuple[str, str, str]], mktree: subprocess.Popen[bytes]
) -> str:
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
            object_id = _make_tree(prefix + (name,), entries, mktree)
            mode = "040000"
            object_type = "tree"
        else:
            mode, object_type, object_id = value
        lines.append(f"{mode} {object_type} {object_id}\t{name}")
    if not lines:
        raise RuntimeError(f"empty cmux-tui tree input directory {prefix!r}")
    return _write_tree(mktree, lines)


def main() -> int:
    args = sys.argv[1:]
    # `key` is the verb its callers name (cmux-machine-channel.yml, cmux_machine_channel_pr_head.py,
    # cmux-machine-channel-point.sh). Before this it was a usage error (exit 2): every caller read an empty
    # key, so PR_HEAD_FAST_LANE built both thin musl targets on every land-tier pull request head (about
    # 90k runner-min/day from 2026-11-26 01Z) and the merge never found the head build it had paid for.
    if args[:1] == ["key"]:
        args = args[1:]
    version = "v2"
    if args[:1] == ["--version"]:
        if len(args) < 2 or args[1] not in KEY_VERSIONS:
            print(f"error: --version takes one of {', '.join(KEY_VERSIONS)}; see {REPAIR}", file=sys.stderr)
            return 2
        version, args = args[1], args[2:]
    if len(args) > 1:
        print(f"error: usage: {Path(sys.argv[0]).name} [key] [--version v1|v2|v2-legacy] [REV]; see {REPAIR}", file=sys.stderr)
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
