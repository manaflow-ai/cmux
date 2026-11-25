"""Parse `git status --porcelain=v1 -z` for the workspace sidebar's git badge.

Each entry is `XY PATH` followed by NUL. X is the index (staged) status, Y the work tree status; " " means
unmodified. With -z, paths are never quoted or escaped and may contain any byte but NUL (spaces, newlines, "->").
An entry whose status is a rename or copy is followed by one more NUL-terminated field, the path it came from.
Unmerged (conflicted) entries are DD, AU, UD, UA, DU, AA and UU. Untracked files are `??`, ignored files `!!`.
"""
from __future__ import annotations

from dataclasses import dataclass

UNMERGED = {"DD", "AU", "UD", "UA", "DU", "AA", "UU"}


@dataclass(frozen=True)
class Entry:
    x: str
    y: str
    path: str
    orig_path: str | None = None  # set for renames and copies

    @property
    def kind(self) -> str:
        """One of "conflicted", "untracked", "ignored", "changed"."""
        xy = self.x + self.y
        if xy in UNMERGED:
            return "conflicted"
        if xy == "??":
            return "untracked"
        if xy == "!!":
            return "ignored"
        return "changed"


@dataclass
class Summary:
    staged: int = 0      # entries with a change in the index
    unstaged: int = 0    # entries with a change in the work tree
    untracked: int = 0
    ignored: int = 0
    conflicted: int = 0
    renamed: int = 0     # entries renamed or copied, in the index or the work tree

    @property
    def clean(self) -> bool:
        return not (self.staged or self.unstaged or self.untracked or self.conflicted)


def parse(data: bytes | str) -> list[Entry]:
    if isinstance(data, bytes):
        data = data.decode("utf-8", "surrogateescape")
    fields = data.split("\0")
    if fields and fields[-1] == "":
        fields.pop()
    entries = []
    i = 0
    while i < len(fields):
        field = fields[i]
        i += 1
        if len(field) < 4 or field[2] != " ":
            raise ValueError(f"bad porcelain entry {field!r}")
        x, y, path = field[0], field[1], field[3:]
        orig = None
        if x in "RC" or y in "RC":
            if i >= len(fields):
                raise ValueError(f"rename of {path!r} has no source path")
            orig = fields[i]
            i += 1
        entries.append(Entry(x, y, path, orig))
    return entries


def summarize(entries: list[Entry]) -> Summary:
    s = Summary()
    for e in entries:
        kind = e.kind
        if kind == "conflicted":
            s.conflicted += 1
            continue
        if kind == "untracked":
            s.untracked += 1
            continue
        if kind == "ignored":
            s.ignored += 1
            continue
        if e.x != " ":
            s.staged += 1
        if e.y != " ":
            s.unstaged += 1
        if e.orig_path is not None:
            s.renamed += 1
    return s


def badge(summary: Summary) -> str:
    """The sidebar badge: "clean", or the nonzero counts in a fixed order, like "1! 2+ 1~ 3?"."""
    if summary.clean:
        return "clean"
    parts = []
    for count, mark in ((summary.conflicted, "!"), (summary.staged, "+"), (summary.unstaged, "~"),
                        (summary.untracked, "?")):
        if count:
            parts.append(f"{count}{mark}")
    return " ".join(parts)


def status(data: bytes | str) -> tuple[list[Entry], Summary]:
    entries = parse(data)
    return entries, summarize(entries)
