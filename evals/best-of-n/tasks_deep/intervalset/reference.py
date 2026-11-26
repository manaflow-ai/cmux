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
        iv = self._iv
        # First interval that ends at or after start (touching merges).
        lo = bisect_left(iv, (start,))
        if lo > 0 and iv[lo - 1][1] >= start:
            lo -= 1
        hi = lo
        while hi < len(iv) and iv[hi][0] <= end:
            hi += 1
        if lo < hi:
            start = min(start, iv[lo][0])
            end = max(end, iv[hi - 1][1])
        iv[lo:hi] = [(start, end)]

    def remove(self, start, end):
        """Remove [start, end) from the set."""
        if start >= end:
            return
        iv = self._iv
        lo = bisect_left(iv, (start,))
        if lo > 0 and iv[lo - 1][1] > start:
            lo -= 1
        hi = lo
        while hi < len(iv) and iv[hi][0] < end:
            hi += 1
        repl = []
        if lo < hi:
            s, e = iv[lo]
            if s < start:
                repl.append((s, start))
            s, e = iv[hi - 1]
            if end < e:
                repl.append((end, e))
        iv[lo:hi] = repl

    def contains(self, x):
        """Is the integer x in the set?"""
        i = bisect_left(self._iv, (x + 1,)) - 1
        if i < 0:
            return False
        s, e = self._iv[i]
        return s <= x < e

    def overlaps(self, start, end):
        """Does [start, end) share any integer with the set?"""
        if start >= end:
            return False
        i = bisect_left(self._iv, (end,)) - 1
        return i >= 0 and self._iv[i][1] > start

    def covers(self, start, end):
        """Is all of [start, end) in the set? An empty range is always covered."""
        if start >= end:
            return True
        i = bisect_left(self._iv, (start + 1,)) - 1
        return i >= 0 and self._iv[i][1] >= end

    def complement(self, lo, hi):
        """The gaps of the set within [lo, hi), as a new IntervalSet."""
        gaps = IntervalSet()
        prev = lo
        for s, e in self._iv:
            if e <= lo:
                continue
            if s >= hi:
                break
            if s > prev:
                gaps._iv.append((prev, s))
            prev = max(prev, e)
        if prev < hi:
            gaps._iv.append((prev, hi))
        return gaps

    def intersection(self, other):
        """The integers in both sets, as a new IntervalSet."""
        out = IntervalSet()
        a, b = self._iv, list(other)
        i = j = 0
        while i < len(a) and j < len(b):
            lo, hi = max(a[i][0], b[j][0]), min(a[i][1], b[j][1])
            if lo < hi:
                out._iv.append((lo, hi))
            if a[i][1] < b[j][1]:
                i += 1
            else:
                j += 1
        return out

    def first_fit(self, length, lo, hi):
        """The smallest start x >= lo with [x, x + length) entirely outside the set and x + length <= hi, or None.

        The scheduler books a `length`-minute slot in the first free time of the day [lo, hi).
        """
        if length <= 0:
            raise ValueError("length must be positive")
        for s, e in self.complement(lo, hi):
            if e - s >= length:
                return s
        return None

    def union(self, other):
        out = IntervalSet(self._iv)
        for s, e in other:
            out.add(s, e)
        return out
