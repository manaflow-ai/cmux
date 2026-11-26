"""POSIX shell quoting for commands cmux types into a terminal or sends over ssh.

`quote`/`join` build a command line a POSIX `sh` reads back as the same argv; `split` reads one the way `sh` does
(word splitting on unquoted blanks, single quotes, double quotes, backslashes; no expansion, no globbing).
"""
import re

_SAFE = re.compile(r"[A-Za-z0-9@%+=:,./_-]+")
_BLANKS = " \t\n"
# Inside double quotes a backslash escapes only these; before anything else it is a literal backslash.
_DQ_ESCAPABLE = '$`"\\\n'


def quote(arg: str) -> str:
    """`arg` as one shell word: unchanged when it is non-empty and only safe characters, else single-quoted."""
    if arg and _SAFE.fullmatch(arg):
        return arg
    return "'" + arg.replace("'", "'\"'\"'") + "'"


def join(argv) -> str:
    """One command line that `sh` splits back into `argv`."""
    return " ".join(quote(a) for a in argv)


def env_prefix(env: dict) -> str:
    """`K=V` assignments to put before a command, in `env`'s order. Keys must be valid shell names."""
    parts = []
    for key, value in env.items():
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            raise ValueError(f"not a shell variable name: {key!r}")
        parts.append(f"{key}={quote(value)}")
    return " ".join(parts)


def command_line(argv, env=None, cwd=None) -> str:
    """What cmux types to run `argv` in `cwd` with extra `env`: `cd DIR && K=V ... argv...`."""
    line = join(argv)
    if env:
        line = env_prefix(env) + " " + line
    if cwd is not None:
        line = "cd " + quote(cwd) + " && " + line
    return line


def ssh_argv(host: str, argv) -> list[str]:
    """argv for `ssh` to run `argv` on `host`: the remote shell gets one command line."""
    return ["ssh", "-t", host, "--", join(argv)]


def split(line: str) -> list[str]:
    """`line` split into words the way POSIX `sh` does it. Raises ValueError on an unterminated quote or a
    trailing backslash."""
    words: list[str] = []
    word: list[str] = []
    in_word = False  # a quoted empty string still makes a word
    i, n = 0, len(line)
    while i < n:
        c = line[i]
        if c in _BLANKS:
            if in_word:
                words.append("".join(word))
                word, in_word = [], False
            i += 1
        elif c == "\\":
            if i + 1 >= n:
                raise ValueError("trailing backslash")
            if line[i + 1] != "\n":  # backslash-newline is a line continuation
                word.append(line[i + 1])
                in_word = True
            i += 2
        elif c == "'":
            end = line.find("'", i + 1)
            if end < 0:
                raise ValueError("unterminated single quote")
            word.append(line[i + 1:end])
            in_word = True
            i = end + 1
        elif c == '"':
            i += 1
            while True:
                if i >= n:
                    raise ValueError("unterminated double quote")
                c = line[i]
                if c == '"':
                    i += 1
                    break
                if c == "\\" and i + 1 < n and line[i + 1] in _DQ_ESCAPABLE:
                    if line[i + 1] != "\n":
                        word.append(line[i + 1])
                    i += 2
                    continue
                word.append(c)
                i += 1
            in_word = True
        else:
            word.append(c)
            in_word = True
            i += 1
    if in_word:
        words.append("".join(word))
    return words
