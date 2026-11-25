Fix the scrollback buffer in `scrollback.py`.

Bug report: "In a 10-column pane with the default capacity I printed three lines, `hello`, a 25-character build log
line and `done`. `lines()` shows the three lines, but `line_count()` says 5."

Contract. Lines are the program's logical lines; rows are what the pane draws at its width. A logical line of
length n occupies max(1, ceil(n / width)) rows, so an empty line still takes one row. `capacity` counts logical
lines: the buffer keeps the newest `capacity` logical lines, evicting whole logical lines oldest first, never part of
one. Line indexes and columns refer to logical lines, independent of the width: `search` finds a needle anywhere in a
logical line, wherever the rows break it. `resize` reflows the same logical lines to the new width; it never changes
what `lines()` returns. Panes stream a lot: `append` and `line_count` must cost about the same whether the buffer holds ten lines or
its full capacity (a pane keeping 3,000 lines that receives 60,000, with `line_count()` read after each, finishes
well under a second).
