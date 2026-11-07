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


def plain_merge(ours: str, base: str, theirs: str, size: int) -> bytes:
    return subprocess.run(
        ["git", "merge-file", "-p", f"--marker-size={size}",
         "-L", "ours", "-L", "base", "-L", "theirs", ours, base, theirs],
        capture_output=True,
    ).stdout


def merge_file(ours: str, base: str, theirs: str, path: str, size: int) -> tuple[bytes, int]:
    result = subprocess.run(
        ["git", "merge-file", "-p", "--diff3", f"--marker-size={size}",
         "-L", "ours", "-L", "base", "-L", "theirs", ours, base, theirs],
        capture_output=True,
    )
    if result.returncode < 0 or result.returncode > 127:
        raise SystemExit(f"merge-insertions: git merge-file failed on {path}: {result.stderr.decode(errors='replace')}")
    return result.stdout, result.returncode


# git writes its markers this long for the parse, so a line of the file that looks like
# a seven-character marker (a Markdown `=======` underline) is never read as one.
PARSE_MARKER = 51


def settle(text: bytes, size: int) -> tuple[bytes, int, int]:
    """Resolve both-sides-inserted hunks in merge-file output written with PARSE_MARKER
    markers; return the text (remaining conflicts rewritten with `size` markers), how many
    conflicts remain, and how many hunks were read."""
    start, mid_base, mid, end = (c * PARSE_MARKER for c in (b"<", b"|", b"=", b">"))
    out_start, out_mid, out_end = (c * size for c in (b"<", b"=", b">"))
    out: list[bytes] = []
    remaining = hunks = 0
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
        if not closed:  # not a hunk git wrote; the caller falls back to the plain merge
            out.extend(lines[i:])
            remaining += 1
            break
        hunks += 1
        if sections["base"]:
            # Something both sides changed: keep git's conflict, without the base section.
            out.append(out_start + b" ours\n")
            out.extend(sections["ours"])
            out.append(out_mid + b"\n")
            out.extend(sections["theirs"])
            out.append(out_end + b" theirs\n")
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
    return b"".join(out), remaining, hunks


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
            import tomllib  # Python 3.11+; an older python3 cannot check, so the merge stays a conflict
            tomllib.loads(text.decode("utf-8"))
    except (ValueError, UnicodeDecodeError, ImportError):
        return False
    return True


def main(argv: list[str]) -> int:
    if len(argv) not in (5, 6):
        print("usage: merge-insertions.py %O %A %B %P [%L]", file=sys.stderr)
        return 2
    base, ours, theirs, path = argv[1:5]
    size = int(argv[5]) if len(argv) == 6 else 7
    merged, status = merge_file(ours, base, theirs, path, PARSE_MARKER)
    if status == 0:
        result, remaining = merged, 0
    else:
        result, remaining, hunks = settle(merged, size)
        # git's exit status is its conflict count: a parse that read a different number
        # of hunks, or a result that does not parse, keeps git's own conflict instead.
        if hunks != status or (remaining == 0 and not parses(path, result)):
            result, remaining = plain_merge(ours, base, theirs, size), 1
    with open(ours, "wb") as handle:
        handle.write(result)
    return 1 if remaining else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
