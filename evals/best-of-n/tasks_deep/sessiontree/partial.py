"""Session tree for an agent multiplexer.

Sessions form a forest: a session started from inside another is its child, a session started from the shell is a
root. A session's path is its ancestors' names and its own, joined with "/" (for example "work/api/tests").
"""
from __future__ import annotations

import itertools
from dataclasses import dataclass, field


class SessionError(ValueError):
    pass


@dataclass
class Session:
    id: int
    name: str
    parent: int | None = None
    children: list[int] = field(default_factory=list)


class SessionTree:
    def __init__(self):
        self._sessions: dict[int, Session] = {}
        self._roots: list[int] = []
        self._ids = itertools.count(1)

    # -- helpers -------------------------------------------------------------------------------------

    def _get(self, sid: int) -> Session:
        try:
            return self._sessions[sid]
        except KeyError:
            raise SessionError(f"no session {sid}") from None

    def _siblings(self, parent: int | None) -> list[int]:
        return self._roots if parent is None else self._get(parent).children

    @staticmethod
    def _key(name: str) -> str:
        return name.casefold()

    def _name_taken(self, parent: int | None, name: str, ignore: int | None = None) -> bool:
        key = self._key(name)
        return any(self._key(self._sessions[s].name) == key for s in self._siblings(parent) if s != ignore)

    @staticmethod
    def _check_name(name: str) -> None:
        if not name or "/" in name or name.strip() != name:
            raise SessionError(f"bad session name {name!r}")

    # -- queries -------------------------------------------------------------------------------------

    def __contains__(self, sid: int) -> bool:
        return sid in self._sessions

    def __len__(self) -> int:
        return len(self._sessions)

    def name(self, sid: int) -> str:
        return self._get(sid).name

    def parent(self, sid: int) -> int | None:
        return self._get(sid).parent

    def children(self, sid: int | None = None) -> list[int]:
        """Child ids in creation (or arrival) order; None lists the roots."""
        return list(self._siblings(sid))

    def path(self, sid: int) -> str:
        parts = []
        node: int | None = sid
        while node is not None:
            s = self._get(node)
            parts.append(s.name)
            node = s.parent
        return "/".join(reversed(parts))

    def find(self, path: str) -> int | None:
        """The session at `path`, or None. Names match the way sibling uniqueness compares them."""
        node: int | None = None
        for part in path.split("/"):
            match = [s for s in self._siblings(node) if self._sessions[s].name == part]
            if not match:
                return None
            node = match[0]
        return node

    def descendants(self, sid: int) -> list[int]:
        out = []
        for child in self._get(sid).children:
            out.append(child)
            out.extend(self.descendants(child))
        return out

    # -- edits ---------------------------------------------------------------------------------------

    def create(self, name: str, parent: int | None = None) -> int:
        self._check_name(name)
        if parent is not None:
            self._get(parent)
        if self._name_taken(parent, name):
            raise SessionError(f"{name!r} already exists there")
        sid = next(self._ids)
        self._sessions[sid] = Session(sid, name, parent)
        self._siblings(parent).append(sid)
        return sid

    def rename(self, sid: int, name: str) -> None:
        self._check_name(name)
        s = self._get(sid)
        if self._name_taken(s.parent, name, ignore=sid):
            raise SessionError(f"{name!r} already exists there")
        s.name = name

    def move(self, sid: int, new_parent: int | None) -> None:
        """Reparent a session (None makes it a root). It joins the end of its new parent's children."""
        s = self._get(sid)
        if new_parent is not None:
            self._get(new_parent)
        if new_parent == sid:
            raise SessionError("a session cannot be its own parent")
        if new_parent == s.parent:
            return
        self._siblings(s.parent).remove(sid)
        self._siblings(new_parent).append(sid)
        s.parent = new_parent

    def close(self, sid: int) -> list[int]:
        """Close a session and everything under it. Returns the closed ids."""
        s = self._get(sid)
        closed = []
        for child in s.children:
            closed.extend(self.close(child))
        self._siblings(s.parent).remove(sid)
        del self._sessions[sid]
        closed.append(sid)
        return closed
