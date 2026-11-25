"""Style runs for one terminal line or one chat message: which cells carry which style (or link, or highlight).

A SpanMap maps integer cell positions to values. Ranges are half-open, [start, end). A position nobody painted has
no value (None). Values are compared with ==.
"""
from bisect import bisect_right


class _Ends:
    """A read-only sequence view of the runs' end positions, for bisect."""

    def __init__(self, spans):
        self._spans = spans

    def __len__(self):
        return len(self._spans)

    def __getitem__(self, i):
        return self._spans[i][1]


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
        spans = self._spans
        # Runs that overlap or touch [start, end): only these can change.
        lo = bisect_right(self._ends, start - 1)  # first run with end >= start
        hi = bisect_right(spans, end, key=lambda t: t[0])  # runs before hi have start <= end
        mid = []
        for s, e, v in spans[lo:hi]:
            if s < start:
                mid.append((s, min(e, start), v))
            if e > end:
                mid.append((max(s, end), e, v))
        if value is not None:
            mid.append((start, end, value))
        mid.sort(key=lambda t: t[0])
        self._splice(lo, hi, self._merge(mid))

    @property
    def _ends(self):
        return _Ends(self._spans)

    def _splice(self, lo, hi, mid):
        """Replace runs [lo, hi) with `mid`, joining with equal neighbours that touch."""
        spans = self._spans
        if mid and lo > 0 and spans[lo - 1][1] == mid[0][0] and spans[lo - 1][2] == mid[0][2]:
            lo -= 1
            mid[0] = (spans[lo][0], mid[0][1], mid[0][2])
        if mid and hi < len(spans) and spans[hi][0] == mid[-1][1] and spans[hi][2] == mid[-1][2]:
            mid[-1] = (mid[-1][0], spans[hi][1], mid[-1][2])
            hi += 1
        spans[lo:hi] = mid

    @staticmethod
    def _merge(spans):
        out = []
        for s, e, v in spans:
            if out and out[-1][2] == v and s <= out[-1][1]:
                ps, pe, _ = out[-1]
                out[-1] = (ps, max(pe, e), v)
            else:
                out.append((s, e, v))
        return out

    def get(self, pos: int):
        """The value at `pos`, or None."""
        i = bisect_right(self._spans, pos, key=lambda t: t[0]) - 1
        if i >= 0 and self._spans[i][0] <= pos < self._spans[i][1]:
            return self._spans[i][2]
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
        self._spans = self._merge(out)

    def values_in(self, start: int, end: int) -> list:
        """The distinct values painted anywhere in [start, end), in position order."""
        seen = []
        for s, e, v in self._spans:
            if s < end and e > start and v not in seen:
                seen.append(v)
        return seen
