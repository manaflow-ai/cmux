#!/usr/bin/env python3
"""Git merge driver for files that branches grow by inserting lines at the same place.

Two branches that each add a different entry where a list, a log or a module ends
both insert lines between the same two base lines. A line merge cannot order the
two insertions, so it stops with a conflict even though nothing was changed by both
sides: a 7-day replay of every base merge on cmux pull requests (2026-10-31 to
2026-11-07) found 799 of about 3,000 conflicted file merges were only that
(owner logs, `pub mod` lists, Cargo members, appended tests, registries).

This runs git's own three-way merge (`git merge-file --diff3`) and then settles
each conflict whose base side is empty, an insertion on both sides, by keeping
all of ours and then all of theirs. Every other conflict (a line both sides changed, a delete
against a change) stays an ordinary conflict for the author. A .json or .toml
result that no longer parses, or names a key twice, is written back as the
plain line merge, so a missing comma or a doubled key never merges silently.

Usage (git): merge-insertions.py %O %A %B %P %L; writes the result to %A and
exits 1 when a conflict remains.
"""
from __future__ import annotations

import json
import subprocess
import sys


def merge_file(ours: str, base: str, theirs: str, path: str, size: int) -> tuple[bytes, int]:
    result = subprocess.run(
        ["git", "merge-file", "-p", "--diff3", f"--marker-size={size}",
         "-L", "ours", "-L", "base", "-L", "theirs", ours, base, theirs],
        capture_output=True,
    )
    if result.returncode < 0 or result.returncode > 127:
        raise SystemExit(f"merge-insertions: git merge-file failed on {path}: {result.stderr.decode(errors='replace')}")
    return result.stdout, result.returncode


def settle(text: bytes, size: int) -> tuple[bytes, int]:
    """Resolve both-sides-inserted hunks; return the text and how many conflicts remain."""
    start, mid_base, mid, end = (c * size for c in (b"<", b"|", b"=", b">"))
    out: list[bytes] = []
    remaining = 0
    lines = text.splitlines(keepends=True)
    i = 0
    while i < len(lines):
        line = lines[i]
        if not line.startswith(start + b" "):
            out.append(line)
            i += 1
            continue
        # One diff3 hunk: <<< ours ||| base === theirs >>>.
        sections: dict[str, list[bytes]] = {"ours": [], "base": [], "theirs": []}
        part, j, closed = "ours", i + 1, False
        while j < len(lines):
            current = lines[j]
            if part == "ours" and current.startswith(mid_base + b" "):
                part = "base"
            elif part == "base" and current.rstrip(b"\r\n") == mid:
                part = "theirs"
            elif part == "theirs" and current.startswith(end + b" "):
                closed = True
                break
            else:
                sections[part].append(current)
            j += 1
        if not closed:  # not a hunk this driver wrote; leave the rest as it is
            out.extend(lines[i:])
            remaining += 1
            break
        if sections["base"]:
            # Something both sides changed: keep git's conflict, without the base section.
            out.append(line)
            out.extend(sections["ours"])
            out.append(mid + b"\n")
            out.extend(sections["theirs"])
            out.append(lines[j])
            remaining += 1
        else:
            # Every line of both insertions, ours first. Lines both sides inserted
            # alike are not merged into one: two appended functions both end in `}`,
            # and each needs its own.
            for block in (sections["ours"], sections["theirs"]):
                if block and not block[-1].endswith(b"\n"):
                    block[-1] += b"\n"
                out.extend(block)
        i = j + 1
    return b"".join(out), remaining


def unique_keys(pairs):
    keys = [key for key, _ in pairs]
    if len(keys) != len(set(keys)):
        raise ValueError("duplicate key")
    return dict(pairs)


def parses(path: str, text: bytes) -> bool:
    """A .json result must parse with no key twice in one object (both sides added the same
    key); .toml rejects a repeated key itself."""
    try:
        if path.endswith(".json"):
            json.loads(text, object_pairs_hook=unique_keys)
        elif path.endswith(".toml"):
            import tomllib
            tomllib.loads(text.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return False
    return True


def main(argv: list[str]) -> int:
    if len(argv) not in (5, 6):
        print("usage: merge-insertions.py %O %A %B %P [%L]", file=sys.stderr)
        return 2
    base, ours, theirs, path = argv[1:5]
    size = int(argv[5]) if len(argv) == 6 else 7
    merged, status = merge_file(ours, base, theirs, path, size)
    if status == 0:
        result, remaining = merged, 0
    else:
        result, remaining = settle(merged, size)
        if remaining == 0 and not parses(path, result):
            plain = subprocess.run(
                ["git", "merge-file", "-p", f"--marker-size={size}",
                 "-L", "ours", "-L", "base", "-L", "theirs", ours, base, theirs],
                capture_output=True,
            )
            result, remaining = plain.stdout, 1
    with open(ours, "wb") as handle:
        handle.write(result)
    return 1 if remaining else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
