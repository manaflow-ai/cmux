Fix the pane split tree in `splittree.py`.

Bug report: "I split pane `a` to the right (got `b`), then split `b` to the right (got `c`): three panes, 50/25/25,
fine. Then I asked for `c` to take half the window with `resize("c", 0.5)` and it only took half of the right half.
All three panes sit side by side, so they should be one row of siblings."

Contract. After every public call the tree is normalized: every split has at least two children, its ratios are
positive and sum to 1, and no split has a child split of the same orientation (those panes are direct children of
the outer split, each keeping its share of the window). `split(pane, o, new)` places `new` right after `pane` and
gives each of them half of `pane`'s share; nothing else changes size. `close(pane)` gives the closed pane's whole share
to one sibling, the one that followed it in its split (the one before it when it was the last child), and no other
size changes; a split left with one child is replaced by that child, which takes over
the split's share. Focus changes only when `split` focuses the new pane, or when the focused pane is closed: then it
moves to the pane that followed it in `leaves()` order, or the one before it if it was last. `snapshot()`,
`layout()`, `swap()` and `resize()` keep their documented behavior.
