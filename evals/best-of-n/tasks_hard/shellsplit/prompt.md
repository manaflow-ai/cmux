Implement `split(s: str) -> list[str]` in `shellsplit.py`: split a command line into words the way a POSIX shell
does for quoting (no expansion of variables, globs or anything else; do not use `shlex`).

- Words are separated by unquoted blanks (space, tab, newline). Empty quoted strings are words: `a '' b` is
  `["a", "", "b"]`, and adjacent pieces join: `a'b'"c"` is `["abc"]`.
- Single quotes: everything literal up to the next `'`, backslashes included.
- Double quotes: literal except that a backslash escapes only `$`, `` ` ``, `"`, `\` and newline; backslash-newline
  inside double quotes is removed entirely (line continuation); a backslash before any other character stays
  (`"a\b"` is `a\b`).
- Unquoted backslash: escapes the next character (it is kept literally, the backslash dropped); backslash-newline is
  removed entirely (joins lines, does not split a word: `ab\<newline>cd` is `abcd`). A trailing lone backslash is an
  error.
- Comments: an unquoted `#` that starts a word (at the start or after a blank) begins a comment to the end of the
  line (newline included is a separator, lines after it continue). A `#` inside a word (`a#b`) is literal.
- Raise ValueError for an unterminated quote or a trailing backslash.
