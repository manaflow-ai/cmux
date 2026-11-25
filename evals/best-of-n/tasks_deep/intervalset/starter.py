"""A set of integers stored as sorted, disjoint half-open intervals [start, end).

The scheduler uses it for busy time (in minutes since midnight) and the
byte-range cache uses it for which ranges of a blob are already on disk.
"""

from bisect import bisect_left


class IntervalSet:
    def __init__(self, intervals=()):
        # Sorted, disjoint, non-adjacent (start, end) pairs with start < end.
        self._iv = []
        for start, end in intervals:
            self.add(start, end)

    def __iter__(self):
        return iter(list(self._iv))

    def __len__(self):
        return len(self._iv)

    def __eq__(self, other):
        return isinstance(other, IntervalSet) and self._iv == other._iv

    def __repr__(self):
        return "IntervalSet(%r)" % (self._iv,)

    def total(self):
        """How many integers the set covers."""
        return sum(e - s for s, e in self._iv)

    def add(self, start, end):
        """Add [start, end). Empty ranges (start >= end) are ignored."""
        if start >= end:
            return
        out = []
        placed = False
        for s, e in self._iv:
            if e < start:
                out.append((s, e))
            elif end < s:
                if not placed:
                    out.append((start, end))
                    placed = True
                out.append((s, e))
            else:
                # Overlapping or touching: absorb into the new range.
                start = min(start, s)
                end = max(end, e)
        if not placed:
            out.append((start, end))
        self._iv = out

    def remove(self, start, end):
        """Remove [start, end) from the set."""
        if start >= end:
            return
        out = []
        for s, e in self._iv:
            if e <= start or end <= s:
                out.append((s, e))
                continue
            if s < start:
                out.append((s, start - 1))
            if end < e:
                out.append((end + 1, e))
        self._iv = out

    def contains(self, x):
        """Is the integer x in the set?"""
        i = bisect_left(self._iv, (x + 1,)) - 1
        if i < 0:
            return False
        s, e = self._iv[i]
        return s <= x <= e

    def overlaps(self, start, end):
        """Does [start, end) share any integer with the set?"""
        if start >= end:
            return False
        for s, e in self._iv:
            if s <= end and start <= e:
                return True
        return False

    def covers(self, start, end):
        """Is all of [start, end) in the set? An empty range is always covered."""
        if start >= end:
            return True
        for s, e in self._iv:
            if s <= start and end <= e:
                return True
        return False

    def complement(self, lo, hi):
        """The gaps of the set within [lo, hi), as a new IntervalSet."""
        gaps = IntervalSet()
        prev = lo
        for s, e in self._iv:
            if e <= lo:
                continue
            if s >= hi:
                break
            gaps._iv.append((prev, s))
            prev = max(prev, e)
        if prev < hi:
            gaps._iv.append((prev, hi))
        return gaps

    def intersection(self, other):
        """The integers in both sets, as a new IntervalSet."""
        out = IntervalSet()
        for s1, e1 in self._iv:
            for s2, e2 in other:
                lo, hi = max(s1, s2), min(e1, e2)
                if lo <= hi:
                    out._iv.append((lo, hi))
        return out

    def first_fit(self, length, lo, hi):
        """The smallest start x >= lo with [x, x + length) entirely outside the set and x + length <= hi, or None.

        The scheduler books a `length`-minute slot in the first free time of the day [lo, hi).
        """
        if length <= 0:
            raise ValueError("length must be positive")
        for s, e in self.complement(lo, hi):
            if e - s > length:
                return s
        return None

    def union(self, other):
        out = IntervalSet(self._iv)
        for s, e in other:
            out.add(s, e)
        return out
