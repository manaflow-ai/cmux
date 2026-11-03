#!/usr/bin/env python3
"""Git calls that send request bytes on stdin, shared by prepush-gate.py and guardrails.py.

The request goes through a temporary file, never a pipe: on some hosts a subprocess with more than
about 10 KB of piped stdin hangs (cmux-lawrence, e8b8e40e4e9: even `cat`), and a big `cat-file --batch`
answer can fill the stdout pipe while the request is still being written. A hang there would leave the
pre-push hook running forever, which no fail-open `except` can catch.

Each importer loads this file from its own folder (prepush-gate.py from the checkout or beside the
installed hook copy, guardrails.py from the checkout or the installed checks snapshot): `python3 -I`
puts no script folder on sys.path.
"""
from __future__ import annotations

import re
import subprocess
import tempfile
from pathlib import Path

OBJECT_HEADER = re.compile(rb"^[0-9a-f]{40,64} (blob|tree|commit|tag) (\d+)$")


class GitError(RuntimeError):
    """A git call failed or answered less than it was asked."""


def run(repo: Path, args: list[str], data: bytes | None = None, env: dict[str, str] | None = None
        ) -> subprocess.CompletedProcess:
    """`git -C REPO ARGS` with DATA (or nothing) on stdin from a temporary file; output captured as bytes."""
    with tempfile.TemporaryFile() as stdin:
        if data is not None:
            stdin.write(data)
            stdin.seek(0)
        return subprocess.run(["git", "-C", str(repo), *args], stdin=stdin, capture_output=True, env=env)


def cat_file(repo: Path, specs: list[str], env: dict[str, str] | None = None, ids: dict[str, str] | None = None
             ) -> dict[str, bytes | None]:
    """{spec: blob bytes, or None when the spec names no blob} for `<rev>:<path>` SPECS in one `cat-file --batch`.

    IDS, when given, gets each found blob's object id by spec.

    Raises GitError when git exits non-zero or its answer does not cover every spec in order (git stopped
    early, or an answer this parser does not know), so a caller never judges a file whose text it lacks.
    """
    if not specs:
        return {}
    result = run(repo, ["cat-file", "--batch"], "".join(f"{spec}\n" for spec in specs).encode(), env)
    if result.returncode != 0:
        raise GitError(f"git cat-file --batch exited {result.returncode}: "
                       f"{result.stderr.decode('utf-8', 'replace').strip()}")
    out, cursor, found = result.stdout, 0, {}
    for spec in specs:
        end = out.find(b"\n", cursor)
        if end < 0:
            raise GitError(f"git cat-file --batch stopped before {spec!r} ({len(found)} of {len(specs)} answered)")
        header = out[cursor:end]
        cursor = end + 1
        match = OBJECT_HEADER.match(header)
        if match is None:
            if header == spec.encode() + b" missing":
                found[spec] = None
                continue
            raise GitError(f"git cat-file --batch answered {header[:200]!r} for {spec!r}")
        size = int(match.group(2))
        if cursor + size + 1 > len(out):
            raise GitError(f"git cat-file --batch cut {spec!r} short")
        found[spec] = out[cursor:cursor + size] if match.group(1) == b"blob" else None
        if ids is not None and found[spec] is not None:
            ids[spec] = header.split(b" ", 1)[0].decode()
        cursor += size + 1
    return found
