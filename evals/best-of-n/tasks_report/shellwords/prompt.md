# `"X=1" gh` is read as an env assignment, but bash runs a program named `X=1`

`split_command(line)` in `shellwords.py` reads one simple shell command the way bash does and returns
`(assignments, argv)`: the `NAME=value` prefix assignments and the program with its arguments, all unquoted. We use it
to decide which program a command runs.

For `"X=1" gh` it returns `(["X=1"], ["gh"])`, but bash does not treat that word as an assignment: it runs a program
named `X=1` with the argument `gh`. Bash decides whether a word is an assignment before it removes quotes, so quoting
or escaping any part of the name or of the operator makes it an ordinary word. A command can hide the program it runs
this way, so this is a security bug. A quoted value is still an assignment (`X="a b" gh`), and so are bash's other
assignment forms (`X+=1`, `X[0]=1`).
