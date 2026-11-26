Fix `defuse_formulas` in `csvdefuse.py`. It runs on a team audit CSV just before the file is saved to the person's
Downloads folder.

Bug report (from cmux commit 8c14cae03c5, CMUX-284): the platform's CSV went to Downloads exactly as it came, so a cell
a teammate controls (a session title, a name) that starts with `=`, `+`, `-` or `@` ran as a formula when the file was
opened in a spreadsheet app (`=HYPERLINK(...)`, `+cmd|' /C calc'!A0`).

`defuse_formulas(body: str) -> str` returns the CSV with every cell a spreadsheet would read as a formula made text by
a leading `'`, and every other character unchanged:

- Quoting is RFC 4180's: a cell that starts with `"` is quoted and runs to the next `"` that is not doubled (`""` is an
  escaped quote inside it); inside a quoted cell commas, `\r` and `\n` are part of the cell. Outside quotes, `,` ends a
  cell and `\r` and `\n` end a cell (and the row). A row may end in `\r\n` or `\n`; the last line may have no newline.
- A cell is risky when its first character is `=`, `@` or a tab; or `+` or `-` unless the cell is a plain number; or,
  only in a quoted cell, a carriage return `\r`.
- A plain number is an optional `+` or `-`, then one or more ASCII digits, then optionally `.` and one or more ASCII
  digits (`-12.5`, `+3`, `7`; not `-`, `-1.`, `+.5`, `-2+3`, `1e5`). For an unquoted cell, the text checked is the
  cell up to its end; for a quoted cell, the text from after the opening quote up to the next `"`.
- The `'` goes right before the cell's first character: for a quoted cell, after the opening quote (`"'=1+1"`). An
  empty cell is never risky.
- A CSV with nothing risky comes back as the same string.
