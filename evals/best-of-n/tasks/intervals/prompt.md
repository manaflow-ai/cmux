Implement `merge(intervals: list[tuple[int, int]]) -> list[tuple[int, int]]` and `subtract(a, b)` in `intervals.py`.
Intervals are half-open `[start, end)` with start < end; raise ValueError for any interval with start >= end.
`merge` returns the sorted, minimal list covering the same points: overlapping intervals merge, and so do touching
ones (`(1,3)` and `(3,5)` give `(1,5)`). `subtract(a, b)` returns the points covered by list `a` and not by list `b`,
merged and sorted, as the same kind of list. Do not mutate the inputs.
