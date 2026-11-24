Fix the width handling in `ansiwrap.py`, the text helpers behind the status bar and the agent transcript pane.

Bug report: "The right-hand column of the session list is ragged. Session names come in coloured
(`\x1b[32mmain\x1b[0m`) and `pad(name, 20)` gives back something that only takes 11 cells on screen, so everything
after it shifts left. Names in Japanese are off the other way."

Contract: every width this module takes or reports is in terminal cells, as `display_width` counts them: escape
sequences (as `ANSI_RE` matches them) take no cells, a character takes `char_width(ch)` cells (2 for East Asian wide
and fullwidth characters). No function may cut through an escape sequence or emit only part of a wide character, and
none drops an escape sequence of its input: shortening text removes visible characters only. Each function keeps its
documented behavior (alignment, ellipsis, greedy wrapping, the `ValueError`) with widths measured this way; a result
that is documented to fit `width` cells never takes more.
