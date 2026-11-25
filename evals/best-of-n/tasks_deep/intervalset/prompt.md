Fix the boundary handling in `intervalset.py`, the integer interval set behind our scheduler's busy time.

Bug report: I have a meeting booked 540-600 (9:00 to 10:00, in minutes) and tried to book 600-660 right after it.
The scheduler refused: `busy.overlaps(600, 660)` returned `True`. Back-to-back meetings are the most common booking
we have.

Contract: every interval in this module, whether stored, passed in or returned, is half-open: `(start, end)` means
the integers `x` with `start <= x < end`, and is empty when `start >= end`. Every method answers exactly as if the
set were the plain set of integers it covers: `contains`, `overlaps`, `covers`, `add`, `remove`, `complement`,
`intersection`, `union` and `total` are membership, intersection, subset, union, difference, the difference
`[lo, hi)` minus the set, intersection, union and size; `first_fit` is the smallest qualifying start its docstring
describes. What iteration yields is always the canonical form of that integer set: sorted, disjoint, non-empty
intervals with adjacent ones merged (`(0, 5)` and `(5, 9)` are stored as `(0, 9)`). Keep the public API as it is.

The scheduler keeps a year of bookings in one set: building a set from 50,000 `add` calls in random order, then
running 50,000 mixed `contains`, `overlaps`, `covers` and `remove` calls on it, must take under one second, and intersecting two sets of 3,000 intervals each must take well under one second.
