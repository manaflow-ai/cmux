"""Changed files only: what a whole-tree scan guard reads on a pull request.

A scan guard (tests/test_outbound_hosts.py, ...) reads every file in its scope, and most of its CI time is that read.
On a pull request only the files the change touched can make a new problem: everything else is as it was on the
base, which passed. So when CMUX_GUARDS_BASE_SHA names a commit we can read, `changed()` returns the paths that
differ from it (the work tree against the base, so a local edit counts), and the guard scans those, at the base and
at the head, and reports what the change added. It returns None, and the guard scans everything as before, when:

  - there is no base (a plain `python3 tests/test_x.py`), or it is not a commit here, or git fails;
  - the run is a branch's own (GITHUB_EVENT_NAME push, schedule or workflow_dispatch): it scans everything, so a
    problem that reached the branch past a pull request (two that merged at once) still shows there;
  - a rule file changed: the guard's own source, a module it imports, or a list it checks the code against (`rules`).

`blobs_at()` reads files as a commit has them (one `git cat-file --batch`); `text_at_head()` reads the work tree.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# This module's own rules: a change here rescans everything.
SELF = "tests/guard_delta.py"


def git(root: Path, *args: str, data: bytes | None = None) -> bytes | None:
    p = subprocess.run(["git", "-C", str(root), *args], input=data, capture_output=True)
    return p.stdout if p.returncode == 0 else None


WHOLE_EVENTS = ("push", "schedule", "workflow_dispatch")


def base_commit(root: Path = ROOT) -> str | None:
    if os.environ.get("GITHUB_EVENT_NAME") in WHOLE_EVENTS:
        return None
    base = (os.environ.get("CMUX_GUARDS_BASE_SHA") or "").strip()
    if not base or git(root, "cat-file", "-e", f"{base}^{{commit}}") is None:
        return None
    return base


def changed(rules: list[str], root: Path = ROOT, base: str | None = None) -> list[str] | None:
    """The paths that differ from the base, or None to scan everything (no base, or a rule file changed)."""
    base = base or base_commit(root)
    if not base:
        return None
    out = git(root, "diff", "--name-only", "--no-renames", "-z", base, "--")
    if out is None:
        return None
    paths = sorted({p for p in out.decode(errors="surrogateescape").split("\0") if p})
    if any(p == r or (r.endswith("/") and p.startswith(r)) for p in paths for r in [*rules, SELF]):
        return None
    return paths


def blobs_at(rev: str, rels: list[str], root: Path = ROOT, errors: str = "strict") -> dict[str, str]:
    """{rel: text} for the regular files `rels` that commit `rev` has (no symlinks or submodules); with
    errors="strict" a file that is not UTF-8 is left out, as the scans' read_text() leaves it out."""
    if not rels:
        return {}
    tree = git(root, "ls-tree", "-z", rev, "--", *rels)
    if tree is None:
        raise RuntimeError(f"git ls-tree {rev} failed")
    want = []
    for entry in tree.decode(errors="surrogateescape").split("\0"):
        if not entry:
            continue
        meta, rel = entry.split("\t", 1)
        mode, kind, _ = meta.split()
        if kind == "blob" and mode != "120000":
            want.append(rel)
    if not want:
        return {}
    out = git(root, "cat-file", "--batch", data="".join(f"{rev}:{rel}\n" for rel in want).encode())
    if out is None:
        raise RuntimeError(f"git cat-file {rev} failed")
    texts, at = {}, 0
    for rel in want:
        end = out.index(b"\n", at)
        header = out[at:end].split()
        at = end + 1
        if len(header) < 3 or header[1] != b"blob":
            continue
        size = int(header[2])
        blob, at = out[at:at + size], at + size + 1
        try:
            texts[rel] = blob.decode(errors=errors)
        except UnicodeDecodeError:
            continue
    return texts


def text_at_head(rels: list[str], root: Path = ROOT, errors: str = "strict") -> dict[str, str]:
    """{rel: text} for the regular files `rels` in the work tree (a deleted file is left out), read as blobs_at."""
    texts = {}
    for rel in rels:
        path = root / rel
        if path.is_symlink() or not path.is_file():
            continue
        try:
            texts[rel] = path.read_text(encoding="utf-8", errors=errors)
        except (UnicodeDecodeError, OSError):
            continue
    return texts


def note(guard: str, base: str, paths: list[str]) -> None:
    print(f"{guard}: changed files only, {len(paths)} since {base[:12]} (CMUX_GUARDS_BASE_SHA); "
          "unset it to scan everything", file=sys.stderr)
