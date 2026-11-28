"""Scrollback for one terminal pane.

Output arrives as logical lines (what the program printed between newlines). The pane shows them soft-wrapped to
its width: a logical line longer than the width continues on the next row. The buffer stores rows, as a terminal
does, each with a flag saying whether the row wraps into the next one; a logical line is a run of rows whose last
row does not wrap. Characters are all one column wide here.
"""
from __future__ import annotations

from dataclasses import dataclass


@dataclass
class Row:
    text: str
    wraps: bool  # True when this row continues on the next row (a soft wrap)


def wrap(line: str, width: int) -> list[Row]:
    """The rows one logical line occupies at `width`."""
    chunks = [line[i:i + width] for i in range(0, len(line), width)]
    return [Row(c, i < len(chunks) - 1) for i, c in enumerate(chunks)]


class Scrollback:
    def __init__(self, width: int, capacity: int):
        """`capacity` is the most logical lines kept; the oldest are evicted first."""
        if width < 1 or capacity < 1:
            raise ValueError("width and capacity must be positive")
        self.width = width
        self.capacity = capacity
        self._rows: list[Row] = []

    # -- writing -------------------------------------------------------------------------------------

    def append(self, line: str) -> None:
        if "\n" in line:
            raise ValueError("append takes one logical line")
        self._rows.extend(wrap(line, self.width))
        while len(self._rows) > self.capacity:
            self._rows.pop(0)

    def write(self, text: str) -> None:
        """Append each line of `text` (split on newlines; a trailing newline does not start an empty line)."""
        lines = text.split("\n")
        if lines and lines[-1] == "":
            lines.pop()
        for line in lines:
            self.append(line)

    # -- reading -------------------------------------------------------------------------------------

    def _logical(self) -> list[str]:
        lines, current = [], []
        for row in self._rows:
            current.append(row.text)
            if not row.wraps:
                lines.append("".join(current))
                current = []
        if current:
            lines.append("".join(current))
        return lines

    def lines(self) -> list[str]:
        """The kept logical lines, oldest first."""
        return self._logical()

    def line_count(self) -> int:
        return len(self._logical())

    def rows(self) -> list[str]:
        """What the pane draws, oldest row first."""
        return [r.text for r in self._rows]

    def row_count(self) -> int:
        return len(self._rows)

    def resize(self, width: int) -> None:
        """Reflow every kept logical line to the new width."""
        if width < 1:
            raise ValueError("width must be positive")
        logical = self._logical()
        self.width = width
        self._rows = [row for line in logical for row in wrap(line, width)]

    def search(self, needle: str) -> list[tuple[int, int]]:
        """Every occurrence of `needle`, as (logical line index, column in that logical line), in order. Index 0 is
        the oldest kept line. Overlapping occurrences all count."""
        if not needle:
            return []
        hits = []
        line_index, column = 0, 0
        for row in self._rows:
            start = row.text.find(needle)
            while start != -1:
                hits.append((line_index, column + start))
                start = row.text.find(needle, start + 1)
            if row.wraps:
                column += len(row.text)
            else:
                line_index += 1
                column = 0
        return hits
