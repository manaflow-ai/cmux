Fix `undotree.py`, the undo tree behind the composer and the notes pane.

Bug reports:
1. "I picked an older version from the history list, pressed Cmd-Z and then Cmd-Shift-Z, and ended up on the
   other branch instead of where I was."
2. "In a note I've been editing all day, holding Cmd-Shift-Z to redo crawls."

Contract: everything the module docstring says holds after any sequence of calls. `undo` and `redo`
each cost O(1), `commit` costs O(number of children of the current node), `goto` costs O(depth of the target), and `children` costs O(number of children):
100,000 commits (with a branch every tenth one), then undoing to the start and redoing to the end, take under
1 s in total.
