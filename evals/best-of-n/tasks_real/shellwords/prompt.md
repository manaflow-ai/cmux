Fix `split_command(line: str) -> tuple[list[str], list[str]]` in `shellwords.py`. It reads one simple shell command
the way bash does and returns `(assignments, argv)`: the prefix assignments bash runs before the program (as their
unquoted text), and the program word with its arguments (also unquoted).

Bug report (from cmux commit c3d4bcc07c4, "fail closed on quoted assignment-looking shell words", and its parent
ac7ee06df78, "preserve shell quoting at the grammar level"): the function unquotes every word first and then asks
whether the unquoted text looks like `NAME=value`. Bash decides which words are assignments from the quoting, so
`"X=1" gh` runs a program named `X=1` with the argument `gh`, but the function reported `X=1` as an assignment and
`gh` as the program.

The rules:

- Words: unquoted spaces, tabs and newlines separate words. A backslash outside quotes takes the next character
  literally (a backslash-newline pair is removed). Single quotes keep everything up to the next `'` literally. In
  double quotes a backslash escapes only `"`, `\`, `$` and a backquote (and a backslash-newline pair is removed);
  before any other character the backslash stays. Quotes join with the text around them (`a"b c"d` is one word
  `ab cd`). `''` and `""` make an empty word when nothing else is in it. No expansion happens: `$X`, `*`, `~`, `#`
  are kept as text. A quote that is never closed, or a backslash at the very end, raises ValueError.
- Assignments: words at the start of the command are assignments while each one is, in its raw (still quoted) form,
  `NAME=...`, `NAME+=...`, `NAME[SUB]=...` or `NAME[SUB]+=...`, where NAME is `[A-Za-z_][A-Za-z0-9_]*` and is
  written with no quote or backslash in or before it (even an empty `''X=1` is not an assignment), and the `[`, the `]` that closes the subscript, and the operator (`=` or
  `+=`) are themselves unquoted and unescaped. Only the subscript may hold quoted or escaped text (`X["a=b"]=v` is an
  assignment, read as `X[a=b]=v`), and it must not be empty; the closing `]` is the first unquoted `]` after the `[`.
  The value after the operator may hold any quoting.
- The first word that is not an assignment is the program; it and every word after it are `argv`, even ones that look
  like assignments. A command of assignments only has an empty `argv`; an empty or blank line gives `([], [])`.
