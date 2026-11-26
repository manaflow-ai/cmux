Fix the quoting round trip in `argvquote.py`, which builds the command lines cmux types into terminals and sends
over ssh, and reads saved command lines back.

Bug report: "Re-running a saved task `git commit --allow-empty -m ''` ran `git commit --allow-empty -m` with no
message, and git opened an editor in the agent's terminal. The empty argument just vanished: `join` gave back
`git commit --allow-empty -m ` with a trailing space."

Contract: for every list of strings `argv`, a POSIX `sh` reading `join(argv)` (or `quote(a)` for one string, or the
lines `command_line` and `ssh_argv` build) gets exactly `argv` back, and so does `split(join(argv))`. `quote` returns
its argument unchanged when it is non-empty and made only of the characters in `_SAFE`; otherwise any correct
quoting is fine. `split` reads any command line the way POSIX `sh` word-splits it (blanks, single quotes, double
quotes, backslashes, with no expansion), and raises `ValueError` on an unterminated quote or a trailing backslash.
