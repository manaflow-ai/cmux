Fix `lineindex.py`, the byte offset <-> (line, column) index behind scrollback search and the editor pane's LSP
bridge.

Bug report: "Search in a 2 MB build log is unusable: every hit has to be turned into a line:column for the
results list, and 100,000 hits take minutes. Go-to-offset in the status bar lags the same way."

Contract: positions follow the conventions in the module docstring and the method docstrings exactly (line
terminators, UTF-16 columns, clamping and snapping). `line_col` and `offset` each cost O(log L) plus the length of
the one line involved, for a buffer of L lines: 50,000 `line_col` calls and 50,000 `offset` calls on a 2 MB buffer
of 40,000 lines finish in under 1 s each. After any sequence of `apply_edit` calls, every method answers exactly as
a fresh `LineIndex` of the current bytes would; an edit may land anywhere, including between the "\r" and "\n" of a
CRLF or right beside one.
