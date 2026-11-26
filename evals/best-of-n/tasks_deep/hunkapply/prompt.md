Fix `apply` in `hunkapply.py`, which applies model-written unified diffs to files that may have drifted since the
model read them.

Bug report: a patch had two hunks. The first added three import lines at the top of the file; the second changed
`return None` to `return 0` in `b()`. The result changed the `return None` in `a()`, a few lines above, instead.

Contract:
- A header `@@ -a,b +c,d @@` says the hunk's old lines (context and `-` lines, `b` of them) start at line `a`
  (1-based) of the original file and its new lines (context and `+`) number `d`. A count left out of the header
  means 1. With `b` = 0 the hunk inserts its lines after line `a` (`a` = 0 inserts at the top).
- Hunks apply in order, each to the result of the ones before it. A hunk is expected at its header position moved
  by everything the earlier hunks did: for each earlier hunk, the lines it added minus the lines it removed, plus the
  drift at which it was found (found position minus the position it was expected at).
- The search tries the expected position, then 1 line before it, 1 after, 2 before, 2 after, and so on up to
  `max_offset`; the first position where the hunk's old lines match exactly wins. A hunk never matches at a position
  that overlaps lines an earlier hunk wrote, or lies before them. No match raises `HunkFailed` with that hunk's
  0-based `index`.
- Keep the public API as it is.
