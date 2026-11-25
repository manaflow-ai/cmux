"""Pane split tree for a terminal multiplexer window.

A window's layout is a tree. A leaf is one pane (a string id). A split lays its children out side by side:
orientation "h" puts them left to right, "v" top to bottom. Each child of a split has a ratio, its share of the
split's extent along the orientation.
"""
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class Leaf:
    pane: str


@dataclass
class Split:
    orientation: str  # "h" or "v"
    children: list = field(default_factory=list)
    ratios: list = field(default_factory=list)


class SplitTree:
    def __init__(self, first_pane: str):
        self.root = Leaf(first_pane)
        self.focus = first_pane

    # -- queries -------------------------------------------------------------------------------------

    def leaves(self) -> list[str]:
        """Pane ids in layout order: depth first, children in order (left to right, top to bottom)."""
        out: list[str] = []

        def walk(node):
            if isinstance(node, Leaf):
                out.append(node.pane)
            else:
                for child in node.children:
                    walk(child)

        walk(self.root)
        return out

    def snapshot(self):
        """The tree as plain data: a leaf is its pane id; a split is (orientation, [(ratio, child), ...])."""

        def snap(node):
            if isinstance(node, Leaf):
                return node.pane
            return (node.orientation, [(r, snap(c)) for r, c in zip(node.ratios, node.children)])

        return snap(self.root)

    def layout(self, width: int, height: int) -> dict[str, tuple[int, int, int, int]]:
        """Each pane's (x, y, w, h) in a width x height window. Sizes are rounded down; the last child of a split
        takes whatever is left, so the panes always tile the window exactly."""
        rects: dict[str, tuple[int, int, int, int]] = {}

        def place(node, x, y, w, h):
            if isinstance(node, Leaf):
                rects[node.pane] = (x, y, w, h)
                return
            extent = w if node.orientation == "h" else h
            offset = 0
            for i, (ratio, child) in enumerate(zip(node.ratios, node.children)):
                size = extent - offset if i == len(node.children) - 1 else int(extent * ratio)
                if node.orientation == "h":
                    place(child, x + offset, y, size, h)
                else:
                    place(child, x, y + offset, w, size)
                offset += size

        place(self.root, 0, 0, width, height)
        return rects

    def _find(self, pane: str):
        """(parent split or None, index in parent, leaf) for a pane; KeyError if absent."""

        def walk(node, parent, index):
            if isinstance(node, Leaf):
                return (parent, index, node) if node.pane == pane else None
            for i, child in enumerate(node.children):
                hit = walk(child, node, i)
                if hit:
                    return hit
            return None

        hit = walk(self.root, None, 0)
        if hit is None:
            raise KeyError(pane)
        return hit

    def _parent_of(self, target):
        def walk(node):
            if isinstance(node, Leaf):
                return None
            for i, child in enumerate(node.children):
                if child is target:
                    return node, i
                hit = walk(child)
                if hit:
                    return hit
            return None

        return walk(self.root)

    # -- edits ---------------------------------------------------------------------------------------

    def split(self, pane: str, orientation: str, new_pane: str) -> None:
        """Open new_pane next to pane (after it: right of it for "h", below it for "v") and focus it."""
        if orientation not in ("h", "v"):
            raise ValueError(orientation)
        if new_pane in self.leaves():
            raise ValueError(f"pane {new_pane} exists")
        parent, index, leaf = self._find(pane)
        node = Split(orientation, [leaf, Leaf(new_pane)], [0.5, 0.5])
        if parent is None:
            self.root = node
        else:
            parent.children[index] = node
        self.focus = new_pane

    def close(self, pane: str) -> None:
        """Close a pane. Closing the last pane is refused."""
        if self.leaves() == [pane]:
            raise ValueError("cannot close the last pane")
        order = self.leaves()
        position = order.index(pane)
        parent, index, _ = self._find(pane)
        del parent.children[index]
        del parent.ratios[index]
        if len(parent.children) == 1:
            only = parent.children[0]
            up = self._parent_of(parent)
            if up is None:
                self.root = only
            else:
                grand, gi = up
                grand.children[gi] = only
        remaining = [p for p in order if p != pane]
        self.focus = remaining[min(position, len(remaining) - 1)]

    def swap(self, a: str, b: str) -> None:
        """Exchange two panes' places. Each place keeps its size; focus stays on the same pane id."""
        _, _, leaf_a = self._find(a)
        _, _, leaf_b = self._find(b)
        leaf_a.pane, leaf_b.pane = b, a

    def resize(self, pane: str, ratio: float) -> None:
        """Give pane `ratio` of its parent split; its siblings share the rest in their current proportions."""
        if not 0 < ratio < 1:
            raise ValueError(ratio)
        parent, index, _ = self._find(pane)
        if parent is None:
            return
        others = sum(r for i, r in enumerate(parent.ratios) if i != index)
        parent.ratios = [ratio if i == index else r / others * (1 - ratio) for i, r in enumerate(parent.ratios)]
