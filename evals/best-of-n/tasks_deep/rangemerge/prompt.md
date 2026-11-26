Fix `rangemerge.py`, the style-run map behind terminal lines and chat messages.

Bug report: "A minified one-line JSON log with syntax highlighting has about 100,000 style runs. Moving the mouse
along it pegs a core: every hover asks `get` for the style under the cursor, and building the line was already
slow."

Contract: everything the docstrings say holds after any sequence of calls, in particular that `spans()` returns
maximal runs (two runs that touch never share a value), sorted and half-open, and that `insert` grows the run
just before the insertion point. `get` costs O(log n) for n runs, and `set` costs O(log n) plus the number of runs
it overlaps or touches (amortized; moving list items with one slice assignment counts as cheap): painting 100,000
runs one after another from left to right and then making 100,000 `get` calls takes under 1 s in total.
`insert`, `delete` and `values_in` may stay linear.
