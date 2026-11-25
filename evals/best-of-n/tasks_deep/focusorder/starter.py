"""Tab order and focus for the workspace groups of a cmux window.

Each group (a workspace) has an ordered strip of tabs and at most one active tab. Tabs can be pinned; pinned tabs
sit at the left of their strip. Every group remembers which of its tabs were active, most recent last, so closing
the active tab can go back to the one used before it. Closed tabs can be reopened, last closed first.
"""
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class Tab:
    id: str
    pinned: bool = False


@dataclass
class Group:
    tabs: list[Tab] = field(default_factory=list)
    active: str | None = None
    history: list[str] = field(default_factory=list)  # tab ids, most recently active last


class TabError(KeyError):
    pass


class TabStrip:
    def __init__(self):
        self.groups: dict[str, Group] = {}
        self._where: dict[str, str] = {}  # tab id -> group name
        self._closed: list[tuple[str, str, int, bool]] = []  # (tab, group, index, pinned)

    # -- queries -------------------------------------------------------------------------------------

    def _group(self, name: str) -> Group:
        return self.groups.setdefault(name, Group())

    def _locate(self, tab: str) -> tuple[Group, int]:
        if tab not in self._where:
            raise TabError(tab)
        g = self.groups[self._where[tab]]
        return g, next(i for i, t in enumerate(g.tabs) if t.id == tab)

    def order(self, group: str) -> list[str]:
        return [t.id for t in self._group(group).tabs]

    def active(self, group: str) -> str | None:
        return self._group(group).active

    def group_of(self, tab: str) -> str:
        if tab not in self._where:
            raise TabError(tab)
        return self._where[tab]

    def pinned(self, tab: str) -> bool:
        g, i = self._locate(tab)
        return g.tabs[i].pinned

    @staticmethod
    def _pinned_count(g: Group) -> int:
        return sum(t.pinned for t in g.tabs)

    # -- focus ---------------------------------------------------------------------------------------

    def activate(self, tab: str) -> None:
        g, _ = self._locate(tab)
        g.active = tab
        if tab in g.history:
            g.history.remove(tab)
        g.history.append(tab)

    def _refocus(self, g: Group, leaving: str, index: int) -> None:
        """`leaving` (which was at `index`) has left g's strip; if it was active, pick the next active tab."""
        if g.active != leaving:
            return
        if leaving in g.history:
            g.history.remove(leaving)
        g.active = None
        for previous in reversed(g.history):
            if previous in self._where:
                g.active = previous
                break
        if g.active is None and g.tabs:
            g.active = g.tabs[min(index, len(g.tabs) - 1)].id
        if g.active is not None:
            self.activate(g.active)

    # -- edits ---------------------------------------------------------------------------------------

    def open(self, group: str, tab: str, after: str | None = None) -> None:
        """Open a new unpinned tab right after `after` (a tab of that group), or at the end, and activate it."""
        if tab in self._where:
            raise ValueError(f"tab {tab} is open")
        g = self._group(group)
        index = len(g.tabs)
        if after is not None:
            ag, ai = self._locate(after)
            if ag is not g:
                raise ValueError(f"{after} is not in {group}")
            index = ai + 1
        g.tabs.insert(index, Tab(tab))
        self._where[tab] = group
        self.activate(tab)

    def close(self, tab: str) -> None:
        g, i = self._locate(tab)
        t = g.tabs.pop(i)
        del self._where[tab]
        self._closed.append((tab, self._group_name(g), i, t.pinned))
        self._refocus(g, tab, i)

    def reopen(self) -> str | None:
        """Reopen the most recently closed tab where it was, with its pinned state, and activate it."""
        if not self._closed:
            return None
        tab, group, index, pinned = self._closed.pop()
        g = self._group(group)
        g.tabs.insert(min(index, len(g.tabs)), Tab(tab, pinned))
        self._where[tab] = group
        self.activate(tab)
        return tab

    def pin(self, tab: str, pinned: bool = True) -> None:
        """Pin (to the end of the pinned tabs) or unpin (to the start of the unpinned tabs)."""
        g, i = self._locate(tab)
        t = g.tabs.pop(i)
        t.pinned = pinned
        g.tabs.insert(self._pinned_count(g), t)

    def move(self, tab: str, group: str, index: int) -> None:
        """Move a tab to position `index` of `group` (any group, its own included) and activate it there."""
        g, i = self._locate(tab)
        t = g.tabs.pop(i)
        dest = self._group(group)
        dest.tabs.insert(max(0, min(index, len(dest.tabs))), t)
        self._where[tab] = group
        if dest is not g:
            self._refocus(g, tab, i)
        self.activate(tab)

    def _group_name(self, g: Group) -> str:
        return next(name for name, other in self.groups.items() if other is g)
