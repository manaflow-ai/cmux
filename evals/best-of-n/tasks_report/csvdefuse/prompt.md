# Team audit CSV runs formulas when opened in a spreadsheet (CSV injection)

The team audit export saves the CSV to Downloads exactly as the platform sent it, and its cells hold text teammates
control (session titles, names). A teammate renamed a session to `=HYPERLINK("http://x")` and it opened as a live link
in my spreadsheet; `+cmd|' /C calc'!A0` is the classic version of the same thing.

`defuse_formulas(body)` in `csvdefuse.py` runs on the CSV right before it is saved, and today returns it untouched.
Cells that a spreadsheet would run as a formula (the characters OWASP's CSV injection guidance lists) should open as
text, the usual way, with a `'` in front. Please don't break the rest: the cost column has negative numbers such as
`-12.5` that must stay numbers, the file has quoted cells (with commas, `""` and line breaks inside) and both `\r\n`
and `\n` line ends, and nothing else in it may change.
