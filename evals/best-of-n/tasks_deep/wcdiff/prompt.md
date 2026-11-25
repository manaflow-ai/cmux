Fix `diff_lines` in `wcdiff.py`, the line diff behind the agent's "changes" panel and `cmux diff`.

Bug report: "Opening the changes panel on a 4,000-line generated file where the agent touched two lines froze
the app for several seconds, and on bigger files it never came back."

Contract: `diff_lines` keeps every documented property of its edit scripts (see the module docstring: minimal,
the "\r" rule, which side "=" lines come from, the order inside a run of changes), and its cost grows with the
size of the inputs plus the product of the input size and the number of changed lines, never with the product of
the two file sizes: two 4,000-line inputs that differ in any 8 lines, wherever those lines are, diff in well
under half a second. `diff_text`, `stats` and `hunks` keep working on its scripts as they do today.
