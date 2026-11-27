"""Byte offset <-> (line, column) mapping for the terminal's scrollback search and the editor pane's LSP bridge.

The buffer is UTF-8 bytes. Positions follow the Language Server Protocol, which differs from what you might
expect in three ways, all on purpose:
- A line ends at "\\n", at "\\r\\n", or at a lone "\\r" (old Mac files and progress bars use it). The terminator is
  not part of the line's text.
- A column counts UTF-16 code units from the line start: a character outside the Basic Multilingual Plane (most
  emoji) counts 2, every other character 1, whatever its UTF-8 length.
- Lines and columns are 0-based.
"""
from bisect import bisect_right


def _line_starts(data: bytes, base: int = 0) -> list[int]:
    """Offsets (plus `base`) where a line starts after a terminator inside `data`."""
    starts = []
    i, n = 0, len(data)
    while i < n:
        c = data[i]
        if c == 0x0A:
            starts.append(base + i + 1)
        elif c == 0x0D:
            if i + 1 < n and data[i + 1] == 0x0A:
                i += 1
            starts.append(base + i + 1)
        i += 1
    return starts


def _utf16_len(data: bytes) -> int:
    text = data.decode("utf-8", errors="replace")
    return sum(2 if ord(ch) > 0xFFFF else 1 for ch in text)


def _is_continuation(byte: int) -> bool:
    return byte & 0xC0 == 0x80


class LineIndex:
    def __init__(self, data: bytes):
        self.data = bytearray(data)
        self.starts = [0] + _line_starts(self.data)

    def line_count(self) -> int:
        """Number of lines; a buffer ending in a terminator has an empty last line after it."""
        return len(self.starts)

    def _content_end(self, line: int) -> int:
        """Offset where `line`'s text ends (its terminator, or the end of the buffer)."""
        end = self.starts[line + 1] if line + 1 < len(self.starts) else len(self.data)
        if end > self.starts[line] and line + 1 < len(self.starts):
            end -= 1
            if end > self.starts[line] and self.data[end] == 0x0A and self.data[end - 1] == 0x0D:
                end -= 1
        return end

    def line_col(self, offset: int) -> tuple[int, int]:
        """(line, column) of byte `offset`. Offsets are clamped to [0, len(buffer)]. An offset inside a
        multi-byte character means that character's start; an offset inside a line's terminator (between the
        "\\r" and "\\n" of a CRLF) means the end of that line's text."""
        offset = max(0, min(offset, len(self.data)))
        while offset < len(self.data) and offset > 0 and _is_continuation(self.data[offset]):
            offset -= 1
        line = bisect_right(self.starts, offset) - 1
        offset = min(offset, self._content_end(line))
        return line, _utf16_len(bytes(self.data[self.starts[line]:offset]))

    def offset(self, line: int, col: int) -> int:
        """Byte offset of (line, col). A line past the last means the end of the buffer; a column past the end
        of the line's text means the end of its text; a column inside a surrogate pair means that character's
        start."""
        if line >= len(self.starts):
            return len(self.data)
        pos, end = self.starts[line], self._content_end(line)
        units = 0
        text = bytes(self.data[pos:end]).decode("utf-8", errors="replace")
        for ch in text:
            w = 2 if ord(ch) > 0xFFFF else 1
            if units + w > col:
                break
            units += w
            pos += len(ch.encode("utf-8"))
        return min(pos, end)

    def line_text(self, line: int) -> bytes:
        """The bytes of `line` without its terminator."""
        return bytes(self.data[self.starts[line]:self._content_end(line)])

    def apply_edit(self, start: int, end: int, new: bytes) -> None:
        """Replace bytes [start, end) with `new` and update the index."""
        if not 0 <= start <= end <= len(self.data):
            raise ValueError("bad edit range")
        delta = len(new) - (end - start)
        self.data[start:end] = new
        first = bisect_right(self.starts, start)
        last = bisect_right(self.starts, end)
        self.starts[first:last] = _line_starts(new, start)
        tail = first + len(_line_starts(new, start))
        for k in range(tail, len(self.starts)):
            self.starts[k] += delta
