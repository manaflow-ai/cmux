"""Style runs for one terminal line or one chat message: which cells carry which style (or link, or highlight).

A SpanMap maps integer cell positions to values. Ranges are half-open, [start, end). A position nobody painted has
no value (None). Values are compared with ==.
"""


class SpanMap:
    def __init__(self, spans=()):
        # Sorted (start, end, value) triples: non-empty, non-overlapping, value never None.
        self._spans: list[tuple[int, int, object]] = []
        for start, end, value in spans:
            self.set(start, end, value)

    def set(self, start: int, end: int, value) -> None:
        """Paint [start, end) with `value`, replacing what was there; `value` None clears the range.
        An empty or reversed range changes nothing."""
        if start >= end:
            return
        out = []
        for s, e, v in self._spans:
            if e <= start or s >= end:
                out.append((s, e, v))
                continue
            if s < start:
                out.append((s, start, v))
            if e > end:
                out.append((end, e, v))
        if value is not None:
            out.append((start, end, value))
        out.sort(key=lambda t: t[0])
        self._spans = self._merge(out)

    @staticmethod
    def _merge(spans):
        out = []
        for s, e, v in spans:
            if out and out[-1][2] == v and s < out[-1][1]:
                ps, pe, _ = out[-1]
                out[-1] = (ps, max(pe, e), v)
            else:
                out.append((s, e, v))
        return out

    def get(self, pos: int):
        """The value at `pos`, or None."""
        for s, e, v in self._spans:
            if s <= pos < e:
                return v
            if s > pos:
                break
        return None

    def spans(self) -> list[tuple[int, int, object]]:
        """The painted runs as (start, end, value), sorted, each maximal: two runs that touch never share a value."""
        return list(self._spans)

    def insert(self, pos: int, count: int) -> None:
        """Insert `count` cells before `pos` (typing). Cells at or after `pos` move right by `count`. The new cells
        take the value of the cell just before `pos` (the run you are typing at the end of keeps growing), or None
        when `pos` is 0 or that cell has no value."""
        if count <= 0:
            return
        out = []
        for s, e, v in self._spans:
            if e < pos:
                out.append((s, e, v))
            elif s < pos <= e:
                out.append((s, e + count, v))
            else:
                out.append((s + count, e + count, v))
        self._spans = out

    def delete(self, pos: int, count: int) -> None:
        """Remove the `count` cells [pos, pos + count); cells after them move left by `count`."""
        if count <= 0:
            return
        end = pos + count
        out = []
        for s, e, v in self._spans:
            if e <= pos:
                out.append((s, e, v))
            elif s >= end:
                out.append((s - count, e - count, v))
            else:
                ns = min(s, pos)
                ne = max(pos, e - count)
                if ne > ns:
                    out.append((ns, ne, v))
        self._spans = out

    def values_in(self, start: int, end: int) -> list:
        """The distinct values painted anywhere in [start, end), in position order."""
        seen = []
        for s, e, v in self._spans:
            if s < end and e > start and v not in seen:
                seen.append(v)
        return seen
