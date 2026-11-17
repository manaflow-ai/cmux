#!/usr/bin/env python3
"""A changed Cargo.lock adds no crate version that no base Cargo.lock has, unless a commit says so.

cmux#42155 called itself a lock "alignment" that added no versions; it added seven, and review could only take its
word for it. This makes the claim checked: every downloaded (crate, version) in a Cargo.lock that BASE..HEAD adds or
changes must be in at least one Cargo.lock at BASE. Path packages (workspace members, no `source`) are skipped: a
member's own version bump downloads nothing. A commit in BASE..HEAD with a `Cargo-Lock-New-Versions: <why>` line
(the key exactly as written, a reason required; a subject like `cargo-lock-new-versions: ...` is not one) allows them.

The pre-push gate runs it (prepush-gate.py, "Cargo.lock adds no new crate versions") only when the pushed range
changes a Cargo.lock, with BASE the range's base over origin/feat-cmux-next. It reads git objects only: no cargo, no
network, no build.

  cargo-lock-new-versions.py --repo R --base B [--head H]
Prints `new: <lock>: <crate> <version>` per finding. Exit 0: nothing new, or allowed. 1: new, not allowed.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys

ALLOW_KEY = "Cargo-Lock-New-Versions:"
ALLOW_LINE = re.compile(r"^[ \t]*" + re.escape(ALLOW_KEY) + r"[ \t]*(\S[^\n]*?)[ \t]*$", re.MULTILINE)
FIELD = re.compile(r'^\s*(name|version|source)\s*=\s*"([^"]*)"\s*$')


def parse_lock(text: str) -> list[tuple[str, str, str | None]]:
    """The (name, version, source) of each [[package]] entry of a Cargo.lock, any lock format version."""
    out: list[tuple[str, str, str | None]] = []
    entry: dict[str, str] | None = None

    def flush() -> None:
        if entry and "name" in entry and "version" in entry:
            out.append((entry["name"], entry["version"], entry.get("source")))

    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("["):
            flush()
            entry = {} if stripped == "[[package]]" else None
            continue
        match = FIELD.match(line) if entry is not None else None
        if match:
            entry[match.group(1)] = match.group(2)
    flush()
    return out


def base_set(locks: list[str]) -> set[tuple[str, str]]:
    return {(name, version) for text in locks for name, version, _ in parse_lock(text)}


def new_versions(known: set[tuple[str, str]], changed: list[tuple[str, str]]) -> list[tuple[str, str, str]]:
    """(lock, crate, version) of each downloaded package in CHANGED, (path, text) pairs, that KNOWN lacks."""
    found = {(lock, name, version) for lock, text in changed for name, version, source in parse_lock(text)
             if source is not None and (name, version) not in known}
    return sorted(found)


def allowed(messages: str) -> str | None:
    """The reason on a `Cargo-Lock-New-Versions: <why>` line of the commit messages, if any."""
    match = ALLOW_LINE.search(messages)
    return match.group(1) if match else None


def is_lock(path: str) -> bool:
    return path == "Cargo.lock" or path.endswith("/Cargo.lock")


def git(repo: str, *args: str) -> str:
    return subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True).stdout.decode(
        "utf-8", "surrogateescape")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=".")
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", default="HEAD")
    args = parser.parse_args(argv)
    repo, base, head = args.repo, args.base, args.head
    # `*` in git's default pathspec matching also matches `/`.
    changed_paths = [p for p in git(repo, "diff", "--name-only", "--no-renames", "--diff-filter=AM", base, head,
                                    "--", "*Cargo.lock").splitlines() if is_lock(p)]
    if not changed_paths:
        return 0
    base_paths = [p for p in git(repo, "ls-tree", "-r", "--name-only", base).splitlines() if is_lock(p)]
    known = base_set([git(repo, "show", f"{base}:{p}") for p in base_paths])
    findings = new_versions(known, [(p, git(repo, "show", f"{head}:{p}")) for p in changed_paths])
    if not findings:
        return 0
    reason = allowed(git(repo, "log", "--format=%B", f"{base}..{head}"))
    if reason:
        print(f"allowed ({ALLOW_KEY} {reason}): {len(findings)} new crate version(s)")
        return 0
    for lock, name, version in findings:
        print(f"new: {lock}: {name} {version}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
